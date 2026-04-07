-- Machine pairing tokens for QR code-based pairing
-- Tokens are single-use, 5-minute TTL

CREATE TABLE machine_pairings (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    machine_id uuid NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    pairing_token text NOT NULL,
    connection_code text NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_active_pairing UNIQUE (machine_id, pairing_token)
);

-- Index for token lookup during claim
CREATE INDEX idx_machine_pairings_token ON machine_pairings(pairing_token);

-- Index for connection code lookup during manual entry
CREATE INDEX idx_machine_pairings_code ON machine_pairings(connection_code);

-- Index for cleanup of expired tokens
CREATE INDEX idx_machine_pairings_expires ON machine_pairings(expires_at);

-- RLS
ALTER TABLE machine_pairings ENABLE ROW LEVEL SECURITY;

-- Machine owner can create and manage pairing tokens
CREATE POLICY "Machine owner can manage pairings"
    ON machine_pairings FOR ALL
    USING (
        machine_id IN (SELECT id FROM machines WHERE user_id = auth.uid())
    );
