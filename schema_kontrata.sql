-- =====================================================================
-- ARKIVA · Moduli KONTRATAT — MIGRACION
-- Ekzekutohet PAS schema.sql (+ schema_protokoll.sql + schema_perms.sql)
-- Shton: kontratat me palë/vlerë/afate, orarin e pagesave me gjendje
-- "paguar", skedar të skanuar, historik të plotë (activity_log) dhe
-- kujtesa 7-ditore (llogaritet në frontend nga datat).
-- Të drejtat: përdorin sistemin ekzistues user_can() —
--   regjistro (shto kontratë/pagesë, ngarko skedar), ndrysho (modifiko,
--   shëno paguar), fshi (fshi/rikthe/pagesa), shkarko (skedari).
-- =====================================================================

-- ---------- Tabelat ----------
create table if not exists public.contracts (
  id            uuid primary key default gen_random_uuid(),
  contract_no   text not null,
  title         text not null,
  counterparty  text,
  start_date    date,
  end_date      date,
  value_num     numeric(14,2),
  notes         text,
  storage_path  text,
  file_name     text,
  size_bytes    bigint,
  mime          text,
  sha256        text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);

create table if not exists public.contract_payments (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references public.contracts(id) on delete cascade,
  due_date     date not null,
  amount       numeric(14,2) not null,
  description  text,
  paid         boolean not null default false,
  paid_at      date,
  created_at   timestamptz not null default now()
);
create index if not exists payments_contract_idx on public.contract_payments(contract_id, due_date);

-- ---------- Historiku: activity_log merr referencë kontrate ----------
-- (pa FK, në të njëjtin stil me document_id ekzistues — historiku mbetet edhe pas fshirjeve)
alter table public.activity_log add column if not exists contract_id uuid;
create index if not exists activity_contract_idx on public.activity_log(contract_id, id desc);

-- ---------- RLS ----------
alter table public.contracts enable row level security;
alter table public.contract_payments enable row level security;

drop policy if exists contracts_read on public.contracts;
create policy contracts_read on public.contracts for select using (public.is_active());
drop policy if exists contracts_insert on public.contracts;
create policy contracts_insert on public.contracts for insert with check (public.user_can('regjistro'));
drop policy if exists contracts_update on public.contracts;
create policy contracts_update on public.contracts for update
  using (public.user_can('ndrysho') or public.user_can('fshi'))
  with check (public.user_can('ndrysho') or public.user_can('fshi'));
drop policy if exists contracts_delete on public.contracts;
create policy contracts_delete on public.contracts for delete using (public.user_can('fshi'));

drop policy if exists pay_read on public.contract_payments;
create policy pay_read on public.contract_payments for select using (public.is_active());
drop policy if exists pay_insert on public.contract_payments;
create policy pay_insert on public.contract_payments for insert with check (public.user_can('regjistro'));
drop policy if exists pay_update on public.contract_payments;
create policy pay_update on public.contract_payments for update using (public.user_can('ndrysho'));
drop policy if exists pay_delete on public.contract_payments;
create policy pay_delete on public.contract_payments for delete using (public.user_can('fshi'));

-- ---------- Roja: NDRYSHIM vs FSHIRJE + updated_at ----------
create or replace function public.guard_contract_write_kind()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.deleted_at is distinct from old.deleted_at and not public.user_can('fshi') then
    raise exception 'S''ke të drejtën për të fshirë ose rikthyer kontratat.';
  end if;
  if (new.contract_no, new.title, new.counterparty, new.start_date, new.end_date, new.value_num,
      new.notes, new.storage_path, new.file_name, new.mime, new.size_bytes, new.sha256)
     is distinct from
     (old.contract_no, old.title, old.counterparty, old.start_date, old.end_date, old.value_num,
      old.notes, old.storage_path, old.file_name, old.mime, old.size_bytes, old.sha256)
     and not public.user_can('ndrysho') then
    raise exception 'S''ke të drejtën për të ndryshuar të dhënat e kontratave.';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists contract_write_guard on public.contracts;
create trigger contract_write_guard before update on public.contracts
  for each row execute function public.guard_contract_write_kind();

-- ---------- Historiku: triggers ----------
create or replace function public.log_contract_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,contract_id,detail)
    values (auth.uid(), public.current_user_name(), 'kontrata_krijuar', new.id,
            'Nr. '||new.contract_no||' · '||new.title);
  elsif tg_op = 'UPDATE' then
    if new.deleted_at is not null and old.deleted_at is null then
      insert into public.activity_log(user_id,user_name,action,contract_id,detail)
      values (auth.uid(), public.current_user_name(), 'kontrata_fshire', new.id, 'Nr. '||new.contract_no);
    elsif new.deleted_at is null and old.deleted_at is not null then
      insert into public.activity_log(user_id,user_name,action,contract_id,detail)
      values (auth.uid(), public.current_user_name(), 'kontrata_rikthyer', new.id, 'Nr. '||new.contract_no);
    elsif new.storage_path is distinct from old.storage_path and new.storage_path is not null then
      insert into public.activity_log(user_id,user_name,action,contract_id,detail)
      values (auth.uid(), public.current_user_name(), 'kontrata_skedar', new.id,
              'Skedari: '||coalesce(new.file_name,'—'));
    elsif (new.contract_no, new.title, new.counterparty, new.start_date, new.end_date, new.value_num, new.notes)
       is distinct from
       (old.contract_no, old.title, old.counterparty, old.start_date, old.end_date, old.value_num, old.notes) then
      insert into public.activity_log(user_id,user_name,action,contract_id,detail)
      values (auth.uid(), public.current_user_name(), 'kontrata_ndryshuar', new.id,
              'Nr. '||new.contract_no||' · '||new.title);
    end if;
  end if;
  return null;
end $$;
drop trigger if exists contracts_log on public.contracts;
create trigger contracts_log after insert or update on public.contracts
  for each row execute function public.log_contract_changes();

create or replace function public.log_payment_changes()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; d text;
begin
  if tg_op = 'DELETE' then
    insert into public.activity_log(user_id,user_name,action,contract_id,detail)
    values (auth.uid(), public.current_user_name(), 'pagesa_fshire', old.contract_id,
            'Pagesa e '||to_char(old.due_date,'DD/MM/YYYY')||' · '||old.amount);
    return null;
  end if;
  cid := case when tg_op='INSERT' then new.contract_id else old.contract_id end;
  if tg_op = 'INSERT' then
    insert into public.activity_log(user_id,user_name,action,contract_id,detail)
    values (auth.uid(), public.current_user_name(), 'pagesa_shtuar', cid,
            'Pagesë më '||to_char(new.due_date,'DD/MM/YYYY')||' · '||new.amount);
  elsif new.paid and not old.paid then
    insert into public.activity_log(user_id,user_name,action,contract_id,detail)
    values (auth.uid(), public.current_user_name(), 'pagesa_paguar', cid,
            'Paguar më '||to_char(coalesce(new.paid_at, current_date),'DD/MM/YYYY')||' · '||new.amount);
  elsif not new.paid and old.paid then
    insert into public.activity_log(user_id,user_name,action,contract_id,detail)
    values (auth.uid(), public.current_user_name(), 'pagesa_hapur', cid,
            'Kthye në të papaguar · afati '||to_char(new.due_date,'DD/MM/YYYY'));
  elsif (new.due_date, new.amount, new.description) is distinct from (old.due_date, old.amount, old.description) then
    insert into public.activity_log(user_id,user_name,action,contract_id,detail)
    values (auth.uid(), public.current_user_name(), 'pagesa_ndryshuar', cid,
            to_char(new.due_date,'DD/MM/YYYY')||' · '||new.amount);
  end if;
  return null;
end $$;
drop trigger if exists payments_log on public.contract_payments;
create trigger payments_log after insert or update or delete on public.contract_payments
  for each row execute function public.log_payment_changes();

-- ---------- Realtime ----------
alter publication supabase_realtime add table public.contracts;
alter publication supabase_realtime add table public.contract_payments;
