-- ============================================================
-- GSMP — open applications → admin review → payment → active membership — 2026-11-06
--
-- Lifecycle (members.membership_status):
--   applicant → approved → active          (rejected at review)
--   active + paid_until in the past → 'grace' for 30 days → 'lapsed'   (computed, no cron)
--
-- * Anyone can apply; referral code is OPTIONAL. A code (if given) must be valid;
--   it records the referrer and the requested chapter. The chapter is only
--   assigned — and the code's use only consumed — when an admin APPROVES.
-- * Applicants get no chapter access, an inactive personal invite code, and no
--   public member card until active.
-- * Payment v1 is manual: an admin sets paid_until (status → active).
-- * Verified Portfolio requires an active member; public page shows "paused"
--   once membership lapses past the 30-day grace period. Nothing is deleted.
-- * Existing members are grandfathered: active, paid_until = today + 1 year.
--
-- Run ONCE in Supabase SQL Editor BEFORE merging the pages. Transactional.
-- ============================================================
BEGIN;

-- ---------- columns ----------
ALTER TABLE public.members
  ADD COLUMN membership_status text NOT NULL DEFAULT 'active'
      CHECK (membership_status IN ('applicant','approved','active','rejected')),
  ADD COLUMN paid_until date,
  ADD COLUMN requested_chapter_id uuid REFERENCES public.chapters(id) ON DELETE SET NULL,
  ADD COLUMN application_message text CHECK (char_length(application_message) <= 1000),
  ADD COLUMN review_note text CHECK (char_length(review_note) <= 1000),
  ADD COLUMN reviewed_by text,
  ADD COLUMN reviewed_at timestamptz,
  ADD COLUMN applied_at timestamptz;

-- grandfather everyone who exists today, then make new rows applicants by default
UPDATE public.members SET paid_until = current_date + interval '1 year';
ALTER TABLE public.members ALTER COLUMN membership_status SET DEFAULT 'applicant';

CREATE INDEX idx_members_status ON public.members (membership_status, applied_at);

INSERT INTO public.site_settings (key, value) VALUES
  ('membership_fee', '100 USD / year'),
  ('membership_payment_instructions',
   'Your application has been approved. To activate your membership, pay the annual fee (100 USD) using the details GSMP sends you, then reply with your payment reference. An admin will activate your account.')
ON CONFLICT (key) DO NOTHING;

-- ---------- effective state (no cron needed) ----------
CREATE OR REPLACE FUNCTION public.gsmp_member_state(p_status text, p_paid_until date)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_status <> 'active' THEN p_status
    WHEN p_paid_until IS NULL OR p_paid_until >= current_date THEN 'active'
    WHEN p_paid_until >= current_date - 30 THEN 'grace'
    ELSE 'lapsed' END;
$$;

CREATE OR REPLACE FUNCTION public.gsmp_is_active_member(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.members
                 WHERE id = p_id AND public.gsmp_member_state(membership_status, paid_until) IN ('active','grace'));
$$;
REVOKE ALL ON FUNCTION public.gsmp_is_active_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gsmp_is_active_member(uuid) TO anon, authenticated;

-- ---------- signup: code optional; nothing granted until approval ----------
CREATE OR REPLACE FUNCTION public.gsmp_enforce_referral()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code public.referral_codes%ROWTYPE;
BEGIN
  IF auth.role() IS NULL OR auth.role() = 'service_role' OR public.is_saas_admin() THEN
    RETURN NEW;
  END IF;

  NEW.membership_status := 'applicant';
  NEW.paid_until := NULL;
  NEW.applied_at := now();
  NEW.reviewed_by := NULL; NEW.reviewed_at := NULL; NEW.review_note := NULL;
  NEW.chapter_id := NULL;               -- granted only on approval
  NEW.requested_chapter_id := NULL;

  IF NEW.referred_by IS NOT NULL AND btrim(NEW.referred_by) <> '' THEN
    NEW.referred_by := upper(btrim(NEW.referred_by));
    SELECT * INTO v_code FROM public.referral_codes WHERE code = NEW.referred_by AND active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invalid or expired referral code. Leave it empty to apply without one.';
    END IF;
    IF COALESCE(v_code.max_uses, 0) > 0 AND v_code.times_used >= v_code.max_uses THEN
      RAISE EXCEPTION 'This referral code has reached its usage limit. Leave it empty to apply without one.';
    END IF;
    NEW.requested_chapter_id := COALESCE(v_code.chapter_id,
      (SELECT m.chapter_id FROM public.members m WHERE m.referral_code = NEW.referred_by LIMIT 1));
  ELSE
    NEW.referred_by := NULL;
  END IF;
  RETURN NEW;
END $$;

-- ---------- privilege guard: members can't change their own membership ----------
CREATE OR REPLACE FUNCTION public.gsmp_guard_member_privileges()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL AND TG_OP = 'UPDATE' THEN RETURN NEW; END IF;
  IF public.is_saas_admin() THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.member_title := NULL;
    RETURN NEW;
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status
     OR NEW.paid_until IS DISTINCT FROM OLD.paid_until
     OR NEW.requested_chapter_id IS DISTINCT FROM OLD.requested_chapter_id
     OR NEW.review_note IS DISTINCT FROM OLD.review_note
     OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     OR NEW.applied_at IS DISTINCT FROM OLD.applied_at THEN
    RAISE EXCEPTION 'Only GSMP admins can change membership status or payment.';
  END IF;

  IF NEW.member_title IS DISTINCT FROM OLD.member_title THEN
    IF NOT (public.gsmp_is_chapter_lead()
            AND OLD.id <> auth.uid()
            AND OLD.chapter_id = public.gsmp_my_chapter()
            AND NEW.member_title IN ('Member','Active Member','Senior Member','Ambassador')) THEN
      RAISE EXCEPTION 'Not allowed to change member_title';
    END IF;
  END IF;

  IF NEW.chapter_id IS DISTINCT FROM OLD.chapter_id AND NOT public.gsmp_is_chapter_lead() THEN
    RAISE EXCEPTION 'Not allowed to change chapter';
  END IF;
  RETURN NEW;
END $$;

-- ---------- admin review: approval grants chapter + consumes the code ----------
CREATE OR REPLACE FUNCTION public.gsmp_member_review()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    NEW.reviewed_by := public.gsmp_actor_email();
    NEW.reviewed_at := now();

    IF OLD.membership_status IN ('applicant','rejected') AND NEW.membership_status IN ('approved','active') THEN
      NEW.chapter_id := COALESCE(NEW.chapter_id, NEW.requested_chapter_id);
      IF NEW.referred_by IS NOT NULL THEN
        UPDATE public.referral_codes SET times_used = times_used + 1 WHERE code = NEW.referred_by;
      END IF;
      -- applicant's own invite code becomes usable, tied to their chapter
      UPDATE public.referral_codes SET active = true, chapter_id = COALESCE(chapter_id, NEW.chapter_id)
       WHERE code = NEW.referral_code AND note LIKE 'Auto:%';
    END IF;

    IF NEW.membership_status = 'active' AND NEW.paid_until IS NULL THEN
      NEW.paid_until := current_date + interval '1 year';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS gsmp_member_review ON public.members;
CREATE TRIGGER gsmp_member_review BEFORE UPDATE ON public.members
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_member_review();

-- ---------- personal invite code inactive until the member is approved ----------
CREATE OR REPLACE FUNCTION public.create_personal_referral_code()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.referral_code IS NOT NULL THEN
    INSERT INTO public.referral_codes (code, note, max_uses, times_used, active, chapter_id, created_by)
    VALUES (NEW.referral_code,
            'Auto: ' || COALESCE(NEW.first_name,'') || ' ' || COALESCE(NEW.last_name,''),
            5, 0, NEW.membership_status IN ('approved','active'), NEW.chapter_id, NEW.email)
    ON CONFLICT (code) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;

-- ---------- public member card only for active members ----------
CREATE OR REPLACE FUNCTION public.get_member_card(p_code text)
RETURNS TABLE (first_name text, last_name text, school text, year text, country text,
               city text, email text, phone text, chapter_id uuid, degree text,
               field text, specialty text, member_title text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT m.first_name, m.last_name, m.school, m.year, m.country, m.city, m.email,
         m.phone, m.chapter_id, m.degree, m.field, m.specialty, m.member_title
  FROM public.members m
  WHERE m.referral_code = upper(p_code) AND length(p_code) >= 6
    AND public.gsmp_member_state(m.membership_status, m.paid_until) IN ('active','grace')
  LIMIT 1;
$$;

-- ---------- portfolio: only for active members; paused when lapsed ----------
CREATE OR REPLACE FUNCTION public.gsmp_portfolio_member_active()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.gsmp_is_active_member(NEW.member_id) THEN
    RAISE EXCEPTION 'Only active (paid) members can have a Verified Portfolio.';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS gsmp_portfolio_member_active ON public.portfolios;
CREATE TRIGGER gsmp_portfolio_member_active BEFORE INSERT ON public.portfolios
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_portfolio_member_active();

CREATE OR REPLACE FUNCTION public.get_portfolio_public(p_public_id text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH x AS (
    SELECT p.*, m.first_name, m.last_name, m.member_title, m.degree, m.specialty, m.school,
           m.country, m.email AS m_email, m.phone AS m_phone, c.name AS chapter_name,
           CASE WHEN p.status = 'active'
                 AND public.gsmp_member_state(m.membership_status, m.paid_until) NOT IN ('active','grace')
                THEN 'paused' ELSE p.status END AS eff
    FROM public.portfolios p
    JOIN public.members m ON m.id = p.member_id
    LEFT JOIN public.chapters c ON c.id = m.chapter_id
    WHERE p.public_id = p_public_id AND length(p_public_id) = 32 AND p.status <> 'draft'
  )
  SELECT jsonb_build_object(
    'status', x.eff,
    'identity_verified', x.identity_verified,
    'version', x.version,
    'published_at', x.published_at,
    'updated_at', x.updated_at,
    'headline', x.headline,
    'bio', CASE WHEN x.eff = 'active' THEN x.bio END,
    'name', initcap(x.first_name) || ' ' || initcap(x.last_name),
    'member_title', COALESCE(x.member_title, 'Member'),
    'degree', x.degree, 'specialty', x.specialty, 'school', x.school, 'country', x.country,
    'chapter', x.chapter_name,
    'email', CASE WHEN x.eff = 'active' AND x.show_email THEN x.m_email END,
    'phone', CASE WHEN x.eff = 'active' AND x.show_phone THEN x.m_phone END,
    'claims', CASE WHEN x.eff = 'active' THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'section', pc.section, 'title', pc.title, 'organization', pc.organization,
               'role', pc.role, 'period', pc.period, 'description', pc.description,
               'status', pc.status, 'method', pc.method, 'verified_at', pc.verified_at)
             ORDER BY pc.section, pc.sort_order, pc.created_at)
      FROM public.portfolio_claims pc
      WHERE pc.portfolio_id = x.id AND pc.status IN ('verified','self_declared')
    ), '[]'::jsonb) ELSE '[]'::jsonb END)
  FROM x;
$$;

COMMIT;

-- ---------- Checks (read-only) ----------
-- select membership_status, count(*) from members group by 1;      -- all 'active' right after running
-- select value from site_settings where key = 'membership_payment_instructions';
