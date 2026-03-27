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
    clients.get(userId)!.add(ws);
    const count = clients.get(userId)!.size;
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

    // WebSocket upgrade — upgrade FIRST, validate token AFTER
    // This prevents Fly.io proxy timeout during Supabase API call
    if (url.pathname === "/ws") {
      const token = url.searchParams.get("token");
      const role = url.searchParams.get("role") as "machine" | "client";

      if (!token || !role || !["machine", "client"].includes(role)) {
        console.log(`[Relay] Rejected: missing token or invalid role="${role}"`);
        return new Response("Missing token or role", { status: 400 });
      }

      const upgraded = server.upgrade(req, {
        data: { token, role },
      });

      if (!upgraded) {
        console.log(`[Relay] WebSocket upgrade failed for role=${role}`);
        return new Response("WebSocket upgrade failed", { status: 500 });
      }

      return undefined;
    }

    return new Response("Tarsy Relay Server", { status: 200 });
  },

  websocket: {
    async open(ws) {
      const { token, role } = ws.data as { token: string; role: "machine" | "client" };
      console.log(`[Relay] WS opened, validating ${role} token...`);

      const start = Date.now();
      const { userId, error } = await validateToken(token);
      const elapsed = Date.now() - start;

      if (!userId) {
        console.log(`[Relay] Auth failed for ${role}: ${error} (${elapsed}ms)`);
        ws.close(4001, "Invalid token");
        return;
      }

      console.log(`[Relay] Auth OK for ${role} ${userId} (${elapsed}ms)`);
      registerConnection(ws, userId, role);
    },

    message(ws, message) {
      const info = connections.get(ws);
      if (!info) return; // Not yet authenticated, ignore

      if (info.role === "machine") {
        forwardToClients(info.userId, message as string | Buffer, ws);
      } else {
        forwardToMachine(info.userId, message as string | Buffer, ws);
      }
    },

    close(ws, code, reason) {
      removeConnection(ws, code, reason);
    },

    idleTimeout: 120, // seconds — send ping/pong to keep alive
    sendPings: true, // Bun auto-sends WebSocket pings
    maxPayloadLength: 4 * 1024 * 1024, // 4MB max message size
    perMessageDeflate: false, // Keep off for binary MJPEG frames
  },
});

console.log(`[Relay] Tarsy Relay Server running on port ${PORT}`);
console.log(`[Relay] Health: http://localhost:${PORT}/health`);
