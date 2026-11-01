# GSMP — project memory

Read this first. It records how the project is built and decisions already made,
so they are not re-litigated. Update the Decision log whenever a decision changes.

## Stack
- Static site: hand-written HTML/CSS/vanilla JS, no build step. Pages in `pages/<name>/index.html`.
- Hosting: GitHub Pages from `main`, domain `gsmpglobal.org` (`CNAME`). Push to `main` = deploy (~2 min).
- Backend: Supabase project "GCMP" (Free plan, region ap-south-1 / Mumbai).
  Client in `js/supabase-config.js`; `supabase-js` pinned to **2.45.4** on every page.
- Security lives entirely in Postgres RLS + SECURITY DEFINER functions. The anon key is public by design.

## Rules for changes
- **Database changes go in `migrations/YYYY-MM-DD_<name>.sql`**, run manually in the Supabase SQL Editor,
  wrapped in `BEGIN; … COMMIT;`. Never edit live policies by hand without a migration file.
  Root-level `*-setup.sql` files are historical and do NOT reflect the live schema.
- **Admins = `public.app_admins` table, checked via `public.is_saas_admin()`.** Never hard-code emails in policies.
- **Escape all user-supplied text** inserted via `innerHTML` with `gsmpEsc()` (defined in `js/supabase-config.js`).
- **No policy may be `USING (true)` / `WITH CHECK (true)` for writes.**
- Signup: `gsmp_enforce_referral` trigger validates `referred_by`, sets `chapter_id`, consumes a use.
- Members table is private: self, admins, and Chapter Leads (own chapter only). Public card goes through
  `get_member_card(code)` RPC.
- Privilege fields on `members` (`member_title`, `chapter_id`) are guarded by trigger
  `gsmp_guard_member_privileges`. Chapter Leads may assign only: Member, Active Member, Senior Member, Ambassador.
- Workflow: Claude pushes to a `claude/*` branch; owner merges to `main` (fast-forward).
- **Deploy order: run the migration in Supabase FIRST, verify, THEN merge to `main`.** Every migration must be
  backward-compatible with the currently-live pages. (2026-11-02: join page went live before its migration →
  one signup landed with no chapter.)

## Decision log
| Date | Decision | Why |
|---|---|---|
| 2026-11-01 | Stay on Supabase + static site; no Next.js/Laravel rewrite | Covers all portfolio needs; a rewrite is cost with no user value |
| 2026-11-01 | Stay on Supabase **Free** until first paying member/partner; upgrade to Pro ($25/mo) **before** storing verification evidence | Free has no backups and auto-pauses — unacceptable for credentials/QR verify pages |
| 2026-11-01 | Security lockdown shipped (`migrations/2026-11-01_security_lockdown.sql`) | World-writable articles, self-promotion to Chapter Lead, stored XSS into admin, member PII readable by any user |
| 2026-11-02 | Admin access only via `app_admins`; employer (propertyfinder.ae) email removed | Employer controls that mailbox → would control GSMP |
| 2026-11-02 | Referral enforced in DB trigger; chapter derived from code; personal codes capped at **5** invites | Invite-only must hold server-side; scarcity supports paid tier |
| 2026-11-04 | Portfolio can go **active** only with ≥1 verified credential (DB-enforced) | "Verified Portfolio" with 0 verified items dilutes the mark |
| 2026-11-05 | Resend on root `gsmpglobal.org` (single team, Servlee domain removed); API key = sending-only, domain-scoped | Free plan = 1 domain; least privilege |
| 2026-11-01 | Personal project uses personal accounts only (GitHub `ameenahsan7`, personal laptop) | Keep GSMP out of employer org/logs |

## Roadmap (in order)
1. ~~Security lockdown~~ (done 2026-11-01)
2. ~~Admins via app_admins~~ (2026-11-02)
3. ~~Live schema in git~~ (2026-11-02, `schema/live-schema.sql`)
3b. ~~Server-side referral enforcement~~ (2026-11-02, `migrations/2026-11-02_referral_enforcement.sql`)
4. Verified Portfolio pilot — **phase 1 built 2026-11-03** (`migrations/2026-11-03_portfolio_pilot.sql`):
   tables `portfolios` / `portfolio_claims` / `claim_reviews` (trigger-written audit log), member editor
   `pages/my-portfolio`, admin queue `pages/admin-portfolios`, public `pages/verify/?id=<32-hex>` with QR,
   revocation, print-to-PDF. Admin creating a portfolio = pilot invitation. Evidence = https links only.
   Public RPC `get_portfolio_public` never exposes evidence_url / issuer_email.
   **Phase 2 built 2026-11-05** (`migrations/2026-11-05_issuer_confirmation.sql`): admin "Email issuer" →
   Edge Function `supabase/functions/send-issuer-confirmation` (deployed via Dashboard editor; secret
   `RESEND_API_KEY`; sender `verify@gsmpglobal.org`, Resend domain verified 2026-11-01, Tokyo region) →
   issuer page `pages/confirm/?t=<64-hex>` → confirm auto-verifies ONLY if claim unchanged since email.
   Token: 256-bit, only sha256 stored, single use, 14-day expiry, 1 email/claim/24h.
   Reviewers = SaaS admins. "Verified" = issuer/official source confirmed, never competence.
5. Paid Verified Portfolio tier → triggers Supabase Pro upgrade.

## Testing
- DB changes are tested on a local Postgres 16 with Supabase stubs (auth.uid/role/jwt, anon/authenticated roles):
  load `schema/live-schema.sql`, then migrations in order, then scenario tests (role switch via
  `set request.jwt.claims` + `SET ROLE`). 35 scenarios passed for referral + pilot on 2026-11-03; 22 for issuer confirmation on 2026-11-05.

## Known gaps
1. `validate_and_use_referral_code` (now check-only) still answers valid/invalid to anyone → codes can be
   guessed. Mitigate with longer random codes if abuse appears.
2. A signup rejected by the DB leaves an auth user with no member row (pre-check makes this rare).
- No CI, no tests, no backups (Free plan) — take a manual `pg_dump` weekly; never commit dumps (repo is public).
- `event_rsvps` readable by anyone; `resources` insertable by any member; `activity_logs` insertable by any member.
- Stock images hot-linked from Unsplash.
