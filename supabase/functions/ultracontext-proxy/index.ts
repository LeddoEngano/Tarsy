// Supabase Edge Function: ultracontext-proxy
// Proxies requests to UltraContext API with server-side API key.
// The UltraContext API key never leaves the server.
// User contexts are tagged with user_id for isolation.
//
// Required secrets (set via Supabase dashboard):
//   ULTRACONTEXT_API_KEY - UltraContext API key
//
// Deploy with: supabase functions deploy ultracontext-proxy --no-verify-jwt
//
// All requests are POST with JSON body containing "action" field:
//   { "action": "create" }
//   { "action": "list" }
//   { "action": "get", "id": "ctx_..." }
//   { "action": "message", "id": "ctx_...", "role": "user", "content": "..." }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ULTRACONTEXT_API_KEY = Deno.env.get("ULTRACONTEXT_API_KEY") ?? "";
const ULTRACONTEXT_BASE_URL = "https://api.ultracontext.ai";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

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

console.log("[ultracontext-proxy] Function loaded, API key present:", !!ULTRACONTEXT_API_KEY);

serve(async (req) => {
  try {
    console.log("[ultracontext-proxy] Request received:", req.method, req.url);

    // Auth
    const authResult = await authenticateUser(req);
    if (authResult instanceof Response) return authResult;
    const { userId } = authResult;

    const payload = await req.json().catch(() => ({}));
    const action = payload.action as string;
    console.log("[ultracontext-proxy] Action:", action, "userId:", userId);

    // CREATE
    if (action === "create") {
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${ULTRACONTEXT_API_KEY}`,
        },
        body: JSON.stringify({ metadata: { user_id: userId } }),
      });
      const data = await res.json();
      if (data?.id) contextOwners.set(data.id, userId);
      return new Response(JSON.stringify(data), {
        status: res.status,
        headers: { "Content-Type": "application/json" },
      });
    }

    // LIST
    if (action === "list") {
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts`, {
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${ULTRACONTEXT_API_KEY}`,
        },
      });
      const raw = await res.json();
      const all = raw?.data ?? raw ?? [];
      const filtered = all.filter((ctx: any) => {
        if (contextOwners.get(ctx.id) === userId) return true;
        if (ctx.metadata?.user_id === userId) return true;
        return false;
      });
      return new Response(JSON.stringify({ data: filtered }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // GET
    if (action === "get" && payload.id) {
      const owner = contextOwners.get(payload.id);
      if (owner && owner !== userId) {
        return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: { "Content-Type": "application/json" } });
      }
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${payload.id}`, {
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
      });
      const data = await res.text();
      return new Response(data, { status: res.status, headers: { "Content-Type": "application/json" } });
    }

    // MESSAGE
    if (action === "message" && payload.id) {
      console.log("[ultracontext-proxy] Message to context:", payload.id, "role:", payload.role);
      const owner = contextOwners.get(payload.id);
      if (owner && owner !== userId) {
        return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: { "Content-Type": "application/json" } });
      }
      try {
        const fetchUrl = `${ULTRACONTEXT_BASE_URL}/contexts/${payload.id}`;
        console.log("[ultracontext-proxy] Fetching:", fetchUrl);
        const res = await fetch(fetchUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
          body: JSON.stringify({ role: payload.role, content: payload.content }),
        });
        const data = await res.text();
        console.log("[ultracontext-proxy] UltraContext response:", res.status, data.substring(0, 200));
        return new Response(data, { status: res.status, headers: { "Content-Type": "application/json" } });
      } catch (fetchErr) {
        console.error("[ultracontext-proxy] Fetch error:", fetchErr);
        return new Response(JSON.stringify({ error: String(fetchErr) }), { status: 502, headers: { "Content-Type": "application/json" } });
      }
    }

    return new Response(JSON.stringify({ error: "Invalid action" }), {
      status: 400,
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
