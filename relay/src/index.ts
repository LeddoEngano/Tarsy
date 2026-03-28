import { createClient } from "@supabase/supabase-js";

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

function isMachineReplacementAbuse(userId: string): boolean {
  const now = Date.now();
  const timestamps = machineReplacements.get(userId) || [];
  const recent = timestamps.filter(t => now - t < 60_000);
  recent.push(now);
  machineReplacements.set(userId, recent);
  return recent.length > 3;
}

// Action allowlists per role — defense in depth against message injection
const CLIENT_ALLOWED_PREFIXES = [
  "workspace:", "stream:start", "stream:stop",
  "remote_input:", "screenshot:request",
  "terminal:create", "terminal:input", "terminal:close", "terminal:list",
  "claude_code:create", "claude_code:message", "claude_code:close",
  "generic_engine:create", "generic_engine:message", "generic_engine:close",
  "openclaw:message",
  "git:", "file:", "browser:", "http_proxy:request",
  "dev_server:", "mcp:", "sudo:response",
  "engine_status:", "agents:", "agent:", "ultracontext:",
  "repo:analyze", "wizard:",
  "security:rotate_machine_secret",
  "e2e:encrypted",
  "auth", "ping", "pong",
];

const MACHINE_ALLOWED_PREFIXES = [
  "workspace:", "stream:frame",
  "screenshot:result", "terminal:output", "terminal:list_result",
  "claude_code:output", "claude_code:complete", "claude_code:ask_user",
  "generic_engine:output", "generic_engine:complete", "generic_engine:ask_user",
  "openclaw:", "git:", "file:", "browser:",
  "http_proxy:response", "dev_server:",
  "mcp:", "engine_status:", "sudo:request", "sudo:result",
  "agents:", "agent:", "ultracontext:",
  "repo:analysis", "wizard:",
  "security:rotate_result", "security:fingerprint_update",
  "e2e:encrypted",
  "relay:machine_online", "auth", "ping", "pong", "error",
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
  }

  connections.delete(ws);
}

function registerConnection(ws: WebSocket, userId: string, role: "machine" | "client") {
  if (role === "machine") {
    const existing = machines.get(userId);
    if (existing) {
      if (isMachineReplacementAbuse(userId)) {
        console.log(`[Relay] Machine replacement abuse detected for ${userId.slice(0, 8)}`);
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

  fetch(req, server) {
    const url = new URL(req.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok" }), {
        headers: { "Content-Type": "application/json" },
      });
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
        const isAllowed = ALLOWED_ORIGINS.some((allowed) =>
          origin === allowed || origin.startsWith(allowed + ":")
        );
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
          const auth = JSON.parse(text) as { action?: string; token?: string; role?: string; machineSecret?: string };

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

          // Verify machine secret for machine role (prevents impersonation)
          if (auth.role === "machine") {
            if (!auth.machineSecret) {
              console.log(`[Relay] Machine auth rejected: no machineSecret (${userId.slice(0, 8)})`);
              ws.close(4003, "Machine secret required");
              return;
            }
            const client = supabaseAdmin || supabase;
            const { data: tokenRow } = await client
              .from("machine_tokens")
              .select("machine_secret")
              .eq("user_id", userId)
              .single();
            const secretsMatch = tokenRow?.machine_secret && auth.machineSecret &&
              tokenRow.machine_secret.length === auth.machineSecret.length &&
              crypto.timingSafeEqual(
                Buffer.from(tokenRow.machine_secret),
                Buffer.from(auth.machineSecret)
              );
            if (!tokenRow || !secretsMatch) {
              console.log(`[Relay] Machine auth rejected: invalid secret (${userId.slice(0, 8)})`);
              ws.close(4003, "Invalid machine credentials");
              return;
            }
          }

          console.log(`[Relay] Auth OK for ${auth.role} ${userId.slice(0, 8)} (${elapsed}ms)`);
          unauthenticatedCount = Math.max(0, unauthenticatedCount - 1);
          registerConnection(ws, userId, auth.role as "machine" | "client");
          ws.send(JSON.stringify({ action: "auth:ok" }));
        } catch {
          console.log(`[Relay] Auth message parse error`);
          ws.close(4001, "Invalid auth message");
        }
        return;
      }

      if (isRateLimited(ws)) return; // Drop excess messages silently

      // Enforce text message size limit (binary frames like video use the WebSocket-level 4MB limit)
      if (typeof message === "string" && message.length > 65536) {
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
