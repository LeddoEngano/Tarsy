import { createClient } from "@supabase/supabase-js";
import { createPublicKey, verify as cryptoVerify } from "node:crypto";

// Bun auto-loads .env files
const SUPABASE_URL = process.env.SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY!;
const PORT = parseInt(process.env.PORT || "8080");

const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
// Service role client for machine_tokens verification (bypasses RLS)
const supabaseAdmin = SUPABASE_SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  : null;

function shortId(id: string) { return id.slice(0, 8); }

// Connected machines and clients, keyed by userId
const machines = new Map<string, WebSocket>();
const clients = new Map<string, Set<WebSocket>>();

// Reverse lookup: ws -> { userId, role }
const connections = new Map<WebSocket, { userId: string; role: "machine" | "client" }>();

// Rate limiting: track messages per user per second (not per connection)
const MAX_MESSAGES_PER_SECOND = 120;
const MAX_CLIENTS_PER_USER = 5;
const userMessageCounts = new Map<string, { count: number; resetAt: number }>();

// Limit unauthenticated connections to prevent resource exhaustion
let unauthenticatedCount = 0;
const MAX_UNAUTH_CONNECTIONS = 50;

// Rate limiting: track machine replacements per userId
const machineReplacements = new Map<string, number[]>(); // userId -> timestamps

// Rate limiting for HTTP permission-response endpoint (per userId)
const HTTP_RATE_LIMIT_MAX = 10;
const HTTP_RATE_LIMIT_WINDOW = 60_000; // 1 minute
const httpRateLimits = new Map<string, number[]>();

function isHttpRateLimited(userId: string): boolean {
  const now = Date.now();
  const timestamps = httpRateLimits.get(userId) || [];
  const recent = timestamps.filter(t => now - t < HTTP_RATE_LIMIT_WINDOW);
  httpRateLimits.set(userId, recent);
  if (recent.length >= HTTP_RATE_LIMIT_MAX) {
    return true;
  }
  recent.push(now);
  return false;
}

function isMachineReplacementAbuse(userId: string): boolean {
  const now = Date.now();
  const timestamps = machineReplacements.get(userId) || [];
  const recent = timestamps.filter(t => now - t < 60_000);
  // Only count successful replacements — rejected attempts must NOT add timestamps,
  // otherwise the counter never resets and creates a permanent reconnect loop.
  machineReplacements.set(userId, recent);
  if (recent.length >= 10) {
    return true;
  }
  recent.push(now);
  return false;
}

// Action allowlists per role — defense in depth against message injection
// Prefixes must match WSAction raw values (e.g., "claude:" not "claude_code:")
const CLIENT_ALLOWED_PREFIXES = [
  "workspace:", "stream:start", "stream:stop",
  "remote:", "screenshot:request",
  "terminal:create", "terminal:input", "terminal:close", "terminal:list", "terminal:complete", "terminal:interrupt",
  "claude:create", "claude:message", "claude:close", "claude:user_response",
  "engine:create", "engine:message", "engine:close", "engine:user_response", "engine:interrupt",
  "openclaw:message",
  "git:", "file:", "browser:", "proxy:",
  "devserver:", "mcp:", "sudo:response",
  "engine:status", "agents:", "agent:", "ultracontext:",
  "repo:analyze", "wizard:",
  "security:rotate_machine_secret",
  "devtools:",
  "e2e:",
  "system_dialog:click_button",
  "permissions:status_request",
  "auth", "ping", "pong",
];

const MACHINE_ALLOWED_PREFIXES = [
  "workspace:", "stream:",
  "screenshot:result", "terminal:",
  "claude:", "engine:",
  "openclaw:", "git:", "file:", "browser:",
  "proxy:", "devserver:",
  "mcp:", "engine:status", "sudo:request", "sudo:result",
  "agents:", "agent:", "ultracontext:",
  "repo:analysis", "wizard:",
  "security:rotate_result", "security:fingerprint_update",
  "devtools:",
  "e2e:",
  "system_dialog:detected", "system_dialog:dismissed",
  "permissions:status",
  "relay:machine_online", "auth", "auth:success", "ping", "pong", "error",
];

function isActionAllowed(action: string, role: "machine" | "client"): boolean {
  const prefixes = role === "machine" ? MACHINE_ALLOWED_PREFIXES : CLIENT_ALLOWED_PREFIXES;
  return prefixes.some((prefix) => action === prefix || action.startsWith(prefix));
}

function isRateLimited(ws: WebSocket): boolean {
  const info = connections.get(ws);
  if (!info) return true; // Not authenticated — drop
  const userId = info.userId;
  const now = Date.now();
  let entry = userMessageCounts.get(userId);
  if (!entry || now >= entry.resetAt) {
    entry = { count: 0, resetAt: now + 1000 };
    userMessageCounts.set(userId, entry);
  }
  entry.count++;
  if (entry.count > MAX_MESSAGES_PER_SECOND) {
    if (entry.count === MAX_MESSAGES_PER_SECOND + 1) {
      // Notify once per window
      ws.send(JSON.stringify({ action: "error", payload: { message: "Rate limited" } }));
    }
    return true;
  }
  return false;
}

async function validateToken(token: string): Promise<{ userId: string | null; error?: string }> {
  try {
    const { data, error } = await supabase.auth.getUser(token);
    if (error) return { userId: null, error: error.message };
    if (!data.user) return { userId: null, error: "no user in response" };
    return { userId: data.user.id };
  } catch (e: any) {
    return { userId: null, error: e?.message || "unknown error" };
  }
}

function forwardToClients(userId: string, data: string | Buffer, sender: WebSocket) {
  const userClients = clients.get(userId);
  if (!userClients) return;
  for (const client of userClients) {
    if (client !== sender && client.readyState === WebSocket.OPEN) {
      client.send(data);
    }
  }
}

function forwardToMachine(userId: string, data: string | Buffer, sender: WebSocket) {
  const machine = machines.get(userId);
  if (machine && machine !== sender && machine.readyState === WebSocket.OPEN) {
    machine.send(data);
  }
}

function removeConnection(ws: WebSocket, code?: number, reason?: string) {
  const info = connections.get(ws);
  if (!info) return;

  if (info.role === "machine") {
    if (machines.get(info.userId) === ws) {
      machines.delete(info.userId);
      console.log(`[Relay] Machine disconnected: ${shortId(info.userId)} (code=${code ?? "?"}, reason=${reason || "none"})`);
    }
  } else {
    const userClients = clients.get(info.userId);
    if (userClients) {
      userClients.delete(ws);
      if (userClients.size === 0) clients.delete(info.userId);
    }
    console.log(`[Relay] Client disconnected: ${shortId(info.userId)} (code=${code ?? "?"}, reason=${reason || "none"})`);

    // Notify machine when last client disconnects so it can stop streaming
    const remainingClients = clients.get(info.userId);
    if (!remainingClients || remainingClients.size === 0) {
      const machine = machines.get(info.userId);
      if (machine && machine.readyState === WebSocket.OPEN) {
        machine.send(JSON.stringify({
          id: crypto.randomUUID(),
          action: "relay:no_clients",
          payload: { timestamp: new Date().toISOString() },
        }));
      }
    }
  }

  connections.delete(ws);
}

function registerConnection(ws: WebSocket, userId: string, role: "machine" | "client") {
  if (role === "machine") {
    const existing = machines.get(userId);
    if (existing) {
      if (isMachineReplacementAbuse(userId)) {
        console.log(`[Relay] Machine replacement abuse detected for ${userId.slice(0, 8)}`);
        // Clean up the dead existing entry so clients don't think machine is online
        if (existing.readyState !== WebSocket.OPEN) {
          machines.delete(userId);
          connections.delete(existing);
        }
        const userClients = clients.get(userId);
        if (userClients) {
          const alert = JSON.stringify({
            id: crypto.randomUUID(),
            action: "relay:machine_replacement_abuse",
            payload: { timestamp: new Date().toISOString() },
          });
          for (const client of userClients) {
            if (client.readyState === WebSocket.OPEN) client.send(alert);
          }
        }
        ws.close(4005, "Too many machine replacements");
        return;
      }

      // Notify all clients that machine is reconnecting
      const userClients = clients.get(userId);
      if (userClients) {
        const warning = JSON.stringify({
          id: crypto.randomUUID(),
          action: "relay:machine_reconnected",
          payload: { timestamp: new Date().toISOString() },
        });
        for (const client of userClients) {
          if (client.readyState === WebSocket.OPEN) client.send(warning);
        }
      }

      console.log(`[Relay] Replacing existing machine for ${shortId(userId)}`);
      existing.close(1000, "replaced");
      removeConnection(existing, 1000, "replaced");
    }
    machines.set(userId, ws);
    console.log(`[Relay] Machine connected: ${shortId(userId)} (machines=${machines.size})`);
  } else {
    if (!clients.has(userId)) {
      clients.set(userId, new Set());
    }
    const userClients = clients.get(userId)!;
    if (userClients.size >= MAX_CLIENTS_PER_USER) {
      console.log(`[Relay] Too many clients for ${shortId(userId)} (${userClients.size}), rejecting`);
      ws.close(4002, "Too many connections");
      return;
    }
    userClients.add(ws);
    const count = userClients.size;
    const hasMachine = machines.has(userId);
    console.log(`[Relay] Client connected: ${shortId(userId)} (clients=${count}, machine_online=${hasMachine})`);
  }

  connections.set(ws, { userId, role });

  // Notify client if machine is online
  if (role === "client") {
    const machine = machines.get(userId);
    if (machine && machine.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        id: crypto.randomUUID(),
        action: "relay:machine_online",
        payload: { status: "connected" },
        timestamp: new Date().toISOString(),
      }));
    }
  }
}

const server = Bun.serve({
  port: PORT,

  async fetch(req, server) {
    const url = new URL(req.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Permission response from iOS widget (HTTP POST — widget can't maintain WebSocket)
    if (url.pathname === "/api/permission-response" && req.method === "POST") {
      try {
        const authHeader = req.headers.get("authorization");
        if (!authHeader?.startsWith("Bearer ")) {
          return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
        }
        const token = authHeader.slice(7);
        const { userId, error } = await validateToken(token);
        if (!userId) {
          return new Response(JSON.stringify({ error: error || "Invalid token" }), { status: 401 });
        }

        if (isHttpRateLimited(userId)) {
          return new Response(JSON.stringify({ error: "Too many requests" }), { status: 429 });
        }

        const body = await req.json() as {
          sessionId?: string; answer?: string; engineType?: string;
          workspaceId?: string; permissionRequestId?: string;
        };
        if (!body.sessionId || !body.answer || !body.engineType) {
          return new Response(JSON.stringify({ error: "Missing required fields" }), { status: 400 });
        }

        // Build the same WSPacket the iOS app would send via WebSocket
        const packet = JSON.stringify({
          id: crypto.randomUUID(),
          action: "engine:user_response",
          payload: {
            sessionId: body.sessionId,
            answer: body.answer,
            engineType: body.engineType,
            ...(body.permissionRequestId ? { permissionRequestId: body.permissionRequestId } : {}),
          },
          timestamp: new Date().toISOString(),
        });

        // Forward directly to the user's machine
        const machine = machines.get(userId);
        if (machine && machine.readyState === WebSocket.OPEN) {
          machine.send(packet);
          console.log(`[Relay] HTTP permission response forwarded to machine (${shortId(userId)})`);
          return new Response(JSON.stringify({ status: "sent" }), {
            headers: { "Content-Type": "application/json" },
          });
        } else {
          console.log(`[Relay] HTTP permission response: no machine online (${shortId(userId)})`);
          return new Response(JSON.stringify({ error: "Machine not connected" }), { status: 503 });
        }
      } catch (e: any) {
        console.log(`[Relay] HTTP permission response error: ${e?.message}`);
        return new Response(JSON.stringify({ error: "Internal error" }), { status: 500 });
      }
    }

    // WebSocket upgrade — validate token via first message (query param auth removed for security)
    if (url.pathname === "/ws") {
      // Origin header validation: native apps won't send Origin, but browsers always do.
      // Block connections from unauthorized browser origins to prevent cross-site WebSocket hijacking.
      const origin = req.headers.get("origin");
      if (origin) {
        const ALLOWED_ORIGINS = [
          "https://tarsy.com",
          "https://www.tarsy.com",
          "https://app.tarsy.com",
          "http://localhost",
          "https://localhost",
        ];
        let isAllowed = ALLOWED_ORIGINS.includes(origin);
        // Allow localhost with any port (for local development)
        if (!isAllowed) {
          try {
            const parsed = new URL(origin);
            if (parsed.hostname === "localhost") {
              isAllowed = parsed.protocol === "http:" || parsed.protocol === "https:";
            }
          } catch {}
        }
        if (!isAllowed) {
          console.log(`[Relay] Rejected WebSocket from disallowed origin: ${origin}`);
          return new Response("Forbidden: origin not allowed", { status: 403 });
        }
      }

      const upgraded = server.upgrade(req, {
        data: { token: null, role: null },
      });

      if (!upgraded) {
        console.log(`[Relay] WebSocket upgrade failed`);
        return new Response("WebSocket upgrade failed", { status: 500 });
      }

      return undefined;
    }

    return new Response("Not Found", { status: 404 });
  },

  websocket: {
    async open(ws) {
      // Reject if too many unauthenticated connections are pending
      if (unauthenticatedCount >= MAX_UNAUTH_CONNECTIONS) {
        console.log(`[Relay] Too many unauthenticated connections (${unauthenticatedCount}), rejecting`);
        ws.close(503, "Service temporarily unavailable");
        return;
      }

      unauthenticatedCount++;
      // Auth via first message only — no query param tokens
      console.log(`[Relay] WS opened, awaiting auth message... (unauth=${unauthenticatedCount})`);

      // Close unauthenticated connections after 5 seconds
      setTimeout(() => {
        if (!connections.has(ws)) {
          console.log(`[Relay] Auth timeout — closing unauthenticated connection`);
          unauthenticatedCount = Math.max(0, unauthenticatedCount - 1);
          ws.close(4001, "Auth timeout");
        }
      }, 5_000);
    },

    async message(ws, message) {
      const info = connections.get(ws);

      // If not yet authenticated, expect first message to be auth payload
      if (!info) {
        try {
          const text = typeof message === "string" ? message : new TextDecoder().decode(message as ArrayBuffer);
          const auth = JSON.parse(text) as {
            action?: string;
            token?: string;
            role?: string;
            // Public-key auth (Phase 3+). Note: `publicKey` (without the
            // `machine` prefix) is reserved for the per-session E2E encryption
            // key and is intentionally distinct from the identity key below.
            machine_id?: string;
            timestamp?: number;
            signature?: string;           // base64(DER ECDSA P-256)
            machinePublicKey?: string;    // base64(DER SPKI P-256) — sanity check vs DB
          };

          if (auth.action !== "auth" || !auth.token || !auth.role || !["machine", "client"].includes(auth.role)) {
            console.log(`[Relay] Invalid auth message`);
            ws.close(4001, "Invalid auth message");
            return;
          }

          const start = Date.now();
          const { userId, error } = await validateToken(auth.token);
          const elapsed = Date.now() - start;

          if (!userId) {
            console.log(`[Relay] Auth failed for ${auth.role}: ${error} (${elapsed}ms)`);
            ws.close(4001, "Invalid token");
            return;
          }

          // Verify machine identity for machine role (prevents impersonation).
          // Signed-timestamp flow: sign ${machine_id}:${timestamp}:${userId}
          // with a P-256 ECDSA key whose public counterpart was uploaded via
          // register_machine_public_key(). Private key lives in Secure Enclave
          // (macOS) or TPM (Windows); relay never sees it.
          if (auth.role === "machine") {
            if (!auth.signature || !auth.timestamp || !auth.machine_id) {
              console.log(`[Relay] Machine auth rejected: missing signed-timestamp fields (${userId.slice(0, 8)})`);
              ws.close(4003, "Machine credentials required");
              return;
            }

            // 1. Freshness
            const now = Date.now();
            const skew = Math.abs(now - auth.timestamp);
            if (skew > 60_000) {
              console.log(`[Relay] Machine auth rejected: stale timestamp (skew=${skew}ms, ${userId.slice(0, 8)})`);
              ws.close(4003, "Stale timestamp");
              return;
            }

            // 2. Fetch public key for this (user_id, machine_id)
            const dbClient = supabaseAdmin || supabase;
            const { data: tokenRow, error: fetchErr } = await dbClient
              .from("machine_tokens")
              .select("public_key, key_algorithm")
              .eq("user_id", userId)
              .eq("machine_id", auth.machine_id)
              .maybeSingle();
            if (fetchErr || !tokenRow?.public_key) {
              console.log(`[Relay] Machine auth rejected: no public_key on file (${userId.slice(0, 8)} / ${String(auth.machine_id).slice(0, 8)})`);
              ws.close(4003, "Public key not registered");
              return;
            }
            if (tokenRow.key_algorithm && tokenRow.key_algorithm !== "p256-ecdsa") {
              console.log(`[Relay] Machine auth rejected: unsupported key algorithm ${tokenRow.key_algorithm}`);
              ws.close(4003, "Unsupported key algorithm");
              return;
            }

            // 3. Decode stored public key. Supabase returns bytea as a
            // "\\x..." hex string through PostgREST.
            let storedPublicKeyDer: Buffer;
            try {
              const raw = tokenRow.public_key as unknown as string;
              storedPublicKeyDer = raw.startsWith("\\x")
                ? Buffer.from(raw.slice(2), "hex")
                : Buffer.from(raw, "base64");
            } catch (e) {
              console.log(`[Relay] Machine auth rejected: public_key decode failed`);
              ws.close(4003, "Invalid stored public key");
              return;
            }

            // 4. Optional sanity check: client-presented public key matches DB
            if (auth.machinePublicKey) {
              const clientPubDer = Buffer.from(auth.machinePublicKey, "base64");
              if (clientPubDer.length !== storedPublicKeyDer.length ||
                  !crypto.timingSafeEqual(clientPubDer, storedPublicKeyDer)) {
                console.log(`[Relay] Machine auth rejected: public_key mismatch (${userId.slice(0, 8)})`);
                ws.close(4003, "Public key mismatch");
                return;
              }
            }

            // 5. Verify ECDSA signature over canonical string
            const canonical = `${auth.machine_id}:${auth.timestamp}:${userId}`;
            let verified = false;
            try {
              const pubKey = createPublicKey({
                key: storedPublicKeyDer,
                format: "der",
                type: "spki",
              });
              const sigBuf = Buffer.from(auth.signature, "base64");
              verified = cryptoVerify(
                "sha256",
                Buffer.from(canonical, "utf8"),
                { key: pubKey, dsaEncoding: "der" },
                sigBuf,
              );
            } catch (e) {
              console.log(`[Relay] Machine auth rejected: verify threw ${e}`);
              ws.close(4003, "Signature verification failed");
              return;
            }
            if (!verified) {
              console.log(`[Relay] Machine auth rejected: bad signature (${userId.slice(0, 8)} / ${String(auth.machine_id).slice(0, 8)})`);
              ws.close(4003, "Invalid signature");
              return;
            }
          }

          console.log(`[Relay] Auth OK for ${auth.role} ${userId.slice(0, 8)} (${elapsed}ms)`);
          unauthenticatedCount = Math.max(0, unauthenticatedCount - 1);
          registerConnection(ws, userId, auth.role as "machine" | "client");
          ws.send(JSON.stringify({
        id: crypto.randomUUID(),
        action: "auth:success",
        payload: {},
        timestamp: new Date().toISOString(),
      }));
        } catch (e) {
          const preview = typeof message === "string" ? message.slice(0, 100) : `[binary ${(message as ArrayBuffer).byteLength}B]`;
          console.log(`[Relay] Auth parse error: ${e} | msg: ${preview}`);
          // Don't close — allow retry within the 5s auth timeout
        }
        return;
      }

      if (isRateLimited(ws)) return; // Drop excess messages silently

      // Enforce text message size limit (binary frames like video use the WebSocket-level 4MB limit)
      // 1MB allows large git diffs and file trees while preventing abuse
      if (typeof message === "string" && message.length > 1_048_576) {
        console.log(`[Relay] Text message too large: ${message.length} bytes from ${info.role} ${shortId(info.userId)}`);
        return;
      }

      // Validate action allowlists for text messages (binary frames pass through)
      if (typeof message === "string") {
        try {
          const parsed = JSON.parse(message);
          if (parsed.action && !isActionAllowed(parsed.action, info.role)) {
            console.log(`[Relay] Blocked ${info.role} action: ${parsed.action} (${shortId(info.userId)})`);
            return;
          }
        } catch {
          // Non-JSON text message — allow (could be legacy format)
        }
      }

      if (info.role === "machine") {
        forwardToClients(info.userId, message as string | Buffer, ws);
      } else {
        forwardToMachine(info.userId, message as string | Buffer, ws);
      }
    },

    close(ws, code, reason) {
      // If connection was never authenticated, decrement the unauthenticated counter
      if (!connections.has(ws)) {
        unauthenticatedCount = Math.max(0, unauthenticatedCount - 1);
      }
      removeConnection(ws, code, reason);
      // Per-user rate limiting cleanup happens when last connection for user disconnects
    },

    idleTimeout: 120, // seconds — send ping/pong to keep alive
    sendPings: true, // Bun auto-sends WebSocket pings
    maxPayloadLength: 4 * 1024 * 1024, // 4MB max message size
    perMessageDeflate: false, // Keep off for binary H.264 frames
  },
});

console.log(`[Relay] Tarsy Relay Server running on port ${PORT}`);
console.log(`[Relay] Health: http://localhost:${PORT}/health`);
