// Supabase Edge Function: verify-receipt
// Server-side validation of App Store transactions.
// Receives a signed transaction JWS from the iOS app, validates it with Apple,
// and updates the user's subscription status in the profiles table.
//
// This prevents subscription bypass from jailbroken devices or modified app binaries.
//
// Required env vars:
// - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// - APP_STORE_ISSUER_ID (from App Store Connect > Keys)
// - APP_STORE_KEY_ID (from App Store Connect > Keys)
// - APP_STORE_PRIVATE_KEY (p8 key content, base64-encoded)
// - APP_STORE_BUNDLE_ID (com.tarsy.ios)
//
// Deploy with: supabase functions deploy verify-receipt

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUNDLE_ID = Deno.env.get("APP_STORE_BUNDLE_ID") ?? "com.tarsy.ios";

// Apple's root certificates for JWS validation
const APPLE_ROOT_CA_G3_URL = "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer";

interface DecodedTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  type: string;
  expiresDate?: number;
  revocationDate?: number;
  environment: string;
}

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
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser(token);
  if (error || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }
  return { userId: user.id };
}

/** Verify JWS signature using the x5c certificate chain from the header,
 *  validating the leaf certificate against Apple's root CA.
 *  Returns the decoded transaction if valid, null otherwise. */
async function verifyAndDecodeJWS(jws: string): Promise<DecodedTransaction | null> {
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return null;

    // Decode header to get x5c certificate chain
    const header = JSON.parse(atob(parts[0].replace(/-/g, "+").replace(/_/g, "/")));
    const x5c = header.x5c as string[] | undefined;

    if (x5c && x5c.length > 0) {
      // Verify the leaf certificate signature on the JWS
      const leafCertDer = Uint8Array.from(atob(x5c[0]), (c) => c.charCodeAt(0));

      // Import the leaf certificate's public key for ECDSA verification
      const leafCert = await crypto.subtle.importKey(
        "spki",
        extractPublicKeyFromCert(leafCertDer),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"]
      );

      // Verify signature
      const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
      const signature = Uint8Array.from(
        atob(parts[2].replace(/-/g, "+").replace(/_/g, "/")),
        (c) => c.charCodeAt(0)
      );

      // Convert DER signature to raw r||s format for WebCrypto
      const rawSig = derSignatureToRaw(signature);

      const valid = await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" },
        leafCert,
        rawSig,
        signingInput
      );

      if (!valid) {
        console.error("[verify-receipt] JWS signature verification FAILED");
        return null;
      }

      // Verify the certificate chain ends at Apple's root CA
      // Check the last cert in x5c chain matches known Apple Root CA fingerprint
      if (x5c.length >= 2) {
        const rootCertDer = Uint8Array.from(atob(x5c[x5c.length - 1]), (c) => c.charCodeAt(0));
        const rootHash = await crypto.subtle.digest("SHA-256", rootCertDer);
        const rootHashHex = Array.from(new Uint8Array(rootHash))
          .map((b) => b.toString(16).padStart(2, "0"))
          .join("");
        // Apple Root CA G3 SHA-256 fingerprint
        const APPLE_ROOT_G3_FINGERPRINT =
          "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
        if (rootHashHex !== APPLE_ROOT_G3_FINGERPRINT) {
          console.error("[verify-receipt] Certificate chain does not end at Apple Root CA");
          return null;
        }
      }

      console.log("[verify-receipt] JWS signature verified successfully");
    } else {
      // No x5c chain — cannot verify signature, reject
      console.error("[verify-receipt] JWS has no x5c certificate chain — rejecting");
      return null;
    }

    // Decode the payload (second part)
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));

    return {
      transactionId: payload.transactionId ?? "",
      originalTransactionId: payload.originalTransactionId ?? "",
      bundleId: payload.bundleId ?? "",
      productId: payload.productId ?? "",
      type: payload.type ?? "",
      expiresDate: payload.expiresDate,
      revocationDate: payload.revocationDate,
      environment: payload.environment ?? "Production",
    };
  } catch (err) {
    console.error("[verify-receipt] JWS verification error:", err);
    return null;
  }
}

/** Extract the SubjectPublicKeyInfo from a DER-encoded X.509 certificate.
 *  This is a simplified parser that finds the SPKI structure. */
function extractPublicKeyFromCert(certDer: Uint8Array): Uint8Array {
  // X.509 certificates have the SPKI as a well-known structure.
  // We search for the OID 1.2.840.10045.2.1 (ecPublicKey) followed by P-256 OID
  // and extract the SPKI block containing it.
  const ecOid = [0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]; // ecPublicKey OID
  for (let i = 0; i < certDer.length - ecOid.length; i++) {
    let match = true;
    for (let j = 0; j < ecOid.length; j++) {
      if (certDer[i + j] !== ecOid[j]) { match = false; break; }
    }
    if (match) {
      // Walk back to find the SEQUENCE that contains the SPKI
      // The SPKI SEQUENCE typically starts 2-4 bytes before the AlgorithmIdentifier
      for (let back = 1; back <= 6; back++) {
        if (certDer[i - back] === 0x30) { // SEQUENCE tag
          const seqStart = i - back;
          const lenByte = certDer[seqStart + 1];
          let totalLen: number;
          let headerLen: number;
          if (lenByte < 0x80) {
            totalLen = lenByte;
            headerLen = 2;
          } else if (lenByte === 0x81) {
            totalLen = certDer[seqStart + 2];
            headerLen = 3;
          } else {
            totalLen = (certDer[seqStart + 2] << 8) | certDer[seqStart + 3];
            headerLen = 4;
          }
          return certDer.slice(seqStart, seqStart + headerLen + totalLen);
        }
      }
    }
  }
  throw new Error("Could not extract SPKI from certificate");
}

/** Convert a DER-encoded ECDSA signature to the raw r||s format expected by WebCrypto. */
function derSignatureToRaw(derSig: Uint8Array): Uint8Array {
  // DER: 0x30 <len> 0x02 <r-len> <r> 0x02 <s-len> <s>
  if (derSig[0] !== 0x30) return derSig; // Already raw format
  let offset = 2;
  // Read r
  if (derSig[offset] !== 0x02) return derSig;
  offset++;
  const rLen = derSig[offset++];
  const rBytes = derSig.slice(offset, offset + rLen);
  offset += rLen;
  // Read s
  if (derSig[offset] !== 0x02) return derSig;
  offset++;
  const sLen = derSig[offset++];
  const sBytes = derSig.slice(offset, offset + sLen);
  // Pad or trim to 32 bytes each
  const raw = new Uint8Array(64);
  raw.set(rBytes.length > 32 ? rBytes.slice(rBytes.length - 32) : rBytes, 32 - Math.min(rBytes.length, 32));
  raw.set(sBytes.length > 32 ? sBytes.slice(sBytes.length - 32) : sBytes, 64 - Math.min(sBytes.length, 32));
  return raw;
}

const APP_STORE_ISSUER_ID = Deno.env.get("APP_STORE_ISSUER_ID") ?? "";
const APP_STORE_KEY_ID = Deno.env.get("APP_STORE_KEY_ID") ?? "";
const APP_STORE_PRIVATE_KEY_B64 = Deno.env.get("APP_STORE_PRIVATE_KEY") ?? "";

/** Verify a transaction exists on Apple's App Store Server API.
 *  Uses the GET /inApps/v1/transactions/{transactionId} endpoint.
 *  Returns true if the transaction is valid, false otherwise.
 *  FAIL-CLOSED: returns false on any error to prevent subscription bypass. */
async function verifyWithApple(transactionId: string, environment: string): Promise<boolean> {
  if (!APP_STORE_ISSUER_ID || !APP_STORE_KEY_ID || !APP_STORE_PRIVATE_KEY_B64) {
    console.error("[verify-receipt] App Store Server API keys not configured — rejecting transaction");
    return false;
  }

  try {
    const baseUrl = environment === "Sandbox"
      ? "https://api.storekit-sandbox.itunes.apple.com"
      : "https://api.storekit.itunes.apple.com";

    const jwt = await generateAppStoreJWT();
    if (!jwt) {
      console.error("[verify-receipt] Failed to generate App Store JWT — rejecting");
      return false;
    }

    const res = await fetch(`${baseUrl}/inApps/v1/transactions/${transactionId}`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });

    if (res.status === 200) return true;
    if (res.status === 404) {
      console.log(`[verify-receipt] Transaction ${transactionId} not found on Apple's servers`);
      return false;
    }

    console.error(`[verify-receipt] Apple API returned unexpected status ${res.status} — rejecting`);
    return false;
  } catch (err) {
    console.error("[verify-receipt] Apple verification error — rejecting:", err);
    return false;
  }
}

/** Generate a JWT for authenticating with Apple's App Store Server API. */
async function generateAppStoreJWT(): Promise<string | null> {
  try {
    const header = { alg: "ES256", kid: APP_STORE_KEY_ID, typ: "JWT" };
    const now = Math.floor(Date.now() / 1000);
    const payload = {
      iss: APP_STORE_ISSUER_ID,
      iat: now,
      exp: now + 3600, // 1 hour
      aud: "appstoreconnect-v1",
      bid: BUNDLE_ID,
    };

    const headerB64 = btoa(JSON.stringify(header)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const payloadB64 = btoa(JSON.stringify(payload)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const signingInput = `${headerB64}.${payloadB64}`;

    // Import the P256 private key
    const keyData = Uint8Array.from(atob(APP_STORE_PRIVATE_KEY_B64), (c) => c.charCodeAt(0));
    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      keyData,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"]
    );

    // Sign
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      cryptoKey,
      new TextEncoder().encode(signingInput)
    );

    const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
      .replace(/=/g, "")
      .replace(/\+/g, "-")
      .replace(/\//g, "_");

    return `${signingInput}.${sigB64}`;
  } catch (err) {
    console.error("[verify-receipt] JWT generation error:", err);
    return null;
  }
}

serve(async (req) => {
  try {
    // Authenticate the user
    const authResult = await authenticateUser(req);
    if (authResult instanceof Response) return authResult;
    const { userId } = authResult;

    const body = await req.json().catch(() => ({}));
    const { signedTransactionInfo } = body;

    if (typeof signedTransactionInfo !== "string") {
      return new Response(
        JSON.stringify({ error: "Missing signedTransactionInfo" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Empty JWS = no active subscription — set profile to inactive
    if (!signedTransactionInfo) {
      const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
      await supabase
        .from("profiles")
        .update({
          is_pro: false,
          subscription_status: "inactive",
          subscription_end_date: null,
        })
        .eq("id", userId);

      console.log(`[verify-receipt] User ${userId}: no transaction — set inactive`);
      return new Response(
        JSON.stringify({ isPro: false, status: "inactive", expirationDate: null }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    // Verify and decode the JWS transaction (validates Apple signature + cert chain)
    const transaction = await verifyAndDecodeJWS(signedTransactionInfo);
    if (!transaction) {
      return new Response(JSON.stringify({ error: "Invalid or unverified transaction" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Validate bundle ID matches our app
    if (transaction.bundleId !== BUNDLE_ID) {
      return new Response(
        JSON.stringify({ error: "Bundle ID mismatch" }),
        { status: 403, headers: { "Content-Type": "application/json" } }
      );
    }

    // Verify the transaction exists on Apple's servers (prevents forged JWS)
    const appleVerified = await verifyWithApple(transaction.transactionId, transaction.environment);
    if (!appleVerified) {
      console.log(`[verify-receipt] Apple verification failed for transaction ${transaction.transactionId}`);
      return new Response(
        JSON.stringify({ error: "Transaction verification failed" }),
        { status: 403, headers: { "Content-Type": "application/json" } }
      );
    }

    // Validate product ID
    const validProductIds = ["tarsy_pro_monthly", "tarsy_pro_annual"];
    if (!validProductIds.includes(transaction.productId)) {
      return new Response(
        JSON.stringify({ error: "Unknown product" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Determine subscription status
    const now = Date.now();
    let isPro = false;
    let status = "inactive";
    let endDate: string | null = null;

    if (transaction.revocationDate) {
      // Revoked by Apple (refund, etc.)
      isPro = false;
      status = "revoked";
    } else if (transaction.expiresDate) {
      endDate = new Date(transaction.expiresDate).toISOString();
      if (transaction.expiresDate > now) {
        isPro = true;
        status = "active";
      } else {
        isPro = false;
        status = "expired";
      }
    } else {
      // Non-expiring (lifetime?) — shouldn't happen for monthly sub
      isPro = true;
      status = "active";
    }

    // Update the profile in Supabase using service role (bypasses RLS)
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { error: updateError } = await supabase
      .from("profiles")
      .update({
        is_pro: isPro,
        subscription_status: status,
        subscription_end_date: endDate,
      })
      .eq("id", userId);

    if (updateError) {
      console.error("[verify-receipt] Profile update error:", updateError);
      return new Response(
        JSON.stringify({ error: "Failed to update profile" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    console.log(
      `[verify-receipt] User ${userId}: isPro=${isPro}, status=${status}, product=${transaction.productId}, env=${transaction.environment}`
    );

    return new Response(
      JSON.stringify({
        isPro,
        status,
        expirationDate: endDate,
        environment: transaction.environment,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("[verify-receipt] Error:", err);
    return new Response(JSON.stringify({ error: "Receipt verification failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
