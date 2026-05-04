-- ============================================
-- GSMP — referral_codes RLS hardening
-- Run in Supabase SQL Editor (idempotent)
-- ============================================

-- 1) Drop the over-permissive policies that allow anon read/insert/update.
DROP POLICY IF EXISTS "Anyone can read active codes"     ON public.referral_codes;
DROP POLICY IF EXISTS "Anyone can view codes"            ON public.referral_codes;
DROP POLICY IF EXISTS "Anyone can view referral codes"   ON public.referral_codes;
DROP POLICY IF EXISTS "Anyone can insert codes"          ON public.referral_codes;
DROP POLICY IF EXISTS "Anyone can update codes"          ON public.referral_codes;
DROP POLICY IF EXISTS "Anyone can increment code usage"  ON public.referral_codes;

-- 2) Authenticated SELECT: own chapter only, or SaaS admin sees all.
DROP POLICY IF EXISTS "Members can view chapter codes" ON public.referral_codes;
CREATE POLICY "Members can view chapter codes" ON public.referral_codes
  FOR SELECT
  USING (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR chapter_id = (SELECT chapter_id FROM public.members WHERE id = auth.uid())
    )
  );

-- 3) RPC for signup flow: validate code + atomically increment usage + resolve chapter.
--    Anon-callable. SECURITY DEFINER bypasses RLS for the read+update.
CREATE OR REPLACE FUNCTION public.validate_and_use_referral_code(p_code TEXT)
RETURNS TABLE (
  is_valid       BOOLEAN,
  chapter_id     UUID,
  error_message  TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     public.referral_codes%ROWTYPE;
  v_chapter  UUID;
BEGIN
  SELECT * INTO v_code
  FROM public.referral_codes
  WHERE code = p_code AND active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, 'Invalid or expired referral code.'::TEXT;
    RETURN;
  END IF;

  IF v_code.max_uses IS NOT NULL
     AND v_code.max_uses > 0
     AND v_code.times_used >= v_code.max_uses THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, 'This referral code has reached its usage limit.'::TEXT;
    RETURN;
  END IF;

  -- Resolve chapter: prefer code's chapter; otherwise use referrer member's chapter.
  v_chapter := v_code.chapter_id;
  IF v_chapter IS NULL THEN
    SELECT m.chapter_id INTO v_chapter
    FROM public.members m
    WHERE m.referral_code = p_code
    LIMIT 1;
  END IF;

  UPDATE public.referral_codes
  SET times_used = times_used + 1
  WHERE id = v_code.id;

  RETURN QUERY SELECT TRUE, v_chapter, NULL::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_and_use_referral_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_and_use_referral_code(TEXT) TO anon, authenticated;

-- 4) Trigger: when a new member is inserted, auto-create their personal referral code.
--    Replaces the previous anon INSERT path on referral_codes.
CREATE OR REPLACE FUNCTION public.create_personal_referral_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.referral_code IS NOT NULL THEN
    INSERT INTO public.referral_codes
      (code, note, max_uses, times_used, active, chapter_id, created_by)
    VALUES
      (NEW.referral_code,
       'Auto: ' || COALESCE(NEW.first_name,'') || ' ' || COALESCE(NEW.last_name,''),
       0,
       0,
       true,
       NEW.chapter_id,
       NEW.email)
    ON CONFLICT (code) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS members_create_personal_code ON public.members;
CREATE TRIGGER members_create_personal_code
  AFTER INSERT ON public.members
  FOR EACH ROW
  EXECUTE FUNCTION public.create_personal_referral_code();

-- ============================================
-- Verify after run:
--   SELECT policyname, cmd, roles::text, qual, with_check
--   FROM pg_policies
--   WHERE schemaname='public' AND tablename='referral_codes'
--   ORDER BY cmd, policyname;
--
--   Should show ONLY:
--     - "Members can view chapter codes" (SELECT)
--     - "Admins full access referral codes" (ALL)
--     - "Admins can delete codes" (DELETE)
--     - "Admins can insert codes" (INSERT)
--     - "Admins can update codes" (UPDATE)
--     - "Chapter leads can manage codes" (ALL)
--   Six "Anyone can ..." policies should be GONE.
-- ============================================
