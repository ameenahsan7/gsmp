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
| 2026-11-01 | Personal project uses personal accounts only (GitHub `ameenahsan7`, personal laptop) | Keep GSMP out of employer org/logs |

## Roadmap (in order)
1. ~~Security lockdown~~ (done 2026-11-01)
2. ~~Admins via app_admins~~ (2026-11-02)
3. ~~Live schema in git~~ (2026-11-02, `schema/live-schema.sql`)
3b. ~~Server-side referral enforcement~~ (2026-11-02, `migrations/2026-11-02_referral_enforcement.sql`)
4. Verified Portfolio **pilot**: 5 members, 4 sections (identity, clinical, research, awards), per-claim status,
   issuer email confirmation (Edge Function + Resend), `/verify/?id=<random>` page with revocation, print-to-PDF.
   No government ID/selfie storage. "Verified" = issuer confirmed the document, never competence.
5. Paid Verified Portfolio tier → triggers Supabase Pro upgrade.

## Known gaps
1. `validate_and_use_referral_code` (now check-only) still answers valid/invalid to anyone → codes can be
   guessed. Mitigate with longer random codes if abuse appears.
2. A signup rejected by the DB leaves an auth user with no member row (pre-check makes this rare).
- No CI, no tests, no backups (Free plan) — take a manual `pg_dump` weekly; never commit dumps (repo is public).
- `event_rsvps` readable by anyone; `resources` insertable by any member; `activity_logs` insertable by any member.
- Stock images hot-linked from Unsplash.
