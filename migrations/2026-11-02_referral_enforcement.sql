-- ============================================================
-- GSMP — server-side referral enforcement — 2026-11-02
-- Before: the referral code was checked only in the browser. Anyone could
-- sign up via the API with any chapter_id, and anyone could burn a code's
-- uses by calling validate_and_use_referral_code() repeatedly.
-- After:
--   * Every non-admin member INSERT must carry a valid referred_by code.
--     The DB validates it, sets chapter_id FROM the code, and consumes one
--     use — atomically, in the same transaction as the insert.
--   * validate_and_use_referral_code() becomes CHECK-ONLY (no use consumed),
--     kept for the join form's pre-check so users see errors before signUp.
--   * Personal (member) codes capped at PERSONAL_CODE_CAP invites.
-- Run ONCE in Supabase SQL Editor. Transactional: all or nothing.
-- ============================================================
BEGIN;

-- ---------- 1. Enforce referral on member insert ----------
CREATE OR REPLACE FUNCTION public.gsmp_enforce_referral()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code    public.referral_codes%ROWTYPE;
  v_chapter uuid;
BEGIN
  -- SQL editor (no JWT), service role, and SaaS admins are exempt
  IF auth.role() IS NULL OR auth.role() = 'service_role' OR public.is_saas_admin() THEN
    RETURN NEW;
  END IF;

  IF NEW.referred_by IS NULL OR btrim(NEW.referred_by) = '' THEN
    RAISE EXCEPTION 'A referral code is required to join GSMP.';
  END IF;
  NEW.referred_by := upper(btrim(NEW.referred_by));

  SELECT * INTO v_code FROM public.referral_codes
   WHERE code = NEW.referred_by AND active = true
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired referral code.';
  END IF;
  IF COALESCE(v_code.max_uses, 0) > 0 AND v_code.times_used >= v_code.max_uses THEN
    RAISE EXCEPTION 'This referral code has reached its usage limit.';
  END IF;

  -- Chapter comes from the code (or the referring member) — never from the client
  v_chapter := v_code.chapter_id;
  IF v_chapter IS NULL THEN
    SELECT m.chapter_id INTO v_chapter FROM public.members m
     WHERE m.referral_code = NEW.referred_by LIMIT 1;
  END IF;
  NEW.chapter_id := v_chapter;

  UPDATE public.referral_codes SET times_used = times_used + 1 WHERE id = v_code.id;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS gsmp_enforce_referral ON public.members;
CREATE TRIGGER gsmp_enforce_referral
  BEFORE INSERT ON public.members
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_enforce_referral();
-- (fires before gsmp_guard_member_privileges: BEFORE triggers run in name order)

-- ---------- 2. Pre-check no longer consumes a use ----------
CREATE OR REPLACE FUNCTION public.validate_and_use_referral_code(p_code text)
RETURNS TABLE(is_valid boolean, chapter_id uuid, error_message text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code public.referral_codes%ROWTYPE;
BEGIN
  SELECT * INTO v_code FROM public.referral_codes
   WHERE code = upper(btrim(p_code)) AND active = true;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL::uuid, 'Invalid or expired referral code.'::text; RETURN;
  END IF;
  IF COALESCE(v_code.max_uses, 0) > 0 AND v_code.times_used >= v_code.max_uses THEN
    RETURN QUERY SELECT FALSE, NULL::uuid, 'This referral code has reached its usage limit.'::text; RETURN;
  END IF;
  -- chapter_id no longer returned: the server decides it at insert time
  RETURN QUERY SELECT TRUE, NULL::uuid, NULL::text;
END $$;

-- ---------- 3. Cap personal (member) codes ----------
-- PERSONAL_CODE_CAP = 5. To change: edit both the function and the UPDATE below.
CREATE OR REPLACE FUNCTION public.create_personal_referral_code()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.referral_code IS NOT NULL THEN
    INSERT INTO public.referral_codes
      (code, note, max_uses, times_used, active, chapter_id, created_by)
    VALUES
      (NEW.referral_code,
       'Auto: ' || COALESCE(NEW.first_name,'') || ' ' || COALESCE(NEW.last_name,''),
       5, 0, true, NEW.chapter_id, NEW.email)
    ON CONFLICT (code) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;

UPDATE public.referral_codes
   SET max_uses = 5
 WHERE note LIKE 'Auto:%' AND COALESCE(max_uses, 0) = 0;

COMMIT;

-- ---------- Checks (read-only) ----------
-- Personal codes now capped:
--   select count(*) filter (where max_uses = 5) capped, count(*) total
--   from referral_codes where note like 'Auto:%';
-- Codes already over the cap (existing members keep their members; code just stops working):
--   select code, times_used from referral_codes where note like 'Auto:%' and times_used >= 5;
