// Supabase Edge Function: ultracontext-proxy
// Proxies requests to UltraContext API with server-side API key.
// Deploy with: supabase functions deploy ultracontext-proxy

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ULTRACONTEXT_API_KEY = Deno.env.get("ULTRACONTEXT_API_KEY") ?? "";
const ULTRACONTEXT_BASE_URL = "https://api.ultracontext.ai";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function authenticateUser(req: Request): Promise<{ userId: string } | Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "Missing authorization" }), {
      status: 401, headers: { "Content-Type": "application/json" },
    });
  }
  const token = authHeader.replace("Bearer ", "");
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: { user }, error } = await supabase.auth.getUser(token);
  if (error || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401, headers: { "Content-Type": "application/json" },
    });
  }
  return { userId: user.id };
}

/** Validate a context ID is a valid UUID to prevent path traversal in API URLs */
function isValidId(id: unknown): id is string {
  return typeof id === "string" && UUID_REGEX.test(id);
}

// Extract readable text from UltraContext message content.
// CLI-ingested messages store the raw JSONL event as content object.
function extractText(content: any): string {
  if (typeof content === "string") return content;
  if (content?.raw?.message?.content) {
    const inner = content.raw.message.content;
    if (typeof inner === "string") return inner;
    if (Array.isArray(inner)) {
      return inner
        .filter((b: any) => b.type === "text" && b.text)
        .map((b: any) => b.text)
        .join("\n") || "[tool use]";
    }
  }
  return "";
}

/** Fetch all contexts and return only those owned by the given user */
async function fetchUserContexts(userId: string): Promise<any[]> {
  const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts`, {
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
  });
  const raw = await res.json();
  const all = raw?.data ?? raw ?? [];
  return all.filter((ctx: any) => ctx.metadata?.user_id === userId);
}

/** Check if a specific context is owned by the user */
async function isOwnedByUser(contextId: string, userId: string): Promise<boolean> {
  const userContexts = await fetchUserContexts(userId);
  return userContexts.some((ctx: any) => ctx.id === contextId);
}

serve(async (req) => {
  try {
    const authResult = await authenticateUser(req);
    if (authResult instanceof Response) return authResult;
    const { userId } = authResult;

    const payload = await req.json().catch(() => ({}));
    const action = payload.action as string;

    // CREATE
    if (action === "create") {
      const metadata: Record<string, string> = { user_id: userId };
      if (payload.project_path) metadata.project_path = payload.project_path;
      if (payload.engine_type) metadata.source = payload.engine_type;

      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
        body: JSON.stringify({ metadata }),
      });
      const data = await res.json();
      return new Response(JSON.stringify(data), {
        status: res.status, headers: { "Content-Type": "application/json" },
      });
    }

    // LIST
    if (action === "list") {
      const filtered = await fetchUserContexts(userId);

      // Fetch first 2 messages of each context to build title
      const enriched = await Promise.all(
        filtered.map(async (ctx: any) => {
          try {
            const detailRes = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${ctx.id}`, {
              headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
            });
            const detail = await detailRes.json();
            const msgs = detail?.data ?? [];
            const messageCount = msgs.length;

            // Find first real user message for title
            let title = "";
            let hasImage = false;
            for (const msg of msgs) {
              if (msg.role === "user") {
                const text = extractText(msg.content);
                if (!text || text.startsWith("[engine:") || text.startsWith("[session:")) continue;

                // Detect image references
                if (text.match(/\[Image[:\s]|\/var\/folders|\/tmp\/|\.png|\.jpg|\.jpeg|\.heic|\.webp|screenshot/i)) {
                  hasImage = true;
                  const cleanText = text
                    .replace(/\[Image[^\]]*\]/gi, "")
                    .replace(/\/[\w\/\-._]+\.(png|jpg|jpeg|heic|webp)/gi, "")
                    .replace(/source:\s*\S+/gi, "")
                    .trim();
                  if (cleanText.length > 10) {
                    title = cleanText.substring(0, 100);
                  }
                  continue;
                }

                title = text.substring(0, 100);
                break;
              }
            }
            if (!title) {
              if (hasImage) {
                title = "Screenshot analysis";
              } else if (msgs.length > 0) {
                title = extractText(msgs[0].content).substring(0, 100) || "Untitled session";
              }
            }

            return {
              id: ctx.id,
              title: title || "Untitled session",
              has_image: hasImage,
              message_count: messageCount,
              project_path: ctx.metadata?.project_path ?? null,
              engine_type: ctx.metadata?.source ?? null,
              created_at: ctx.created_at,
            };
          } catch {
            return {
              id: ctx.id,
              title: "Session",
              message_count: 0,
              project_path: ctx.metadata?.project_path ?? null,
              engine_type: ctx.metadata?.source ?? null,
              created_at: ctx.created_at,
            };
          }
        }),
      );

      return new Response(JSON.stringify({ data: enriched }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    // GET
    if (action === "get" && payload.id) {
      if (!isValidId(payload.id)) {
        return new Response(JSON.stringify({ error: "Invalid context ID" }), { status: 400, headers: { "Content-Type": "application/json" } });
      }
      if (!(await isOwnedByUser(payload.id, userId))) {
        return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: { "Content-Type": "application/json" } });
      }
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${payload.id}`, {
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
      });
      const raw = await res.json();
      const messages = (raw?.data ?? []).map((msg: any) => ({
        role: msg.role,
        content: extractText(msg.content),
        index: msg.index,
      }));
      return new Response(JSON.stringify({
        id: payload.id,
        messages,
        version: raw?.version ?? 0,
      }), { status: res.status, headers: { "Content-Type": "application/json" } });
    }

    // MESSAGE
    if (action === "message" && payload.id) {
      if (!isValidId(payload.id)) {
        return new Response(JSON.stringify({ error: "Invalid context ID" }), { status: 400, headers: { "Content-Type": "application/json" } });
      }
      if (!(await isOwnedByUser(payload.id, userId))) {
        return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: { "Content-Type": "application/json" } });
      }
      const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${payload.id}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
        body: JSON.stringify({ role: payload.role, content: payload.content }),
      });
      const data = await res.text();
      return new Response(data, { status: res.status, headers: { "Content-Type": "application/json" } });
    }

    // DELETE — verify ownership of each context before deletion
    if (action === "delete" && payload.ids) {
      const contextIds = (Array.isArray(payload.ids) ? payload.ids : [payload.ids]).filter(isValidId);
      if (contextIds.length === 0) {
        return new Response(JSON.stringify({ error: "No valid context IDs provided" }), {
          status: 400, headers: { "Content-Type": "application/json" },
        });
      }

      // Verify ownership of all contexts before deleting any
      const userContexts = await fetchUserContexts(userId);
      const ownedIds = new Set(userContexts.map((ctx: any) => ctx.id));
      const unauthorizedIds = contextIds.filter((id: string) => !ownedIds.has(id));
      if (unauthorizedIds.length > 0) {
        return new Response(JSON.stringify({ error: "Forbidden: not all contexts belong to you" }), {
          status: 403, headers: { "Content-Type": "application/json" },
        });
      }

      // Try batch-delete first
      const batchRes = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/batch-delete`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
        body: JSON.stringify({ ids: contextIds }),
      });

      if (batchRes.ok) {
        const data = await batchRes.json();
        return new Response(JSON.stringify(data), {
          status: 200, headers: { "Content-Type": "application/json" },
        });
      }

      // Fallback: delete each context individually
      const results = await Promise.all(
        contextIds.map(async (ctxId: string) => {
          try {
            const res = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${ctxId}`, {
              method: "DELETE",
              headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
            });
            if (res.ok) return { id: ctxId, deleted: true };
            // Final fallback: delete all messages individually
            const getRes = await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${ctxId}`, {
              headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
            });
            const detail = await getRes.json();
            const msgs = detail?.data ?? [];
            if (msgs.length > 0) {
              const msgIds = msgs.map((m: any) => m.id).filter(Boolean);
              if (msgIds.length > 0) {
                await fetch(`${ULTRACONTEXT_BASE_URL}/contexts/${ctxId}`, {
                  method: "DELETE",
                  headers: { "Content-Type": "application/json", Authorization: `Bearer ${ULTRACONTEXT_API_KEY}` },
                  body: JSON.stringify({ ids: msgIds }),
                });
              }
            }
            return { id: ctxId, deleted: true };
          } catch {
            return { id: ctxId, deleted: false };
          }
        }),
      );

      return new Response(JSON.stringify({ results }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ error: "Invalid action" }), {
      status: 400, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[ultracontext-proxy] Error:", err);
    return new Response(JSON.stringify({ error: "Proxy request failed" }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
