-- ============================================
-- GSMP — Gallery (Albums + Photos) Setup
-- Run in Supabase SQL Editor (idempotent)
-- ============================================

-- 1) TABLE: gallery_albums
--    One album per event/topic. chapter_id NULL = global.
CREATE TABLE IF NOT EXISTS public.gallery_albums (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title         TEXT NOT NULL,
  description   TEXT,
  event_date    DATE,
  chapter_id    UUID REFERENCES public.chapters(id) ON DELETE CASCADE,
  cover_url     TEXT,
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_gallery_albums_chapter ON public.gallery_albums(chapter_id);
CREATE INDEX IF NOT EXISTS idx_gallery_albums_date    ON public.gallery_albums(event_date DESC NULLS LAST);

-- 2) TABLE: gallery_photos
--    Photos inside an album. Cascade delete when album is removed.
CREATE TABLE IF NOT EXISTS public.gallery_photos (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  album_id      UUID NOT NULL REFERENCES public.gallery_albums(id) ON DELETE CASCADE,
  image_url     TEXT NOT NULL,
  caption       TEXT,
  display_order INT NOT NULL DEFAULT 0,
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_gallery_photos_album ON public.gallery_photos(album_id, display_order);

-- 3) RLS — albums
ALTER TABLE public.gallery_albums ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view albums" ON public.gallery_albums;
CREATE POLICY "Public can view albums" ON public.gallery_albums
  FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Organizers can insert albums" ON public.gallery_albums;
CREATE POLICY "Organizers can insert albums" ON public.gallery_albums
  FOR INSERT
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR (SELECT member_title FROM public.members WHERE id = auth.uid()) IN ('Chapter Lead','Fellow')
    )
  );

DROP POLICY IF EXISTS "Organizers can update own albums" ON public.gallery_albums;
CREATE POLICY "Organizers can update own albums" ON public.gallery_albums
  FOR UPDATE
  USING (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR created_by = (SELECT email FROM public.members WHERE id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "Organizers can delete own albums" ON public.gallery_albums;
CREATE POLICY "Organizers can delete own albums" ON public.gallery_albums
  FOR DELETE
  USING (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR created_by = (SELECT email FROM public.members WHERE id = auth.uid())
    )
  );

-- 4) RLS — photos (mirror album permissions)
ALTER TABLE public.gallery_photos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view photos" ON public.gallery_photos;
CREATE POLICY "Public can view photos" ON public.gallery_photos
  FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Organizers can insert photos" ON public.gallery_photos;
CREATE POLICY "Organizers can insert photos" ON public.gallery_photos
  FOR INSERT
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR EXISTS (
        SELECT 1
        FROM public.gallery_albums a
        JOIN public.members m ON m.id = auth.uid()
        WHERE a.id = gallery_photos.album_id
          AND m.member_title IN ('Chapter Lead','Fellow')
          AND (a.chapter_id IS NULL OR a.chapter_id = m.chapter_id)
      )
    )
  );

DROP POLICY IF EXISTS "Organizers can update own photos" ON public.gallery_photos;
CREATE POLICY "Organizers can update own photos" ON public.gallery_photos
  FOR UPDATE
  USING (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR created_by = (SELECT email FROM public.members WHERE id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "Organizers can delete own photos" ON public.gallery_photos;
CREATE POLICY "Organizers can delete own photos" ON public.gallery_photos
  FOR DELETE
  USING (
    auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR created_by = (SELECT email FROM public.members WHERE id = auth.uid())
    )
  );

-- 5) STORAGE BUCKET: gallery-images
INSERT INTO storage.buckets (id, name, public)
  VALUES ('gallery-images', 'gallery-images', true)
  ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "Public can view gallery images" ON storage.objects;
CREATE POLICY "Public can view gallery images" ON storage.objects
  FOR SELECT
  USING (bucket_id = 'gallery-images');

DROP POLICY IF EXISTS "Organizers can upload gallery images" ON storage.objects;
CREATE POLICY "Organizers can upload gallery images" ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'gallery-images'
    AND auth.uid() IS NOT NULL
    AND (
      public.is_saas_admin()
      OR (SELECT member_title FROM public.members WHERE id = auth.uid()) IN ('Chapter Lead','Fellow')
    )
  );

DROP POLICY IF EXISTS "Owners can delete own gallery images" ON storage.objects;
CREATE POLICY "Owners can delete own gallery images" ON storage.objects
  FOR DELETE
  USING (
    bucket_id = 'gallery-images'
    AND (owner = auth.uid() OR public.is_saas_admin())
  );

-- 6) updated_at trigger on albums
CREATE OR REPLACE FUNCTION public.touch_gallery_album_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS gallery_albums_touch ON public.gallery_albums;
CREATE TRIGGER gallery_albums_touch
  BEFORE UPDATE ON public.gallery_albums
  FOR EACH ROW EXECUTE FUNCTION public.touch_gallery_album_updated_at();

-- ============================================
-- Verify after run:
--   SELECT policyname, cmd FROM pg_policies
--   WHERE schemaname='public' AND tablename IN ('gallery_albums','gallery_photos')
--   ORDER BY tablename, cmd;
-- ============================================
