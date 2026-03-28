import { createClient } from "@supabase/supabase-js";

// Bun auto-loads .env files
const SUPABASE_URL = process.env.SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY!;
const PORT = parseInt(process.env.PORT || "8080");

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Connected machines and clients, keyed by userId
const machines = new Map<string, WebSocket>();
const clients = new Map<string, Set<WebSocket>>();

// Reverse lookup: ws -> { userId, role }
const connections = new Map<WebSocket, { userId: string; role: "machine" | "client" }>();

// Rate limiting: track messages per connection per second
const MAX_MESSAGES_PER_SECOND = 120;
const MAX_CLIENTS_PER_USER = 5;
const messageCounts = new Map<WebSocket, { count: number; resetAt: number }>();

function isRateLimited(ws: WebSocket): boolean {
  const now = Date.now();
  let entry = messageCounts.get(ws);
  if (!entry || now >= entry.resetAt) {
    entry = { count: 0, resetAt: now + 1000 };
    messageCounts.set(ws, entry);
  }
  entry.count++;
  return entry.count > MAX_MESSAGES_PER_SECOND;
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
      console.log(`[Relay] Machine disconnected: ${info.userId} (code=${code ?? "?"}, reason=${reason || "none"})`);
    }
  } else {
    const userClients = clients.get(info.userId);
    if (userClients) {
      userClients.delete(ws);
      if (userClients.size === 0) clients.delete(info.userId);
    }
    console.log(`[Relay] Client disconnected: ${info.userId} (code=${code ?? "?"}, reason=${reason || "none"})`);
  }

  connections.delete(ws);
}

function registerConnection(ws: WebSocket, userId: string, role: "machine" | "client") {
  if (role === "machine") {
    const existing = machines.get(userId);
    if (existing) {
      console.log(`[Relay] Replacing existing machine for ${userId}`);
      existing.close(1000, "replaced");
      removeConnection(existing, 1000, "replaced");
    }
    machines.set(userId, ws);
    console.log(`[Relay] Machine connected: ${userId} (machines=${machines.size})`);
  } else {
    if (!clients.has(userId)) {
      clients.set(userId, new Set());
    }
    const userClients = clients.get(userId)!;
    if (userClients.size >= MAX_CLIENTS_PER_USER) {
      console.log(`[Relay] Too many clients for ${userId} (${userClients.size}), rejecting`);
      ws.close(4002, "Too many connections");
      return;
    }
    userClients.add(ws);
    const count = userClients.size;
    const hasMachine = machines.has(userId);
    console.log(`[Relay] Client connected: ${userId} (clients=${count}, machine_online=${hasMachine})`);
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
      return new Response(JSON.stringify({
        status: "ok",
        machines: machines.size,
        clients: [...clients.values()].reduce((sum, s) => sum + s.size, 0),
      }), { headers: { "Content-Type": "application/json" } });
    }

    // WebSocket upgrade — validate token via first message (query param auth removed for security)
    if (url.pathname === "/ws") {
      const upgraded = server.upgrade(req, {
        data: { token: null, role: null },
      });

      if (!upgraded) {
        console.log(`[Relay] WebSocket upgrade failed`);
        return new Response("WebSocket upgrade failed", { status: 500 });
      }

      return undefined;
    }

    return new Response("Tarsy Relay Server", { status: 200 });
  },

  websocket: {
    async open(ws) {
      // Auth via first message only — no query param tokens
      console.log(`[Relay] WS opened, awaiting auth message...`);

      // Close unauthenticated connections after 10 seconds
      setTimeout(() => {
        if (!connections.has(ws)) {
          console.log(`[Relay] Auth timeout — closing unauthenticated connection`);
          ws.close(4001, "Auth timeout");
        }
      }, 10_000);
    },

    async message(ws, message) {
      const info = connections.get(ws);

      // If not yet authenticated, expect first message to be auth payload
      if (!info) {
        try {
          const text = typeof message === "string" ? message : new TextDecoder().decode(message as ArrayBuffer);
          const auth = JSON.parse(text) as { action?: string; token?: string; role?: string };

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

          console.log(`[Relay] Auth OK for ${auth.role} ${userId} (${elapsed}ms)`);
          registerConnection(ws, userId, auth.role as "machine" | "client");
          ws.send(JSON.stringify({ action: "auth:ok" }));
        } catch {
          console.log(`[Relay] Auth message parse error`);
          ws.close(4001, "Invalid auth message");
        }
        return;
      }

      if (isRateLimited(ws)) return; // Drop excess messages silently

      if (info.role === "machine") {
        forwardToClients(info.userId, message as string | Buffer, ws);
      } else {
        forwardToMachine(info.userId, message as string | Buffer, ws);
      }
    },

    close(ws, code, reason) {
      removeConnection(ws, code, reason);
      messageCounts.delete(ws);
    },

    idleTimeout: 120, // seconds — send ping/pong to keep alive
    sendPings: true, // Bun auto-sends WebSocket pings
    maxPayloadLength: 4 * 1024 * 1024, // 4MB max message size
    perMessageDeflate: false, // Keep off for binary H.264 frames
  },
});

console.log(`[Relay] Tarsy Relay Server running on port ${PORT}`);
console.log(`[Relay] Health: http://localhost:${PORT}/health`);
