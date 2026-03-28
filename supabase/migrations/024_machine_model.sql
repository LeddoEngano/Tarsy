-- Add model identifier column to machines for device-specific icons
ALTER TABLE machines ADD COLUMN IF NOT EXISTS model_identifier TEXT;
