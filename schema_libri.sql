-- ============================================================================
-- MIGRACIONI · LIBRI I PROTOKOLLIT (Detyra 9) + FORMA «PROTOKOLLO NJË DOKUMENT»
-- (Detyra 10)
-- Projekti: Arkiva Elektronike (ymetytjelrawsahpdisn)
-- Ekzekutohet NË SQL Editor të Supabase, para deploy-it të faqes së re.
-- Idempotent: mund të ekzekutohet sërish pa rrezik — s'i prek të dhënat.
-- ============================================================================

-- ---------- Detyra 9 · kolonat e librit të protokollit ----------
alter table public.correspondence add column if not exists doc_no   text;  -- Nr. i dokumentit (shkresa e palës)
alter table public.correspondence add column if not exists remarks  text;  -- Vërejtje (rreshti i librit)

-- ---------- Detyra 10 · kolonat e formës së re ----------
alter table public.correspondence add column if not exists channel           text;                 -- kanali i ardhjes: E-mail / Postë / Dorë / Faks…
alter table public.correspondence add column if not exists sender_ref        text;                 -- referenca e dërguesit (opsionale)
alter table public.correspondence add column if not exists confidential      boolean not null default false;  -- fletë konfidencialiteti
alter table public.correspondence add column if not exists retention_class   text;                 -- afati i ruajtjes: A (pa afat) / B (20 vjet) / C (10 vjet)
alter table public.correspondence add column if not exists physical_location text;                 -- ruajtja fizike, p.sh. «Arkiv B — rafti 12»
alter table public.correspondence add column if not exists labels            text;                 -- etiketa me presje: urgjent, ankesë, leje
alter table public.correspondence add column if not exists internal_note     text;                 -- shënim i brendshëm (jashtë librit, vetëm për stafin)

-- ---------- komente për dokumentimin e skemës ----------
comment on column public.correspondence.doc_no            is 'Detyra 9: nr. i dokumentit — kolona «Nr. i dokumentit» e librit';
comment on column public.correspondence.remarks           is 'Detyra 9: vërejtje — kolona «Vërejtje» e librit';
comment on column public.correspondence.channel           is 'Detyra 10: kanali i ardhjes (E-mail, Postë, Dorë, Faks, Telefonata, Tjetër)';
comment on column public.correspondence.sender_ref        is 'Detyra 10: referenca e dërguesit (nr. poste, ID e-mail-i etj.)';
comment on column public.correspondence.confidential      is 'Detyra 10: dokument me fletë konfidencialiteti';
comment on column public.correspondence.retention_class   is 'Detyra 10: klasa e ruajtjes — A pa afat, B 20 vjet, C 10 vjet';
comment on column public.correspondence.physical_location is 'Detyra 10: vendndodhja fizike e origjinalit (p.sh. Arkiv B — rafti 12)';
comment on column public.correspondence.labels            is 'Detyra 10: etiketa të ndara me presje (urgjent, ankesë, leje…)';
comment on column public.correspondence.internal_note     is 'Detyra 10: shënim i brendshëm për stafin — nuk shfaqet në libër';

-- ---------- indeks për kontrollin e dublimit (vit + palë + objekt) ----------
create index if not exists corr_dup_check_idx
  on public.correspondence (from_to, subject, created_at);

-- ---------- verifikimi ----------
-- Duhen të shfaqen TË GJITHA kolonat e mësipërme (doc_no, remarks, channel,
-- sender_ref, confidential, retention_class, physical_location, labels, internal_note):
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'correspondence'
order by ordinal_position;
