-- Restrict subscription columns on profiles table.
-- Only the service role (edge functions) should update subscription status.
-- Client-side updates to is_pro, subscription_status, subscription_end_date are blocked.
--
-- This prevents subscription bypass from modified app binaries or jailbroken devices.

-- Drop the existing wide-open UPDATE policy
drop policy if exists "users can update own profile" on profiles;

-- Create a restricted UPDATE policy that excludes subscription columns.
-- The client can update display_name, avatar_url, agent_permissions, etc.
-- but NOT is_pro, subscription_status, or subscription_end_date.
--
-- We use a CHECK expression in the policy: if the user tries to change
-- subscription fields, the update is rejected.
create policy "users can update own profile (non-subscription fields)"
  on profiles for update using (auth.uid() = id)
  with check (
    -- Ensure subscription fields are unchanged from current values
    is_pro = (select p.is_pro from profiles p where p.id = id)
    and subscription_status = (select p.subscription_status from profiles p where p.id = id)
    and (
      subscription_end_date is not distinct from
      (select p.subscription_end_date from profiles p where p.id = id)
    )
  );

-- The verify-receipt edge function uses the service role key,
-- which bypasses RLS entirely and can update any column.
