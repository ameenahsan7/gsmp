// GSMP — notify (Supabase Edge Function)
// Drains public.notification_outbox and sends each email through Resend.
// Triggered by a Database Webhook on INSERT into notification_outbox (and safe to call any time:
// it takes no input, only sends what the database queued, and claims rows with SKIP LOCKED).
// Deploy: Dashboard → Edge Functions → Deploy a new function → Via Editor → name "notify" → paste → Deploy.
// Secrets: RESEND_API_KEY (already set). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided automatically.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SITE = "https://gsmpglobal.org";
const FROM = "GSMP <notifications@gsmpglobal.org>";

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const fmtDate = (d: unknown) => d ? new Date(String(d) + (String(d).length === 10 ? "T00:00:00Z" : "")).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }) : "";
const METHOD: Record<string, string> = { bank_transfer: "Bank transfer", cash: "Cash", card: "Card", payment_link: "Payment link", other: "Other" };

type P = Record<string, any>;
type Mail = { subject: string; heading: string; body: string; cta?: [string, string] };

function nl2p(t: string) { return esc(t).split(/\n+/).filter(Boolean).map((x) => `<p>${x}</p>`).join(""); }
function rows(pairs: [string, unknown][]) {
  return `<table style="border-collapse:collapse;margin:14px 0;">${pairs.filter(([, v]) => v !== null && v !== undefined && v !== "")
    .map(([k, v]) => `<tr><td style="padding:5px 14px 5px 0;color:#6b7280;">${esc(k)}</td><td style="padding:5px 0;"><strong>${esc(v)}</strong></td></tr>`).join("")}</table>`;
}

const T: Record<string, (p: P) => Mail> = {
  application_received: (p) => ({
    subject: "We received your GSMP application",
    heading: `Thank you, ${p.first_name}`,
    body: `<p>Your application to the Galen Society of Medical Professionals has been received. Our team reviews every application, usually within 48 hours.</p>
           <p>You can follow its status any time by logging in.</p>`,
    cta: ["View my application", `${SITE}/pages/dashboard`] }),
  application_approved: (p) => ({
    subject: "Your GSMP application is approved",
    heading: `Welcome, ${p.first_name}`,
    body: `<p>Your application has been approved.</p>${p.note ? `<p style="border-left:3px solid #C49A3C;padding-left:10px;">${esc(p.note)}</p>` : ""}
           <p><strong>Activate your membership</strong>${p.fee ? ` — ${esc(p.fee)}` : ""}:</p>${nl2p(p.instructions || "")}
           <p>Once you've paid, log in and press <strong>"I've paid"</strong> with your payment reference — we'll activate you quickly.</p>`,
    cta: ["Log in to GSMP", `${SITE}/pages/dashboard`] }),
  application_rejected: (p) => ({
    subject: "Your GSMP application",
    heading: `Hello ${p.first_name}`,
    body: `<p>Thank you for applying to GSMP. After review, we're unable to approve your application at this time.</p>
           ${p.note ? `<p style="border-left:3px solid #C49A3C;padding-left:10px;">${esc(p.note)}</p>` : ""}
           <p>If your circumstances change, you're welcome to contact us.</p>` }),
  payment_receipt: (p) => ({
    subject: `GSMP payment receipt ${p.receipt_no}`,
    heading: "Payment received — thank you",
    body: `<p>Your GSMP membership is active.</p>${rows([["Receipt no.", p.receipt_no], ["Member", p.name],
      ["Amount", `${p.amount} ${p.currency}`], ["Method", METHOD[p.method] || p.method], ["Reference", p.reference],
      ["Paid on", fmtDate(p.paid_at)], ["Membership valid until", fmtDate(p.covers_until)]])}`,
    cta: ["Go to my dashboard", `${SITE}/pages/dashboard`] }),
  claim_needs_info: (p) => ({
    subject: "GSMP needs a little more information",
    heading: `Hi ${p.first_name}`,
    body: `<p>A reviewer needs more information before verifying <strong>${esc(p.title)}</strong> on your portfolio:</p>
           <p style="border-left:3px solid #C49A3C;padding-left:10px;">${esc(p.note || "")}</p>
           <p>Update the credential and submit it again.</p>`,
    cta: ["Update my portfolio", `${SITE}/pages/my-portfolio`] }),
  claim_rejected: (p) => ({
    subject: "A credential on your GSMP portfolio was not verified",
    heading: `Hi ${p.first_name}`,
    body: `<p><strong>${esc(p.title)}</strong> could not be verified.</p>${p.note ? `<p style="border-left:3px solid #C49A3C;padding-left:10px;">${esc(p.note)}</p>` : ""}
           <p>It won't appear on your public portfolio. You can add a corrected credential at any time.</p>`,
    cta: ["Open my portfolio", `${SITE}/pages/my-portfolio`] }),
  portfolio_invited: (p) => ({
    subject: "You're invited to build your GSMP Verified Portfolio",
    heading: `${p.first_name}, your Verified Portfolio is ready to build`,
    body: `<p>GSMP has opened your Verified Portfolio. Add your credentials, photos and story — each credential is checked with its issuer, and you get a shareable page and PDF with a QR code anyone can verify.</p>`,
    cta: ["Start my portfolio", `${SITE}/pages/my-portfolio`] }),
  portfolio_active: (p) => ({
    subject: "Your GSMP Verified Portfolio is live",
    heading: `Congratulations, ${p.first_name}`,
    body: `<p>Your Verified Portfolio is now public. Share it on LinkedIn, add the PDF to applications, and print the QR on your CV.</p>
           <p><a href="${SITE}/pages/verify/?id=${esc(p.public_id)}">${SITE.replace("https://", "")}/pages/verify/?id=${esc(p.public_id)}</a></p>`,
    cta: ["View my portfolio", `${SITE}/pages/verify/?id=${encodeURIComponent(p.public_id || "")}`] }),
  portfolio_suspended: (p) => ({
    subject: "Your GSMP portfolio has been suspended",
    heading: `Hello ${p.first_name}`,
    body: `<p>Your Verified Portfolio has been suspended and currently shows as suspended to anyone who opens it. Please contact GSMP for details.</p>` }),
  portfolio_revoked: (p) => ({
    subject: "Your GSMP portfolio has been revoked",
    heading: `Hello ${p.first_name}`,
    body: `<p>Your Verified Portfolio has been revoked. Please contact GSMP if you believe this is a mistake.</p>` }),
  renewal_30: (p) => ({
    subject: "Your GSMP membership renews soon",
    heading: `Hi ${p.first_name}`,
    body: `<p>Your membership is valid until <strong>${fmtDate(p.paid_until)}</strong>.${p.fee ? ` Renewal: ${esc(p.fee)}.` : ""}</p>
           <p>Renew early to keep your Verified Portfolio and chapter access uninterrupted. After paying, press <strong>"I've paid"</strong> on your dashboard.</p>`,
    cta: ["Renew now", `${SITE}/pages/dashboard`] }),
  renewal_7: (p) => ({
    subject: "7 days left on your GSMP membership",
    heading: `Hi ${p.first_name}`,
    body: `<p>Your membership expires on <strong>${fmtDate(p.paid_until)}</strong>.${p.fee ? ` Renewal: ${esc(p.fee)}.` : ""} Renew now to keep your Verified Portfolio live.</p>`,
    cta: ["Renew now", `${SITE}/pages/dashboard`] }),
  renewal_overdue: (p) => ({
    subject: "Your GSMP membership has expired — 30-day grace period",
    heading: `Hi ${p.first_name}`,
    body: `<p>Your membership expired on <strong>${fmtDate(p.paid_until)}</strong>. You have a 30-day grace period; after that your Verified Portfolio is paused (nothing is deleted).</p>`,
    cta: ["Renew now", `${SITE}/pages/dashboard`] }),
  admin_new_application: (p) => ({
    subject: `New application: ${p.name}`,
    heading: "New membership application",
    body: `${rows([["Name", p.name], ["Email", p.email], ["Institution", p.school], ["Country", p.country], ["Referral code", p.referred_by || "none"]])}
           ${p.message ? `<p style="border-left:3px solid #C49A3C;padding-left:10px;">${esc(p.message)}</p>` : ""}<p>Target: review within 48 hours.</p>`,
    cta: ["Review applications", `${SITE}/pages/admin-applications`] }),
  admin_payment_reported: (p) => ({
    subject: `Payment reported: ${p.name}`,
    heading: "A member reported a payment",
    body: `${rows([["Member", p.name], ["Email", p.email], ["Amount", p.amount ? `${p.amount} ${p.currency}` : "not stated"],
      ["Method", METHOD[p.method] || p.method], ["Reference", p.reference], ["Paid on", fmtDate(p.paid_on)], ["Note", p.note]])}
           <p>Check it against your account, then record it in Applications &amp; payments.</p>`,
    cta: ["Record the payment", `${SITE}/pages/admin-applications`] }),
};

function render(m: Mail) {
  const html = `<div style="background:#f6f7f9;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;color:#111827;">
  <div style="max-width:560px;margin:0 auto;background:#fff;border:1px solid #e5e7eb;border-radius:10px;overflow:hidden;">
    <div style="background:#1B2A4A;padding:18px 24px;color:#C49A3C;font-size:12px;font-weight:bold;letter-spacing:2px;">GALEN SOCIETY OF MEDICAL PROFESSIONALS</div>
    <div style="padding:24px;line-height:1.6;font-size:15px;">
      <h1 style="font-family:Georgia,serif;font-weight:normal;font-size:24px;margin:0 0 12px;color:#1B2A4A;">${esc(m.heading)}</h1>
      ${m.body}
      ${m.cta ? `<p style="margin-top:22px;"><a href="${m.cta[1]}" style="display:inline-block;background:#1B2A4A;color:#fff;padding:12px 20px;border-radius:6px;text-decoration:none;font-weight:bold;">${esc(m.cta[0])}</a></p>` : ""}
    </div>
    <div style="padding:14px 24px;border-top:1px solid #e5e7eb;font-size:12px;color:#6b7280;">
      GSMP · <a href="${SITE}" style="color:#6b7280;">gsmpglobal.org</a> · <a href="${SITE}/pages/privacy" style="color:#6b7280;">Privacy</a>
      <br>You're receiving this because of your GSMP account or application.</div>
  </div></div>`;
  const text = `${m.heading}\n\n${m.body.replace(/<\/td>\s*<td[^>]*>/g, ": ").replace(/<br\s*\/?>/g, "\n").replace(/<\/(p|tr)>/g, "\n").replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/\n{3,}/g, "\n\n").trim()}${m.cta ? `\n\n${m.cta[0]}: ${m.cta[1]}` : ""}\n\nGSMP · ${SITE}`;
  return { html, text };
}

Deno.serve(async () => {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) return new Response("RESEND_API_KEY not set", { status: 500 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: setting } = await db.from("site_settings").select("value").eq("key", "contact_email").maybeSingle();
  const replyTo = setting?.value && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(setting.value) ? setting.value : undefined;

  let sent = 0, failed = 0;
  for (let round = 0; round < 4; round++) {           // up to 100 emails per invocation
    const { data: batch, error } = await db.rpc("gsmp_claim_outbox", { p_limit: 25 });
    if (error) return new Response("claim failed: " + error.message, { status: 500 });
    if (!batch?.length) break;
    for (const row of batch) {
      const tpl = T[row.template];
      if (!tpl) { await db.rpc("gsmp_finish_outbox", { p_id: row.id, p_ok: false, p_error: "unknown template" }); failed++; continue; }
      try {
        const m = tpl(row.payload || {});
        const { html, text } = render(m);
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json", "Idempotency-Key": `gsmp-outbox-${row.id}` },
          body: JSON.stringify({ from: FROM, to: [row.to_email], subject: m.subject, html, text, ...(replyTo ? { reply_to: replyTo } : {}) }),
        });
        if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 300)}`);
        await db.rpc("gsmp_finish_outbox", { p_id: row.id, p_ok: true });
        sent++;
      } catch (e) {
        await db.rpc("gsmp_finish_outbox", { p_id: row.id, p_ok: false, p_error: String(e) });
        failed++;
      }
    }
  }
  return new Response(JSON.stringify({ sent, failed }), { headers: { "Content-Type": "application/json" } });
});
