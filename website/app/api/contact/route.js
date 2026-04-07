import { NextResponse } from "next/server";
import { Resend } from "resend";

const RESEND_API_KEY = process.env.RESEND_API_KEY;
const RESEND_FROM = process.env.RESEND_FROM_EMAIL || "Tarsy <noreply@tarsy.dev>";
const CONTACT_RECIPIENT = process.env.CONTACT_EMAIL || "support@tarsy.dev";

const SUBJECT_LABELS = {
  general: "General Inquiry",
  support: "Support",
  bug: "Bug Report",
  feature: "Feature Request",
  business: "Business Inquiry",
  other: "Other",
};

const VALID_SUBJECTS = Object.keys(SUBJECT_LABELS);

// In-memory rate limiting (per-process).
// NOTE: This works for single-process deployments (e.g., `next start`).
// For serverless (Vercel), replace with an external store (Upstash Redis, KV, etc.).
const rateLimitMap = new Map();
const RATE_LIMIT_MAX = 5;
const RATE_LIMIT_WINDOW = 60 * 60 * 1000; // 1 hour
const MAX_RATE_LIMIT_ENTRIES = 10_000; // Prevent unbounded memory growth

function checkRateLimit(ip) {
  // Evict if map grows too large (DoS via many unique IPs)
  if (rateLimitMap.size > MAX_RATE_LIMIT_ENTRIES) {
    rateLimitMap.clear();
  }

  const now = Date.now();
  const entry = rateLimitMap.get(ip) || [];
  const recent = entry.filter((t) => now - t < RATE_LIMIT_WINDOW);
  rateLimitMap.set(ip, recent);

  if (recent.length >= RATE_LIMIT_MAX) {
    return false;
  }
  recent.push(now);
  return true;
}

// Cleanup old entries every 60s
setInterval(() => {
  const now = Date.now();
  for (const [key, timestamps] of rateLimitMap.entries()) {
    const recent = timestamps.filter((t) => now - t < RATE_LIMIT_WINDOW);
    if (recent.length === 0) {
      rateLimitMap.delete(key);
    } else {
      rateLimitMap.set(key, recent);
    }
  }
}, 60000);

export async function POST(req) {
  try {
    // Rate limit
    const ip =
      req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
      req.headers.get("x-real-ip") ||
      "unknown";

    if (!checkRateLimit(ip)) {
      return NextResponse.json(
        { success: false, error: "Too many requests. Please try again later." },
        { status: 429 }
      );
    }

    const body = await req.json().catch(() => ({}));
    const { subject, name, email, message } = body;

    // Validate subject
    const subjectType =
      subject && VALID_SUBJECTS.includes(subject) ? subject : "general";
    const subjectLabel = SUBJECT_LABELS[subjectType];

    // Validate required fields
    if (!name || typeof name !== "string" || !name.trim()) {
      return NextResponse.json(
        { success: false, error: "Name is required" },
        { status: 400 }
      );
    }

    if (!email || typeof email !== "string" || !email.trim()) {
      return NextResponse.json(
        { success: false, error: "Email is required" },
        { status: 400 }
      );
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email.trim())) {
      return NextResponse.json(
        { success: false, error: "Invalid email address" },
        { status: 400 }
      );
    }

    if (!message || typeof message !== "string" || !message.trim()) {
      return NextResponse.json(
        { success: false, error: "Message is required" },
        { status: 400 }
      );
    }

    if (!RESEND_API_KEY) {
      console.error("[Contact API] RESEND_API_KEY not configured");
      return NextResponse.json(
        { success: false, error: "Email service not configured" },
        { status: 500 }
      );
    }

    const resend = new Resend(RESEND_API_KEY);

    const sanitize = (str) => str.replace(/</g, "&lt;").replace(/>/g, "&gt;");

    const emailHtml = `
      <!DOCTYPE html>
      <html>
        <head>
          <style>
            body { font-family: 'JetBrains Mono', monospace, sans-serif; line-height: 1.6; color: #e8e0d4; background: #1a1a1a; }
            .container { max-width: 600px; margin: 0 auto; padding: 20px; }
            .header { background: #d4a574; color: #1a1a1a; padding: 20px; border-radius: 8px 8px 0 0; }
            .content { background: #2a2a2a; padding: 20px; border: 1px solid #3a3a3a; border-top: none; border-radius: 0 0 8px 8px; }
            .meta { color: #a89e91; font-size: 14px; margin: 16px 0; padding-top: 16px; border-top: 1px solid #3a3a3a; }
            .message { background: #1a1a1a; padding: 16px; border-radius: 8px; border: 1px solid #3a3a3a; margin: 16px 0; white-space: pre-wrap; color: #e8e0d4; }
            .subject-badge { display: inline-block; background: #3a3a3a; color: #d4a574; padding: 4px 12px; border-radius: 16px; font-size: 14px; }
            h2 { margin: 0 0 8px 0; }
            h3 { color: #a89e91; margin: 16px 0 8px 0; }
            a { color: #d4a574; }
            strong { color: #e8e0d4; }
          </style>
        </head>
        <body>
          <div class="container">
            <div class="header">
              <h2>New Contact Form Submission</h2>
            </div>
            <div class="content">
              <p><span class="subject-badge">${subjectLabel}</span></p>

              <h3>From:</h3>
              <p><strong>${sanitize(name.trim())}</strong></p>
              <p><a href="mailto:${email.trim()}">${sanitize(email.trim())}</a></p>

              <h3>Message:</h3>
              <div class="message">${sanitize(message.trim()).replace(/\n/g, "<br>")}</div>

              <div class="meta">
                <p><strong>Subject Type:</strong> ${subjectType}</p>
                <p><strong>Submitted:</strong> ${new Date().toISOString()}</p>
              </div>
            </div>
          </div>
        </body>
      </html>
    `;

    await resend.emails.send({
      from: RESEND_FROM,
      to: [CONTACT_RECIPIENT],
      replyTo: email.trim(),
      subject: `[Tarsy ${subjectLabel}] Message from ${name.trim()}`,
      html: emailHtml,
    });

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error("[Contact API] Unexpected error:", error);
    return NextResponse.json(
      { success: false, error: "Internal server error" },
      { status: 500 }
    );
  }
}
