-- =====================================================================
-- ARKIVA · «Pastro gjurmimin» — e drejta e fshirjes së regjistrit
-- Ekzekuto PAS schema_perms.sql.
-- Vetëm drejtuesi (user_can('perdoruesit')) mund ta pastrojë regjistrin
-- e veprimeve. Dokumentet, dosjet dhe kontratat NUK preken.
-- =====================================================================

drop policy if exists activity_clear on public.activity_log;
create policy activity_clear on public.activity_log for delete
  using (public.user_can('perdoruesit'));
