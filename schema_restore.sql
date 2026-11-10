-- =====================================================================
-- ARKIVA · Restore nga backup + Reset i plotë — MIGRACION (schema_restore.sql)
-- Ekzekuto PAS schema_perms.sql / schema_kujtesa2.sql.
--   • restore_arkiva(jsonb): rikthen të dhënat nga skedari i backup-ut
--     (upsert — rreshtat ekzistues me të njëjtin ID përditësohen).
--   • reset_arkiva(): fshin dosjet, dokumentet, lidhjet, kontratat,
--     pagesat dhe historikun (gjendja fillestare). Përdoruesit dhe
--     numërimi i protokolleve mbeten (pa dyfishime).
--   • Politika storage_delete: drejtuesi fshin skedarët fizikë.
-- =====================================================================

-- ---------- Politika: fshirja e skedarëve në Storage (vetëm drejtuesi) ----------
drop policy if exists storage_delete on storage.objects;
create policy storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'dokumente' and public.user_can('perdoruesit'));

-- ---------- Ndihmës i brendshëm: upsert i përgjithshëm nga jsonb ----------
-- (i revokuar nga të gjithë — thirret vetëm brenda restore_arkiva)
create or replace function public._upsert_nga_jsonb(t text, rreshta jsonb, overrid boolean default false)
returns int language plpgsql security definer set search_path=public as $fn$
declare
  deklar text; selekt text; vendos text; n int; ka_id boolean;
begin
  if rreshta is null or jsonb_typeof(rreshta) <> 'array' or jsonb_array_length(rreshta) = 0 then return 0; end if;
  select string_agg(format('%1$I %2s', c.column_name, c.data_type), ', '),
         string_agg(format('%1$I', c.column_name), ', ')
    into deklar, selekt
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = t
    and c.column_name in (select jsonb_object_keys(rreshta->0));
  if deklar is null then return 0; end if;
  select string_agg(format('%1$I = excluded.%1$I', c.column_name), ', ')
    into vendos
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = t
    and c.column_name in (select jsonb_object_keys(rreshta->0))
    and c.column_name <> 'id';
  ka_id := 'id' in (select jsonb_object_keys(rreshta->0))
           and exists(select 1 from information_schema.columns
                      where table_schema='public' and table_name=t and column_name='id');
  if ka_id then
    execute format('insert into public.%I (%s) %sselect %s from jsonb_to_recordset($1) as x(%s) on conflict (id) %s',
      t, selekt, case when overrid then 'overriding system value ' else '' end, selekt, deklar,
      coalesce('do update set ' || vendos, 'do nothing'))
    using rreshta;
  else
    execute format('insert into public.%I (%s) select %s from jsonb_to_recordset($1) as x(%s)',
      t, selekt, selekt, deklar)
    using rreshta;
  end if;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke execute on function public._upsert_nga_jsonb(text, jsonb, boolean) from public, anon, authenticated;

-- ---------- Restore nga backup (vetëm me të drejtën 'backup') ----------
create or replace function public.restore_arkiva(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  r jsonb := '{}'::jsonb; n int;
begin
  if not public.user_can('backup') then
    raise exception 'Vetëm drejtuesi mund të rikthejë të dhëna nga backup.';
  end if;
  if payload is null or not (payload ? 'note') or not (payload ? 'exported_at') then
    raise exception 'Skedari s''është backup i Arkivës Elektronike.';
  end if;
  -- rendi i FK-së: prindërit përpara fëmijëve
  r := r || jsonb_build_object('folders',             public._upsert_nga_jsonb('folders', payload->'folders'));
  r := r || jsonb_build_object('documents',           public._upsert_nga_jsonb('documents', payload->'documents'));
  r := r || jsonb_build_object('cases',               public._upsert_nga_jsonb('cases', payload->'cases'));
  r := r || jsonb_build_object('correspondence',      public._upsert_nga_jsonb('correspondence', payload->'correspondence'));
  r := r || jsonb_build_object('correspondence_links',public._upsert_nga_jsonb('correspondence_links', payload->'correspondence_links'));
  r := r || jsonb_build_object('contracts',           public._upsert_nga_jsonb('contracts', payload->'contracts'));
  r := r || jsonb_build_object('contract_payments',   public._upsert_nga_jsonb('contract_payments', payload->'contract_payments'));
  -- historiku: id-të vjetra ruhen (overriding); user_id pa përdorues ekzistues → bosh
  if payload ? 'activity_log' and jsonb_typeof(payload->'activity_log') = 'array' and jsonb_array_length(payload->'activity_log') > 0 then
    n := public._upsert_nga_jsonb('activity_log',
      (select jsonb_agg(case when (x->>'user_id') is null
                              or not exists(select 1 from auth.users u where u.id::text = x->>'user_id')
                             then (x - 'user_id') || jsonb_build_object('user_id', null)
                             else x end)
       from jsonb_array_elements(payload->'activity_log') x), true);
    perform setval(pg_get_serial_sequence('public.activity_log','id'),
                  greatest((select coalesce(max(id),1) from public.activity_log), 1));
    r := r || jsonb_build_object('activity_log', n);
  end if;
  -- profiles: vetëm për përdoruesit ekzistues (FK auth.users)
  if payload ? 'profiles' and jsonb_typeof(payload->'profiles') = 'array' then
    n := public._upsert_nga_jsonb('profiles',
      (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(payload->'profiles') x
        where exists(select 1 from auth.users u where u.id::text = x->>'id')));
    r := r || jsonb_build_object('profiles', n);
  end if;
  insert into public.activity_log(user_name, action, detail)
    values (public.current_user_name(), 'arkiva_rikthyer',
            'Të dhënat u rikthyen nga backup-i i ' || coalesce(payload->>'exported_at', '?'));
  return jsonb_build_object('ok', true, 'rikthyer', r);
end $fn$;
revoke execute on function public.restore_arkiva(jsonb) from public, anon;
grant execute on function public.restore_arkiva(jsonb) to authenticated;

-- ---------- Reset i plotë (vetëm drejtuesi) ----------
create or replace function public.reset_arkiva()
returns jsonb language plpgsql security definer set search_path=public as $fn$
begin
  if not public.user_can('perdoruesit') then
    raise exception 'Vetëm drejtuesi mund të rivendosë arkivën në gjendjen fillestare.';
  end if;
  delete from public.activity_log where true;
  delete from public.correspondence_links where true;
  delete from public.contract_payments where true;
  delete from public.correspondence where true;
  delete from public.contracts where true;
  delete from public.documents where true;
  delete from public.folders where true;
  delete from public.cases where true;
  insert into public.activity_log(user_name, action, detail)
    values (public.current_user_name(), 'arkiva_u_rivendos',
            'Gjendja fillestare: u fshinë dosjet, dokumentet, lidhjet, kontratat, pagesat dhe historiku. Përdoruesit dhe numërimi i protokolleve mbetën.');
  return jsonb_build_object('ok', true);
end $fn$;
revoke execute on function public.reset_arkiva() from public, anon;
grant execute on function public.reset_arkiva() to authenticated;
