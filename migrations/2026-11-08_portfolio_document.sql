-- ============================================================
-- GSMP — Verified Portfolio "document" (editorial A4 portfolio) — 2026-11-08
--
-- * Portfolio: cover photo, quote, tagline, longer story, logbook summary.
-- * Claims: 10 sections (clinical journey, operating theatre, logbook-backed
--   research, memberships, initiatives, awards, media, CME, beyond medicine,
--   education), optional photo, optional PUBLIC link, cover highlight flag.
-- * Media: public bucket `portfolio-media`; members write only to <their uid>/.
-- * Patient privacy: a theatre ("surgical") claim with a photo must carry a
--   consent/de-identification confirmation and can NEVER be self-declared —
--   it is only published after an admin has seen the photo and verified it.
-- * Integrity: an admin acting on THEIR OWN portfolio is treated as a member
--   (cannot verify own claims, activate own portfolio or tick own identity).
-- Run ONCE in Supabase SQL Editor, BEFORE merging the pages. Transactional.
-- ============================================================
BEGIN;

-- ---------- portfolio fields ----------
ALTER TABLE public.portfolios
  ADD COLUMN photo_url text CHECK (photo_url IS NULL OR photo_url ~* '^https://[^ ]+$'),
  ADD COLUMN quote text CHECK (char_length(quote) <= 200),
  ADD COLUMN tagline text CHECK (char_length(tagline) <= 80),
  ADD COLUMN logbook_total integer CHECK (logbook_total IS NULL OR logbook_total BETWEEN 0 AND 100000),
  ADD COLUMN logbook_curated integer CHECK (logbook_curated IS NULL OR logbook_curated BETWEEN 0 AND 100000),
  ADD COLUMN logbook_note text CHECK (char_length(logbook_note) <= 800);
ALTER TABLE public.portfolios DROP CONSTRAINT IF EXISTS portfolios_bio_check;
ALTER TABLE public.portfolios ADD CONSTRAINT portfolios_bio_check CHECK (char_length(bio) <= 4000);

-- ---------- claim fields ----------
ALTER TABLE public.portfolio_claims DROP CONSTRAINT IF EXISTS portfolio_claims_section_check;
ALTER TABLE public.portfolio_claims ADD CONSTRAINT portfolio_claims_section_check CHECK (section IN
  ('education','clinical','surgical','research','membership','initiative','award','media','credential','beyond'));
ALTER TABLE public.portfolio_claims
  ADD COLUMN image_url text CHECK (image_url IS NULL OR image_url ~* '^https://[^ ]+$'),
  ADD COLUMN public_url text CHECK (public_url IS NULL OR public_url ~* '^https://[^ ]+$'),
  ADD COLUMN highlight boolean NOT NULL DEFAULT false,
  ADD COLUMN consent_confirmed boolean NOT NULL DEFAULT false;
ALTER TABLE public.portfolio_claims ADD CONSTRAINT portfolio_claims_theatre_photo_consent
  CHECK (NOT (section = 'surgical' AND image_url IS NOT NULL AND NOT consent_confirmed));
ALTER TABLE public.portfolio_claims ADD CONSTRAINT portfolio_claims_theatre_photo_not_self_declared
  CHECK (NOT (section = 'surgical' AND image_url IS NOT NULL AND status = 'self_declared'));

-- ---------- helper: is the caller the owner of this portfolio? ----------
CREATE OR REPLACE FUNCTION public.gsmp_is_own_portfolio(p_portfolio uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.portfolios WHERE id = p_portfolio AND member_id = auth.uid());
$$;
REVOKE ALL ON FUNCTION public.gsmp_is_own_portfolio(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gsmp_is_own_portfolio(uuid) TO anon, authenticated;

-- ---------- portfolio guard: admins can't self-approve ----------
CREATE OR REPLACE FUNCTION public.gsmp_guard_portfolio()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.updated_at := now();

  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active'
     AND NOT EXISTS (SELECT 1 FROM public.portfolio_claims
                     WHERE portfolio_id = NEW.id AND status = 'verified') THEN
    RAISE EXCEPTION 'Verify at least one credential before activating this portfolio.';
  END IF;

  IF pg_trigger_depth() > 1 OR auth.uid() IS NULL
     OR (public.is_saas_admin() AND OLD.member_id <> auth.uid()) THEN
    IF NEW.status = 'active' AND NEW.published_at IS NULL THEN NEW.published_at := now(); END IF;
    RETURN NEW;
  END IF;

  IF NEW.member_id IS DISTINCT FROM OLD.member_id
     OR NEW.public_id IS DISTINCT FROM OLD.public_id
     OR NEW.status IS DISTINCT FROM OLD.status
     OR NEW.identity_verified IS DISTINCT FROM OLD.identity_verified
     OR NEW.version IS DISTINCT FROM OLD.version
     OR NEW.published_at IS DISTINCT FROM OLD.published_at THEN
    RAISE EXCEPTION 'Status and identity of your own portfolio are set by another GSMP admin.';
  END IF;
  RETURN NEW;
END $$;

-- ---------- claim guard: admins can't verify their own claims ----------
CREATE OR REPLACE FUNCTION public.gsmp_guard_claim()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reviewer boolean := auth.uid() IS NULL
    OR (public.is_saas_admin() AND NOT public.gsmp_is_own_portfolio(NEW.portfolio_id));
BEGIN
  NEW.updated_at := now();

  IF v_reviewer THEN
    IF NEW.status = 'verified' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'verified') THEN
      NEW.verified_at := now();
      NEW.verified_by := public.gsmp_actor_email();
    ELSIF NEW.status <> 'verified' THEN
      NEW.verified_at := NULL; NEW.verified_by := NULL;
    END IF;
    RETURN NEW;
  END IF;

  -- owner (including an admin editing their own portfolio)
  IF TG_OP = 'UPDATE' AND OLD.status IN ('verified','rejected') THEN
    -- reviewed content is locked; only the cover-highlight flag may change
    IF (NEW.portfolio_id, NEW.section, NEW.title, NEW.organization, NEW.role, NEW.period, NEW.description,
        NEW.evidence_url, NEW.issuer_email, NEW.status, NEW.image_url, NEW.public_url, NEW.consent_confirmed,
        NEW.method, NEW.reviewer_note, NEW.verified_by, NEW.verified_at)
       IS DISTINCT FROM
       (OLD.portfolio_id, OLD.section, OLD.title, OLD.organization, OLD.role, OLD.period, OLD.description,
        OLD.evidence_url, OLD.issuer_email, OLD.status, OLD.image_url, OLD.public_url, OLD.consent_confirmed,
        OLD.method, OLD.reviewer_note, OLD.verified_by, OLD.verified_at) THEN
      RAISE EXCEPTION 'This credential has been reviewed and is locked. Add a new one instead.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status NOT IN ('draft','submitted','self_declared') THEN
    RAISE EXCEPTION 'You can save your own credential as draft, submitted or self-declared. Another admin verifies it.';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.method := NULL; NEW.reviewer_note := NULL; NEW.verified_by := NULL; NEW.verified_at := NULL;
  ELSE
    IF NEW.portfolio_id IS DISTINCT FROM OLD.portfolio_id THEN
      RAISE EXCEPTION 'Cannot move a credential to another portfolio.';
    END IF;
    NEW.method := OLD.method; NEW.reviewer_note := OLD.reviewer_note;
    NEW.verified_by := NULL; NEW.verified_at := NULL;
  END IF;
  RETURN NEW;
END $$;

-- ---------- media bucket ----------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('portfolio-media', 'portfolio-media', true, 3145728, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = 3145728,
  allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp'];

DROP POLICY IF EXISTS "Portfolio media public read" ON storage.objects;
CREATE POLICY "Portfolio media public read" ON storage.objects
  FOR SELECT USING (bucket_id = 'portfolio-media');
DROP POLICY IF EXISTS "Members upload own portfolio media" ON storage.objects;
CREATE POLICY "Members upload own portfolio media" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (
    bucket_id = 'portfolio-media'
    AND (storage.foldername(name))[1] = auth.uid()::text
    AND public.gsmp_is_active_member(auth.uid()));
DROP POLICY IF EXISTS "Members manage own portfolio media" ON storage.objects;
CREATE POLICY "Members manage own portfolio media" ON storage.objects
  FOR DELETE TO authenticated USING (
    bucket_id = 'portfolio-media' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.is_saas_admin()));

-- ---------- public document payload ----------
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
    'tagline', CASE WHEN x.eff = 'active' THEN x.tagline END,
    'quote', CASE WHEN x.eff = 'active' THEN x.quote END,
    'photo_url', CASE WHEN x.eff = 'active' THEN x.photo_url END,
    'bio', CASE WHEN x.eff = 'active' THEN x.bio END,
    'logbook_total', CASE WHEN x.eff = 'active' THEN x.logbook_total END,
    'logbook_curated', CASE WHEN x.eff = 'active' THEN x.logbook_curated END,
    'logbook_note', CASE WHEN x.eff = 'active' THEN x.logbook_note END,
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
               'status', pc.status, 'method', pc.method, 'verified_at', pc.verified_at,
               'image_url', pc.image_url, 'public_url', pc.public_url, 'highlight', pc.highlight)
             ORDER BY pc.section, pc.sort_order, pc.created_at)
      FROM public.portfolio_claims pc
      WHERE pc.portfolio_id = x.id AND pc.status IN ('verified','self_declared')
    ), '[]'::jsonb) ELSE '[]'::jsonb END)
  FROM x;
$$;

COMMIT;
