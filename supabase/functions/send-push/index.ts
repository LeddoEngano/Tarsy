// Supabase Edge Function: send-push
// Triggered via database webhook on insert to push_notifications table.
// Reads device tokens from push_tokens and sends APNs via HTTP/2.
//
// Required secrets (set via Supabase dashboard):
//   APNS_KEY_ID       - Apple APNs Key ID
//   APNS_TEAM_ID      - Apple Developer Team ID
//   APNS_PRIVATE_KEY  - APNs p8 private key (base64 encoded)
//   APNS_BUNDLE_ID    - App bundle ID (e.g., com.tarsy.ios)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://deno.land/x/jose@v4.14.4/index.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_PRIVATE_KEY_B64 = Deno.env.get("APNS_PRIVATE_KEY")!;
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") || "com.tarsy.ios";

// Use sandbox for development, production for release
const APNS_HOST = Deno.env.get("APNS_PRODUCTION") === "true"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

interface PushNotification {
  id: string;
  user_id: string;
  title: string;
  body: string;
  sent: boolean;
  workspace_id?: string;
}

async function generateAPNsToken(): Promise<string> {
  const privateKeyPem = atob(APNS_PRIVATE_KEY_B64);
  const privateKey = await jose.importPKCS8(privateKeyPem, "ES256");

  const jwt = await new jose.SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: APNS_KEY_ID })
    .setIssuer(APNS_TEAM_ID)
    .setIssuedAt()
    .sign(privateKey);

  return jwt;
}

async function sendAPNs(
  deviceToken: string,
  title: string,
  body: string,
  token: string,
  workspaceId?: string
): Promise<boolean> {
  try {
    const payload: Record<string, unknown> = {
      aps: {
        alert: { title, body },
        sound: "default",
        badge: 1,
      },
    };
    if (workspaceId) {
      payload.workspace_id = workspaceId;
    }
    const response = await fetch(
      `${APNS_HOST}/3/device/${deviceToken}`,
      {
        method: "POST",
        headers: {
          Authorization: `bearer ${token}`,
          "apns-topic": APNS_BUNDLE_ID,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: JSON.stringify(payload),
      }
    );

    if (!response.ok) {
      const error = await response.text();
      console.error(`APNs error for ${deviceToken}: ${response.status} ${error}`);
      return false;
    }
    return true;
  } catch (err) {
    console.error(`APNs send failed for ${deviceToken}:`, err);
    return false;
  }
}

serve(async (req) => {
  try {
    // Validate Authorization header (webhook calls use service role key)
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
    }
    const token = authHeader.replace("Bearer ", "");
    if (token !== SUPABASE_SERVICE_ROLE_KEY) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const { record } = await req.json() as { record: PushNotification };

    if (!record || record.sent) {
      return new Response(JSON.stringify({ skipped: true }), { status: 200 });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Get device tokens for this user
    const { data: tokens, error: tokensError } = await supabase
      .from("push_tokens")
      .select("device_token")
      .eq("user_id", record.user_id);

    if (tokensError || !tokens?.length) {
      console.log(`No tokens found for user ${record.user_id}`);
      // Mark as sent anyway to avoid retries
      await supabase
        .from("push_notifications")
        .update({ sent: true })
        .eq("id", record.id);
      return new Response(JSON.stringify({ sent: 0 }), { status: 200 });
    }

    // Generate APNs JWT
    const apnsToken = await generateAPNsToken();

    // Send to all devices
    let sentCount = 0;
    for (const { device_token } of tokens) {
      const success = await sendAPNs(
        device_token,
        record.title,
        record.body,
        apnsToken,
        record.workspace_id
      );
      if (success) sentCount++;
    }

    // Mark notification as sent
    await supabase
      .from("push_notifications")
      .update({ sent: true })
      .eq("id", record.id);

    return new Response(
      JSON.stringify({ sent: sentCount, total: tokens.length }),
      { status: 200 }
    );
  } catch (err) {
    console.error("Edge function error:", err);
    return new Response(JSON.stringify({ error: "Failed to send notification" }), { status: 500 });
  }
});
