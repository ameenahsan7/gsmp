-- ============================================
-- GSMP — Announcements / Noticeboard Setup
-- Run this in Supabase SQL Editor (one-time)
-- Idempotent: safe to re-run.
-- ============================================

-- =========================================
-- 1) Source-of-truth: SaaS admin allowlist
-- =========================================
CREATE TABLE IF NOT EXISTS public.app_admins (
  email TEXT PRIMARY KEY,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed admin (gmail only — never seed work emails).
-- Add more later via: INSERT INTO public.app_admins (email) VALUES ('someone@example.com');
INSERT INTO public.app_admins (email) VALUES
  ('ameenahsan7@gmail.com')
ON CONFLICT (email) DO NOTHING;

ALTER TABLE public.app_admins ENABLE ROW LEVEL SECURITY;

-- Lock the table down. is_saas_admin() uses SECURITY DEFINER and bypasses RLS.
DROP POLICY IF EXISTS "Admins can view admin list" ON public.app_admins;
CREATE POLICY "Admins can view admin list" ON public.app_admins
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM auth.users u WHERE u.id = auth.uid() AND u.email = public.app_admins.email)
  );

-- =========================================
-- 2) Helper function: is_saas_admin()
--    SECURITY DEFINER => runs with owner privileges, bypasses RLS on app_admins.
-- =========================================
CREATE OR REPLACE FUNCTION public.is_saas_admin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, auth
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.app_admins a
    JOIN auth.users u ON u.email = a.email
    WHERE u.id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_saas_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_saas_admin() TO authenticated, anon;

-- =========================================
-- 3) Announcements table
-- =========================================
CREATE TABLE IF NOT EXISTS public.announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chapter_id UUID REFERENCES public.chapters(id) ON DELETE CASCADE, -- NULL = global (SaaS admin only)
  author_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 160),
  body TEXT NOT NULL DEFAULT '' CHECK (char_length(body) <= 4000),
  image_url TEXT,
  is_pinned BOOLEAN NOT NULL DEFAULT FALSE,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_announcements_chapter ON public.announcements(chapter_id);
CREATE INDEX IF NOT EXISTS idx_announcements_pinned_created
  ON public.announcements(is_pinned DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_announcements_author ON public.announcements(author_id);

ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

-- ---- SELECT ----
-- Members see global notices + their own chapter's notices; SaaS admins see all.
DROP POLICY IF EXISTS "Visible announcements" ON public.announcements;
CREATE POLICY "Visible announcements" ON public.announcements
  FOR SELECT
  USING (
    public.is_saas_admin()
    OR chapter_id IS NULL
    OR chapter_id = (SELECT chapter_id FROM public.members WHERE id = auth.uid())
  );

-- ---- INSERT ----
-- SaaS admin: any chapter or global.
-- Chapter Lead / Fellow: only their own chapter (no global posts).
DROP POLICY IF EXISTS "Authors can insert announcements" ON public.announcements;
CREATE POLICY "Authors can insert announcements" ON public.announcements
  FOR INSERT
  WITH CHECK (
    author_id = auth.uid()
    AND (
      public.is_saas_admin()
      OR (
        chapter_id IS NOT NULL
        AND chapter_id = (SELECT chapter_id FROM public.members WHERE id = auth.uid())
        AND (SELECT member_title FROM public.members WHERE id = auth.uid()) IN ('Chapter Lead','Fellow')
      )
    )
  );

-- ---- UPDATE ----
-- Author can edit their own; SaaS admin can edit anything.
-- WITH CHECK re-applies scope rules so a Chapter Lead/Fellow cannot
-- escalate by changing chapter_id to NULL (global) or to another chapter.
DROP POLICY IF EXISTS "Authors can update own announcements" ON public.announcements;
CREATE POLICY "Authors can update own announcements" ON public.announcements
  FOR UPDATE
  USING (author_id = auth.uid() OR public.is_saas_admin())
  WITH CHECK (
    (author_id = auth.uid() OR public.is_saas_admin())
    AND (
      public.is_saas_admin()
      OR (
        chapter_id IS NOT NULL
        AND chapter_id = (SELECT chapter_id FROM public.members WHERE id = auth.uid())
        AND (SELECT member_title FROM public.members WHERE id = auth.uid()) IN ('Chapter Lead','Fellow')
      )
    )
  );

-- ---- DELETE ----
DROP POLICY IF EXISTS "Authors can delete own announcements" ON public.announcements;
CREATE POLICY "Authors can delete own announcements" ON public.announcements
  FOR DELETE
  USING (author_id = auth.uid() OR public.is_saas_admin());

-- =========================================
-- 4) updated_at trigger
-- =========================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS announcements_updated_at ON public.announcements;
CREATE TRIGGER announcements_updated_at
  BEFORE UPDATE ON public.announcements
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =========================================
-- 5) Storage bucket: announcement-images
-- =========================================
INSERT INTO storage.buckets (id, name, public)
  VALUES ('announcement-images', 'announcement-images', true)
  ON CONFLICT (id) DO NOTHING;

-- Public read (images are embedded in the noticeboard — public URLs are fine).
DROP POLICY IF EXISTS "Public can view announcement images" ON storage.objects;
CREATE POLICY "Public can view announcement images" ON storage.objects
  FOR SELECT
  USING (bucket_id = 'announcement-images');

-- Only Chapter Lead / Fellow / SaaS admin can upload.
DROP POLICY IF EXISTS "Authors can upload announcement images" ON storage.objects;
CREATE POLICY "Authors can upload announcement images" ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'announcement-images'
    AND auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR (SELECT member_title FROM public.members WHERE id = auth.uid()) IN ('Chapter Lead','Fellow')
    )
  );

-- Owners can delete their own uploads; SaaS admin can delete anything.
DROP POLICY IF EXISTS "Authors can delete own announcement images" ON storage.objects;
CREATE POLICY "Authors can delete own announcement images" ON storage.objects
  FOR DELETE
  USING (
    bucket_id = 'announcement-images'
    AND (owner = auth.uid() OR public.is_saas_admin())
  );

-- ============================================
-- Done. Run from Supabase Dashboard > SQL Editor.
-- After running, create one test announcement to verify RLS:
--   INSERT INTO public.announcements (chapter_id, author_id, title, body)
--   VALUES (NULL, auth.uid(), 'Welcome to the Noticeboard', 'This is a global announcement.');
-- ============================================
