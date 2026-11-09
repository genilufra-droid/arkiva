-- =====================================================================
-- ARKIVA · Skema për Supabase (Postgres + Auth + Storage + RLS)
-- Ekzekutoje një herë në: Supabase Dashboard → SQL Editor → New query
-- =====================================================================

-- ---------- Profilet e përdoruesve (lidhen me auth.users) ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  role        text not null default 'viewer' check (role in ('admin','editor','viewer')),
  active      boolean not null default false,   -- përdoruesi i ri mbetet joaktiv deri në miratim
  created_at  timestamptz not null default now()
);

-- Çdo llogari e re krijon automatikisht një profil (lexues, jo aktiv)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Funksionet ndihmëse për RLS
create or replace function public.current_role_name()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.is_active()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select active from public.profiles where id = auth.uid()), false)
$$;

-- ---------- Dosjet ----------
create table if not exists public.folders (
  id                 uuid primary key default gen_random_uuid(),
  parent_id          uuid references public.folders(id),
  name               text not null check (length(name) between 1 and 120),
  physical_location  text not null default '',
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  deleted_at         timestamptz
);
create unique index if not exists folders_sibling_name_uq
  on public.folders (coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name))
  where deleted_at is null;

-- Dosja rrënjë
insert into public.folders (id, parent_id, name)
values ('00000000-0000-0000-0000-000000000001', null, 'Arkiva')
on conflict (id) do nothing;

-- ---------- Dokumentet ----------
create table if not exists public.documents (
  id             uuid primary key default gen_random_uuid(),
  folder_id      uuid not null references public.folders(id),
  title          text not null check (length(title) between 1 and 200),
  original_name  text not null,
  storage_path   text not null unique,      -- rruga në bucket-in 'dokumente'
  mime           text,
  size_bytes     bigint,
  sha256         text,
  source         text not null default 'ngarkim',
  ocr_text       text not null default '',
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index if not exists documents_folder_idx on public.documents(folder_id);
create index if not exists documents_sha_idx on public.documents(sha256);
create index if not exists documents_search_idx
  on public.documents using gin (to_tsvector('simple', title || ' ' || original_name || ' ' || ocr_text));

-- ---------- Gjurmimi (audit log) — plotësohet vetëm nga triggers ----------
create table if not exists public.activity_log (
  id           bigint generated always as identity primary key,
  ts           timestamptz not null default now(),
  user_id      uuid references auth.users(id),
  user_name    text,
  action       text not null,
  folder_id    uuid,
  document_id  uuid,
  detail       text
);
create index if not exists activity_folder_idx on public.activity_log(folder_id, id desc);
create index if not exists activity_doc_idx on public.activity_log(document_id, id desc);

create or replace function public.current_user_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from public.profiles where id = auth.uid()), 'sistemi')
$$;

-- Trigger për dosjet
create or replace function public.log_folder_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,folder_id,detail)
    values (auth.uid(), public.current_user_name(), 'dosje_krijuar', new.id, 'Emri: '||new.name);
  elsif tg_op = 'UPDATE' then
    if new.name is distinct from old.name then
      insert into public.activity_log(user_id,user_name,action,folder_id,detail)
      values (auth.uid(), public.current_user_name(), 'dosje_riemertuar', new.id, old.name||' → '||new.name);
    end if;
    if new.physical_location is distinct from old.physical_location then
      insert into public.activity_log(user_id,user_name,action,folder_id,detail)
      values (auth.uid(), public.current_user_name(), 'vendndodhja_ndryshuar', new.id,
              '«'||coalesce(nullif(old.physical_location,''),'—')||'» → «'||coalesce(nullif(new.physical_location,''),'—')||'»');
    end if;
    if new.deleted_at is not null and old.deleted_at is null then
      insert into public.activity_log(user_id,user_name,action,folder_id,detail)
      values (auth.uid(), public.current_user_name(), 'dosje_fshire', new.id, 'Emri: '||new.name);
    end if;
  end if;
  return null;
end $$;

drop trigger if exists folders_log on public.folders;
create trigger folders_log after insert or update on public.folders
  for each row execute function public.log_folder_changes();

-- Trigger për dokumentet
create or replace function public.log_document_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,folder_id,document_id,detail)
    values (auth.uid(), public.current_user_name(), 'dokument_ngarkuar', new.folder_id, new.id,
            new.original_name||' ('||greatest(1,coalesce(new.size_bytes,0)/1024)||' KB)'
            || case when exists (select 1 from public.documents d where d.sha256 = new.sha256 and d.id <> new.id and d.deleted_at is null)
                    then '; mundet dublikat' else '' end);
  elsif tg_op = 'UPDATE' then
    if new.title is distinct from old.title then
      insert into public.activity_log(user_id,user_name,action,folder_id,document_id,detail)
      values (auth.uid(), public.current_user_name(), 'dokument_riemertuar', new.folder_id, new.id, old.title||' → '||new.title);
    end if;
    if new.folder_id is distinct from old.folder_id then
      insert into public.activity_log(user_id,user_name,action,folder_id,document_id,detail)
      values (auth.uid(), public.current_user_name(), 'dokument_larguar', old.folder_id, new.id, 'Për te dosja tjetër');
      insert into public.activity_log(user_id,user_name,action,folder_id,document_id,detail)
      values (auth.uid(), public.current_user_name(), 'dokument_shtuar', new.folder_id, new.id, 'Nga dosja tjetër');
    end if;
    if new.deleted_at is not null and old.deleted_at is null then
      insert into public.activity_log(user_id,user_name,action,folder_id,document_id,detail)
      values (auth.uid(), public.current_user_name(), 'dokument_fshire', new.folder_id, new.id, new.title||' (mbetet në gjurmim)');
    end if;
    if new.deleted_at is null and old.deleted_at is not null then
      insert into public.activity_log(user_id,user_name,action,folder_id,document_id,detail)
      values (auth.uid(), public.current_user_name(), 'dokument_rikthyer', new.folder_id, new.id, new.title);
    end if;
  end if;
  return null;
end $$;

drop trigger if exists documents_log on public.documents;
create trigger documents_log after insert or update on public.documents
  for each row execute function public.log_document_changes();

-- ---------- RLS: vetëm përdoruesit e miratuar lexojnë; redaktorët shkruajnë ----------
alter table public.profiles     enable row level security;
alter table public.folders      enable row level security;
alter table public.documents    enable row level security;
alter table public.activity_log enable row level security;

-- Profilet: secili sheh vetveten; admini shohin dhe ndryshojnë të gjithë
create policy profiles_self_read on public.profiles for select
  using (id = auth.uid() or public.current_role_name() = 'admin');
create policy profiles_admin_update on public.profiles for update
  using (public.current_role_name() = 'admin') with check (public.current_role_name() = 'admin');

-- Dosjet
create policy folders_read on public.folders for select
  using (public.is_active());
create policy folders_write on public.folders for insert
  with check (public.current_role_name() in ('admin','editor'));
create policy folders_update on public.folders for update
  using (public.current_role_name() in ('admin','editor'))
  with check (public.current_role_name() in ('admin','editor'));
-- S'ka DELETE: fshirja bëhet me deleted_at (mbetet në gjurmim)

-- Dokumentet
create policy documents_read on public.documents for select
  using (public.is_active());
create policy documents_insert on public.documents for insert
  with check (public.current_role_name() in ('admin','editor'));
create policy documents_update on public.documents for update
  using (public.current_role_name() in ('admin','editor'))
  with check (public.current_role_name() in ('admin','editor'));

-- Gjurmimi: vetëm lexim; nuk mund të shtohet/ndryshohet/fshihet nga klienti
create policy activity_read on public.activity_log for select
  using (public.is_active());

-- ---------- Storage: bucket privat 'dokumente' ----------
insert into storage.buckets (id, name, public)
values ('dokumente', 'dokumente', false)
on conflict (id) do nothing;

create policy storage_read on storage.objects for select to authenticated
  using (bucket_id = 'dokumente' and public.is_active());
create policy storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'dokumente' and public.current_role_name() in ('admin','editor'));
-- S'ka policy për update/delete të skedarëve: skedarët nuk fshihen fizikisht
