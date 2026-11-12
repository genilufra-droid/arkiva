-- =====================================================================
-- FAZA 2 · «PËRCILL TE» — delegimet, sektorët dhe linkjet e jashtme
-- Ekzekutohet PAS schema_libri.sql. Idempotent.
-- Përmban: tabelat sectors/delegations/external_links + RLS, gjurmimin,
-- email-njoftimin e përcjelljes (Brevo) dhe kujtesën e afateve të trajtimit.
-- ✅ EKZEKTUAR në DB më 12/11/2026 (statement pas statement-i përmes
--    connector-it Supabase) + verifikuar me smoke test të plotë.
--    Edge function shoqërues: functions/delegim-jashtme.js (deployuar,
--    verify_jwt=false) — faqja publike #/link/<token> për të jashtmit.
-- =====================================================================

-- ---------- 1 · sektorët/njësitë ----------
create table if not exists public.sectors (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.sectors enable row level security;
drop policy if exists sectors_select on public.sectors;
create policy sectors_select on public.sectors for select to authenticated using (true);
drop policy if exists sectors_insert on public.sectors;
create policy sectors_insert on public.sectors for insert to authenticated with check (public.user_can('regjistro'));
drop policy if exists sectors_update on public.sectors;
create policy sectors_update on public.sectors for update to authenticated
  using (public.user_can('ndrysho')) with check (public.user_can('ndrysho'));

-- ---------- 2 · delegimet (përcjelljet) ----------
create table if not exists public.delegations (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.correspondence(id) on delete cascade,
  from_user uuid references auth.users(id),
  to_sector uuid references public.sectors(id),
  to_user uuid references auth.users(id),
  note text,
  status text not null default 'ne_pritje' check (status in ('ne_pritje','ne_trajtim','mbyllur','anuluar')),
  due_date date,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  closed_at timestamptz,
  closed_note text,
  reminded3_at timestamptz,
  reminded0_at timestamptz
);
create index if not exists delegations_doc_idx on public.delegations (document_id, created_at);
create index if not exists delegations_user_idx on public.delegations (to_user, status);
alter table public.delegations enable row level security;
drop policy if exists deleg_select on public.delegations;
create policy deleg_select on public.delegations for select to authenticated using (true);
drop policy if exists deleg_insert on public.delegations;
create policy deleg_insert on public.delegations for insert to authenticated with check (public.user_can('regjistro'));
drop policy if exists deleg_update on public.delegations;
-- përditësim: drejtuesi/regjistruesi me të drejtë ndryshimi, ose vetë i përcjelluri (pranon/mbyll trajtimin e vet)
create policy deleg_update on public.delegations for update to authenticated
  using (public.user_can('ndrysho') or to_user = auth.uid())
  with check (public.user_can('ndrysho') or to_user = auth.uid());

-- ---------- 3 · linkjet e jashtme (delegim me link, 60 minuta) ----------
create table if not exists public.external_links (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.correspondence(id) on delete cascade,
  token text not null unique default encode(gen_random_bytes(18),'hex'),
  created_by uuid references auth.users(id),
  expires_at timestamptz not null default now() + interval '60 minutes',
  used_at timestamptz,
  name text,
  note text,
  signature_data text,
  created_at timestamptz not null default now()
);
create index if not exists xlinks_doc_idx on public.external_links (document_id, created_at);
alter table public.external_links enable row level security;
-- anon s'ka asgjë: leximi/shkrimi nga të jashtmit bëhet VETËM nga edge function «delegim-jashtme» (service role)
drop policy if exists xlink_select on public.external_links;
create policy xlink_select on public.external_links for select to authenticated using (true);
drop policy if exists xlink_insert on public.external_links;
create policy xlink_insert on public.external_links for insert to authenticated with check (public.user_can('regjistro'));
drop policy if exists xlink_update on public.external_links;
create policy xlink_update on public.external_links for update to authenticated
  using (public.user_can('regjistro')) with check (public.user_can('regjistro'));

-- ---------- 4 · stafi i lexueshëm nga të gjithë të autentikuarit ----------
-- (dropdown-i «Personi përgjegjës» në formën e protokollimit;
--  më parë profili lexohej vetëm nga vetja/admini)
drop policy if exists profiles_self_read on public.profiles;
create policy profiles_self_read on public.profiles for select to authenticated using (true);

-- ---------- 5 · gjurmimi i delegimeve dhe i linkjeve ----------
create or replace function public.log_deleg_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,document_id,detail)
    values (auth.uid(), public.current_user_name(), 'dokument_percjelle', new.document_id,
      coalesce((select name from public.sectors where id = new.to_sector), '—')
      || case when new.to_user is not null then ' · ' || coalesce((select full_name from public.profiles where id = new.to_user), 'person') else '' end
      || case when new.due_date is not null then ' · afati ' || to_char(new.due_date,'DD/MM/YYYY') else '' end);
  elsif new.status is distinct from old.status then
    insert into public.activity_log(user_id,user_name,action,document_id,detail)
    values (auth.uid(), public.current_user_name(),
      case new.status when 'ne_trajtim' then 'trajtim_pranuar' when 'mbyllur' then 'trajtim_mbyllur' else 'percjellje_anuluar' end,
      new.document_id, coalesce(new.closed_note, ''));
  end if;
  return null;
end $$;
drop trigger if exists deleg_log on public.delegations;
create trigger deleg_log after insert or update on public.delegations
  for each row execute function public.log_deleg_changes();

create or replace function public.log_xlink_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_log(user_id,user_name,action,document_id,detail)
  values (auth.uid(), public.current_user_name(), 'link_jashtme_lshuar', new.document_id,
    'link për të jashtëm · skadon ' || to_char(new.expires_at,'DD/MM/YYYY HH24:MI'));
  return null;
end $$;
drop trigger if exists xlink_log on public.external_links;
create trigger xlink_log after insert on public.external_links
  for each row execute function public.log_xlink_insert();

-- ---------- 6 · email-njoftimi në çastin e përcjelljes (Brevo) ----------
create or replace function public.njofto_percjellje() returns trigger
language plpgsql security definer set search_path = public, net as $$
declare k text; snd_e text; snd_n text; em text; pn text; proto text; subj text;
begin
  if new.to_user is null then return new; end if;   /* vetëm sektori → pa email */
  select value into k from public.settings where key = 'brevo_api_key';
  if coalesce(k,'') = '' then return new; end if;
  select coalesce(value,'elektronikearkiva@gmail.com') into snd_e from public.settings where key = 'brevo_sender_email';
  select coalesce(value,'Arkiva Elektronike')         into snd_n from public.settings where key = 'brevo_sender_name';
  select u.email into em from auth.users u where u.id = new.to_user;
  if em is null then return new; end if;
  select p.full_name into pn from public.profiles p where p.id = new.to_user;
  select protocol_no, subject into proto, subj from public.correspondence where id = new.document_id;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', snd_n, 'email', snd_e),
      'to', jsonb_build_array(jsonb_build_object('email', em, 'name', coalesce(pn,''))),
      'subject', 'Të është përcjellë dokumenti ' || coalesce(proto,'—'),
      'htmlContent',
        '<html><body style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222;max-width:560px;margin:0 auto">'
        || '<div style="background:#b91c1c;color:#fff;padding:12px 18px;border-radius:8px 8px 0 0;font-weight:bold">PËRCJELLJE DOKUMENTI</div>'
        || '<div style="border:1px solid #e5e5ea;border-top:0;border-radius:0 0 8px 8px;padding:16px 18px">'
        || '<p>Të është përcjellë për trajtim dokumenti <b>' || coalesce(proto,'—') || '</b> — ' || public.htmlesc(coalesce(subj,'')) || '</p>'
        || case when coalesce(new.note,'') <> '' then '<p><i>„' || public.htmlesc(new.note) || '“</i></p>' else '' end
        || case when new.due_date is not null then '<p>Afati i trajtimit: <b>' || to_char(new.due_date,'DD/MM/YYYY') || '</b></p>' else '' end
        || '<p style="margin-top:18px"><a href="https://genilufra-droid.github.io/arkiva/#/dokument/' || new.document_id || '" style="background:#b91c1c;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Hap dokumentin</a></p>'
        || '</div><p style="color:#999;font-size:11px">Njoftim automatik i Arkivës Elektronike</p></body></html>'
    ),
    headers := jsonb_build_object('api-key', k, 'content-type','application/json', 'accept','application/json')
  );
  return new;
end $$;
drop trigger if exists trg_njofto_percjellje on public.delegations;
create trigger trg_njofto_percjellje after insert on public.delegations
  for each row execute function public.njofto_percjellje();

-- ---------- 7 · kujtesa e afateve të trajtimit: 3 ditë para + ditën e afatit ----------
create or replace function public.kujtesa_percjellje() returns jsonb
language plpgsql security definer set search_path = public, net as $$
declare k text; snd_e text; snd_n text; n int := 0; r record; proto text; subj text; lloji text;
begin
  select value into k from public.settings where key = 'brevo_api_key';
  if coalesce(k,'') = '' then return jsonb_build_object('gabim','Mungon «brevo_api_key» në public.settings.'); end if;
  select coalesce(value,'elektronikearkiva@gmail.com') into snd_e from public.settings where key = 'brevo_sender_email';
  select coalesce(value,'Arkiva Elektronike')         into snd_n from public.settings where key = 'brevo_sender_name';

  for r in
    select d.id, d.document_id, d.due_date, u.email as em, p.full_name as pn
    from public.delegations d
    join auth.users u   on u.id = d.to_user
    left join public.profiles p on p.id = d.to_user
    where d.status in ('ne_pritje','ne_trajtim')
      and d.due_date is not null
      and ( (d.due_date = current_date + 3 and d.reminded3_at is null)
         or (d.due_date = current_date     and d.reminded0_at is null) )
  loop
    select protocol_no, subject into proto, subj from public.correspondence where id = r.document_id;
    lloji := case when r.due_date = current_date then 'AFATI I TRAJTIMIT SKADON SOT' else '3 ditë deri në afatin e trajtimit' end;
    perform net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      body := jsonb_build_object(
        'sender', jsonb_build_object('name', snd_n, 'email', snd_e),
        'to', jsonb_build_array(jsonb_build_object('email', r.em, 'name', coalesce(r.pn,''))),
        'subject', case when proto is null then lloji else lloji || ' — dokumenti ' || proto end,
        'htmlContent',
          '<html><body style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222;max-width:560px;margin:0 auto">'
          || '<div style="background:#b91c1c;color:#fff;padding:12px 18px;border-radius:8px 8px 0 0;font-weight:bold">' || lloji || '</div>'
          || '<div style="border:1px solid #e5e5ea;border-top:0;border-radius:0 0 8px 8px;padding:16px 18px">'
          || '<p>Dokumenti <b>' || coalesce(proto,'—') || '</b> — ' || public.htmlesc(coalesce(subj,''))
          || ' · afati i trajtimit: <b>' || to_char(r.due_date,'DD/MM/YYYY') || '</b></p>'
          || '<p style="margin-top:18px"><a href="https://genilufra-droid.github.io/arkiva/#/dokument/' || r.document_id || '" style="background:#b91c1c;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Hap dokumentin</a></p>'
          || '</div><p style="color:#999;font-size:11px">Kujtesë automatike e Arkivës Elektronike</p></body></html>'
      ),
      headers := jsonb_build_object('api-key', k, 'content-type','application/json', 'accept','application/json')
    );
    update public.delegations set
      reminded3_at = case when due_date = current_date + 3 then now() else reminded3_at end,
      reminded0_at = case when due_date = current_date     then now() else reminded0_at end
    where id = r.id;
    n := n + 1;
  end loop;
  return jsonb_build_object('email_derguar', n);
end $$;

do $$ begin
  perform cron.unschedule('arkiva-percjellje-ditore');
exception when others then null; end $$;
select cron.schedule('arkiva-percjellje-ditore','45 6 * * *','select public.kujtesa_percjellje()');

-- ---------- verifikimi ----------
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('sectors','delegations','external_links')
order by table_name;
select jobname, schedule from cron.job order by jobid;
