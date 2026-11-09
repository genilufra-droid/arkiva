-- =====================================================================
-- ARKIVA · Protokolli dhe jeta e dosjes (hapje → kërkesa → përgjigje → mbyllje)
-- Ekzekutoje PAS schema.sql (përdor profiles, is_active, current_role_name, activity_log).
-- Role: admin = drejtues · editor = regjistrues · viewer = lexues
-- =====================================================================

-- ---------- Numërimi automatik (protokolli + numrat e dosjeve) ----------
create table if not exists public.protocol_counters (
  year       int  not null,
  kind       text not null,           -- 'hyrje' | 'dalje' | 'dosje'
  last_no    int  not null default 0,
  primary key (year, kind)
);

create or replace function public.next_number(p_kind text)
returns text language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now())::int; n int; prefix text;
begin
  insert into public.protocol_counters(year, kind, last_no) values (y, p_kind, 1)
  on conflict (year, kind) do update set last_no = public.protocol_counters.last_no + 1
  returning last_no into n;
  prefix := case p_kind when 'hyrje' then 'H' when 'dalje' then 'D' else 'DS' end;
  return prefix || '-' || y || '-' || lpad(n::text, 4, '0');
end $$;

-- ---------- Dosjet (çështjet) ----------
create table if not exists public.cases (
  id               uuid primary key default gen_random_uuid(),
  case_no          text unique,                       -- p.sh. DS-2026-0001
  title            text not null check (length(title) between 1 and 200),
  subject          text not null default '',
  physical_location text not null default '',
  status           text not null default 'hapur' check (status in ('hapur','mbyllur')),
  opened_at        timestamptz not null default now(),
  closed_at        timestamptz,
  closed_by        uuid references auth.users(id),
  closure_note     text,
  created_by       uuid references auth.users(id)
);

create or replace function public.set_case_no()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.case_no is null then new.case_no := public.next_number('dosje'); end if;
  return new;
end $$;
drop trigger if exists cases_numbering on public.cases;
create trigger cases_numbering before insert on public.cases
  for each row execute function public.set_case_no();

-- ---------- Dokumentet e dosjes (shkresa, kërkesa, përgjigje, kontrata, fletë) ----------
create table if not exists public.correspondence (
  id            uuid primary key default gen_random_uuid(),
  case_id       uuid not null references public.cases(id),
  direction     text not null check (direction in ('hyrje','dalje','brendshme')),
  kind          text not null check (kind in ('shkresë','kërkesë','përgjigje','kontratë','fletë','dokument')),
  protocol_no   text unique,                          -- vetëm për hyrje/dalje
  doc_date      date not null default current_date,
  from_to       text not null default '',             -- nga / për kë
  subject       text not null,
  due_date      date,                                 -- afati, për kërkesat
  storage_path  text unique,
  mime          text,
  size_bytes    bigint,
  sha256        text,
  ocr_text      text not null default '',
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  constraint due_only_for_requests check (due_date is null or kind = 'kërkesë')
);
create index if not exists corr_case_idx on public.correspondence(case_id);

-- Protokolli i automatik për hyrje/dalje
create or replace function public.assign_protocol()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.direction in ('hyrje','dalje') and new.protocol_no is null then
    new.protocol_no := public.next_number(new.direction);
  end if;
  return new;
end $$;
drop trigger if exists corr_protocol on public.correspondence;
create trigger corr_protocol before insert on public.correspondence
  for each row execute function public.assign_protocol();

-- Lidhjet mes dokumenteve (p.sh. përgjigjja → kërkesa)
create table if not exists public.correspondence_links (
  id        bigint generated always as identity primary key,
  from_id   uuid not null references public.correspondence(id) on delete cascade,
  to_id     uuid not null references public.correspondence(id) on delete cascade,
  relation  text not null check (relation in ('pergjigje_per','lidhur_me')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint no_self_link check (from_id <> to_id),
  unique (from_id, to_id, relation)
);

-- Një kërkesë është e hapur nëse nuk ka asnjë përgjigje të lidhur me të
create or replace function public.is_request_open(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.correspondence_links l
    join public.correspondence a on a.id = l.from_id
    where l.to_id = p_id and l.relation = 'pergjigje_per' and a.deleted_at is null
  )
$$;

-- Pamja e kërkesave të hapura (me afatet)
create or replace view public.open_requests
with (security_invoker = true) as
select c.id, c.case_id, c.protocol_no, c.subject, c.from_to, c.due_date,
       (c.due_date < current_date) as overdue
from public.correspondence c
where c.kind = 'kërkesë' and c.deleted_at is null and public.is_request_open(c.id);

-- ---------- Rregulla të jetës së dosjes ----------
-- 1) Nuk shtohen dokumente në dosje të mbyllur
create or replace function public.guard_closed_case()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.cases where id = new.case_id and status = 'mbyllur') then
    raise exception 'Dosja është e mbyllur; nuk mund të shtohen dokumente. Riapeni dosjen më parë.';
  end if;
  return new;
end $$;
drop trigger if exists corr_guard_closed on public.correspondence;
create trigger corr_guard_closed before insert on public.correspondence
  for each row execute function public.guard_closed_case();

-- 2) Dosja mbyllet vetëm kur të gjitha kërkesat kanë përgjigje dhe ka shënim mbylljeje
create or replace function public.guard_case_closure()
returns trigger language plpgsql security definer set search_path = public as $$
declare open_list text;
begin
  if new.status = 'mbyllur' and old.status = 'hapur' then
    select string_agg(coalesce(protocol_no, subject), ', ') into open_list
    from public.open_requests where case_id = new.id;
    if open_list is not null then
      raise exception 'Nuk mund të mbyllet: kërkesa pa përgjigje: %', open_list;
    end if;
    if coalesce(trim(new.closure_note), '') = '' then
      raise exception 'Shkruani shënimin e mbylljes (p.sh. "Çështja u zgjidh me përgjigjen H-2026-0010").';
    end if;
    new.closed_at := now();
    new.closed_by := auth.uid();
  elsif new.status = 'hapur' and old.status = 'mbyllur' then
    -- rihapja bëhet vetëm nga drejtuesi, dhe pastrohen fushat e mbylljes
    if public.current_role_name() is distinct from 'admin' then
      raise exception 'Vetëm drejtuesi mund ta rihapë dosjen.';
    end if;
    new.closed_at := null; new.closed_by := null;
  end if;
  return new;
end $$;
drop trigger if exists cases_closure on public.cases;
create trigger cases_closure before update on public.cases
  for each row execute function public.guard_case_closure();

-- ---------- Gjurmimi (activity_log nga schema.sql) ----------
create or replace function public.log_case_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,folder_id,detail)
    values (auth.uid(), public.current_user_name(), 'dosje_hapur', null, new.case_no||' · '||new.title);
  elsif new.status is distinct from old.status then
    insert into public.activity_log(user_id,user_name,action,folder_id,detail)
    values (auth.uid(), public.current_user_name(),
            case when new.status = 'mbyllur' then 'dosje_mbyllur' else 'dosje_rihapur' end,
            null, new.case_no||' · '||coalesce(new.closure_note,''));
  end if;
  return null;
end $$;
drop trigger if exists cases_log on public.cases;
create trigger cases_log after insert or update on public.cases
  for each row execute function public.log_case_changes();

create or replace function public.log_corr_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,document_id,detail)
    values (auth.uid(), public.current_user_name(), 'dokument_regjistruar', new.id,
            coalesce(new.protocol_no,'pa protokoll')||' · '||new.kind||' · '||new.subject);
  elsif new.deleted_at is not null and old.deleted_at is null then
    insert into public.activity_log(user_id,user_name,action,document_id,detail)
    values (auth.uid(), public.current_user_name(), 'dokument_fshire', new.id, new.subject||' (mbetet në gjurmim)');
  end if;
  return null;
end $$;
drop trigger if exists corr_log on public.correspondence;
create trigger corr_log after insert or update on public.correspondence
  for each row execute function public.log_corr_changes();

create or replace function public.log_link_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_log(user_id,user_name,action,document_id,detail)
  values (auth.uid(), public.current_user_name(), 'lidhje_shtuar', new.from_id,
          new.relation||' → '||(select coalesce(protocol_no,subject) from public.correspondence where id = new.to_id));
  return null;
end $$;
drop trigger if exists links_log on public.correspondence_links;
create trigger links_log after insert on public.correspondence_links
  for each row execute function public.log_link_insert();

-- ---------- RLS ----------
alter table public.cases                enable row level security;
alter table public.correspondence       enable row level security;
alter table public.correspondence_links enable row level security;
alter table public.protocol_counters    enable row level security;

create policy cases_read on public.cases for select using (public.is_active());
create policy cases_insert on public.cases for insert
  with check (public.current_role_name() in ('admin','editor'));
create policy cases_update on public.cases for update
  using (public.current_role_name() in ('admin','editor'))
  with check (public.current_role_name() in ('admin','editor'));

create policy corr_read on public.correspondence for select using (public.is_active());
create policy corr_insert on public.correspondence for insert
  with check (public.current_role_name() in ('admin','editor'));
create policy corr_update on public.correspondence for update
  using (public.current_role_name() in ('admin','editor'))
  with check (public.current_role_name() in ('admin','editor'));

create policy links_read on public.correspondence_links for select using (public.is_active());
create policy links_insert on public.correspondence_links for insert
  with check (public.current_role_name() in ('admin','editor'));

-- numëruesit: asnjë akses direkt nga klienti (vetëm funksioni next_number)
-- (s'ka policy => s'lexohen/s'ndryshohen direkt)
