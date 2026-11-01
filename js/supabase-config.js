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

// Escape user-supplied text before inserting into innerHTML (prevents stored XSS).
function gsmpEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
window.gsmpEsc = gsmpEsc;

// Membership lifecycle — mirrors SQL public.gsmp_member_state():
// applicant | approved | rejected | active | grace (≤30 days past paid_until) | lapsed
function gsmpMemberState(m) {
  if (!m) return 'applicant';
  const s = m.membership_status || 'active';
  if (s !== 'active') return s;
  if (!m.paid_until) return 'active';
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const paid = new Date(m.paid_until + 'T00:00:00');
  if (paid >= today) return 'active';
  return (today - paid) / 86400000 <= 30 ? 'grace' : 'lapsed';
}
window.gsmpMemberState = gsmpMemberState;

// Status card HTML for non-active members (null when nothing to show).
async function gsmpMembershipNotice(m) {
  const st = gsmpMemberState(m);
  const box = (bg, fg, title, body) =>
    `<div class="dash-section" id="membershipNotice" style="background:${bg};border-color:${fg}33;"><h2 style="color:${fg};margin-bottom:8px;">${title}</h2>${body}</div>`;
  if (st === 'applicant') return box('#eff6ff', '#1e40af', 'Application under review',
    '<p>Thanks for applying. The GSMP team reviews every application, usually within 48 hours. You\'ll see the result here.</p>');
  if (st === 'rejected') return box('#fef2f2', '#991b1b', 'Application not approved',
    `<p>${m.review_note ? gsmpEsc(m.review_note) : 'Your application was not approved at this time.'}</p>`);
  if (st === 'approved' || st === 'lapsed' || st === 'grace') {
    const { data } = await sb.from('site_settings').select('key, value').in('key', ['membership_payment_instructions', 'membership_fee']);
    const get = k => ((data || []).find(r => r.key === k) || {}).value || '';
    const fee = get('membership_fee');
    if (st === 'approved') return box('#ecfdf5', '#065f46', 'Approved — activate your membership',
      `<p>${m.review_note ? gsmpEsc(m.review_note) + '<br><br>' : ''}${gsmpEsc(get('membership_payment_instructions'))}</p>${fee ? `<p><strong>Fee:</strong> ${gsmpEsc(fee)}</p>` : ''}`);
    const until = new Date(m.paid_until + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
    if (st === 'grace') return box('#fffbeb', '#92400e', 'Membership renewal due',
      `<p>Your membership expired on ${until}. Renew within 30 days of that date to keep your Verified Portfolio live.</p>${fee ? `<p><strong>Fee:</strong> ${gsmpEsc(fee)}</p>` : ''}`);
    return box('#fef2f2', '#991b1b', 'Membership lapsed',
      `<p>Your membership expired on ${until}. Your Verified Portfolio is paused (nothing is deleted). Renew to reactivate it instantly.</p>${fee ? `<p><strong>Fee:</strong> ${gsmpEsc(fee)}</p>` : ''}<p>${gsmpEsc(get('membership_payment_instructions'))}</p>`);
  }
  return null;
}
window.gsmpMembershipNotice = gsmpMembershipNotice;
