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

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_PRIVATE_KEY_B64 = Deno.env.get("APNS_PRIVATE_KEY") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") || "com.tarsy.ios";

// Try production first, then sandbox — covers both App Store and Xcode builds
const APNS_HOSTS = Deno.env.get("APNS_PRODUCTION") === "true"
  ? ["https://api.push.apple.com", "https://api.sandbox.push.apple.com"]
  : ["https://api.sandbox.push.apple.com", "https://api.push.apple.com"];

interface PushNotification {
  id: string;
  user_id: string;
  title: string;
  body: string;
  sent: boolean;
  workspace_id?: string;
}

function pemToKeyData(input: string): Uint8Array {
  // Decode base64-encoded PEM if needed
  let pem = input.startsWith("-----") ? input : atob(input);
  pem = pem.replace(/\\n/g, "\n");

  // Strip PEM headers/footers and whitespace to get raw base64
  const b64 = pem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s/g, "");

  // Decode base64 to binary
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function base64url(data: Uint8Array | string): string {
  const str = typeof data === "string"
    ? btoa(data)
    : btoa(String.fromCharCode(...data));
  return str.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function generateAPNsToken(): Promise<string> {
  const keyData = pemToKeyData(APNS_PRIVATE_KEY_B64);

  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const header = base64url(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(JSON.stringify({ iss: APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${payload}`;

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(signingInput)
  );

  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

async function sendAPNs(
  deviceToken: string,
  title: string,
  body: string,
  token: string,
  badgeCount: number,
  workspaceId?: string
): Promise<boolean> {
  const payload: Record<string, unknown> = {
    aps: {
      alert: { title, body },
      sound: "default",
      badge: badgeCount,
    },
  };
  if (workspaceId) {
    payload.workspace_id = workspaceId;
  }
  const payloadBody = JSON.stringify(payload);
  const headers = {
    Authorization: `bearer ${token}`,
    "apns-topic": APNS_BUNDLE_ID,
    "apns-push-type": "alert",
    "apns-priority": "10",
  };

  // Try both APNs environments — covers App Store and Xcode builds
  for (const host of APNS_HOSTS) {
    try {
      const response = await fetch(
        `${host}/3/device/${deviceToken}`,
        { method: "POST", headers, body: payloadBody }
      );

      if (response.ok) {
        console.log(`APNs OK via ${host.includes("sandbox") ? "sandbox" : "production"} for ${deviceToken.substring(0, 8)}...`);
        return true;
      }

      const error = await response.text();
      console.log(`APNs ${response.status} via ${host.includes("sandbox") ? "sandbox" : "production"}: ${error}`);
    } catch (err) {
      console.error(`APNs send failed (${host}) for ${deviceToken}:`, err);
    }
  }

  return false;
}

serve(async (req) => {
  try {
    // Validate Authorization header — accept only service_role JWTs.
    // Supabase gateway already validates the JWT (verify_jwt: true),
    // so we just need to confirm the caller has the service_role role.
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
    }
    const jwt = authHeader.replace("Bearer ", "");
    try {
      const payload = JSON.parse(atob(jwt.split(".")[1]));
      if (payload.role !== "service_role") {
        return new Response(JSON.stringify({ error: "Forbidden: requires service_role" }), { status: 403 });
      }
    } catch {
      return new Response(JSON.stringify({ error: "Invalid token" }), { status: 401 });
    }

    // Check required env vars before proceeding
    const missingVars = [];
    if (!APNS_KEY_ID) missingVars.push("APNS_KEY_ID");
    if (!APNS_TEAM_ID) missingVars.push("APNS_TEAM_ID");
    if (!APNS_PRIVATE_KEY_B64) missingVars.push("APNS_PRIVATE_KEY");
    if (!SUPABASE_URL) missingVars.push("SUPABASE_URL");
    if (!SUPABASE_SERVICE_ROLE_KEY) missingVars.push("SUPABASE_SERVICE_ROLE_KEY");
    if (missingVars.length > 0) {
      console.error(`Missing env vars: ${missingVars.join(", ")}`);
      return new Response(JSON.stringify({ error: `Missing env vars: ${missingVars.join(", ")}` }), { status: 500 });
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

    // Compute dynamic badge count (current unread + this new one)
    const { data: currentUnread, error: countError } = await supabase.rpc("get_total_unread_count", { p_user_id: record.user_id });
    if (countError) {
      console.error(`Failed to get unread count: ${countError.message}`);
    }
    const badgeCount = (currentUnread ?? 0) + 1;

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
        badgeCount,
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
    const errorMsg = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    const stack = err instanceof Error ? err.stack : "";
    console.error("Edge function error:", errorMsg, stack);
    return new Response(JSON.stringify({ error: "Internal server error" }), { status: 500 });
  }
});
