-- ============================================================
-- GSMP security lockdown — 2026-11-01
-- Run ONCE in Supabase SQL Editor. Wrapped in a transaction:
-- if any statement fails, nothing is applied.
--
-- Closes:
--   1. articles: anyone (even logged-out) could create/edit/delete articles
--   2. members: any signed-in user could read every member's email/phone
--   3. members: any member could promote themselves to 'Chapter Lead'
--   4. members: logged-out insert with no checks (fake member rows)
--   5. chapters / referral_codes: any Chapter Lead could edit/delete ALL chapters/codes
-- Keeps working: signup, public profile card, chapter-admin, admin.
-- ============================================================
BEGIN;

-- ---------- Helpers (SECURITY DEFINER = no RLS recursion) ----------
CREATE OR REPLACE FUNCTION public.gsmp_my_chapter()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT chapter_id FROM public.members WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.gsmp_is_chapter_lead()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.members
                 WHERE id = auth.uid() AND member_title = 'Chapter Lead');
$$;

-- Signup inserts the member row right after auth.signUp, possibly before
-- email confirmation (no session). Allow it only for a real, fresh auth user
-- whose email matches.
CREATE OR REPLACE FUNCTION public.gsmp_can_claim_member(p_id uuid, p_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth AS $$
  SELECT EXISTS (SELECT 1 FROM auth.users u
                 WHERE u.id = p_id
                   AND lower(u.email) = lower(p_email)
                   AND u.created_at > now() - interval '1 day');
$$;

REVOKE ALL ON FUNCTION public.gsmp_my_chapter(), public.gsmp_is_chapter_lead(),
                       public.gsmp_can_claim_member(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gsmp_my_chapter(), public.gsmp_is_chapter_lead()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.gsmp_can_claim_member(uuid, text) TO anon, authenticated;

-- Public business card: one member, by their referral code, fixed fields only.
CREATE OR REPLACE FUNCTION public.get_member_card(p_code text)
RETURNS TABLE (first_name text, last_name text, school text, year text, country text,
               city text, email text, phone text, chapter_id uuid, degree text,
               field text, specialty text, member_title text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT m.first_name, m.last_name, m.school, m.year, m.country, m.city, m.email,
         m.phone, m.chapter_id, m.degree, m.field, m.specialty, m.member_title
  FROM public.members m
  WHERE m.referral_code = upper(p_code) AND length(p_code) >= 6
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.get_member_card(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_member_card(text) TO anon, authenticated;

-- ---------- 1. articles ----------
DROP POLICY IF EXISTS "Admins can do everything with articles" ON public.articles;   -- USING(true): open to the world
DROP POLICY IF EXISTS "Anyone can view published articles"     ON public.articles;   -- USING(true): leaked drafts
-- kept: "Anyone can read published articles" (published = true), "Admins full access articles"

-- ---------- 2 + 4. members read / insert ----------
DROP POLICY IF EXISTS "Authenticated can view members" ON public.members;
DROP POLICY IF EXISTS "Users can insert own profile"   ON public.members;           -- WITH CHECK(true)

CREATE POLICY "Chapter leads can view own chapter members" ON public.members
  FOR SELECT USING (public.gsmp_is_chapter_lead() AND chapter_id = public.gsmp_my_chapter());

CREATE POLICY "New signups can create own profile" ON public.members
  FOR INSERT WITH CHECK (public.gsmp_can_claim_member(id, email));
-- kept: "Admins can view all members" (admins + self), "Users can insert own record"

-- ---------- 3. members: privilege fields ----------
CREATE OR REPLACE FUNCTION public.gsmp_guard_member_privileges()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- service role / SQL editor (no JWT) and SaaS admins are unrestricted
  IF auth.uid() IS NULL AND TG_OP = 'UPDATE' THEN RETURN NEW; END IF;
  IF public.is_saas_admin() THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.member_title := NULL;          -- shows as 'Member'
    RETURN NEW;
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

DROP TRIGGER IF EXISTS gsmp_guard_member_privileges ON public.members;
CREATE TRIGGER gsmp_guard_member_privileges
  BEFORE INSERT OR UPDATE ON public.members
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_guard_member_privileges();

-- ---------- 5. chapters / referral_codes scoped to own chapter ----------
DROP POLICY IF EXISTS "Chapter leads can manage own chapter" ON public.chapters;
CREATE POLICY "Chapter leads can create chapters" ON public.chapters
  FOR INSERT WITH CHECK (public.gsmp_is_chapter_lead());
CREATE POLICY "Chapter leads can update own chapter" ON public.chapters
  FOR UPDATE USING (public.gsmp_is_chapter_lead() AND id = public.gsmp_my_chapter())
  WITH CHECK (public.gsmp_is_chapter_lead() AND id = public.gsmp_my_chapter());
-- (leads can no longer DELETE chapters; admins still can)

DROP POLICY IF EXISTS "Chapter leads can manage codes" ON public.referral_codes;
CREATE POLICY "Chapter leads can manage own chapter codes" ON public.referral_codes
  FOR ALL USING (public.gsmp_is_chapter_lead() AND chapter_id = public.gsmp_my_chapter())
  WITH CHECK (public.gsmp_is_chapter_lead() AND chapter_id = public.gsmp_my_chapter());

COMMIT;

-- ---------- After running: sanity checks (read-only) ----------
-- Should return only activity_logs (log inserts are intentionally open to signed-in users):
-- select tablename, policyname, cmd from pg_policies
--  where schemaname='public' and cmd <> 'SELECT'
--    and (qual = 'true' or with_check = 'true');
