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
  attachments?: { filename: string; content: string; content_type: string }[];
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Shared email styles matching TarsyTheme
const EMAIL_STYLES = `
    body { margin: 0; padding: 0; background-color: #131316; font-family: 'Courier New', Courier, monospace; color: #e4e4e7; }
    .container { max-width: 560px; margin: 0 auto; padding: 40px 24px; }
    .logo-row { display: flex; align-items: center; gap: 10px; margin-bottom: 32px; }
    .logo-text { font-size: 24px; font-weight: bold; color: #e4e4e7; }
    h1 { font-size: 20px; color: #e4e4e7; margin-bottom: 16px; font-weight: 600; }
    p { font-size: 14px; line-height: 1.7; color: #71717a; margin-bottom: 16px; }
    .highlight { color: #e4e4e7; font-weight: 600; }
    .card { background-color: #1c1c21; border: 1px solid #2a2a30; border-radius: 8px; padding: 20px 24px; margin: 24px 0; }
    .card li { color: #71717a; margin-bottom: 8px; font-size: 13px; }
    .card li span { color: #6bc77b; }
    .badge { display: inline-block; color: #e4e4e7; padding: 4px 12px; border-radius: 4px; font-size: 11px; font-weight: bold; margin-bottom: 16px; text-transform: uppercase; letter-spacing: 0.5px; }
    .meta { font-size: 11px; color: #52525b; margin-bottom: 4px; }
    .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #2a2a30; font-size: 11px; color: #52525b; }
`;

const LOGO_HTML = `<div class="logo-row">
      <img src="https://tarsy.dev/eyes.png" alt="tarsy" width="28" height="28" style="display: block;" />
      <span class="logo-text">tarsy</span>
    </div>`;

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
  <style>${EMAIL_STYLES}</style>
</head>
<body>
  <div class="container">
    ${LOGO_HTML}
    <h1>Hey ${name}, welcome aboard.</h1>
    <p>You now have a remote command center for your Mac — right from your iPhone.</p>
    <p>Tarsy lets you run <span class="highlight">Claude Code</span>, <span class="highlight">Gemini CLI</span>, <span class="highlight">Codex</span>, and <span class="highlight">Aider</span> remotely, so your AI agents keep working even when you step away.</p>

    <div class="card">
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
  <style>${EMAIL_STYLES}</style>
</head>
<body>
  <div class="container">
    ${LOGO_HTML}
    <div class="badge" style="background-color: #6bc77b; color: #131316;">PRO</div>
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
  <style>${EMAIL_STYLES}</style>
</head>
<body>
  <div class="container">
    ${LOGO_HTML}
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
  <style>${EMAIL_STYLES}</style>
</head>
<body>
  <div class="container">
    ${LOGO_HTML}
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

function feedbackEmail(
  userEmail: string,
  displayName: string,
  feedbackType: string,
  title: string,
  description: string,
  platform: string,
  appVersion?: string,
  imageBase64?: string
): EmailContent {
  const typeLabels: Record<string, string> = {
    bug: "Bug Report",
    feature: "Feature Request",
    general: "General Feedback",
  };
  const typeColors: Record<string, string> = {
    bug: "#e5716a",
    feature: "#6bc77b",
    general: "#71717a",
  };
  const label = escapeHtml(typeLabels[feedbackType] || feedbackType);
  const color = typeColors[feedbackType] || "#71717a";
  const safeName = escapeHtml(displayName || "Unknown");
  const safeTitle = escapeHtml(title);
  const safeDesc = escapeHtml(description).replace(/\n/g, "<br>");
  const safeEmail = escapeHtml(userEmail);
  const safePlatform = escapeHtml(platform);
  const safeVersion = appVersion ? escapeHtml(appVersion) : "n/a";

  const attachments = imageBase64
    ? [{ filename: "screenshot.jpg", content: imageBase64, content_type: "image/jpeg" }]
    : undefined;

  return {
    subject: `[${label}] ${title}`,
    attachments,
    html: `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>${EMAIL_STYLES}</style>
</head>
<body>
  <div class="container">
    ${LOGO_HTML}
    <div class="badge" style="background-color: ${color}; color: #131316;">${label}</div>
    <h1>${safeTitle}</h1>

    <div class="card">
      <p style="margin: 0; color: #e4e4e7;">${safeDesc}</p>
    </div>

    ${imageBase64 ? `<div style="margin: 16px 0;"><img src="data:image/jpeg;base64,${imageBase64}" style="max-width: 100%; border-radius: 8px; border: 1px solid #2a2a30;" alt="Screenshot"></div>` : ""}

    <div class="meta">From: ${safeName} (${safeEmail})</div>
    <div class="meta">Platform: ${safePlatform} | App version: ${safeVersion}</div>

    <div class="footer">
      <p>Reply to this email to respond directly to the user.</p>
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
      ...(content.attachments && { attachments: content.attachments }),
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

type EmailType = "welcome" | "subscription_active" | "subscription_cancelled" | "subscription_renewed" | "feedback";

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
  feedback_type?: string;
  feedback_title?: string;
  feedback_description?: string;
  feedback_platform?: string;
  feedback_app_version?: string;
  feedback_image_base64?: string;
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
    // Webhooks MUST use the service role key — no user JWT fallback
    if (body.type === "INSERT" && body.record?.email) {
      if (token !== SUPABASE_SERVICE_ROLE_KEY) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
      }
      const { record } = body as WebhookPayload;
      const content = welcomeEmail(record.display_name || "");
      const result = await sendEmail(record.email, content);
      console.log(`Welcome email to ${record.email}: ${result.success ? "sent" : result.error}`);
      return new Response(JSON.stringify(result), { status: result.success ? 200 : 500 });
    }

    // Direct invocation (billing/feedback emails) — validate user JWT
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      console.error(`Auth failed: ${authError?.message || "no user"}, token prefix: ${token.substring(0, 20)}...`);
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const { email_type, email, display_name, subscription_end_date,
            feedback_type, feedback_title, feedback_description,
            feedback_platform, feedback_app_version, feedback_image_base64 } = body as DirectPayload;

    if (!email_type) {
      return new Response(JSON.stringify({ error: "email_type is required" }), { status: 400 });
    }

    // Feedback emails go to support, not the user — skip email mismatch check
    if (email_type === "feedback") {
      if (!feedback_type || !feedback_title || !feedback_description) {
        return new Response(JSON.stringify({ error: "feedback_type, feedback_title, and feedback_description are required" }), { status: 400 });
      }
      const content = feedbackEmail(
        user.email || email || "unknown",
        display_name || user.user_metadata?.display_name || "",
        feedback_type,
        feedback_title,
        feedback_description,
        feedback_platform || "ios",
        feedback_app_version,
        feedback_image_base64
      );
      const result = await sendEmail("support@tarsy.dev", content);
      console.log(`Feedback email (${feedback_type}): ${result.success ? "sent" : result.error}`);
      return new Response(JSON.stringify(result), { status: result.success ? 200 : 500 });
    }

    // Billing emails — users can only send to their own address
    if (!email) {
      return new Response(JSON.stringify({ error: "email is required" }), { status: 400 });
    }
    if (email !== user.email) {
      return new Response(JSON.stringify({ error: "Email mismatch" }), { status: 403 });
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
    return new Response(JSON.stringify({ error: "Failed to send email" }), { status: 500 });
  }
});
