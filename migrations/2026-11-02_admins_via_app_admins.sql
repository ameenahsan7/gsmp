-- ============================================================
-- GSMP — single source of truth for admins — 2026-11-02
-- Replaces every policy that hard-codes admin emails with
-- public.is_saas_admin() (backed by public.app_admins), and removes
-- the employer (propertyfinder.ae) address from admin access.
-- Run ONCE in Supabase SQL Editor. Transactional: all or nothing.
--
-- To add/remove an admin later:  INSERT/DELETE in public.app_admins.
-- ============================================================
BEGIN;

-- 0. Admin roster: personal address only
INSERT INTO public.app_admins (email) VALUES ('ameenahsan7@gmail.com')
  ON CONFLICT (email) DO NOTHING;
DELETE FROM public.app_admins WHERE lower(email) LIKE '%@propertyfinder.ae';

-- Safety net: abort if the roster would be empty (would lock you out)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.app_admins) THEN
    RAISE EXCEPTION 'app_admins is empty — aborting';
  END IF;
END $$;

-- 1. Drop all hard-coded-email policies
DROP POLICY IF EXISTS "Admins can read logs"            ON public.activity_logs;
DROP POLICY IF EXISTS "Admins full access articles"     ON public.articles;
DROP POLICY IF EXISTS "Admins can delete chapters"      ON public.chapters;
DROP POLICY IF EXISTS "Admins can insert chapters"      ON public.chapters;
DROP POLICY IF EXISTS "Admins can update chapters"      ON public.chapters;
DROP POLICY IF EXISTS "Admins full access chapters"     ON public.chapters;
DROP POLICY IF EXISTS "Admins full access rsvps"        ON public.event_rsvps;
DROP POLICY IF EXISTS "Admins full access events"       ON public.events;
DROP POLICY IF EXISTS "Admins can delete members"       ON public.members;
DROP POLICY IF EXISTS "Admins can update members"       ON public.members;
DROP POLICY IF EXISTS "Admins can view all members"     ON public.members;
DROP POLICY IF EXISTS "Admins full access members"      ON public.members;
DROP POLICY IF EXISTS "Admins can delete codes"         ON public.referral_codes;
DROP POLICY IF EXISTS "Admins can insert codes"         ON public.referral_codes;
DROP POLICY IF EXISTS "Admins can update codes"         ON public.referral_codes;
DROP POLICY IF EXISTS "Admins full access referral codes" ON public.referral_codes;
DROP POLICY IF EXISTS "Admins full access shop items"   ON public.shop_items;
DROP POLICY IF EXISTS "Admins can modify site settings" ON public.site_settings;

-- 2. Recreate, one per table, via is_saas_admin()
CREATE POLICY "Admins can read logs" ON public.activity_logs
  FOR SELECT TO authenticated USING (public.is_saas_admin());

CREATE POLICY "Admins full access articles" ON public.articles
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins full access chapters" ON public.chapters
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins full access rsvps" ON public.event_rsvps
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins full access events" ON public.events
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins full access members" ON public.members
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins full access referral codes" ON public.referral_codes
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins full access shop items" ON public.shop_items
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Admins can modify site settings" ON public.site_settings
  FOR ALL TO authenticated USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());

-- members: self-read was bundled into the old admin SELECT policy — keep it
CREATE POLICY "Users can view own record" ON public.members
  FOR SELECT USING (auth.uid() = id);

COMMIT;

-- ---------- Check (read-only): should return 0 rows ----------
-- select tablename, policyname from pg_policies
--  where coalesce(qual,'') || coalesce(with_check,'') ilike '%@%';
