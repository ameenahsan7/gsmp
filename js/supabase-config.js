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

// Status card HTML for non-active / renewal-due members (null when nothing to show).
// Needs m.id, membership_status, paid_until, review_note.
async function gsmpMembershipNotice(m) {
  const st = gsmpMemberState(m);
  const box = (bg, fg, title, body) =>
    `<div class="dash-section" id="membershipNotice" style="background:${bg};border-color:${fg}33;"><h2 style="color:${fg};margin-bottom:8px;">${title}</h2>${body}</div>`;
  if (st === 'applicant') return box('#eff6ff', '#1e40af', 'Application under review',
    '<p>Thanks for applying. The GSMP team reviews every application, usually within 48 hours. We\'ll email you the result.</p>');
  if (st === 'rejected') return box('#fef2f2', '#991b1b', 'Application not approved',
    `<p>${m.review_note ? gsmpEsc(m.review_note) : 'Your application was not approved at this time.'}</p>`);

  const soon = st === 'active' && m.paid_until && (new Date(m.paid_until + 'T00:00:00') - new Date()) / 864e5 <= 30;
  if (!(st === 'approved' || st === 'lapsed' || st === 'grace' || soon)) return null;

  const [{ data }, { data: open }] = await Promise.all([
    sb.from('site_settings').select('key, value').in('key', ['membership_payment_instructions', 'membership_fee']),
    m.id ? sb.from('payment_reports').select('created_at, reference').eq('member_id', m.id).eq('status', 'open').order('created_at', { ascending: false }).limit(1)
         : Promise.resolve({ data: [] })]);
  const get = k => ((data || []).find(r => r.key === k) || {}).value || '';
  const fee = get('membership_fee');
  const feeLine = fee ? `<p><strong>Fee:</strong> ${gsmpEsc(fee)}</p>` : '';
  const instr = `<p style="white-space:pre-line;">${gsmpEsc(get('membership_payment_instructions'))}</p>`;
  const until = m.paid_until ? new Date(m.paid_until + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
  const paid = (open && open[0])
    ? `<div style="margin-top:12px;padding:10px 12px;background:#fff;border:1px solid #d1fae5;border-radius:8px;">✓ We received your payment report${open[0].reference ? ` (ref. ${gsmpEsc(open[0].reference)})` : ''} on ${new Date(open[0].created_at).toLocaleDateString('en-GB')}. We'll confirm by email shortly.</div>`
    : gsmpPaidForm(m.id);

  if (st === 'approved') return box('#ecfdf5', '#065f46', 'Approved — activate your membership',
    `${m.review_note ? `<p>${gsmpEsc(m.review_note)}</p>` : ''}${instr}${feeLine}${paid}`);
  if (soon) return box('#eff6ff', '#1e40af', 'Renewal coming up',
    `<p>Your membership is valid until <strong>${until}</strong>. Renew early to keep everything uninterrupted.</p>${feeLine}${instr}${paid}`);
  if (st === 'grace') return box('#fffbeb', '#92400e', 'Membership renewal due',
    `<p>Your membership expired on ${until}. Renew within 30 days of that date to keep your Verified Portfolio live.</p>${feeLine}${instr}${paid}`);
  return box('#fef2f2', '#991b1b', 'Membership lapsed',
    `<p>Your membership expired on ${until}. Your Verified Portfolio is paused (nothing is deleted). Renew to reactivate it instantly.</p>${feeLine}${instr}${paid}`);
}

function gsmpPaidForm(memberId) {
  if (!memberId) return '';
  const today = new Date().toISOString().slice(0, 10);
  const f = 'padding:8px 10px;border:1px solid #d1d5db;border-radius:6px;font:inherit;font-size:14px;';
  return `<details style="margin-top:12px;" id="paidBox"><summary style="cursor:pointer;font-weight:600;color:#1B2A4A;">I've paid — tell GSMP</summary>
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px;margin-top:10px;">
      <input id="prAmount" type="number" min="1" step="0.01" placeholder="Amount (e.g. 100)" style="${f}">
      <select id="prMethod" style="${f}"><option value="bank_transfer">Bank transfer</option><option value="cash">Cash</option><option value="card">Card</option><option value="payment_link">Payment link</option><option value="other">Other</option></select>
      <input id="prDate" type="date" value="${today}" max="${today}" style="${f}">
      <input id="prRef" maxlength="200" placeholder="Payment reference / receipt no." style="${f}">
    </div>
    <textarea id="prNote" maxlength="500" placeholder="Anything we should know? (optional)" style="${f}width:100%;margin-top:8px;min-height:50px;"></textarea>
    <button type="button" onclick="gsmpSubmitPaid('${memberId}')" style="margin-top:8px;background:#1B2A4A;color:#fff;border:none;border-radius:8px;padding:9px 16px;font-weight:600;cursor:pointer;">Send to GSMP</button>
    <span id="prMsg" style="margin-left:8px;font-size:13px;"></span></details>`;
}

async function gsmpSubmitPaid(memberId) {
  const v = id => document.getElementById(id).value.trim();
  const msg = document.getElementById('prMsg');
  if (!v('prRef') && !v('prNote')) { msg.style.color = '#991b1b'; msg.textContent = 'Add a payment reference or a short note.'; return; }
  const { error } = await sb.from('payment_reports').insert({
    member_id: memberId, amount: v('prAmount') ? Number(v('prAmount')) : null, method: v('prMethod'),
    paid_on: v('prDate') || null, reference: v('prRef') || null, note: v('prNote') || null });
  if (error) { msg.style.color = '#991b1b'; msg.textContent = error.message; return; }
  document.getElementById('paidBox').outerHTML = '<div style="margin-top:12px;padding:10px 12px;background:#fff;border:1px solid #d1fae5;border-radius:8px;">✓ Thanks — GSMP has been notified and will confirm by email.</div>';
}
window.gsmpSubmitPaid = gsmpSubmitPaid;
window.gsmpMembershipNotice = gsmpMembershipNotice;
