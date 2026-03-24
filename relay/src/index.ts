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

async function validateToken(token: string): Promise<string | null> {
  try {
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data.user) return null;
    return data.user.id;
  } catch {
    return null;
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

function removeConnection(ws: WebSocket) {
  const info = connections.get(ws);
  if (!info) return;

  if (info.role === "machine") {
    if (machines.get(info.userId) === ws) {
      machines.delete(info.userId);
      console.log(`[Relay] Machine disconnected: ${info.userId}`);
    }
  } else {
    const userClients = clients.get(info.userId);
    if (userClients) {
      userClients.delete(ws);
      if (userClients.size === 0) clients.delete(info.userId);
    }
    console.log(`[Relay] Client disconnected: ${info.userId}`);
  }

  connections.delete(ws);
}

const server = Bun.serve({
  port: PORT,

  async fetch(req, server) {
    const url = new URL(req.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({
        status: "ok",
        machines: machines.size,
        clients: [...clients.values()].reduce((sum, s) => sum + s.size, 0),
      }), { headers: { "Content-Type": "application/json" } });
    }

    // WebSocket upgrade
    if (url.pathname === "/ws") {
      const token = url.searchParams.get("token");
      const role = url.searchParams.get("role") as "machine" | "client";

      if (!token || !role || !["machine", "client"].includes(role)) {
        return new Response("Missing token or role", { status: 400 });
      }

      const userId = await validateToken(token);
      if (!userId) {
        return new Response("Invalid token", { status: 401 });
      }

      const upgraded = server.upgrade(req, {
        data: { userId, role },
      });

      if (!upgraded) {
        return new Response("WebSocket upgrade failed", { status: 500 });
      }

      return undefined;
    }

    return new Response("Tarsy Relay Server", { status: 200 });
  },

  websocket: {
    open(ws) {
      const { userId, role } = ws.data as { userId: string; role: "machine" | "client" };

      if (role === "machine") {
        // Close existing machine connection if any
        const existing = machines.get(userId);
        if (existing) {
          existing.close(1000, "replaced");
          removeConnection(existing);
        }
        machines.set(userId, ws);
        console.log(`[Relay] Machine connected: ${userId}`);
      } else {
        if (!clients.has(userId)) {
          clients.set(userId, new Set());
        }
        clients.get(userId)!.add(ws);
        console.log(`[Relay] Client connected: ${userId}`);
      }

      connections.set(ws, { userId, role });

      // Notify the other side about connection
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
    },

    message(ws, message) {
      const info = connections.get(ws);
      if (!info) return;

      if (info.role === "machine") {
        // Machine -> forward to all clients of this user
        forwardToClients(info.userId, message as string | Buffer, ws);
      } else {
        // Client -> forward to machine of this user
        forwardToMachine(info.userId, message as string | Buffer, ws);
      }
    },

    close(ws) {
      removeConnection(ws);
    },

    perMessageDeflate: false, // Keep off for binary MJPEG frames
  },
});

console.log(`[Relay] Tarsy Relay Server running on port ${PORT}`);
console.log(`[Relay] Health: http://localhost:${PORT}/health`);
