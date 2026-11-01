-- ============================================================
-- GSMP — Verified Portfolio pilot (phase 1) — 2026-11-03
--
-- Model: verify at the CLAIM level, not the whole portfolio.
--   portfolios        one per member; created by an admin (= pilot invitation)
--   portfolio_claims  each credential, with its own status + verification method
--   claim_reviews     append-only audit log, written only by triggers
--
-- Phase 1 evidence = HTTPS links only (no file storage on the Free plan).
-- Public page reads ONLY through get_portfolio_public(public_id).
-- Evidence links and issuer emails are never exposed publicly.
--
-- Run ONCE in Supabase SQL Editor ("Run without RLS" if prompted — RLS is
-- enabled explicitly below). Transactional: all or nothing.
-- Safe to run before the pages are merged (adds new objects only).
-- ============================================================
BEGIN;

-- ---------- TABLES ----------
CREATE TABLE public.portfolios (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id         uuid NOT NULL UNIQUE REFERENCES public.members(id) ON DELETE CASCADE,
  public_id         text NOT NULL UNIQUE DEFAULT replace(gen_random_uuid()::text, '-', ''),
  status            text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','active','suspended','revoked')),
  identity_verified boolean NOT NULL DEFAULT false,
  headline          text CHECK (char_length(headline) <= 120),
  bio               text CHECK (char_length(bio) <= 1500),
  show_email        boolean NOT NULL DEFAULT false,
  show_phone        boolean NOT NULL DEFAULT false,
  version           integer NOT NULL DEFAULT 1,
  published_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.portfolio_claims (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  portfolio_id  uuid NOT NULL REFERENCES public.portfolios(id) ON DELETE CASCADE,
  section       text NOT NULL CHECK (section IN ('education','clinical','research','award')),
  title         text NOT NULL CHECK (char_length(title) BETWEEN 2 AND 200),
  organization  text CHECK (char_length(organization) <= 200),
  role          text CHECK (char_length(role) <= 120),
  period        text CHECK (char_length(period) <= 60),
  description   text CHECK (char_length(description) <= 1000),
  evidence_url  text CHECK (evidence_url IS NULL OR evidence_url ~* '^https://[^ ]+$'),
  issuer_email  text CHECK (issuer_email IS NULL OR issuer_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status        text NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','submitted','verified','needs_info','rejected','self_declared')),
  method        text CHECK (method IN ('issuer_email','registry_link','document_review')),
  reviewer_note text CHECK (char_length(reviewer_note) <= 1000),
  verified_by   text,
  verified_at   timestamptz,
  sort_order    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_portfolio_claims_portfolio ON public.portfolio_claims (portfolio_id);
CREATE INDEX idx_portfolio_claims_queue ON public.portfolio_claims (created_at) WHERE status = 'submitted';

CREATE TABLE public.claim_reviews (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  portfolio_id uuid,
  claim_id     uuid,          -- no FK: log survives claim deletion
  actor_email  text,
  action       text NOT NULL, -- 'claim_status' | 'claim_deleted' | 'portfolio_status' | 'identity'
  from_status  text,
  to_status    text,
  note         text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_claim_reviews_portfolio ON public.claim_reviews (portfolio_id, created_at DESC);

-- ---------- HELPERS ----------
CREATE OR REPLACE FUNCTION public.gsmp_owns_portfolio(p_portfolio uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.portfolios WHERE id = p_portfolio AND member_id = auth.uid());
$$;
REVOKE ALL ON FUNCTION public.gsmp_owns_portfolio(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gsmp_owns_portfolio(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.gsmp_actor_email()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(auth.jwt() ->> 'email', 'system');
$$;

-- ---------- PORTFOLIO GUARD (owners can edit content, not status) ----------
CREATE OR REPLACE FUNCTION public.gsmp_guard_portfolio()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.updated_at := now();
  -- nested updates from our own triggers (version bumps) and admins/SQL editor pass
  IF pg_trigger_depth() > 1 OR auth.uid() IS NULL OR public.is_saas_admin() THEN
    IF NEW.status = 'active' AND NEW.published_at IS NULL THEN NEW.published_at := now(); END IF;
    RETURN NEW;
  END IF;
  IF NEW.member_id IS DISTINCT FROM OLD.member_id
     OR NEW.public_id IS DISTINCT FROM OLD.public_id
     OR NEW.status IS DISTINCT FROM OLD.status
     OR NEW.identity_verified IS DISTINCT FROM OLD.identity_verified
     OR NEW.version IS DISTINCT FROM OLD.version
     OR NEW.published_at IS DISTINCT FROM OLD.published_at THEN
    RAISE EXCEPTION 'Only GSMP admins can change portfolio status or verification.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gsmp_guard_portfolio BEFORE UPDATE ON public.portfolios
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_guard_portfolio();

CREATE OR REPLACE FUNCTION public.gsmp_log_portfolio()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.claim_reviews (portfolio_id, actor_email, action, from_status, to_status)
    VALUES (NEW.id, public.gsmp_actor_email(), 'portfolio_status', OLD.status, NEW.status);
  END IF;
  IF NEW.identity_verified IS DISTINCT FROM OLD.identity_verified THEN
    INSERT INTO public.claim_reviews (portfolio_id, actor_email, action, from_status, to_status)
    VALUES (NEW.id, public.gsmp_actor_email(), 'identity', OLD.identity_verified::text, NEW.identity_verified::text);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gsmp_log_portfolio AFTER UPDATE ON public.portfolios
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_log_portfolio();

-- ---------- CLAIM GUARD (owners cannot verify their own claims) ----------
CREATE OR REPLACE FUNCTION public.gsmp_guard_claim()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.updated_at := now();

  IF auth.uid() IS NULL OR public.is_saas_admin() THEN
    -- admin: stamp / clear verification metadata
    IF NEW.status = 'verified' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'verified') THEN
      NEW.verified_at := now();
      NEW.verified_by := public.gsmp_actor_email();
    ELSIF NEW.status <> 'verified' THEN
      NEW.verified_at := NULL; NEW.verified_by := NULL;
    END IF;
    RETURN NEW;
  END IF;

  -- owner
  IF NEW.status NOT IN ('draft','submitted','self_declared') THEN
    RAISE EXCEPTION 'Members can only save a claim as draft, submitted or self-declared.';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.method := NULL; NEW.reviewer_note := NULL; NEW.verified_by := NULL; NEW.verified_at := NULL;
  ELSE
    IF NEW.portfolio_id IS DISTINCT FROM OLD.portfolio_id THEN
      RAISE EXCEPTION 'Cannot move a claim to another portfolio.';
    END IF;
    IF OLD.status IN ('verified','rejected') THEN
      RAISE EXCEPTION 'This claim has been reviewed and is locked. Add a new claim instead.';
    END IF;
    NEW.method := OLD.method; NEW.reviewer_note := OLD.reviewer_note;
    NEW.verified_by := NULL; NEW.verified_at := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gsmp_guard_claim BEFORE INSERT OR UPDATE ON public.portfolio_claims
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_guard_claim();

-- Audit + bump portfolio version whenever what the public sees changes
CREATE OR REPLACE FUNCTION public.gsmp_log_claim()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old text := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  v_new text := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.status END;
  v_pid uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.portfolio_id ELSE NEW.portfolio_id END;
  v_cid uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
BEGIN
  IF v_old IS DISTINCT FROM v_new THEN
    INSERT INTO public.claim_reviews (portfolio_id, claim_id, actor_email, action, from_status, to_status, note)
    VALUES (v_pid, v_cid, public.gsmp_actor_email(),
            CASE WHEN TG_OP = 'DELETE' THEN 'claim_deleted' ELSE 'claim_status' END,
            v_old, v_new,
            CASE WHEN TG_OP = 'UPDATE' THEN NEW.reviewer_note END);
  END IF;
  IF v_old IN ('verified','self_declared') OR v_new IN ('verified','self_declared') THEN
    UPDATE public.portfolios SET version = version + 1 WHERE id = v_pid;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER gsmp_log_claim AFTER INSERT OR UPDATE OR DELETE ON public.portfolio_claims
  FOR EACH ROW EXECUTE FUNCTION public.gsmp_log_claim();

-- ---------- RLS ----------
ALTER TABLE public.portfolios       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.portfolio_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.claim_reviews    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins full access portfolios" ON public.portfolios
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Owners view own portfolio" ON public.portfolios
  FOR SELECT USING (member_id = auth.uid());
CREATE POLICY "Owners update own portfolio" ON public.portfolios
  FOR UPDATE USING (member_id = auth.uid()) WITH CHECK (member_id = auth.uid());
-- (no owner INSERT/DELETE: an admin creating the row IS the pilot invitation)

CREATE POLICY "Admins full access claims" ON public.portfolio_claims
  FOR ALL USING (public.is_saas_admin()) WITH CHECK (public.is_saas_admin());
CREATE POLICY "Owners view own claims" ON public.portfolio_claims
  FOR SELECT USING (public.gsmp_owns_portfolio(portfolio_id));
CREATE POLICY "Owners add claims" ON public.portfolio_claims
  FOR INSERT WITH CHECK (public.gsmp_owns_portfolio(portfolio_id));
CREATE POLICY "Owners edit claims" ON public.portfolio_claims
  FOR UPDATE USING (public.gsmp_owns_portfolio(portfolio_id))
  WITH CHECK (public.gsmp_owns_portfolio(portfolio_id));
CREATE POLICY "Owners delete claims" ON public.portfolio_claims
  FOR DELETE USING (public.gsmp_owns_portfolio(portfolio_id));

CREATE POLICY "Admins read review log" ON public.claim_reviews
  FOR SELECT USING (public.is_saas_admin());
-- (no INSERT/UPDATE/DELETE policies: only SECURITY DEFINER triggers write the log)

-- ---------- PUBLIC VERIFY ----------
CREATE OR REPLACE FUNCTION public.get_portfolio_public(p_public_id text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'status', p.status,
    'identity_verified', p.identity_verified,
    'version', p.version,
    'published_at', p.published_at,
    'updated_at', p.updated_at,
    'headline', p.headline,
    'bio', CASE WHEN p.status = 'active' THEN p.bio END,
    'name', initcap(m.first_name) || ' ' || initcap(m.last_name),
    'member_title', COALESCE(m.member_title, 'Member'),
    'degree', m.degree,
    'specialty', m.specialty,
    'school', m.school,
    'country', m.country,
    'chapter', c.name,
    'email', CASE WHEN p.status = 'active' AND p.show_email THEN m.email END,
    'phone', CASE WHEN p.status = 'active' AND p.show_phone THEN m.phone END,
    'claims', CASE WHEN p.status = 'active' THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'section', pc.section, 'title', pc.title, 'organization', pc.organization,
               'role', pc.role, 'period', pc.period, 'description', pc.description,
               'status', pc.status, 'method', pc.method, 'verified_at', pc.verified_at)
             ORDER BY pc.section, pc.sort_order, pc.created_at)
      FROM public.portfolio_claims pc
      WHERE pc.portfolio_id = p.id AND pc.status IN ('verified','self_declared')
    ), '[]'::jsonb) ELSE '[]'::jsonb END
  )
  FROM public.portfolios p
  JOIN public.members m ON m.id = p.member_id
  LEFT JOIN public.chapters c ON c.id = m.chapter_id
  WHERE p.public_id = p_public_id
    AND length(p_public_id) = 32
    AND p.status <> 'draft';
$$;
REVOKE ALL ON FUNCTION public.get_portfolio_public(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_portfolio_public(text) TO anon, authenticated;

COMMIT;

-- ---------- Smoke test (read-only) ----------
-- select count(*) from portfolios;                      -- 0
-- select public.get_portfolio_public(repeat('x',32));   -- null
