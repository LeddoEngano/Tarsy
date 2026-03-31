// Supabase Edge Function: update-live-activity
// Called by macOS daemon to push Live Activity content-state updates via APNs.
// Looks up activity push tokens from live_activity_tokens table and sends
// liveactivity push notifications to update the Lock Screen / Dynamic Island.
//
// Required secrets (shared with send-push):
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

const APNS_HOST = Deno.env.get("APNS_PRODUCTION") === "true"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

// --- APNs JWT helpers (shared with send-push) ---

function pemToKeyData(input: string): Uint8Array {
  let pem = input.startsWith("-----") ? input : atob(input);
  pem = pem.replace(/\\n/g, "\n");
  const b64 = pem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s/g, "");
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

// --- Live Activity push ---

interface LiveActivityUpdateRequest {
  user_id: string;
  workspace_id: string;
  content_state: Record<string, unknown>;
  event: "update" | "end";
  alert?: { title: string; body: string };
  dismissal_date?: number;
}

async function sendLiveActivityPush(
  activityToken: string,
  apnsJwt: string,
  body: LiveActivityUpdateRequest
): Promise<boolean> {
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(Date.now() / 1000),
    event: body.event,
    "content-state": body.content_state,
  };

  if (body.event === "update") {
    aps["stale-date"] = Math.floor(Date.now() / 1000) + 240;
  }

  if (body.event === "end" && body.dismissal_date) {
    aps["dismissal-date"] = body.dismissal_date;
  }

  if (body.alert) {
    aps.alert = body.alert;
    aps.sound = "default";
  }

  const payload = JSON.stringify({ aps });
  const headers = {
    Authorization: `bearer ${apnsJwt}`,
    "apns-topic": `${APNS_BUNDLE_ID}.push-type.liveactivity`,
    "apns-push-type": "liveactivity",
    "apns-priority": body.event === "end" || body.alert ? "10" : "5",
  };

  // Try both APNs environments — sandbox for Xcode builds, production for App Store.
  // APNs returns 200 even for wrong-environment tokens, so we try both to ensure delivery.
  const hosts = [
    "https://api.sandbox.push.apple.com",
    "https://api.push.apple.com",
  ];

  for (const host of hosts) {
    try {
      const response = await fetch(`${host}/3/device/${activityToken}`, {
        method: "POST",
        headers,
        body: payload,
      });

      if (response.ok) {
        console.log(`[LA] APNs OK via ${host.includes("sandbox") ? "sandbox" : "production"} for token ${activityToken.substring(0, 8)}...`);
      } else {
        const error = await response.text();
        console.log(`[LA] APNs ${response.status} via ${host.includes("sandbox") ? "sandbox" : "production"}: ${error}`);
      }
    } catch (err) {
      console.error(`[LA] APNs send failed (${host}):`, err);
    }
  }

  return true;
}

serve(async (req) => {
  try {
    // Auth: accept user JWT — validate user_id matches the token's subject.
    // Supabase gateway validates the JWT signature (verify_jwt: true).
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
    }

    const jwt = authHeader.replace("Bearer ", "");
    let callerUserId: string;
    try {
      const payload = JSON.parse(atob(jwt.split(".")[1]));
      // Accept both service_role and authenticated user tokens
      if (payload.role === "service_role") {
        callerUserId = "service_role";
      } else {
        callerUserId = payload.sub;
        if (!callerUserId) {
          return new Response(JSON.stringify({ error: "Invalid token: no sub" }), { status: 401 });
        }
      }
    } catch {
      return new Response(JSON.stringify({ error: "Invalid token" }), { status: 401 });
    }

    // Check required env vars
    if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY_B64 || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
      return new Response(JSON.stringify({ error: "Missing APNs configuration" }), { status: 500 });
    }

    const body = (await req.json()) as LiveActivityUpdateRequest;

    if (!body.user_id || !body.workspace_id || !body.content_state || !body.event) {
      return new Response(JSON.stringify({ error: "Missing required fields" }), { status: 400 });
    }

    // Validate caller matches request (unless service_role)
    // Compare case-insensitive: Swift UUID.uuidString is uppercase, Supabase JWT sub is lowercase
    if (callerUserId !== "service_role" && callerUserId.toLowerCase() !== body.user_id.toLowerCase()) {
      return new Response(JSON.stringify({ error: "Forbidden: user mismatch" }), { status: 403 });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Look up activity push tokens for this user + workspace
    // Lowercase UUIDs: Swift sends uppercase, Supabase stores lowercase
    const userId = body.user_id.toLowerCase();
    const workspaceId = body.workspace_id.toLowerCase();

    const { data: tokens, error: tokensError } = await supabase
      .from("live_activity_tokens")
      .select("activity_token")
      .eq("user_id", userId)
      .eq("workspace_id", workspaceId);

    console.log(`[LA] Token lookup: user=${userId.substring(0, 8)} ws=${workspaceId.substring(0, 8)} found=${tokens?.length ?? 0} error=${tokensError?.message ?? 'none'}`);

    if (tokensError || !tokens?.length) {
      return new Response(JSON.stringify({ sent: 0, reason: "no_tokens" }), { status: 200 });
    }

    const apnsJwt = await generateAPNsToken();

    let sentCount = 0;
    for (const { activity_token } of tokens) {
      const success = await sendLiveActivityPush(activity_token, apnsJwt, body);
      if (success) sentCount++;
    }

    console.log(`[LA] Push results: sent=${sentCount}/${tokens.length}`);

    // Clean up tokens on end event
    if (body.event === "end") {
      await supabase
        .from("live_activity_tokens")
        .delete()
        .eq("user_id", userId)
        .eq("workspace_id", workspaceId);
    }

    return new Response(
      JSON.stringify({ sent: sentCount, total: tokens.length }),
      { status: 200 }
    );
  } catch (err) {
    const errorMsg = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    console.error("update-live-activity error:", errorMsg);
    return new Response(JSON.stringify({ error: "Internal server error" }), { status: 500 });
  }
});
