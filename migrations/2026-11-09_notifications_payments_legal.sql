-- ============================================================
-- GSMP — notifications, "I've paid" reports, terms acceptance — 2026-11-09
--
-- 1. notification_outbox: every member-facing event enqueues an email here
--    (DB triggers). Edge Function `notify` drains it via Resend. A Supabase
--    Database Webhook on INSERT calls `notify`; a daily cron enqueues
--    renewal reminders (see 2026-11-09b_cron.sql). Dedupe keys stop repeats.
-- 2. payment_reports: a member says "I've paid" (amount, method, reference).
--    Admins are notified; recording the payment closes open reports.
-- 3. members.terms_version / terms_accepted_at: recorded at application.
-- Backward-compatible with the live pages. Run ONCE, BEFORE merging pages.
-- ============================================================
BEGIN;

-- ---------- terms acceptance ----------
ALTER TABLE public.members
  ADD COLUMN terms_version text CHECK (char_length(terms_version) <= 20),
  ADD COLUMN terms_accepted_at timestamptz;

CREATE OR REPLACE FUNCTION public.gsmp_stamp_terms()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- the server, not the browser, decides the timestamp
  IF NEW.terms_version IS NOT NULL THEN NEW.terms_accepted_at := now(); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gsmp_stamp_terms BEFORE INSERT ON public.members
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_stamp_terms();

-- ---------- outbox ----------
CREATE TABLE public.notification_outbox (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  to_email    text NOT NULL,
  template    text NOT NULL,
  payload     jsonb NOT NULL DEFAULT '{}'::jsonb,
  dedupe_key  text UNIQUE,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sending','sent','failed')),
  attempts    integer NOT NULL DEFAULT 0,
  last_error  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz
);
CREATE INDEX idx_outbox_pending ON public.notification_outbox (created_at) WHERE status IN ('pending','failed');
ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read outbox" ON public.notification_outbox FOR SELECT USING (public.is_saas_admin());
-- no write policies: only SECURITY DEFINER functions / service role write

CREATE OR REPLACE FUNCTION public.gsmp_enqueue(p_to text, p_template text, p_payload jsonb, p_dedupe text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_to IS NULL OR p_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RETURN; END IF;
  INSERT INTO public.notification_outbox (to_email, template, payload, dedupe_key)
  VALUES (lower(p_to), p_template, COALESCE(p_payload, '{}'::jsonb), p_dedupe)
  ON CONFLICT (dedupe_key) DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION public.gsmp_enqueue(text, text, jsonb, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.gsmp_enqueue_admins(p_template text, p_payload jsonb, p_dedupe text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a record;
BEGIN
  FOR a IN SELECT email FROM public.app_admins LOOP
    PERFORM public.gsmp_enqueue(a.email, p_template, p_payload,
      CASE WHEN p_dedupe IS NULL THEN NULL ELSE p_dedupe || ':' || lower(a.email) END);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.gsmp_enqueue_admins(text, jsonb, text) FROM PUBLIC, anon, authenticated;

-- Edge Function: claim a batch (SKIP LOCKED = safe with concurrent runs), then report results
CREATE OR REPLACE FUNCTION public.gsmp_claim_outbox(p_limit integer DEFAULT 25)
RETURNS SETOF public.notification_outbox LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.notification_outbox o SET status = 'sending', attempts = o.attempts + 1
   WHERE o.id IN (
     SELECT id FROM public.notification_outbox
      WHERE status = 'pending'
         OR (status = 'failed' AND attempts < 3 AND created_at > now() - interval '2 days')
         OR (status = 'sending' AND created_at < now() - interval '15 minutes' AND attempts < 3)
      ORDER BY created_at LIMIT p_limit
      FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
$$;
CREATE OR REPLACE FUNCTION public.gsmp_finish_outbox(p_id bigint, p_ok boolean, p_error text DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.notification_outbox
     SET status = CASE WHEN p_ok THEN 'sent' ELSE 'failed' END,
         sent_at = CASE WHEN p_ok THEN now() END,
         last_error = CASE WHEN p_ok THEN NULL ELSE left(p_error, 500) END
   WHERE id = p_id;
$$;
REVOKE ALL ON FUNCTION public.gsmp_claim_outbox(integer), public.gsmp_finish_outbox(bigint, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gsmp_claim_outbox(integer), public.gsmp_finish_outbox(bigint, boolean, text) TO service_role;

-- ---------- member events ----------
CREATE OR REPLACE FUNCTION public.gsmp_notify_member()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v jsonb := jsonb_build_object('first_name', initcap(NEW.first_name),
                                'name', initcap(NEW.first_name) || ' ' || initcap(NEW.last_name),
                                'email', NEW.email);
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.membership_status = 'applicant' THEN
      PERFORM public.gsmp_enqueue(NEW.email, 'application_received', v, 'app-recv:' || NEW.id);
      PERFORM public.gsmp_enqueue_admins('admin_new_application',
        v || jsonb_build_object('school', NEW.school, 'country', NEW.country, 'referred_by', NEW.referred_by,
                                'message', left(COALESCE(NEW.application_message, ''), 400)),
        'admin-app:' || NEW.id);
    END IF;
    RETURN NULL;
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    IF NEW.membership_status = 'approved' THEN
      PERFORM public.gsmp_enqueue(NEW.email, 'application_approved',
        v || jsonb_build_object('note', NEW.review_note,
          'fee', (SELECT value FROM public.site_settings WHERE key = 'membership_fee'),
          'instructions', (SELECT value FROM public.site_settings WHERE key = 'membership_payment_instructions')),
        'app-approved:' || NEW.id || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
    ELSIF NEW.membership_status = 'rejected' THEN
      PERFORM public.gsmp_enqueue(NEW.email, 'application_rejected', v || jsonb_build_object('note', NEW.review_note),
        'app-rejected:' || NEW.id || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER gsmp_notify_member AFTER INSERT OR UPDATE OF membership_status ON public.members
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_notify_member();

-- ---------- payment receipt + close "I've paid" reports ----------
CREATE TABLE public.payment_reports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id   uuid NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  amount      numeric(10,2) CHECK (amount IS NULL OR amount > 0),
  currency    text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  method      text NOT NULL CHECK (method IN ('bank_transfer','cash','card','payment_link','other')),
  reference   text CHECK (char_length(reference) <= 200),
  paid_on     date,
  note        text CHECK (char_length(note) <= 500),
  status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','processed','dismissed')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  processed_by text
);
CREATE INDEX idx_payment_reports_open ON public.payment_reports (created_at) WHERE status = 'open';
ALTER TABLE public.payment_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members file own payment report" ON public.payment_reports
  FOR INSERT TO authenticated WITH CHECK (member_id = auth.uid() AND status = 'open');
CREATE POLICY "Members see own payment reports" ON public.payment_reports
  FOR SELECT USING (member_id = auth.uid());
CREATE POLICY "Admins manage payment reports" ON public.payment_reports
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());

CREATE OR REPLACE FUNCTION public.gsmp_payment_report_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.members%ROWTYPE;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.status := 'open'; NEW.processed_at := NULL; NEW.processed_by := NULL;
    IF (SELECT count(*) FROM public.payment_reports
         WHERE member_id = NEW.member_id AND created_at > now() - interval '1 day') >= 3 THEN
      RAISE EXCEPTION 'You have already reported a payment today. GSMP will confirm it shortly.';
    END IF;
    SELECT * INTO m FROM public.members WHERE id = NEW.member_id;
    PERFORM public.gsmp_enqueue_admins('admin_payment_reported',
      jsonb_build_object('name', initcap(m.first_name) || ' ' || initcap(m.last_name), 'email', m.email,
                         'amount', NEW.amount, 'currency', NEW.currency, 'method', NEW.method,
                         'reference', NEW.reference, 'paid_on', NEW.paid_on, 'note', NEW.note),
      'admin-payrep:' || NEW.id);
  ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'open' THEN
    NEW.processed_at := now(); NEW.processed_by := public.gsmp_actor_email();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gsmp_payment_report_guard BEFORE INSERT OR UPDATE ON public.payment_reports
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_payment_report_guard();

CREATE OR REPLACE FUNCTION public.gsmp_on_payment_recorded()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.payment_reports SET status = 'processed'
   WHERE member_id = NEW.member_id AND status = 'open';
  PERFORM public.gsmp_enqueue(NEW.member_email, 'payment_receipt',
    jsonb_build_object('name', NEW.member_name, 'amount', NEW.amount, 'currency', NEW.currency,
                       'method', NEW.method, 'reference', NEW.reference, 'paid_at', NEW.paid_at,
                       'covers_until', NEW.covers_until, 'receipt_no', upper(left(replace(NEW.id::text, '-', ''), 10))),
    'receipt:' || NEW.id);
  RETURN NULL;
END $$;
CREATE TRIGGER gsmp_on_payment_recorded AFTER INSERT ON public.membership_payments
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_on_payment_recorded();

-- ---------- portfolio events (actionable only; verified items show on the portfolio) ----------
CREATE OR REPLACE FUNCTION public.gsmp_notify_claim()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m record;
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('needs_info','rejected') THEN
    SELECT mb.email, mb.first_name INTO m FROM public.portfolios p JOIN public.members mb ON mb.id = p.member_id
     WHERE p.id = NEW.portfolio_id;
    PERFORM public.gsmp_enqueue(m.email, 'claim_' || NEW.status,
      jsonb_build_object('first_name', initcap(m.first_name), 'title', NEW.title, 'note', NEW.reviewer_note),
      'claim:' || NEW.id || ':' || NEW.status || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER gsmp_notify_claim AFTER UPDATE OF status ON public.portfolio_claims
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_notify_claim();

CREATE OR REPLACE FUNCTION public.gsmp_notify_portfolio()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m record;
BEGIN
  SELECT email, first_name INTO m FROM public.members WHERE id = NEW.member_id;
  IF TG_OP = 'INSERT' THEN
    PERFORM public.gsmp_enqueue(m.email, 'portfolio_invited', jsonb_build_object('first_name', initcap(m.first_name)),
      'pf-invite:' || NEW.id);
  ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('active','suspended','revoked') THEN
    PERFORM public.gsmp_enqueue(m.email, 'portfolio_' || NEW.status,
      jsonb_build_object('first_name', initcap(m.first_name), 'public_id', NEW.public_id),
      'pf:' || NEW.id || ':' || NEW.status || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER gsmp_notify_portfolio AFTER INSERT OR UPDATE OF status ON public.portfolios
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_notify_portfolio();

-- ---------- renewal reminders (called daily by cron; safe to call any time) ----------
CREATE OR REPLACE FUNCTION public.gsmp_enqueue_renewal_reminders()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; n integer := 0; v_fee text;
BEGIN
  SELECT value INTO v_fee FROM public.site_settings WHERE key = 'membership_fee';
  FOR r IN
    SELECT id, email, first_name, paid_until,
           CASE WHEN paid_until < current_date THEN 'renewal_overdue'
                WHEN paid_until <= current_date + 7 THEN 'renewal_7'
                ELSE 'renewal_30' END AS tpl
      FROM public.members
     WHERE membership_status = 'active' AND paid_until IS NOT NULL
       AND paid_until BETWEEN current_date - 30 AND current_date + 30
  LOOP
    -- one email per stage per paid_until date; renewing (new date) resets the cycle
    PERFORM public.gsmp_enqueue(r.email, r.tpl,
      jsonb_build_object('first_name', initcap(r.first_name), 'paid_until', r.paid_until, 'fee', v_fee),
      r.tpl || ':' || r.id || ':' || r.paid_until);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.gsmp_enqueue_renewal_reminders() FROM PUBLIC, anon, authenticated;

INSERT INTO public.site_settings (key, value) VALUES ('contact_email', 'info@gsmpglobal.org')
ON CONFLICT (key) DO NOTHING;

COMMIT;
