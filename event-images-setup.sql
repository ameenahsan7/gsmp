-- ============================================
-- GSMP — Event Images Storage Setup
-- Run this in Supabase SQL Editor (one-time, idempotent)
-- ============================================

-- Bucket: event-images (public read, restricted insert)
INSERT INTO storage.buckets (id, name, public)
  VALUES ('event-images', 'event-images', true)
  ON CONFLICT (id) DO NOTHING;

-- Public read (event images are embedded on the public homepage).
DROP POLICY IF EXISTS "Public can view event images" ON storage.objects;
CREATE POLICY "Public can view event images" ON storage.objects
  FOR SELECT
  USING (bucket_id = 'event-images');

-- Only Chapter Lead / Fellow / SaaS admin can upload.
DROP POLICY IF EXISTS "Event organizers can upload images" ON storage.objects;
CREATE POLICY "Event organizers can upload images" ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'event-images'
    AND auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR (SELECT member_title FROM public.members WHERE id = auth.uid()) IN ('Chapter Lead','Fellow')
    )
  );

-- Owners can delete their own uploads; SaaS admin can delete anything.
DROP POLICY IF EXISTS "Owners can delete own event images" ON storage.objects;
CREATE POLICY "Owners can delete own event images" ON storage.objects
  FOR DELETE
  USING (
    bucket_id = 'event-images'
    AND (owner = auth.uid() OR public.is_saas_admin())
  );
