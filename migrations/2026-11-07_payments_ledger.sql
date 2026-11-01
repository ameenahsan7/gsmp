-- ============================================================
-- GSMP — membership payments ledger — 2026-11-07
-- Requires 2026-11-06_membership_applications.sql.
--
-- * membership_payments = append-only ledger. Rows are never deleted or edited;
--   a mistake is VOIDED (with reason, who, when) and re-entered.
-- * Admins record a payment through record_membership_payment(): ledger row +
--   member activated + paid_until extended, atomically.
-- * Ledger keeps a name/email snapshot so history survives member deletion.
-- Run ONCE in Supabase SQL Editor, after the 2026-11-06 migration. Transactional.
-- ============================================================
BEGIN;

CREATE TABLE public.membership_payments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id     uuid REFERENCES public.members(id) ON DELETE SET NULL,
  member_name   text NOT NULL,
  member_email  text NOT NULL,
  chapter_id    uuid REFERENCES public.chapters(id) ON DELETE SET NULL,
  amount        numeric(10,2) NOT NULL CHECK (amount > 0),
  currency      text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  method        text NOT NULL CHECK (method IN ('bank_transfer','cash','card','payment_link','other')),
  reference     text CHECK (char_length(reference) <= 200),
  paid_at       date NOT NULL DEFAULT current_date,
  covers_until  date NOT NULL,
  recorded_by   text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  voided        boolean NOT NULL DEFAULT false,
  void_reason   text CHECK (char_length(void_reason) <= 300),
  voided_by     text,
  voided_at     timestamptz
);
CREATE INDEX idx_payments_paid_at ON public.membership_payments (paid_at DESC);
CREATE INDEX idx_payments_member ON public.membership_payments (member_id);

ALTER TABLE public.membership_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read payments" ON public.membership_payments
  FOR SELECT USING (public.is_saas_admin());
-- no INSERT/UPDATE/DELETE policies: writes only via the functions below

-- ---------- record a payment (admin) ----------
CREATE OR REPLACE FUNCTION public.record_membership_payment(
  p_member uuid, p_amount numeric, p_currency text, p_method text,
  p_reference text, p_paid_at date, p_covers_until date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m public.members%ROWTYPE;
  v_id uuid;
BEGIN
  IF NOT public.is_saas_admin() THEN RAISE EXCEPTION 'Admins only.'; END IF;
  SELECT * INTO m FROM public.members WHERE id = p_member FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Member not found.'; END IF;
  IF m.membership_status IN ('applicant','rejected') THEN
    RAISE EXCEPTION 'Approve the application before recording a payment.';
  END IF;
  IF p_covers_until IS NULL OR p_covers_until <= COALESCE(p_paid_at, current_date) THEN
    RAISE EXCEPTION 'The "paid until" date must be after the payment date.';
  END IF;

  INSERT INTO public.membership_payments
    (member_id, member_name, member_email, chapter_id, amount, currency, method, reference, paid_at, covers_until, recorded_by)
  VALUES
    (m.id, initcap(m.first_name) || ' ' || initcap(m.last_name), m.email, m.chapter_id,
     p_amount, upper(COALESCE(NULLIF(btrim(p_currency), ''), 'USD')), p_method,
     NULLIF(btrim(p_reference), ''), COALESCE(p_paid_at, current_date), p_covers_until, public.gsmp_actor_email())
  RETURNING id INTO v_id;

  UPDATE public.members
     SET membership_status = 'active',
         paid_until = GREATEST(COALESCE(paid_until, p_covers_until), p_covers_until)
   WHERE id = m.id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.record_membership_payment(uuid, numeric, text, text, text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_membership_payment(uuid, numeric, text, text, text, date, date) TO authenticated;

-- ---------- void a payment (admin) ----------
-- Voiding does NOT shorten paid_until automatically (could lock out a member who
-- paid twice); the admin adjusts the date separately if needed.
CREATE OR REPLACE FUNCTION public.void_membership_payment(p_payment uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_saas_admin() THEN RAISE EXCEPTION 'Admins only.'; END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'A reason is required to void a payment.'; END IF;
  UPDATE public.membership_payments
     SET voided = true, void_reason = left(btrim(p_reason), 300), voided_by = public.gsmp_actor_email(), voided_at = now()
   WHERE id = p_payment AND NOT voided;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found or already voided.'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.void_membership_payment(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_membership_payment(uuid, text) TO authenticated;

-- Admins may still set paid_until directly (e.g. correcting a date, comp membership);
-- that is logged in members.reviewed_by only when status changes. Payments are the
-- money record; paid_until is the access record.

COMMIT;
