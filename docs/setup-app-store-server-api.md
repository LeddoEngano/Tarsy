# Setup: App Store Server API for Receipt Validation

The `verify-receipt` edge function validates subscription transactions with Apple's servers.
This prevents subscription bypass from jailbroken devices or modified app binaries.

## Step 1: Create an API Key in App Store Connect

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Navigate to **Users and Access** > **Integrations** > **In-App Purchase**
3. Click **Generate In-App Purchase Key**
4. Give it a name (e.g., "Tarsy Receipt Validation")
5. Download the `.p8` file — **save it securely, you can only download it once**
6. Note the **Key ID** shown next to the key (e.g., `ABC123DEFG`)
7. Note the **Issuer ID** shown at the top of the page (e.g., `12345678-1234-1234-1234-123456789012`)

## Step 2: Encode the Private Key

The `.p8` file needs to be base64-encoded for storage as an environment variable.

```bash
# Strip the header/footer lines and base64-encode the raw key
grep -v "^-----" AuthKey_ABC123DEFG.p8 | tr -d '\n' | base64
```

This gives you a single base64 string (the `APP_STORE_PRIVATE_KEY` value).

Alternatively, encode the entire file content:
```bash
cat AuthKey_ABC123DEFG.p8 | base64
```

**Note:** The edge function expects the PKCS8 DER key in base64. The `grep -v` approach strips the PEM headers, giving you just the raw key bytes in base64 — which is what `crypto.subtle.importKey("pkcs8", ...)` needs.

## Step 3: Set Supabase Secrets

```bash
cd /path/to/Tarsy

supabase secrets set \
  APP_STORE_ISSUER_ID="12345678-1234-1234-1234-123456789012" \
  APP_STORE_KEY_ID="ABC123DEFG" \
  APP_STORE_PRIVATE_KEY="BASE64_ENCODED_KEY_HERE" \
  APP_STORE_BUNDLE_ID="com.tarsy.ios"
```

Replace the placeholder values with your actual credentials from Step 1 and 2.

## Step 4: Verify the Setup

Test the edge function with a sandbox transaction:

```bash
# Get a valid auth token first
TOKEN=$(supabase auth token)

# Call verify-receipt with an empty transaction (should return inactive)
curl -X POST \
  https://xtblbghhlkroskzljqcl.supabase.co/functions/v1/verify-receipt \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"signedTransactionInfo": ""}'
```

Expected response:
```json
{"isPro": false, "status": "inactive", "expirationDate": null}
```

## How It Works

1. **iOS app** makes a purchase via StoreKit 2
2. **iOS app** gets the `jwsRepresentation` from the `VerificationResult`
3. **iOS app** sends it to `verify-receipt` edge function
4. **Edge function** decodes the JWS, validates `bundleId` and `productId`
5. **Edge function** calls Apple's App Store Server API to confirm the transaction exists
6. **Edge function** updates the `profiles` table with the subscription status (using service role, bypassing RLS)
7. **RLS policy** on `profiles` prevents the iOS client from modifying `is_pro`, `subscription_status`, or `subscription_end_date` directly

## Security Model

- The **client** cannot set its own subscription status — the RLS policy on `profiles` blocks writes to subscription columns
- The **edge function** uses the service role key to bypass RLS and is the only path to update subscription status
- A **forged JWS** is rejected because the edge function verifies the transaction exists on Apple's servers via the App Store Server API
- If the App Store Server API keys are **not configured**, the function falls back to accepting the JWS payload (graceful degradation) — configure the keys for full security

## Troubleshooting

**"Transaction verification failed" (403)**
- The transaction ID does not exist on Apple's servers. This could be a forged JWS or a sandbox/production environment mismatch.

**"Bundle ID mismatch" (403)**
- The JWS was generated for a different app. Check `APP_STORE_BUNDLE_ID`.

**Apple API returns non-200 but function still succeeds**
- By design, the function allows transactions when Apple's API returns unexpected errors (to avoid blocking paying users due to Apple outages). Only a 404 (transaction not found) is treated as a hard failure.

**Subscription shows as active but user didn't pay**
- Check if `APP_STORE_PRIVATE_KEY` is set correctly. Without it, the Apple verification is skipped.
- Check Supabase function logs: `supabase functions logs verify-receipt`
