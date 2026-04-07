// Supabase Edge Function: claim-machine
// Called from iOS app to claim a machine via QR code pairing token or manual connection code.
// Validates the token/code, transfers machine ownership to the calling user.
//
// Uses service role to bypass RLS (iOS user doesn't own the machine yet).

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  try {
    // Verify caller's JWT
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), { status: 401 });
    }
    const token = authHeader.replace("Bearer ", "");

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const body = await req.json();
    const { machine_id, pairing_token, connection_code } = body;

    if (!machine_id && !connection_code) {
      return new Response(
        JSON.stringify({ error: "machine_id with pairing_token, or connection_code is required" }),
        { status: 400 }
      );
    }

    let pairing;

    if (connection_code) {
      // Manual code entry: look up by connection_code
      const code = connection_code.replace(/-/g, "").toUpperCase();
      const { data, error } = await supabase
        .from("machine_pairings")
        .select("*")
        .eq("connection_code", code)
        .gt("expires_at", new Date().toISOString())
        .limit(1)
        .single();

      if (error || !data) {
        return new Response(
          JSON.stringify({ error: "Invalid or expired connection code" }),
          { status: 400 }
        );
      }
      pairing = data;
    } else {
      // QR code: look up by machine_id + pairing_token
      if (!pairing_token) {
        return new Response(
          JSON.stringify({ error: "pairing_token is required with machine_id" }),
          { status: 400 }
        );
      }

      const { data, error } = await supabase
        .from("machine_pairings")
        .select("*")
        .eq("machine_id", machine_id)
        .eq("pairing_token", pairing_token)
        .gt("expires_at", new Date().toISOString())
        .limit(1)
        .single();

      if (error || !data) {
        return new Response(
          JSON.stringify({ error: "Invalid or expired pairing code" }),
          { status: 400 }
        );
      }
      pairing = data;
    }

    const targetMachineId = pairing.machine_id;

    // Transfer machine ownership to the iOS user
    const { error: updateError } = await supabase
      .from("machines")
      .update({ user_id: user.id })
      .eq("id", targetMachineId);

    if (updateError) {
      console.error(`Failed to claim machine ${targetMachineId}:`, updateError);
      return new Response(
        JSON.stringify({ error: "Failed to claim machine" }),
        { status: 500 }
      );
    }

    // Delete all pairing tokens for this machine (consumed)
    await supabase
      .from("machine_pairings")
      .delete()
      .eq("machine_id", targetMachineId);

    // Fetch updated machine details to return
    const { data: machine } = await supabase
      .from("machines")
      .select("id, hostname, status, local_ip, model_identifier, display_name, last_seen_at")
      .eq("id", targetMachineId)
      .single();

    console.log(`Machine ${targetMachineId} claimed by user ${user.id} (${user.email})`);

    return new Response(
      JSON.stringify({ success: true, machine }),
      { status: 200 }
    );
  } catch (err) {
    console.error("claim-machine error:", err);
    return new Response(
      JSON.stringify({ error: "Failed to claim machine" }),
      { status: 500 }
    );
  }
});
