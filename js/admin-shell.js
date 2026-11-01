/* GSMP admin shell — shared sidebar for all admin pages.
   Usage: <aside class="adm-side" id="admSide"></aside> then gsmpAdminShell('members').
   On pages/admin, section links switch tabs in place (#hash); elsewhere they link back. */
(function () {
  const I = {
    home: '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/>',
    inbox: '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    users: '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    map: '<path d="M12 22s7-6.2 7-12a7 7 0 1 0-14 0c0 5.8 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/>',
    bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
    cal: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
    img: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/>',
    doc: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M8 13h8M8 17h6"/>',
    bag: '<path d="M6 2L3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4z"/><path d="M3 6h18M16 10a4 4 0 0 1-8 0"/>',
    shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/>',
    cash: '<rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/><path d="M6 12h.01M18 12h.01"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
  };
  const NAV = [
    [null, [['overview', 'Overview', 'home', 'tab']]],
    ['People', [['applications', 'Applications', 'inbox', '../admin-applications', 'apps'],
                ['members', 'Members', 'users', 'tab'],
                ['chapters', 'Chapters', 'map', 'tab']]],
    ['Content', [['notices', 'Notices', 'bell', 'tab'], ['events', 'Events', 'cal', 'tab'],
                 ['gallery', 'Gallery', 'img', 'tab'], ['articles', 'Articles', 'doc', 'tab'], ['shop', 'Shop', 'bag', 'tab']]],
    ['Verification', [['portfolios', 'Portfolio review', 'shield', '../admin-portfolios', 'claims']]],
    ['Finance', [['accounting', 'Accounting', 'cash', '../admin-accounting', 'unpaid']]],
    ['System', [['logs', 'Activity log', 'list', 'tab']]],
  ];
  const onAdminPage = () => !!document.getElementById('tab-overview');

  window.gsmpAdminShell = async function (active) {
    const side = document.getElementById('admSide');
    if (!side) return;
    const link = ([id, label, icon, target, badge]) => {
      const href = target === 'tab' ? (onAdminPage() ? '#' + id : '../admin/#' + id) : target;
      return `<a href="${href}" data-nav="${id}" class="${id === active ? 'on' : ''}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${I[icon]}</svg>
        ${label}${badge ? `<span class="adm-badge" data-badge="${badge}" style="display:none"></span>` : ''}</a>`;
    };
    const { data: { session } } = await sb.auth.getSession();
    side.innerHTML = `
      <a class="adm-brand" href="../admin/#overview"><img src="../../images/pgcmp_logo_inverted.jpeg" alt="">
        <div><b>GSMP Admin</b><span>Galen Society</span></div></a>
      <nav class="adm-nav">${NAV.map(([g, items]) => (g ? `<div class="adm-group">${g}</div>` : '') + items.map(link).join('')).join('')}</nav>
      <div class="adm-side-foot">
        <div style="margin-bottom:6px;">${session ? gsmpEsc(session.user.email) : ''}</div>
        <a href="../dashboard">← Member dashboard</a>
        <a href="../../" target="_blank">View public site ↗</a>
        <a href="#" id="admLogout">Log out</a>
      </div>`;
    if (onAdminPage() && location.hash) window.gsmpAdminSetActive(location.hash.slice(1));
    document.getElementById('admLogout').onclick = async e => { e.preventDefault(); await sb.auth.signOut(); location.href = '../login'; };
    window.gsmpAdminRefreshBadges();
  };

  window.gsmpAdminSetActive = function (id) {
    document.querySelectorAll('.adm-nav a').forEach(a => a.classList.toggle('on', a.dataset.nav === id));
  };

  // Live counts of work waiting. RLS limits these to admins; failures just hide the badge.
  window.gsmpAdminRefreshBadges = async function () {
    const set = (k, n, soft) => document.querySelectorAll(`[data-badge="${k}"]`).forEach(b => {
      b.textContent = n; b.style.display = n ? '' : 'none'; b.classList.toggle('soft', !!soft); });
    try {
      const [a, c, u, r] = await Promise.all([
        sb.from('members').select('id', { count: 'exact', head: true }).eq('membership_status', 'applicant'),
        sb.from('portfolio_claims').select('id', { count: 'exact', head: true }).eq('status', 'submitted'),
        sb.from('members').select('id', { count: 'exact', head: true }).eq('membership_status', 'approved'),
        sb.from('payment_reports').select('id', { count: 'exact', head: true }).eq('status', 'open')]);
      set('apps', (a.count || 0) + (r.count || 0)); set('claims', c.count || 0); set('unpaid', u.count || 0, true);
    } catch (_) { /* badges are optional */ }
  };
})();
