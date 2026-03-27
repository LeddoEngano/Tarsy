// Supabase Edge Function: delete-account
// Deletes all user data and the auth account.
// All user-owned tables cascade on auth.users deletion, so we only need to delete the auth user.
//
// Called from the iOS/macOS app with the user's JWT.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
    }
    const token = authHeader.replace("Bearer ", "");

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Verify the user's JWT
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    console.log(`Deleting account for user ${user.id} (${user.email})`);

    // Delete the auth user — all tables with ON DELETE CASCADE will be cleaned up automatically
    const { error: deleteError } = await supabase.auth.admin.deleteUser(user.id);
    if (deleteError) {
      console.error(`Failed to delete user ${user.id}:`, deleteError);
      return new Response(JSON.stringify({ error: "Failed to delete account" }), { status: 500 });
    }

    console.log(`Account deleted successfully: ${user.id}`);
    return new Response(JSON.stringify({ success: true }), { status: 200 });
  } catch (err) {
    console.error("delete-account error:", err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
