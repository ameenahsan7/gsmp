// GSMP — send-issuer-confirmation (Supabase Edge Function)
// Deploy: Supabase Dashboard → Edge Functions → Deploy a new function → Via Editor
//         name: send-issuer-confirmation, paste this file, keep "Verify JWT" ON.
// Secrets used: RESEND_API_KEY (you add), SUPABASE_URL / SUPABASE_ANON_KEY /
//               SUPABASE_SERVICE_ROLE_KEY (provided automatically by Supabase).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SITE = "https://gsmpglobal.org";
const FROM = "GSMP Verification <verify@gsmpglobal.org>";
const ALLOWED_ORIGINS = ["https://gsmpglobal.org", "https://www.gsmpglobal.org"];
const SECTION: Record<string, string> = {
  education: "Education / degree", clinical: "Clinical experience", research: "Research", award: "Award",
};

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function cors(req: Request) {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function sha256Hex(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "Method not allowed" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) return json(req, 500, { error: "RESEND_API_KEY secret is not set" });

  // 1. Caller must be a GSMP admin (checked with THEIR token, not the service key)
  const authHeader = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
  const { data: userData } = await asUser.auth.getUser();
  const { data: isAdmin } = await asUser.rpc("is_saas_admin");
  if (!userData?.user || isAdmin !== true) return json(req, 403, { error: "Admins only" });

  let claimId: string;
  try { claimId = (await req.json()).claim_id; } catch { return json(req, 400, { error: "Bad request" }); }
  if (!/^[0-9a-f-]{36}$/i.test(claimId ?? "")) return json(req, 400, { error: "claim_id required" });

  // 2. Create single-use token; DB stores only its hash and validates the claim
  const token = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join("");
  const tokenHash = await sha256Hex(token);
  const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: info, error: dbErr } = await svc.rpc("gsmp_create_issuer_confirmation", {
    p_claim: claimId, p_token_hash: tokenHash, p_sent_by: userData.user.email ?? "admin",
  });
  if (dbErr) return json(req, 409, { error: dbErr.message });

  // 3. Send email
  const s = info.snapshot ?? {};
  const link = `${SITE}/pages/confirm/?t=${token}`;
  const rows = [["Credential", s.title], ["Type", SECTION[s.section] ?? s.section], ["Institution", s.organization],
                ["Role", s.role], ["Period", s.period]]
    .filter(([, v]) => v).map(([k, v]) =>
      `<tr><td style="padding:4px 12px 4px 0;color:#6b7280;">${esc(k)}</td><td style="padding:4px 0;"><strong>${esc(v)}</strong></td></tr>`).join("");
  const html = `<div style="font-family:Arial,sans-serif;max-width:560px;color:#111827;line-height:1.5;">
    <p style="color:#C49A3C;font-weight:bold;letter-spacing:2px;font-size:12px;">GSMP VERIFICATION REQUEST</p>
    <p>Hello,</p>
    <p><strong>${esc(info.member_name)}</strong> has listed the following credential on their GSMP Verified Portfolio
       and named you as someone who can confirm it:</p>
    <table style="border-collapse:collapse;margin:12px 0;">${rows}</table>
    <p>It takes about 30 seconds. Please confirm only if this is accurate to your knowledge.</p>
    <p><a href="${link}" style="display:inline-block;background:#1B2A4A;color:#fff;padding:12px 20px;border-radius:6px;text-decoration:none;font-weight:bold;">Review and respond</a></p>
    <p style="font-size:12px;color:#6b7280;">This link is personal to you, works once and expires in 14 days.
       If you don't recognise this request, you can ignore this email.<br>
       GSMP (Galen Society of Medical Professionals) · ${SITE}</p></div>`;
  const text = `GSMP verification request\n\n${info.member_name} has listed a credential and named you as someone who can confirm it:\n` +
    [s.title, s.organization, s.role, s.period].filter(Boolean).join(" · ") +
    `\n\nReview and respond (single use, expires in 14 days):\n${link}\n\nIf you don't recognise this request, ignore this email.`;

  const send = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [info.issuer_email], subject: `Please confirm a credential for ${info.member_name}`, html, text }),
  });
  if (!send.ok) {
    await svc.rpc("gsmp_cancel_issuer_confirmation", { p_token_hash: tokenHash });
    return json(req, 502, { error: "Email provider error: " + (await send.text()).slice(0, 300) });
  }
  return json(req, 200, { ok: true, sent_to: info.issuer_email });
});
