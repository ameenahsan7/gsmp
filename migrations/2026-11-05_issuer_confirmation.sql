-- ============================================================
-- GSMP — Verified Portfolio phase 2: issuer confirmation — 2026-11-05
--
-- Flow:
--   1. Admin clicks "Email issuer" → Edge Function `send-issuer-confirmation`
--      (service role) calls gsmp_create_issuer_confirmation(): validates the
--      claim, throttles, stores ONLY the sha256 of a random 256-bit token +
--      a snapshot of what the issuer is asked to confirm. Function emails link.
--   2. Issuer opens /pages/confirm/?t=<token> → get_issuer_request(token).
--   3. Issuer answers → respond_issuer_request(token, ...):
--        confirmed + claim unchanged since email + claim still pending
--          → claim auto-VERIFIED (method issuer_email, verified_by issuer:<email>)
--        denied, or claim changed → recorded; claim stays in admin queue.
--   Links: single-use, expire after 14 days, max 1 per claim per 24h.
--
-- Run ONCE in Supabase SQL Editor (before merging the pages). Transactional.
-- ============================================================
BEGIN;

CREATE TABLE public.issuer_confirmations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id      uuid NOT NULL REFERENCES public.portfolio_claims(id) ON DELETE CASCADE,
  token_hash    text NOT NULL UNIQUE,
  issuer_email  text NOT NULL,
  snapshot      jsonb NOT NULL,
  sent_by       text NOT NULL,
  sent_at       timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '14 days',
  responded_at  timestamptz,
  response      text CHECK (response IN ('confirmed','denied')),
  response_note text CHECK (char_length(response_note) <= 500),
  auto_verified boolean NOT NULL DEFAULT false
);
CREATE INDEX idx_issuer_confirmations_claim ON public.issuer_confirmations (claim_id, sent_at DESC);

ALTER TABLE public.issuer_confirmations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read issuer confirmations" ON public.issuer_confirmations
  FOR SELECT USING (public.is_saas_admin());
-- no write policies: only the SECURITY DEFINER functions below write

-- Actor for audit log: explicit override (issuer) > JWT email > 'system'
CREATE OR REPLACE FUNCTION public.gsmp_actor_email()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('gsmp.actor', true), ''), auth.jwt() ->> 'email', 'system');
$$;

CREATE OR REPLACE FUNCTION public.gsmp_claim_snapshot(c public.portfolio_claims)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('section', c.section, 'title', c.title, 'organization', c.organization,
                            'role', c.role, 'period', c.period);
$$;

CREATE OR REPLACE FUNCTION public.gsmp_token_hash(p_token text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
$$;

-- ---------- 1. Create (service role only — called by the Edge Function) ----------
CREATE OR REPLACE FUNCTION public.gsmp_create_issuer_confirmation(p_claim uuid, p_token_hash text, p_sent_by text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c public.portfolio_claims%ROWTYPE;
  v_member text;
BEGIN
  IF p_token_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Bad token hash'; END IF;
  SELECT * INTO c FROM public.portfolio_claims WHERE id = p_claim FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Claim not found'; END IF;
  IF c.status NOT IN ('submitted','needs_info') THEN
    RAISE EXCEPTION 'Only submitted or needs-info claims can be sent to the issuer (status: %).', c.status;
  END IF;
  IF c.issuer_email IS NULL THEN RAISE EXCEPTION 'This claim has no issuer email.'; END IF;
  IF EXISTS (SELECT 1 FROM public.issuer_confirmations
             WHERE claim_id = p_claim AND sent_at > now() - interval '24 hours') THEN
    RAISE EXCEPTION 'An issuer email was already sent for this claim in the last 24 hours.';
  END IF;

  SELECT initcap(m.first_name) || ' ' || initcap(m.last_name) INTO v_member
  FROM public.portfolios p JOIN public.members m ON m.id = p.member_id WHERE p.id = c.portfolio_id;

  -- any older unanswered link for this claim is superseded
  UPDATE public.issuer_confirmations SET expires_at = now()
   WHERE claim_id = p_claim AND responded_at IS NULL AND expires_at > now();

  INSERT INTO public.issuer_confirmations (claim_id, token_hash, issuer_email, snapshot, sent_by)
  VALUES (p_claim, p_token_hash, lower(c.issuer_email), public.gsmp_claim_snapshot(c), p_sent_by);

  INSERT INTO public.claim_reviews (portfolio_id, claim_id, actor_email, action, to_status, note)
  VALUES (c.portfolio_id, c.id, p_sent_by, 'issuer_emailed', c.status, lower(c.issuer_email));

  RETURN jsonb_build_object('issuer_email', lower(c.issuer_email), 'member_name', v_member,
                            'snapshot', public.gsmp_claim_snapshot(c));
END $$;
REVOKE ALL ON FUNCTION public.gsmp_create_issuer_confirmation(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gsmp_create_issuer_confirmation(uuid, text, text) TO service_role;

-- If the email fails to send, the Edge Function removes the row
CREATE OR REPLACE FUNCTION public.gsmp_cancel_issuer_confirmation(p_token_hash text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM public.issuer_confirmations WHERE token_hash = p_token_hash AND responded_at IS NULL;
$$;
REVOKE ALL ON FUNCTION public.gsmp_cancel_issuer_confirmation(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gsmp_cancel_issuer_confirmation(text) TO service_role;

-- ---------- 2. Read request (public, by token) ----------
CREATE OR REPLACE FUNCTION public.get_issuer_request(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.issuer_confirmations%ROWTYPE;
  v_member text;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('state', 'invalid'); END IF;
  SELECT * INTO r FROM public.issuer_confirmations WHERE token_hash = public.gsmp_token_hash(p_token);
  IF NOT FOUND THEN RETURN jsonb_build_object('state', 'invalid'); END IF;
  IF r.responded_at IS NOT NULL THEN RETURN jsonb_build_object('state', 'responded', 'response', r.response); END IF;
  IF r.expires_at <= now() THEN RETURN jsonb_build_object('state', 'expired'); END IF;

  SELECT initcap(m.first_name) || ' ' || initcap(m.last_name) INTO v_member
  FROM public.portfolio_claims c JOIN public.portfolios p ON p.id = c.portfolio_id
  JOIN public.members m ON m.id = p.member_id WHERE c.id = r.claim_id;

  RETURN jsonb_build_object('state', 'pending', 'member_name', v_member, 'snapshot', r.snapshot,
                            'issuer_email', r.issuer_email, 'expires_at', r.expires_at);
END $$;
REVOKE ALL ON FUNCTION public.get_issuer_request(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_issuer_request(text) TO anon, authenticated;

-- ---------- 3. Respond (public, by token, single use) ----------
CREATE OR REPLACE FUNCTION public.respond_issuer_request(p_token text, p_response text, p_note text, p_authorised boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.issuer_confirmations%ROWTYPE;
  c public.portfolio_claims%ROWTYPE;
  v_auto boolean := false;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Invalid link.'; END IF;
  IF p_response NOT IN ('confirmed','denied') THEN RAISE EXCEPTION 'Invalid response.'; END IF;
  IF p_response = 'confirmed' AND p_authorised IS NOT TRUE THEN
    RAISE EXCEPTION 'Please confirm you are authorised to verify this on behalf of the institution.';
  END IF;

  SELECT * INTO r FROM public.issuer_confirmations
   WHERE token_hash = public.gsmp_token_hash(p_token) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid link.'; END IF;
  IF r.responded_at IS NOT NULL THEN RAISE EXCEPTION 'This request has already been answered.'; END IF;
  IF r.expires_at <= now() THEN RAISE EXCEPTION 'This link has expired.'; END IF;

  SELECT * INTO c FROM public.portfolio_claims WHERE id = r.claim_id FOR UPDATE;

  IF p_response = 'confirmed' AND FOUND
     AND c.status IN ('submitted','needs_info')
     AND public.gsmp_claim_snapshot(c) = r.snapshot THEN
    PERFORM set_config('gsmp.actor', 'issuer:' || r.issuer_email, true);
    UPDATE public.portfolio_claims
       SET status = 'verified', method = 'issuer_email',
           reviewer_note = 'Confirmed by issuer (' || r.issuer_email || ')'
     WHERE id = c.id;
    v_auto := true;
  END IF;

  UPDATE public.issuer_confirmations
     SET responded_at = now(), response = p_response,
         response_note = NULLIF(left(btrim(COALESCE(p_note, '')), 500), ''), auto_verified = v_auto
   WHERE id = r.id;

  INSERT INTO public.claim_reviews (portfolio_id, claim_id, actor_email, action, to_status, note)
  VALUES (c.portfolio_id, r.claim_id, 'issuer:' || r.issuer_email, 'issuer_response', p_response,
          NULLIF(left(btrim(COALESCE(p_note, '')), 500), ''));

  RETURN jsonb_build_object('state', 'responded', 'response', p_response);
END $$;
REVOKE ALL ON FUNCTION public.respond_issuer_request(text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_issuer_request(text, text, text, boolean) TO anon, authenticated;

COMMIT;
