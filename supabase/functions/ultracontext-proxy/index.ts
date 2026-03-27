// Supabase Edge Function: ultracontext-proxy
// Proxies requests to UltraContext API with server-side API key.
// The UltraContext API key never leaves the server.
// User contexts are tagged with user_id for isolation.
//
// Required secrets (set via Supabase dashboard):
//   ULTRACONTEXT_API_KEY - UltraContext API key

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ULTRACONTEXT_API_KEY = Deno.env.get("ULTRACONTEXT_API_KEY")!;
const ULTRACONTEXT_BASE_URL = "https://api.ultracontext.ai";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// In-memory mapping: contextId -> userId (for access control)
// For production, store this in a Supabase table instead.
const contextOwners = new Map<string, string>();

async function authenticateUser(req: Request): Promise<{ userId: string } | Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "Missing authorization" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const token = authHeader.replace("Bearer ", "");
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: { user }, error } = await supabase.auth.getUser(token);

  if (error || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  return { userId: user.id };
}

async function proxyToUltraContext(
  path: string,
  method: string,
  body?: string,
): Promise<Response> {
  const res = await fetch(`${ULTRACONTEXT_BASE_URL}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${ULTRACONTEXT_API_KEY}`,
    },
    body: body || undefined,
  });

  const data = await res.text();
  return new Response(data, {
    status: res.status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  try {
    const url = new URL(req.url);
    const method = req.method;

    // Auth
    const authResult = await authenticateUser(req);
    if (authResult instanceof Response) return authResult;
    const { userId } = authResult;

    // Route: POST /contexts — create a new context
    if (url.pathname === "/ultracontext-proxy/contexts" && method === "POST") {
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${ULTRACONTEXT_API_KEY}`,
        },
        body: JSON.stringify({ metadata: { user_id: userId } }),
      });

      const data = await res.json();
      // Track ownership
      if (data?.id) {
        contextOwners.set(data.id, userId);
      }

      return new Response(JSON.stringify(data), {
        status: res.status,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Route: GET /contexts — list contexts (filtered by user)
    if (url.pathname === "/ultracontext-proxy/contexts" && method === "GET") {
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts`, {
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${ULTRACONTEXT_API_KEY}`,
        },
      });

      const raw = await res.json();
      const allContexts = raw?.data ?? raw ?? [];

      // Filter to only this user's contexts
      const userContexts = allContexts.filter((ctx: any) => {
        // Check in-memory map
        if (contextOwners.get(ctx.id) === userId) return true;
        // Check metadata tag
        if (ctx.metadata?.user_id === userId) return true;
        return false;
      });

      return new Response(JSON.stringify({ data: userContexts }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Route: GET /contexts/:id — get a single context
    const getContextMatch = url.pathname.match(
      /^\/ultracontext-proxy\/contexts\/([^/]+)$/,
    );
    if (getContextMatch && method === "GET") {
      const contextId = getContextMatch[1];

      // Ownership check
      const owner = contextOwners.get(contextId);
      if (owner && owner !== userId) {
        return new Response(JSON.stringify({ error: "Forbidden" }), {
          status: 403,
          headers: { "Content-Type": "application/json" },
        });
      }

      return await proxyToUltraContext(`/contexts/${contextId}`, "GET");
    }

    // Route: POST /contexts/:id/messages — append message
    const messagesMatch = url.pathname.match(
      /^\/ultracontext-proxy\/contexts\/([^/]+)\/messages$/,
    );
    if (messagesMatch && method === "POST") {
      const contextId = messagesMatch[1];

      // Ownership check
      const owner = contextOwners.get(contextId);
      if (owner && owner !== userId) {
        return new Response(JSON.stringify({ error: "Forbidden" }), {
          status: 403,
          headers: { "Content-Type": "application/json" },
        });
      }

      const body = await req.text();
      return await proxyToUltraContext(
        `/contexts/${contextId}/messages`,
        "POST",
        body,
      );
    }

    return new Response(JSON.stringify({ error: "Not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[ultracontext-proxy] Error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
