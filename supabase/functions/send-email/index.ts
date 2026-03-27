// Supabase Edge Function: send-email
// Sends transactional emails via Resend API.
// Handles: welcome emails (triggered by profiles webhook) and billing emails (called directly).
//
// Required secrets (set via Supabase dashboard):
//   RESEND_API_KEY    - Resend API key
//   RESEND_FROM_EMAIL - Sender email (e.g., "Tarsy <hello@tarsy.dev>")

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const RESEND_FROM = Deno.env.get("RESEND_FROM_EMAIL") || "Tarsy <hello@tarsy.dev>";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ---------------------------------------------------------------------------
// Email templates
// ---------------------------------------------------------------------------

interface EmailContent {
  subject: string;
  html: string;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function welcomeEmail(displayName: string): EmailContent {
  const name = escapeHtml(displayName || "there");
  return {
    subject: "Welcome to Tarsy",
    html: `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { margin: 0; padding: 0; background-color: #1a1a1a; font-family: 'Courier New', monospace; color: #e8e0d4; }
    .container { max-width: 560px; margin: 0 auto; padding: 40px 24px; }
    .logo { font-size: 28px; font-weight: bold; color: #d4a574; margin-bottom: 32px; }
    h1 { font-size: 22px; color: #e8e0d4; margin-bottom: 16px; }
    p { font-size: 15px; line-height: 1.6; color: #a89e91; margin-bottom: 16px; }
    .highlight { color: #d4a574; }
    .cta { display: inline-block; background-color: #c4704b; color: #e8e0d4; padding: 12px 28px; text-decoration: none; border-radius: 6px; font-weight: bold; margin: 24px 0; font-family: 'Courier New', monospace; }
    .features { background-color: #2a2a2a; border-radius: 8px; padding: 20px 24px; margin: 24px 0; }
    .features li { color: #a89e91; margin-bottom: 8px; font-size: 14px; }
    .features li span { color: #7a8b6f; }
    .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #3a3a3a; font-size: 12px; color: #6b6358; }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">tarsy</div>
    <h1>Hey ${name}, welcome aboard.</h1>
    <p>You now have a remote command center for your Mac — right from your iPhone.</p>
    <p>Tarsy lets you run <span class="highlight">Claude Code</span>, <span class="highlight">Gemini CLI</span>, <span class="highlight">Codex</span>, and <span class="highlight">Aider</span> remotely, so your AI agents keep working even when you step away.</p>

    <div class="features">
      <ul style="list-style: none; padding: 0; margin: 0;">
        <li><span>→</span> Stream your Mac screen to your phone</li>
        <li><span>→</span> Chat with AI agents in real time</li>
        <li><span>→</span> Approve file changes and permissions on the go</li>
        <li><span>→</span> Get push notifications when agents need you</li>
      </ul>
    </div>

    <p>To get started, install the macOS menu bar app and sign in with the same account.</p>

    <div class="footer">
      <p>Tarsy — remote AI coding, from your pocket.</p>
    </div>
  </div>
</body>
</html>`,
  };
}

function subscriptionActiveEmail(displayName: string): EmailContent {
  const name = escapeHtml(displayName || "there");
  return {
    subject: "You're now Tarsy Pro",
    html: `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { margin: 0; padding: 0; background-color: #1a1a1a; font-family: 'Courier New', monospace; color: #e8e0d4; }
    .container { max-width: 560px; margin: 0 auto; padding: 40px 24px; }
    .logo { font-size: 28px; font-weight: bold; color: #d4a574; margin-bottom: 32px; }
    h1 { font-size: 22px; color: #e8e0d4; margin-bottom: 16px; }
    p { font-size: 15px; line-height: 1.6; color: #a89e91; margin-bottom: 16px; }
    .highlight { color: #d4a574; }
    .badge { display: inline-block; background-color: #7a8b6f; color: #e8e0d4; padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: bold; margin-bottom: 16px; }
    .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #3a3a3a; font-size: 12px; color: #6b6358; }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">tarsy</div>
    <div class="badge">PRO</div>
    <h1>Welcome to Pro, ${name}.</h1>
    <p>Your subscription is now active. You have access to <span class="highlight">unlimited workspaces</span> and all Pro features.</p>
    <p>Your plan renews monthly. You can manage your subscription anytime from the app settings.</p>
    <div class="footer">
      <p>Tarsy — remote AI coding, from your pocket.</p>
    </div>
  </div>
</body>
</html>`,
  };
}

function subscriptionCancelledEmail(displayName: string, endDate?: string): EmailContent {
  const name = escapeHtml(displayName || "there");
  const dateStr = endDate ? new Date(endDate).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }) : "the end of your billing period";
  return {
    subject: "Your Tarsy Pro subscription has been cancelled",
    html: `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { margin: 0; padding: 0; background-color: #1a1a1a; font-family: 'Courier New', monospace; color: #e8e0d4; }
    .container { max-width: 560px; margin: 0 auto; padding: 40px 24px; }
    .logo { font-size: 28px; font-weight: bold; color: #d4a574; margin-bottom: 32px; }
    h1 { font-size: 22px; color: #e8e0d4; margin-bottom: 16px; }
    p { font-size: 15px; line-height: 1.6; color: #a89e91; margin-bottom: 16px; }
    .highlight { color: #d4a574; }
    .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #3a3a3a; font-size: 12px; color: #6b6358; }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">tarsy</div>
    <h1>We're sorry to see you go, ${name}.</h1>
    <p>Your Pro subscription has been cancelled. You'll still have access to Pro features until <span class="highlight">${dateStr}</span>.</p>
    <p>After that, your account will revert to the free plan (1 workspace). Your data and workspaces won't be deleted — you can resubscribe anytime to unlock them again.</p>
    <div class="footer">
      <p>Tarsy — remote AI coding, from your pocket.</p>
    </div>
  </div>
</body>
</html>`,
  };
}

function subscriptionRenewedEmail(displayName: string): EmailContent {
  const name = escapeHtml(displayName || "there");
  return {
    subject: "Your Tarsy Pro subscription has been renewed",
    html: `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { margin: 0; padding: 0; background-color: #1a1a1a; font-family: 'Courier New', monospace; color: #e8e0d4; }
    .container { max-width: 560px; margin: 0 auto; padding: 40px 24px; }
    .logo { font-size: 28px; font-weight: bold; color: #d4a574; margin-bottom: 32px; }
    h1 { font-size: 22px; color: #e8e0d4; margin-bottom: 16px; }
    p { font-size: 15px; line-height: 1.6; color: #a89e91; margin-bottom: 16px; }
    .highlight { color: #d4a574; }
    .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #3a3a3a; font-size: 12px; color: #6b6358; }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">tarsy</div>
    <h1>Renewed! You're all set, ${name}.</h1>
    <p>Your <span class="highlight">Tarsy Pro</span> subscription has been renewed for another month. Unlimited workspaces and all Pro features remain active.</p>
    <div class="footer">
      <p>Tarsy — remote AI coding, from your pocket.</p>
    </div>
  </div>
</body>
</html>`,
  };
}

// ---------------------------------------------------------------------------
// Resend API
// ---------------------------------------------------------------------------

async function sendEmail(to: string, content: EmailContent): Promise<{ success: boolean; error?: string }> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: RESEND_FROM,
      to: [to],
      subject: content.subject,
      html: content.html,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    console.error(`Resend error: ${res.status} ${body}`);
    return { success: false, error: body };
  }

  return { success: true };
}

// ---------------------------------------------------------------------------
// Request types
// ---------------------------------------------------------------------------

type EmailType = "welcome" | "subscription_active" | "subscription_cancelled" | "subscription_renewed";

interface WebhookPayload {
  type: "INSERT";
  record: {
    id: string;
    email: string;
    display_name?: string;
  };
}

interface DirectPayload {
  email_type: EmailType;
  email: string;
  display_name?: string;
  subscription_end_date?: string;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req) => {
  try {
    // Validate Authorization header
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
    }
    const token = authHeader.replace("Bearer ", "");

    const body = await req.json();

    // Webhook trigger (profiles INSERT → welcome email)
    // Webhooks use the service role key — verify it matches
    if (body.type === "INSERT" && body.record?.email) {
      if (token !== SUPABASE_SERVICE_ROLE_KEY) {
        // Also accept a valid user JWT for the webhook (pg_net uses service role)
        const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
        const { data: { user }, error } = await supabase.auth.getUser(token);
        if (error || !user) {
          return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
        }
      }
      const { record } = body as WebhookPayload;
      const content = welcomeEmail(record.display_name || "");
      const result = await sendEmail(record.email, content);
      console.log(`Welcome email to ${record.email}: ${result.success ? "sent" : result.error}`);
      return new Response(JSON.stringify(result), { status: result.success ? 200 : 500 });
    }

    // Direct invocation (billing emails) — validate user JWT
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const { email_type, email, display_name, subscription_end_date } = body as DirectPayload;

    // Users can only send billing emails to their own address
    if (email !== user.email) {
      return new Response(JSON.stringify({ error: "Email mismatch" }), { status: 403 });
    }

    if (!email_type || !email) {
      return new Response(JSON.stringify({ error: "email_type and email are required" }), { status: 400 });
    }

    let content: EmailContent;
    switch (email_type) {
      case "welcome":
        content = welcomeEmail(display_name || "");
        break;
      case "subscription_active":
        content = subscriptionActiveEmail(display_name || "");
        break;
      case "subscription_cancelled":
        content = subscriptionCancelledEmail(display_name || "", subscription_end_date);
        break;
      case "subscription_renewed":
        content = subscriptionRenewedEmail(display_name || "");
        break;
      default:
        return new Response(JSON.stringify({ error: `Unknown email_type: ${email_type}` }), { status: 400 });
    }

    const result = await sendEmail(email, content);
    console.log(`${email_type} email to ${email}: ${result.success ? "sent" : result.error}`);
    return new Response(JSON.stringify(result), { status: result.success ? 200 : 500 });
  } catch (err) {
    console.error("send-email error:", err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
