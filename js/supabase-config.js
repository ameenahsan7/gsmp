/* ============================================
   GSMP — Supabase Configuration
   ============================================ */

const SUPABASE_URL = 'https://jeumykmrcbyugfdsttxf.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpldW15a21yY2J5dWdmZHN0dHhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ2MjQ0ODEsImV4cCI6MjA5MDIwMDQ4MX0.M4N2GHlB0d-bN1QE_YGR2nmJooDsKZ6RVV3fRX1gAZY';

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Source-of-truth admin check — backed by public.app_admins via the is_saas_admin() SQL function.
// Returns boolean. Resolves false on any error (caller can still fail-closed).
async function checkIsSaasAdmin() {
  try {
    const { data, error } = await sb.rpc('is_saas_admin');
    if (error) return false;
    return !!data;
  } catch (e) {
    return false;
  }
}
window.checkIsSaasAdmin = checkIsSaasAdmin;
