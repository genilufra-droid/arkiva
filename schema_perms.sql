-- =====================================================================
-- ARKIVA · Të drejtat me check box (Odoo/Vyapar-style) — MIGRACION
-- Ekzekutoje PAS schema.sql + schema_protokoll.sql në projektet ekzistuese.
-- (Në projektet e reja, schema.sql e krijon automatikisshëm profilit vetëm
--  kolonat bazë; ky skript shton sistemin e të drejtave të imëta.)
-- =====================================================================

-- ---------- Kolona e të drejtave në profile ----------
alter table public.profiles add column if not exists perms jsonb not null default '{}'::jsonb;

-- ---------- Funksioni: a ka përdoruesi i miratuar të drejtën X? ----------
-- Të drejtat: gjurmimi, regjistro, ndrysho, fshi, mbyll, shkarko,
--             perdoruesit, backup
create or replace function public.user_can(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (perms->>p)::boolean from public.profiles where id = auth.uid() and active), false)
$$;

-- ---------- Mbushje sipas roleve ekzistuese ----------
update public.profiles set perms='{"gjurmimi":true,"regjistro":true,"ndrysho":true,"fshi":true,"mbyll":true,"shkarko":true,"perdoruesit":true,"backup":true}'::jsonb where role='admin';
update public.profiles set perms='{"gjurmimi":true,"regjistro":true,"ndrysho":true,"fshi":true,"mbyll":true,"shkarko":true}'::jsonb where role='editor';
update public.profiles set perms='{"shkarko":true}'::jsonb where role='viewer';

-- ---------- Politika RLS të përditësuara ----------
drop policy if exists folders_write on public.folders;
create policy folders_write on public.folders for insert with check (public.user_can('regjistro'));
drop policy if exists folders_update on public.folders;
create policy folders_update on public.folders for update using (public.user_can('regjistro')) with check (public.user_can('regjistro'));

drop policy if exists documents_insert on public.documents;
create policy documents_insert on public.documents for insert with check (public.user_can('regjistro'));
drop policy if exists documents_update on public.documents;
create policy documents_update on public.documents for update using (public.user_can('ndrysho')) with check (public.user_can('ndrysho'));

drop policy if exists profiles_self_read on public.profiles;
create policy profiles_self_read on public.profiles for select
  using (id = auth.uid() or public.user_can('perdoruesit'));
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update
  using (public.user_can('perdoruesit')) with check (public.user_can('perdoruesit'));

drop policy if exists activity_read on public.activity_log;
create policy activity_read on public.activity_log for select
  using (public.user_can('gjurmimi'));

drop policy if exists storage_read on storage.objects;
create policy storage_read on storage.objects for select to authenticated
  using (bucket_id = 'dokumente' and public.user_can('shkarko'));
drop policy if exists storage_insert on storage.objects;
create policy storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'dokumente' and public.user_can('regjistro'));

drop policy if exists cases_insert on public.cases;
create policy cases_insert on public.cases for insert with check (public.user_can('regjistro'));
drop policy if exists cases_update on public.cases;
create policy cases_update on public.cases for update
  using (public.user_can('mbyll')) with check (public.user_can('mbyll'));

drop policy if exists corr_insert on public.correspondence;
create policy corr_insert on public.correspondence for insert with check (public.user_can('regjistro'));
drop policy if exists corr_update on public.correspondence;
create policy corr_update on public.correspondence for update
  using (public.user_can('ndrysho') or public.user_can('fshi'))
  with check (public.user_can('ndrysho') or public.user_can('fshi'));

drop policy if exists links_insert on public.correspondence_links;
create policy links_insert on public.correspondence_links for insert with check (public.user_can('regjistro'));

-- ---------- Trigger: dallon NDRYSHIM nga FSHIRJE në dokumente ----------
create or replace function public.guard_doc_write_kind()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.deleted_at is distinct from old.deleted_at and not public.user_can('fshi') then
    raise exception 'S''ke të drejtën për të fshirë ose rikthyer dokumente.';
  end if;
  if (new.subject, new.from_to, new.kind, new.doc_date, new.due_date, new.storage_path, new.mime, new.size_bytes, new.sha256, new.ocr_text, new.case_id, new.direction, new.protocol_no)
     is distinct from
     (old.subject, old.from_to, old.kind, old.doc_date, old.due_date, old.storage_path, old.mime, old.size_bytes, old.sha256, old.ocr_text, old.case_id, old.direction, old.protocol_no)
     and not public.user_can('ndrysho') then
    raise exception 'S''ke të drejtën për të ndryshuar të dhënat e dokumenteve.';
  end if;
  return new;
end $$;
drop trigger if exists doc_write_guard on public.correspondence;
create trigger doc_write_guard before update on public.correspondence
  for each row execute function public.guard_doc_write_kind();

-- ---------- Rihapja e dosjes kërkon të drejtën 'mbyll' ----------
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
    if not public.user_can('mbyll') then
      raise exception 'Vetëm përdoruesit me të drejtën e mbylljes mund ta rihapin dosjen.';
    end if;
    new.closed_at := null; new.closed_by := null;
  end if;
  return new;
end $$;
