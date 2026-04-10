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

    // Pairings are stored as HMAC(pepper, token). Use the service-role RPC
    // which computes the HMAC server-side and returns the matching row id
    // (or null if no match / expired).
    let targetMachineId: string | null = null;

    if (connection_code) {
      const { data: pairingId, error } = await supabase
        .rpc("claim_pairing_by_code", { p_code: connection_code });
      if (error || !pairingId) {
        return new Response(
          JSON.stringify({ error: "Invalid or expired connection code" }),
          { status: 400 }
        );
      }
      // claim_pairing_by_code returns machine_pairings.id, but we need the
      // machine_id to transfer ownership. Fetch it.
      const { data: row } = await supabase
        .from("machine_pairings")
        .select("machine_id")
        .eq("id", pairingId)
        .single();
      targetMachineId = row?.machine_id ?? null;
    } else {
      if (!pairing_token) {
        return new Response(
          JSON.stringify({ error: "pairing_token is required with machine_id" }),
          { status: 400 }
        );
      }
      const { data: pairingId, error } = await supabase
        .rpc("claim_pairing_by_token", {
          p_machine_id: machine_id,
          p_token: pairing_token,
        });
      if (error || !pairingId) {
        return new Response(
          JSON.stringify({ error: "Invalid or expired pairing code" }),
          { status: 400 }
        );
      }
      // The RPC already confirmed machine_id matches, so we can reuse it.
      targetMachineId = machine_id;
    }

    if (!targetMachineId) {
      return new Response(
        JSON.stringify({ error: "Invalid or expired pairing code" }),
        { status: 400 }
      );
    }

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
      .select("*")
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
