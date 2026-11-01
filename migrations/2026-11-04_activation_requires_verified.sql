-- ============================================================
-- GSMP — a portfolio can only go ACTIVE with >= 1 verified credential — 2026-11-04
-- Why: a public "GSMP Verified Portfolio" showing "0 verified credentials"
-- dilutes the mark. Applies to the transition into 'active' only; portfolios
-- already active are untouched. Run ONCE in Supabase SQL Editor.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.gsmp_guard_portfolio()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.updated_at := now();

  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active'
     AND NOT EXISTS (SELECT 1 FROM public.portfolio_claims
                     WHERE portfolio_id = NEW.id AND status = 'verified') THEN
    RAISE EXCEPTION 'Verify at least one credential before activating this portfolio.';
  END IF;

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

COMMIT;
