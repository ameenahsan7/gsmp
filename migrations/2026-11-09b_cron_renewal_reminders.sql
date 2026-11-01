-- ============================================================
-- GSMP — daily renewal reminders — 2026-11-09 (run AFTER 2026-11-09_notifications_payments_legal.sql)
-- Requires the pg_cron extension (Supabase Dashboard → Database → Extensions → pg_cron → Enable,
-- or the CREATE EXTENSION line below). Enqueues reminder emails daily at 05:17 UTC (09:17 Dubai);
-- the outbox webhook then sends them.
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'gsmp-renewal-reminders';
SELECT cron.schedule('gsmp-renewal-reminders', '17 5 * * *', $$SELECT public.gsmp_enqueue_renewal_reminders()$$);

-- Check: select jobname, schedule, active from cron.job;
