-- =====================================================================
-- ARKIVA · Kujtesa automatike: EMAIL (+ SMS opsional) përmes Brevo
-- Ekzekutohet PAS schema_kontrata.sql
-- Kërkon shtesat pg_cron + pg_net (të lira në Supabase).
--
-- Çelësi i Brevo-s RUHET në tabelën public.settings dhe vendoset VETËM
-- nga drejtuesi përmes Supabase SQL Editor (kurrë në kod/repo/chat):
--   insert into public.settings(key,value) values('brevo_api_key','xkeysib-...')
--     on conflict (key) do update set value=excluded.value;
--
-- Email prove (pas vendosjes së çelësit):
--   select public.dergo_kujtesa(true);
--
-- Planifikimi: çdo ditë 07:00 UTC (08:00 në Shqipëri) — email dërgohet
-- NJË herë për çdo pagesë/afat që hyn në dritaren 7-ditore.
--
-- SMS (opsional, kërkon kredi të blera në Brevo → SMS):
--   insert into public.settings(key,value) values('brevo_sms','1')
--     on conflict (key) do update set value=excluded.value;
--   update public.profiles set phone='+3556XXXXXXXX' where id='...';
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

alter table public.contracts         add column if not exists end_reminded_at timestamptz;
alter table public.contract_payments add column if not exists reminded_at timestamptz;
alter table public.profiles          add column if not exists phone text;

-- ---------- Cilësimet (çelësat) — vetëm serveri i akseson ----------
create table if not exists public.settings (
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;   /* pa politika: anon/authenticated s'kanë akses */
revoke all on public.settings from anon, authenticated;

create or replace function public.htmlesc(t text) returns text
language sql immutable as $$
  select replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;')
$$;

-- ---------- Funksioni: dërgon përmbledhjen e kujtesave ----------
create or replace function public.dergo_kujtesa(te_test boolean default false)
returns jsonb language plpgsql security definer set search_path = public, net as $$
declare
  k text; snd_e text; snd_n text;
  marrsit jsonb; lista text; n_sms int; sms_text text; r record;
begin
  select value into k     from public.settings where key='brevo_api_key';
  if coalesce(k,'')='' then
    return jsonb_build_object('gabim','Mungon «brevo_api_key» në public.settings. Vendose atë: insert into public.settings(key,value) values(''brevo_api_key'',''xkeysib-...'') on conflict (key) do update set value=excluded.value;');
  end if;
  select coalesce(value,'elektronikearkiva@gmail.com') into snd_e from public.settings where key='brevo_sender_email';
  select coalesce(value,'Arkiva Elektronike')         into snd_n from public.settings where key='brevo_sender_name';

  select coalesce(jsonb_agg(jsonb_build_object('email', u.email)), '[]'::jsonb) into marrsit
  from public.profiles p join auth.users u on u.id = p.id
  where p.active and u.email_confirmed_at is not null;
  if jsonb_array_length(marrsit) = 0 then
    return jsonb_build_object('gabim','S''ka përdorues aktivë për t''u njoftuar.');
  end if;

  if te_test then
    lista := '<li>Ky është një <b>email prove</b> nga kujtesa e arkivës — çelësi i Brevo-s punon.</li>';
  else
    select string_agg('<li>'||txt||'</li>', chr(10) order by rend) into lista from (
      select '<b>'||public.htmlesc(c.contract_no)||'</b> — pagesë <b>'||to_char(p.amount,'FM999G999G990D00')||' LEK</b>'
             ||case when coalesce(p.description,'')<>'' then ' ('||public.htmlesc(p.description)||')' else '' end
             ||' · afati <b>'||to_char(p.due_date,'DD/MM/YYYY')||'</b> '
             ||case when p.due_date < current_date then '<span style="color:#b91c1c"><b>ME VONESË</b></span>'
                    else '(pas '||(p.due_date-current_date)||' ditësh)' end as txt,
             p.due_date as rend
      from public.contract_payments p join public.contracts c on c.id=p.contract_id
      where not p.paid and p.reminded_at is null and c.deleted_at is null
        and p.due_date <= current_date + 7
      union all
      select '<b>'||public.htmlesc(c.contract_no)||'</b> — kontrata skadon më <b>'||to_char(c.end_date,'DD/MM/YYYY')||'</b> (pas '||(c.end_date-current_date)||' ditësh)'
             ||case when coalesce(c.title,'')<>'' then '<br><span style="color:#666">'||public.htmlesc(c.title)||'</span>' else '' end,
             c.end_date
      from public.contracts c
      where c.deleted_at is null and c.end_reminded_at is null
        and c.end_date between current_date and current_date + 7
    ) x;
  end if;

  if te_test or (lista is not null and lista <> '') then
    perform net.http_post(
      url     := 'https://api.brevo.com/v3/smtp/email',
      body    := jsonb_build_object(
        'sender',  jsonb_build_object('name', snd_n, 'email', snd_e),
        'to',      marrsit,
        'subject', case when te_test then 'Arkiva — email prove i kujtesës'
                        else '⚠ Arkiva: kujtesë — pagesa dhe afate brenda 7 ditëve' end,
        'htmlContent',
          '<html><body style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222;max-width:560px;margin:0 auto">'
          ||'<div style="background:#b91c1c;color:#fff;padding:12px 18px;border-radius:8px 8px 0 0;font-weight:bold">⚠ KUJTESA E ARKIVËS</div>'
          ||'<div style="border:1px solid #e5e5ea;border-top:0;border-radius:0 0 8px 8px;padding:16px 18px">'
          ||case when te_test then '<p>Sistemi i kujtesave automatike punon.</p>' else '<p>Elementet që afrohen brenda 7 ditëve:</p>' end
          ||'<ul style="padding-left:18px;line-height:1.8">'||coalesce(lista,'')||'</ul>'
          ||'<p style="margin-top:18px"><a href="https://genilufra-droid.github.io/arkiva/#/kontratat?k=1" style="background:#b91c1c;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Hap Kontratat</a></p>'
          ||'</div><p style="color:#999;font-size:11px">Email automatik i Arkivës Elektronike · dërgohet një herë për çdo element.</p></body></html>'
      )::text,
      headers := jsonb_build_object('api-key', k, 'content-type','application/json', 'accept','application/json')
    );

    if not te_test then
      update public.contract_payments set reminded_at = now()
      where not paid and reminded_at is null and due_date <= current_date + 7;
      update public.contracts set end_reminded_at = now()
      where deleted_at is null and end_reminded_at is null
        and end_date between current_date and current_date + 7;
    end if;
  end if;

  -- SMS opsionale (vetëm nëse është aktivizuar me brevo_sms='1' — kërkon kredi Brevo SMS)
  if exists(select 1 from public.settings where key='brevo_sms' and value='1') then
    select count(*) into n_sms
    from public.contract_payments p join public.contracts c on c.id=p.contract_id
    where not p.paid and c.deleted_at is null and p.due_date <= current_date+7;
    if n_sms > 0 then
      sms_text := 'ARKIVA: '||n_sms||' page(s)a/afate brenda 7 diteve. Hap arkiven.';
      for r in select p.phone from public.profiles p where p.active and coalesce(p.phone,'')<>'' loop
        perform net.http_post(
          url     := 'https://api.brevo.com/v3/transactionalSMS/sms',
          body    := jsonb_build_object('sender','Arkiva','recipient',r.phone,'content',sms_text)::text,
          headers := jsonb_build_object('api-key', k, 'content-type','application/json','accept','application/json')
        );
      end loop;
    end if;
  end if;

  return jsonb_build_object(
    'email_derguar', (te_test or coalesce(lista,'')<>''),
    'marrsit', marrsit,
    'sms_aktiv', exists(select 1 from public.settings where key='brevo_sms' and value='1')
  );
end $$;
revoke all on function public.dergo_kujtesa(boolean) from public, authenticated, anon;

-- ---------- Planifikimi ditor: 07:00 UTC = 08:00 në Shqipëri ----------
select cron.unschedule('arkiva-kujtesa-ditore')
 where exists (select 1 from cron.job where jobname='arkiva-kujtesa-ditore');
select cron.schedule('arkiva-kujtesa-ditore','0 7 * * *','select public.dergo_kujtesa();');
