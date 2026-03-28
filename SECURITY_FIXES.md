# Tarsy — Security Fixes Roadmap

> **Contexto:** Tarsy permite ao usuario controlar seu Mac pessoal pelo iPhone a distancia. O usuario so tem acesso fisico ao Mac durante o onboarding (3 steps: login → permissions → ready). Apos o onboarding, o Mac roda como menu bar app sem nenhuma interacao fisica. Todas as solucoes DEVEM:
> - Funcionar sem interacao fisica no Mac apos o setup inicial
> - Nunca mostrar dialogs, prompts de senha, ou janelas no macOS pos-onboarding
> - Usar Keychain com `kSecAttrAccessibleAfterFirstUnlock` (nunca `WhenUnlocked` que exige desbloqueio)
> - Qualquer configuracao pos-onboarding deve ser feita pelo iPhone via WebSocket/Supabase

---

## CRITICAL

### C1. Verificacao de Role no Relay — Impedir Impersonacao de Machine
**Arquivo:** `relay/src/index.ts:82-122, 196-197`
**Problema:** O client auto-declara seu role ("machine" ou "client"). Um atacante com JWT valido pode conectar como `role:"machine"`, expulsar a machine real silenciosamente, e receber todos os pacotes do iPhone (incluindo senhas sudo).

**Solucao:**
- [ ] Criar tabela `machine_tokens` no Supabase com colunas: `id`, `user_id`, `machine_secret` (UUID v4), `created_at`
- [ ] Durante o onboarding no macOS (step 3 "Ready", quando `registerMachine()` ja roda), gerar um `machine_secret` unico e:
  - Salvar no Keychain do Mac com `kSecAttrAccessibleAfterFirstUnlock` (mesmo pattern do TLS cert — sem prompt)
  - Inserir na tabela `machine_tokens` via Supabase (ja autenticado nesse ponto)
- [ ] Alterar o auth message do relay para exigir `machine_secret` quando `role === "machine"`:
  ```typescript
  if (auth.role === "machine") {
    const { data } = await supabase
      .from("machine_tokens")
      .select("machine_secret")
      .eq("user_id", user.id)
      .single();
    if (!data || data.machine_secret !== auth.machineSecret) {
      ws.close(4003, "Invalid machine credentials");
      return;
    }
  }
  ```
- [ ] No macOS `RelayClient`, enviar o `machine_secret` do Keychain no auth message
- [ ] Adicionar RLS na tabela `machine_tokens`: SELECT/UPDATE apenas para `auth.uid() = user_id`
- [ ] Adicionar migration sequencial (`019_machine_tokens.sql`)
- [ ] **Rotacao remota (sem acesso fisico):** Adicionar WSAction `security:rotate_machine_secret`:
  - iPhone envia `security:rotate_machine_secret` pelo relay (autenticado com JWT)
  - Mac gera novo UUID v4, atualiza Keychain + Supabase
  - Mac responde com confirmacao, reconecta ao relay com novo secret
  - Disponivel em `WorkspaceSettingsView` no iPhone como "Rotate Machine Key"
- [ ] **Auto-rotacao:** Mac rotaciona automaticamente a cada 90 dias (check no heartbeat timer que ja roda a cada 30s)

**Impacto:** Elimina impersonacao de machine. Mesmo com JWT vazado, atacante nao tem o `machine_secret` que so existe no Keychain do Mac. Rotacao funciona 100% remoto.

---

### C2. Validacao de Actions por Role no Relay
**Arquivo:** `relay/src/index.ts:225-229`
**Problema:** Relay encaminha mensagens sem inspecao. Um client malicioso pode enviar `terminal:input`, `sudo:response`, ou qualquer action reservada para machines.

**Solucao:**
- [ ] Criar allowlists de actions por role no relay:
  ```typescript
  const CLIENT_ALLOWED_PREFIXES = [
    "workspace:", "stream:start", "stream:stop",
    "remote_input:", "screenshot:request",
    "terminal:create", "terminal:input", "terminal:close",
    "claude_code:create", "claude_code:message", "claude_code:close",
    "generic_engine:", "openclaw:message",
    "git:", "file:", "browser:", "http_proxy:request",
    "dev_server:", "mcp:", "sudo:response",
    "engine_status:", "agents:", "ultracontext:",
    "auth:", "ping", "pong"
  ];
  const MACHINE_ALLOWED_PREFIXES = [
    "workspace:", "stream:frame",
    "screenshot:result", "terminal:output", "terminal:list_result",
    "claude_code:output", "claude_code:complete", "claude_code:ask_user",
    "generic_engine:output", "generic_engine:complete", "generic_engine:ask_user",
    "openclaw:", "git:", "file:", "browser:",
    "http_proxy:response", "dev_server:",
    "mcp:", "engine_status:", "sudo:request", "sudo:result",
    "agents:", "ultracontext:",
    "relay:machine_online", "auth:", "ping", "pong", "error"
  ];
  ```
- [ ] Parsear o `action` de cada mensagem texto antes de encaminhar
- [ ] Rejeitar (drop + log) mensagens com actions fora da allowlist do role
- [ ] Mensagens binarias (video frames) passam sem inspecao (nao tem action)
- [ ] Adicionar testes unitarios para as allowlists

**Impacto:** Impede que clients enviem actions reservadas para machines e vice-versa. Defesa em profundidade mesmo se C1 falhar.

---

### C3. Restringir Comandos Sudo a Whitelist
**Arquivo:** `TarsymacOS/Sources/DaemonManager.swift:600-632`, `SudoPasswordManager.swift:177-223`
**Problema:** `handleSudoRequest` executa qualquer comando como root via `sudo /bin/zsh -c <command>`. E essencialmente um root shell remoto.

**Solucao:**
- [ ] Criar whitelist de comandos sudo permitidos com categorias:
  ```swift
  enum SudoCategory: String, Codable, CaseIterable {
      case packageManagers  // npm, yarn, pnpm, bun, pip, gem, brew
      case filePermissions  // chmod, chown
      case processControl   // kill, killall, launchctl
      case devTools         // xcode-select
  }

  // Cada categoria mapeia para prefixos de comando permitidos
  static let categoryPatterns: [SudoCategory: [String]] = [
      .packageManagers: ["npm install", "npm ci", "yarn install", "pnpm install",
                         "bun install", "gem install", "pip install", "pip3 install",
                         "brew install"],
      .filePermissions: ["chmod", "chown"],
      .processControl: ["kill", "killall", "launchctl"],
      .devTools: ["xcode-select"]
  ]
  ```
- [ ] Em `runWithSudo()`, validar que o comando comeca com um dos patterns permitidos antes de executar
- [ ] Rejeitar comandos com shell metacharacters perigosos apos o pattern: `;`, `&&`, `||`, `$(`, `` ` ``, `|`, `>`, `<` (exceto dentro de aspas do argumento)
- [ ] Retornar erro especifico para o iOS quando comando for rejeitado: `"Command not allowed for remote sudo execution"`
- [ ] Logar tentativas de comandos rejeitados para auditoria
- [ ] **Configuracao 100% remota pelo iPhone (nunca no Mac):**
  - Salvar categorias habilitadas no Supabase `profiles.sudo_categories` (array de strings, default: todas habilitadas)
  - No Mac, carregar do profile na inicializacao e observar mudancas via Realtime
  - No iPhone, adicionar secao "Sudo Permissions" em `WorkspaceSettingsView`:
    - Toggle por categoria com descricao do que cada uma permite
    - Mudancas salvam no Supabase → Mac recebe via Realtime → atualiza whitelist local
  - **Sem UI no macOS** — tudo configurado pelo iPhone
- [ ] Default seguro: todas as categorias habilitadas (o usuario veio do onboarding, espera que tudo funcione)

**Impacto:** Mesmo com acesso autenticado, atacante nao consegue executar comandos arbitrarios como root. Configuracao funciona 100% pelo iPhone.

---

### C4. Verificar Assinatura JWS do Apple — Impedir Subscription Bypass
**Arquivo:** `supabase/functions/verify-receipt/index.ts:61-85, 95-126`
**Problema:** `decodeJWS()` nao verifica assinatura. `verifyWithApple()` tem multiplos caminhos fail-open que retornam `true` em caso de erro.

**Solucao:**
- [ ] Implementar verificacao de assinatura JWS contra o Apple Root CA:
  ```typescript
  import { jwtVerify, importX509 } from "jose";

  async function verifyJWSSignature(jws: string): Promise<DecodedTransaction | null> {
    // Extrair certificados do header x5c
    const header = JSON.parse(atob(jws.split(".")[0]));
    const certs = header.x5c as string[];
    if (!certs?.length) return null;

    // Verificar cadeia de certificados contra Apple Root CA
    // Apple Root CA: https://www.apple.com/certificateauthority/
    const leafCert = await importX509(
      `-----BEGIN CERTIFICATE-----\n${certs[0]}\n-----END CERTIFICATE-----`,
      "ES256"
    );

    const { payload } = await jwtVerify(jws, leafCert);
    return payload as unknown as DecodedTransaction;
  }
  ```
- [ ] Mudar TODOS os caminhos fail-open em `verifyWithApple()` para fail-closed (`return false`)
- [ ] Especificamente corrigir:
  - Linha 97-99: Se API keys nao configuradas → `return false` (nao `true`)
  - Linha 108: Se JWT generation falha → `return false`
  - Linha 121: Status inesperado → `return false`
  - Linha 124: Erro de rede → `return false`
- [ ] Adicionar cache de verificacao (Redis ou in-memory com TTL de 1h) para nao bater na Apple API a cada request
- [ ] Adicionar logging detalhado para cada rejeicao

**Impacto:** Elimina subscription bypass. Ninguem consegue Pro sem pagamento real via App Store.

---

### C5. Forcar E2E para Senhas Sudo — Nunca Fallback Plaintext
**Arquivo:** `TarsyiOS/Sources/ContentView.swift:79-86`, `TarsymacOS/Sources/DaemonManager.swift:415-422`
**Problema:** Quando E2E nao esta pronto, a senha sudo e enviada em plaintext. No relay, o servidor pode ler a senha.

**Solucao:**
- [ ] No iOS (`ContentView.swift`), bloquear envio de senha quando E2E nao esta pronto:
  ```swift
  if connectionManager.e2e.isReady,
     let encrypted = connectionManager.e2e.encrypt(sudoPassword) {
      payload = ["encryptedPassword": encrypted]
  } else {
      // Mostrar alerta ao usuario
      showSudoError = true
      sudoErrorMessage = "Secure connection not established. Reconnect and try again."
      return
  }
  ```
- [ ] No macOS (`DaemonManager.swift`), rejeitar pacotes `sudoResponse` sem `encryptedPassword`:
  ```swift
  case .sudoResponse:
      guard let encrypted = packet.payload?["encryptedPassword"],
            !encrypted.isEmpty,
            let plaintext = e2e.decrypt(encrypted) else {
          print("[Sudo] Rejected: password not E2E encrypted")
          return
      }
  ```
- [ ] Remover completamente o fallback `payload = ["password": sudoPassword]` do iOS
- [ ] Garantir que o key exchange E2E acontece automaticamente em toda reconexao (ja acontece no auth, verificar edge cases)
- [ ] Adicionar retry automatico do key exchange se falhar, antes de mostrar erro ao usuario

**Impacto:** Senhas sudo nunca trafegam em plaintext, nem no relay nem no LAN.

---

### C6. Corrigir Auth do Webhook send-email
**Arquivo:** `supabase/functions/send-email/index.ts:261-268`
**Problema:** Qualquer usuario autenticado pode enviar welcome emails para qualquer endereco, abusando da conta Resend.

**Solucao:**
- [ ] Remover o fallback para user JWT no path de webhook:
  ```typescript
  // Webhook path: ONLY accept service role key
  if (body.type === "INSERT" && body.record?.email) {
    if (token !== SUPABASE_SERVICE_ROLE_KEY) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401
      });
    }
    // ... send welcome email
  }
  ```
- [ ] Manter validacao de user JWT apenas para invocacao direta (billing emails)
- [ ] No path de billing emails, validar que o `email` no body corresponde ao email do user autenticado:
  ```typescript
  const { data: { user } } = await supabase.auth.getUser(token);
  if (body.email !== user.email) {
    return new Response(JSON.stringify({ error: "Email mismatch" }), { status: 403 });
  }
  ```
- [ ] Adicionar rate limiting: max 5 emails por usuario por hora

**Impacto:** Impede abuso do servico de email. Webhooks so aceitam service role key.

---

## HIGH

### H1. Restringir WebSocket Server ao Necessario
**Arquivo:** `TarsymacOS/Sources/Networking/WebSocketServer.swift:76, 155-178`
**Problema:** Porta 8642 escuta em todas as interfaces. Qualquer dispositivo no mesmo WiFi pode conectar.

**Solucao (100% automatica, sem config no Mac):**
- [ ] Adicionar validacao de `machineId` no handshake do WebSocket local:
  - O iOS ja conhece o `machineId` (vem da tabela `machines` do Supabase)
  - iOS envia `machineId` no auth message junto com o JWT
  - macOS valida que o `machineId` corresponde ao seu proprio ID (ja armazenado em `self.machineId`)
  - Rejeita se nao bater — impede conexoes de quem nao conhece o ID
- [ ] Reduzir o auth timeout de 5s para 3s
- [ ] Adicionar rate limiting de tentativas de auth falhadas por IP: max 3 falhas em 60s → ban temporario de 5 minutos (implementado como `Dictionary<String, (failures: Int, bannedUntil: Date?)>` no WebSocketServer)
- [ ] Logar IPs que falham auth para deteccao de scanning
- [ ] **Tudo automatico** — `machineId` ja existe em ambos os lados, so precisa validar no handshake

**Nota:** Nao podemos bind a localhost porque LAN e um modo de conexao valido e importante para latencia.

---

### H2. Proteger Senha Sudo em Memoria
**Arquivo:** `TarsymacOS/Sources/SudoPasswordManager.swift:9-11`
**Problema:** Senha cachada como `String` por 60s. Strings Swift sao imutaveis e nao zeradas na desalocacao.

**Solucao:**
- [ ] Substituir `String` por `[UInt8]` para o cache de senha:
  ```swift
  private var cachedPassword: [UInt8]?

  private func clearPasswordBytes() {
      guard var bytes = cachedPassword else { return }
      for i in bytes.indices { bytes[i] = 0 }
      cachedPassword = nil
      cacheExpiry = nil
  }
  ```
- [ ] Converter `SudoPasswordManager` de `final class` para `actor` para eliminar data races:
  ```swift
  actor SudoPasswordManager {
      static let shared = SudoPasswordManager()
      private var cachedPassword: [UInt8]?
      // ...
  }
  ```
- [ ] Converter `[UInt8]` para `String` apenas no momento do uso, e zerar imediatamente apos
- [ ] Chamar `clearPasswordBytes()` explicitamente no `deinit` e quando cache expira
- [ ] **Nota:** Nenhuma interacao no Mac necessaria — e pura refatoracao de codigo. A senha continua vindo do iPhone via WebSocket, cachada por 60s em memoria

---

### H3. Eliminar Temp Files e Env Vars com Senha
**Arquivo:** `TarsymacOS/Sources/SudoPasswordManager.swift:102-119`
**Problema:** Senha colocada em env var `TARSY_SUDO_PASS` e escrita em temp file. Visivel via `ps eww` e persiste se processo crashar.

**Solucao:**
- [ ] Substituir o pattern `sudoAskpassWrapper` por pipe via stdin (ja existe em `runWithSudo`):
  ```swift
  func rewriteCommandWithStdinSudo(_ command: String, password: [UInt8]) -> (command: String, stdinData: Data?) {
      let sudoCmd = command.replacingOccurrences(of: "sudo ", with: "")
      let fullCmd = "sudo -S \(sudoCmd)"
      let passwordString = String(bytes: password, encoding: .utf8)! + "\n"
      return (fullCmd, passwordString.data(using: .utf8))
  }
  ```
- [ ] Modificar `TerminalSessionManager.sendInput()` para suportar stdin pipe quando sudo detectado
- [ ] Remover completamente `sudoAskpassWrapper()` e `TARSY_SUDO_PASS`
- [ ] Garantir que a senha nunca toca o filesystem

---

### H4. Notificar Clients ao Substituir Machine
**Arquivo:** `relay/src/index.ts:84-89`
**Problema:** Machine substituida silenciosamente. Clients nao sabem que estao falando com outra entidade.

**Solucao:**
- [ ] Enviar notificacao a todos os clients quando machine e substituida:
  ```typescript
  const existing = machines.get(userId);
  if (existing) {
    console.log(`[Relay] Replacing existing machine for ${userId}`);
    // Notify all clients BEFORE replacing
    const userClients = clients.get(userId);
    if (userClients) {
      const warning = JSON.stringify({
        action: "relay:machine_reconnected",
        payload: { timestamp: Date.now() }
      });
      for (const client of userClients) {
        client.send(warning);
      }
    }
    existing.close(1000, "replaced");
    removeConnection(existing, 1000, "replaced");
  }
  ```
- [ ] No iOS, exibir `StatusBanner` avisando "Machine reconnected" quando receber `relay:machine_reconnected`
- [ ] Adicionar cooldown: se machine for substituida mais de 3x em 60s, rejeitar novas conexoes e notificar clients de possivel ataque

---

### H5. Limitar Conexoes Nao-Autenticadas
**Arquivo:** `relay/src/index.ts:175-185`
**Problema:** Janela de 10s para auth sem limite de conexoes simultaneas. Atacante pode abrir milhares de conexoes.

**Solucao:**
- [ ] Adicionar contador global de conexoes nao-autenticadas:
  ```typescript
  let unauthenticatedCount = 0;
  const MAX_UNAUTH_CONNECTIONS = 50;
  ```
- [ ] Rejeitar upgrade WebSocket quando limite atingido (retornar 503)
- [ ] Reduzir auth timeout de 10s para 5s
- [ ] Incrementar contador em `open()`, decrementar em auth success ou timeout
- [ ] Adicionar rate limiting por IP: max 10 conexoes por IP por minuto

---

### H6. Remover `--no-verify-jwt` do ultracontext-proxy
**Arquivo:** `supabase/functions/ultracontext-proxy/index.ts:3`
**Problema:** Gateway do Supabase nao valida JWT. Se `authenticateUser()` tiver bug, nao ha fallback.

**Solucao (mudanca apenas no deploy, nao afeta Mac/iPhone):**
- [ ] Remover o comentario de deploy com `--no-verify-jwt`
- [ ] Testar que a funcao funciona com JWT verification do gateway habilitada
- [ ] Se precisar de chamadas sem auth (health check), criar endpoint separado
- [ ] Atualizar script/documentacao de deploy
- [ ] Redesploy: `supabase functions deploy ultracontext-proxy` (sem `--no-verify-jwt`)

---

### H7. Mover Service Role Key para Vault do Supabase
**Arquivo:** `supabase/migrations/010_fix_welcome_email_webhook.sql:14-25`
**Problema:** Service role key em plaintext na tabela `private_config`. Qualquer `SECURITY DEFINER` function pode ler.

**Solucao:**
- [ ] Migrar para `supabase_vault` (se disponivel no plano) ou para secrets do edge functions:
  ```sql
  -- Nova migration: 019_remove_service_key_from_db.sql
  -- Remover a key da tabela
  DELETE FROM private_config WHERE key = 'service_role_key';
  ```
- [ ] Alterar a trigger function `notify_welcome_email()` para chamar o edge function via `net.http_post()` usando apenas a URL (sem service role key no DB)
- [ ] Passar a service role key como secret do Supabase (`supabase secrets set SERVICE_ROLE_KEY=...`) e usar `Deno.env.get()` no edge function
- [ ] Se a trigger precisar chamar o edge function, usar o `SUPABASE_SERVICE_ROLE_KEY` que ja esta disponivel como env var nos edge functions

---

### H8. Sanitizar Mensagens de Erro nos Edge Functions
**Arquivo:** Todos os edge functions
**Problema:** `String(err)` retornado ao client pode expor stack traces e detalhes internos.

**Solucao:**
- [ ] Criar helper de erro padrao:
  ```typescript
  function safeError(err: unknown, publicMessage: string): Response {
    console.error("[Edge] Internal error:", err);
    return new Response(
      JSON.stringify({ error: publicMessage }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
  ```
- [ ] Aplicar em todos os edge functions:
  - `send-email/index.ts` → `safeError(err, "Failed to send email")`
  - `delete-account/index.ts` → `safeError(err, "Failed to delete account")`
  - `send-push/index.ts` → `safeError(err, "Failed to send notification")`
  - `ultracontext-proxy/index.ts` → `safeError(err, "Proxy request failed")`
  - `verify-receipt/index.ts` → `safeError(err, "Receipt verification failed")`
- [ ] Manter o `console.error` com detalhes para debugging nos logs do Supabase

---

### H9. Validar Paths no handleFileTree e Git Operations
**Arquivo:** `DaemonManager.swift:2640-2728, 2396-2618`
**Problema:** `handleFileTree` aceita qualquer path sem validacao. Git operations tambem. Atacante pode enumerar `~/.ssh/`, `~/.aws/`.

**Solucao:**
- [ ] Aplicar `sanitizedPath` no `handleFileTree`:
  ```swift
  private func handleFileTree(clientId: String, packet: WSPacket) async {
      guard let requestedPath = packet.payload?["path"] else { return }

      // Validar que path esta dentro de um workspace registrado
      let expandedPath = (requestedPath as NSString).expandingTildeInPath
      guard isPathInRegisteredWorkspace(expandedPath) else {
          sendPacket(.fileTreeResult, payload: ["error": "Path not in workspace"], to: clientId)
          return
      }
      // ... resto da logica
  }
  ```
- [ ] Criar metodo `isPathInRegisteredWorkspace(_ path: String) -> Bool`:
  - Iterar pelos workspaces ativos (ja existem em `DaemonManager.workspaces`, carregados do Supabase)
  - Verificar que `path.hasPrefix(workspace.localPath)`
  - Resolver symlinks antes da comparacao
  - **Sem config adicional** — usa os workspaces que o user criou pelo iPhone (via `NewWorkspaceView`)
- [ ] Aplicar mesma validacao em TODOS os git handlers:
  - `handleGitCheckpoint`
  - `handleGitDiff`
  - `handleGitRollback`
  - `handleGitHistory`
  - `handleGitFileDiff`
  - `handleGitBranches`
  - `handleGitCheckout`
  - `handleGitPull`
- [ ] Criar teste que verifica que paths como `/etc/passwd`, `~/.ssh/id_rsa`, `../../` sao rejeitados

---

## MEDIUM

### M1. Corrigir TOFU Pinning — Rejeitar Certificados Alterados
**Arquivo:** `ConnectionManager.swift:510-519`
**Problema:** TOFU pinning aceita qualquer certificado novo, nunca rejeita. MITM trivial.

**Solucao:**
- [ ] Quando fingerprint muda no LAN, rejeitar e cair pro relay:
  ```swift
  if fingerprint == pinned {
      completion(true)
  } else {
      print("[WS] TLS fingerprint CHANGED — rejecting LAN, will use relay")
      completion(false)
      // Nao mostrar erro — automaticamente cai pro relay (smart connect)
      // O relay e seguro (TLS do Fly.io) e funciona como fallback
  }
  ```
- [ ] **Re-pin automatico sem interacao do user:**
  1. Mac envia `security:fingerprint_update` com novo fingerprint pelo **relay** (canal seguro — TLS do Fly.io)
  2. iOS recebe pelo relay, valida que veio de conexao relay autenticada (nao LAN)
  3. iOS atualiza fingerprint no Keychain automaticamente
  4. Proxima tentativa LAN usa o novo pin
  5. **Nenhum prompt, nenhuma acao do user** — tudo automatico
- [ ] O Mac so regenera cert se o Keychain for limpo (raro). Nesse caso:
  - `TLSCertificateManager.getOrCreateIdentity()` gera novo cert automaticamente (ja funciona assim)
  - Na proxima conexao relay, envia o novo fingerprint
  - iOS re-pina automaticamente
- [ ] Adicionar campo `tls_fingerprint` na tabela `machines` do Supabase como backup:
  - Mac atualiza quando gera/regenera cert
  - iOS pode consultar se nunca conectou por relay (edge case)
- [ ] **Fluxo completo sem acesso fisico ao Mac:**
  ```
  Mac regenera cert (automatico) →
  Mac conecta ao relay (automatico) →
  Mac envia fingerprint pelo relay (automatico) →
  iOS recebe e re-pina (automatico) →
  Proxima conexao LAN funciona (automatico)
  ```

---

### M2. Validar OAuth Callback URL
**Arquivo:** `TarsyiOSApp.swift:118-121`, `AuthManager.swift:175-186`
**Problema:** Qualquer URL passada para `handleOAuthCallback` sem validacao de scheme/host.

**Solucao:**
- [ ] Validar antes de processar:
  ```swift
  .onOpenURL { url in
      guard url.scheme == "com.tarsy.ios",
            url.host == "login-callback" else {
          print("[Auth] Ignored unexpected URL: \(url.scheme ?? "nil")")
          return
      }
      Task { await authManager.handleOAuthCallback(url: url) }
  }
  ```
- [ ] Aplicar mesma validacao no macOS (`com.tarsy.macos`)

---

### M3. Rate Limiting Per-User no Relay
**Arquivo:** `relay/src/index.ts:18-31`
**Problema:** Rate limiting por conexao, nao por usuario. 5 clients = 600 msg/s.

**Solucao:**
- [ ] Mudar `messageCounts` para ser por userId:
  ```typescript
  const userMessageCounts = new Map<string, { count: number; resetAt: number }>();

  function isUserRateLimited(userId: string): boolean {
    const now = Date.now();
    let entry = userMessageCounts.get(userId);
    if (!entry || now >= entry.resetAt) {
      userMessageCounts.set(userId, { count: 1, resetAt: now + 1000 });
      return false;
    }
    entry.count++;
    return entry.count > MAX_MESSAGES_PER_SECOND;
  }
  ```
- [ ] Enviar mensagem de warning quando rate limited (em vez de drop silencioso):
  ```typescript
  if (isUserRateLimited(info.userId)) {
    ws.send(JSON.stringify({ action: "error", payload: { message: "Rate limited" } }));
    return;
  }
  ```
- [ ] Adicionar rate limiting nas tentativas de auth: max 5 falhas por IP por minuto

---

### M4. Limite de Tamanho em Mensagens LAN
**Arquivo:** `ConnectionManager.swift:251-280`
**Problema:** Relay tem limite de 4MB mas LAN nao tem. Payload gigante pode causar OOM.

**Solucao:**
- [ ] Adicionar check de tamanho antes de parsear JSON no LAN:
  ```swift
  private let maxLANMessageSize = 4 * 1024 * 1024 // 4MB, same as relay

  // No receiveLANLoop:
  guard data.count <= maxLANMessageSize else {
      print("[WS] LAN message too large: \(data.count) bytes, dropping")
      continue
  }
  ```

---

### M5. Validar Proxy Requests no macOS
**Arquivo:** `TarsyiOS/Sources/Views/Components/TarsyProxySchemeHandler.swift:41-46`
**Problema:** Validacao de host so no iOS. MacOS pode receber proxy requests para hosts arbitrarios via WebSocket direto.

**Solucao:**
- [ ] No macOS, no handler de `http_proxy:request`, validar que o host e localhost/loopback:
  ```swift
  let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
  guard let host = URL(string: urlString)?.host,
        allowedHosts.contains(host) else {
      // Rejeitar request
      sendPacket(.httpProxyResponse, payload: ["error": "Host not allowed"], to: clientId)
      return
  }
  ```

---

### M6. Proteger Workspace Limit Server-Side
**Arquivo:** `SubscriptionManager.swift:112-115`
**Problema:** Limite de 1 workspace free e so UI. Chamada direta ao Supabase bypassa.

**Solucao:**
- [ ] Adicionar RLS policy ou database function que enforce o limite:
  ```sql
  -- Migration 019 ou 020
  CREATE OR REPLACE FUNCTION check_workspace_limit()
  RETURNS TRIGGER AS $$
  DECLARE
    workspace_count INTEGER;
    is_pro BOOLEAN;
  BEGIN
    SELECT profiles.is_pro INTO is_pro
    FROM profiles WHERE id = auth.uid();

    IF NOT COALESCE(is_pro, false) THEN
      SELECT COUNT(*) INTO workspace_count
      FROM workspaces WHERE user_id = auth.uid();

      IF workspace_count >= 1 THEN
        RAISE EXCEPTION 'Free plan limited to 1 workspace. Upgrade to Pro.';
      END IF;
    END IF;

    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql SECURITY DEFINER;

  CREATE TRIGGER enforce_workspace_limit
    BEFORE INSERT ON workspaces
    FOR EACH ROW EXECUTE FUNCTION check_workspace_limit();
  ```

---

### M7. SudoPasswordManager Data Race
**Arquivo:** `SudoPasswordManager.swift:6-18`
**Problema:** `final class` com estado mutavel acessado de multiplas tasks async sem sincronizacao.

**Solucao:**
- [ ] Ja coberto por H2 — converter para `actor`. Garantir que todas as chamadas usem `await`.

---

### M8. Push Notification Rate Limiting
**Arquivo:** `supabase/migrations/002_push_notifications.sql`
**Problema:** Sem rate limit. Usuario malicioso pode inserir milhares de notificacoes.

**Solucao:**
- [ ] Adicionar trigger ou RLS que limita inserts:
  ```sql
  CREATE OR REPLACE FUNCTION check_push_rate_limit()
  RETURNS TRIGGER AS $$
  DECLARE
    recent_count INTEGER;
  BEGIN
    SELECT COUNT(*) INTO recent_count
    FROM push_notifications
    WHERE user_id = auth.uid()
      AND created_at > NOW() - INTERVAL '1 minute';

    IF recent_count >= 10 THEN
      RAISE EXCEPTION 'Push notification rate limit exceeded';
    END IF;

    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;

  CREATE TRIGGER push_rate_limit
    BEFORE INSERT ON push_notifications
    FOR EACH ROW EXECUTE FUNCTION check_push_rate_limit();
  ```

---

### M9. Ocultar Identidade do Relay Server
**Arquivo:** `relay/src/index.ts:171`
**Problema:** Resposta padrao revela `"Tarsy Relay Server"`.

**Solucao:**
- [ ] Retornar 404 para paths desconhecidos:
  ```typescript
  return new Response("Not Found", { status: 404 });
  ```

---

## LOW

### L1. Truncar User IDs nos Logs
**Arquivo:** `relay/src/index.ts` (multiplas linhas)

- [ ] Criar helper `shortId(userId: string) => userId.slice(0, 8)` e usar em todos os logs

---

### L2. Pinar Imagem Docker
**Arquivo:** `relay/Dockerfile:1`

- [ ] Trocar `FROM oven/bun:1` para versao especifica com digest:
  ```dockerfile
  FROM oven/bun:1.1.45@sha256:<digest>
  ```

---

### L3. Remover Device Token dos Logs
**Arquivo:** `TarsyiOS/Sources/TarsyiOSApp.swift:37`

- [ ] Trocar `print("[Push] Device token: \(token)")` para `print("[Push] Device token registered (\(token.count) chars)")`

---

### L4. Limpar Arquivo Tracked no .gitignore
**Arquivo:** `supabase/.temp/cli-latest`

- [ ] Executar `git rm --cached supabase/.temp/cli-latest` e commitar

---

### L5. Adicionar Limite de Tamanho Separado para Texto vs Binario no Relay
**Arquivo:** `relay/src/index.ts:239`

- [ ] Texto: max 64KB. Binario (video): max 4MB:
  ```typescript
  if (typeof message === "string" && message.length > 65536) {
    ws.close(4004, "Text message too large");
    return;
  }
  ```

---

## Ordem de Execucao Recomendada

### Sprint 1 — Criticos (1-2 dias)
1. C5 — Forcar E2E para sudo (mudanca pequena, impacto grande)
2. C6 — Fix webhook auth (mudanca pequena)
3. C4 — Verificar JWS signatures (medio esforco)
4. C1 — Machine tokens no relay (medio esforco)
5. C2 — Action allowlists no relay (medio esforco)

### Sprint 2 — Criticos + High (2-3 dias)
6. C3 — Whitelist de comandos sudo
7. H9 — Path validation (file tree + git)
8. H2 + H3 + M7 — SudoPasswordManager overhaul (actor + bytes + stdin)
9. H8 — Sanitizar erros nos edge functions
10. H4 — Notificar clients de machine replacement

### Sprint 3 — High + Medium (2-3 dias)
11. H1 — Rate limiting no WebSocket local
12. H5 — Limitar conexoes nao-autenticadas
13. H6 — Remover --no-verify-jwt
14. H7 — Mover service role key
15. M1 — Fix TOFU pinning
16. M6 — Workspace limit server-side

### Sprint 4 — Medium + Low (1-2 dias)
17. M2, M3, M4, M5, M8, M9
18. L1, L2, L3, L4, L5

---

## Classificacao por Onde a Mudanca Acontece

> Nenhuma solucao requer interacao fisica no Mac pos-onboarding.

| Fix | Relay (server) | macOS (code) | iOS (code) | Supabase (backend) | Mac Onboarding | iPhone UI |
|-----|:-:|:-:|:-:|:-:|:-:|:-:|
| C1. Machine tokens | X | X | | X | gera secret | |
| C2. Action allowlists | X | | | | | |
| C3. Sudo whitelist | | X | X | X | | config via Settings |
| C4. JWS verification | | | | X | | |
| C5. E2E obrigatorio | | X | X | | | erro se E2E falhar |
| C6. Webhook auth | | | | X | | |
| H1. WebSocket local | | X | X | | | |
| H2. Sudo em memoria | | X | | | | |
| H3. Eliminar temp files | | X | | | | |
| H4. Notificar replacement | X | | X | | | banner status |
| H5. Limitar unauth | X | | | | | |
| H6. --no-verify-jwt | | | | X | | |
| H7. Service role key | | | | X | | |
| H8. Sanitizar erros | | | | X | | |
| H9. Path validation | | X | | | | |
| M1. TOFU pinning | | X | X | X | | automatico |
| M2. OAuth callback | | | X | | | |
| M3. Rate limit user | X | | | | | |
| M4. LAN msg size | | | X | | | |
| M5. Proxy validation | | X | | | | |
| M6. Workspace limit | | | | X | | |
| M7. Data race | | X | | | | |
| M8. Push rate limit | | | | X | | |
| M9. Ocultar servidor | X | | | | | |

**Legenda:**
- **Mac Onboarding** = acontece apenas durante setup inicial (user esta fisicamente no Mac)
- **iPhone UI** = nova UI/feedback no app iOS (user opera 100% pelo iPhone)
- **macOS (code)** = mudanca de codigo que roda silenciosamente, sem UI no Mac
- **Relay/Supabase** = mudanca server-side, nao afeta nenhum app diretamente
