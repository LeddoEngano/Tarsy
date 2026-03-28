# Security Audit Report — Tarsy

**Data:** 2026-03-28
**Escopo:** Supabase (migrations, edge functions, RLS), Relay Server, TarsymacOS, TarsyiOS, TarsyShared
**Método:** Análise estática de código em todos os endpoints, handlers e pontos de entrada

---

## Resumo Executivo

| Severidade | Quantidade |
|-----------|-----------|
| CRITICAL  | 1         |
| HIGH      | 8         |
| MEDIUM    | 12        |
| LOW       | 10        |
| **Total** | **31**    |

---

## CRITICAL

### C1 — MJPEG Stream Server sem autenticação (porta 8643)

- **Arquivo:** `TarsymacOS/Sources/Stream/MJPEGStreamServer.swift:98-119`
- **Descrição:** O server MJPEG na porta 8643 aceita conexões HTTP sem nenhuma autenticação. Qualquer dispositivo na LAN (ou na internet, se a porta estiver exposta) pode conectar e receber stream de tela em tempo real.
- **Impacto:** Exposição total da tela do usuário para qualquer atacante na mesma rede.
- **Reprodução:** `curl http://<mac-ip>:8643/stream` retorna frames JPEG contínuos.
- **Fix planejado:** Eliminar o MJPEG server inteiro. Migrar LAN para H.264 via WebSocket (porta 8642, que já tem auth). Deletar `MJPEGStreamServer.swift`.

---

## HIGH

### H1 — WebSocket LAN auth não verifica dono da máquina

- **Arquivo:** `TarsymacOS/Sources/DaemonManager.swift:243-250`
- **Descrição:** `validateAuthToken` valida que o JWT é real via `supabase.auth.user(jwt:)`, mas não verifica que o `user.id` é o dono da máquina. Qualquer usuário Tarsy válido com acesso à LAN controla a máquina.
- **Impacto:** Acesso remoto não autorizado por qualquer conta Tarsy na mesma rede.
- **Fix:** Após validar JWT, comparar `user.id` com `machine.user_id` no Supabase antes de autenticar.

### H2 — Path traversal em fileRead

- **Arquivo:** `TarsymacOS/Sources/DaemonManager.swift:2665-2669`
- **Descrição:** `filePath` do payload WebSocket é concatenado diretamente com `basePath` sem sanitização: `let fullPath = "\(expandedBase)/\(filePath)"`. Um atacante pode enviar `filePath: "../../../../../../etc/passwd"`.
- **Impacto:** Leitura de qualquer arquivo acessível pelo processo macOS.
- **Fix:** Resolver com `URL(fileURLWithPath:).standardized` e verificar que o path resultante começa com `expandedBase`. Rejeitar paths com `..`.

### H3 — Path traversal em gitFileDiff

- **Arquivo:** `TarsymacOS/Sources/DaemonManager.swift:2497`
- **Descrição:** Mesmo problema do H2 — `let fullPath = "\(expandedPath)/\(file)"` sem validação.
- **Fix:** Mesmo que H2.

### H4 — Shell injection no wizard via projectName

- **Arquivo:** `TarsymacOS/Sources/DaemonManager.swift:2153`
- **Descrição:** `config.projectName` é interpolado diretamente em string passada para `zsh -c`: `"gh repo create \(config.projectName) --private --source=. --remote=origin"`. Um nome como `foo; rm -rf / #` executa comandos arbitrários.
- **Impacto:** Execução remota de comandos arbitrários no Mac.
- **Fix:** Usar `Process` com arguments array: `["gh", "repo", "create", name, "--private", "--source=.", "--remote=origin"]`.

### H5 — Sudo password em plaintext na memória e via LAN

- **Arquivo:** `TarsymacOS/Sources/SudoPasswordManager.swift:9,52`
- **Descrição:** A senha sudo é armazenada como `String?` em memória (imutável, não-zerável) e transmitida em plaintext no payload WebSocket. Via LAN (`ws://`, sem TLS), a senha trafega em texto claro. Via relay (`wss://`), o relay server vê a senha descriptografada ao re-encaminhar.
- **Impacto:** Senha sudo do Mac interceptável na rede local.
- **Fix:** Usar criptografia end-to-end para a troca de senha. Usar `Data` (zerável) em vez de `String` para cache. Considerar Keychain para storage temporário.

### H6 — SSRF via TarsyProxySchemeHandler

- **Arquivo:** `TarsyiOS/Sources/Views/Components/TarsyProxySchemeHandler.swift:42-48`
- **Descrição:** O handler converte qualquer URL `tarsy-http://` para `http://` e proxia via WebSocket para o Mac, sem validação. Um dev server malicioso pode redirecionar para `http://169.254.169.254/latest/meta-data/` (cloud metadata) ou `http://127.0.0.1:<porta>/` (serviços internos).
- **Impacto:** O Mac faz requests HTTP para qualquer host/porta que o atacante escolher.
- **Fix:** Allowlist: só proxiar para `localhost`, `127.0.0.1`, `0.0.0.0`. Bloquear `169.254.x.x`, ranges RFC 1918, e IPs de cloud metadata.

### H7 — Subscription validation apenas client-side

- **Arquivo:** `TarsyiOS/Sources/Subscription/SubscriptionManager.swift:49-65`
- **Descrição:** `refreshStatus()` checa `Transaction.currentEntitlements` localmente e sincroniza `isPro` com Supabase via `profileService.updateSubscription()`. O cliente diz ao servidor seu status — não o contrário. Dispositivo jailbroken pode setar `isPro = true`.
- **Impacto:** Bypass completo do paywall.
- **Fix:** Implementar validação server-side via App Store Server Notifications v2 ou verificar JWS em edge function Supabase.

### H8 — UltraContext proxy: mapa in-memory efêmero permite acesso cross-user

- **Arquivo:** `supabase/functions/ultracontext-proxy/index.ts`
- **Descrição:** `contextOwners` é um `Map` em memória da edge function. Após cold start, o mapa está vazio e o check `if (owner && owner !== userId)` passa porque `owner` é `undefined`. Qualquer usuário autenticado acessa contextos de outros.
- **Impacto:** Vazamento de dados entre usuários.
- **Fix:** Sempre verificar ownership via metadata `user_id` da API UltraContext, ou armazenar ownership em tabela Supabase.

---

## MEDIUM

### M1 — `private_config` sem RLS

- **Arquivo:** `supabase/migrations/010_*.sql`
- **Descrição:** Tabela que armazena service role key depende apenas de `REVOKE ALL` em `anon`/`authenticated`. Sem RLS como segunda camada de defesa.
- **Fix:** `ALTER TABLE private_config ENABLE ROW LEVEL SECURITY;` com zero policies (deny all).

### M2 — UltraContext delete sem verificação de ownership

- **Arquivo:** `supabase/functions/ultracontext-proxy/index.ts`
- **Descrição:** A ação `delete` aceita `payload.ids` sem verificar que o usuário logado é dono dos contextos.
- **Fix:** Verificar ownership de cada ID antes de deletar.

### M3 — UltraContext `payload.id` sem validação de formato

- **Arquivo:** `supabase/functions/ultracontext-proxy/index.ts`
- **Descrição:** `payload.id` é usado diretamente em URL (`/contexts/${payload.id}`). Path traversal possível com `../`.
- **Fix:** Validar que `payload.id` é UUID antes de usar.

### M4 — `send-push` sem validação explícita de auth

- **Arquivo:** `supabase/functions/send-push/index.ts`
- **Descrição:** Depende da flag `--no-verify-jwt` do Supabase para auth. Sem validação explícita como `send-email` faz.
- **Fix:** Validar Authorization header contra service role key.

### M5 — `chat_messages` sem policies de UPDATE/DELETE

- **Arquivo:** `supabase/migrations/001_*.sql`
- **Descrição:** Tabela tem apenas SELECT e INSERT policies. Se o app precisar editar/deletar mensagens, não há policy.
- **Fix:** Adicionar policies ou documentar que é intencional (chat imutável).

### M6 — Token em query string no relay (legacy)

- **Arquivo:** `relay/src/index.ts:143`
- **Descrição:** Path legacy `?token=...` expõe JWT em logs de proxy, CDN e browser history.
- **Fix:** Remover path legacy. Usar apenas auth via primeiro message.

### M7 — Sem validação de Origin no WebSocket upgrade

- **Arquivo:** `relay/src/index.ts:141`
- **Descrição:** Qualquer site pode iniciar conexão WebSocket ao relay. Combinado com M6, um site malicioso com token roubado conecta imediatamente.
- **Fix:** Validar header `Origin` contra allowlist.

### M8 — LAN WebSocket usa `ws://` sem TLS

- **Arquivo:** `TarsyShared/Sources/TarsyShared/Networking/ConnectionManager.swift:139`
- **Descrição:** Conexões LAN usam `ws://` (plaintext). Auth tokens, sudo passwords, e dados de tela trafegam sem criptografia.
- **Fix:** Migrar para `wss://` com certificado self-signed gerado no Mac e pinned no iOS.

### M9 — Shell injection via idb text input

- **Arquivo:** `TarsymacOS/Sources/Stream/RemoteInputService.swift:437-441`
- **Descrição:** `runIdb` faz quoting com aspas duplas insuficiente antes de passar para `zsh -c`. Caracteres como `"`, `$`, backticks podem escapar.
- **Fix:** Usar `Process` com array args ou shell-escape adequado.

### M10 — Git checkout vulnerável a flag injection

- **Arquivo:** `TarsymacOS/Sources/DaemonManager.swift:2553`
- **Descrição:** `runGitCommand(["checkout", branch])` — branch como `--orphan=x` é interpretado como flag.
- **Fix:** Usar `["checkout", "--", branch]`.

### M11 — Sem Content Security Policy no WKWebView

- **Arquivo:** `TarsyiOS/Sources/Views/Components/WebBrowserView.swift:912-922`
- **Descrição:** WKWebView carrega conteúdo de dev servers sem restrições. Dev server comprometido executa JS arbitrário.
- **Fix:** Configurar `WKWebViewConfiguration` com content rules ou CSP headers.

### M12 — Sem PKCE explícito no GitHub OAuth

- **Arquivo:** `TarsyShared/Sources/TarsyShared/AuthManager.swift:134-153`
- **Descrição:** OAuth flow não passa `codeVerifier`/`codeChallenge` explicitamente. Pode depender do SDK fazê-lo.
- **Fix:** Verificar se `supabase-swift` v2+ habilita PKCE por default. Se não, passar parâmetros explícitos.

---

## LOW

### L1 — Porta 8642 binds em todas interfaces

- **Arquivo:** `TarsymacOS/Sources/Networking/WebSocketServer.swift:42`
- **Descrição:** `NWListener` binds em `0.0.0.0`, expondo o WebSocket se o Mac estiver sem firewall.
- **Fix:** Considerar bind apenas em interfaces locais ou documentar requisito de firewall.

### L2 — Clientes WS não-autenticados não são desconectados

- **Arquivo:** `TarsymacOS/Sources/Networking/WebSocketServer.swift:166-170`
- **Descrição:** Clientes que falham auth recebem `authFail` mas o loop continua. Podem flodar o server.
- **Fix:** Desconectar após `authFail`.

### L3 — Conexões relay não-autenticadas ficam abertas 120s

- **Arquivo:** `relay/src/index.ts:181-183`
- **Descrição:** Conexão sem auth fica aberta até idle timeout. Possível exaustão de recursos.
- **Fix:** Timeout de 5-10s para autenticação.

### L4 — `/health` expõe métricas sem auth

- **Arquivo:** `relay/src/index.ts:131-136`
- **Descrição:** Retorna contagem de máquinas e clientes conectados publicamente.
- **Fix:** Remover contagens ou requerer API key.

### L5 — Sudo password escrito em arquivo temp

- **Arquivo:** `TarsymacOS/Sources/SudoPasswordManager.swift:101-116`
- **Descrição:** Senha escrita em `/tmp/.sudo_wrap.XXXXXX/askpass` com `chmod 700`. Se o processo morrer, o arquivo persiste.
- **Fix:** Usar pipe anônimo em vez de arquivo.

### L6 — Keychain sem `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

- **Arquivo:** `TarsyiOS/Sources/Views/AppSettingsView.swift:556-592`
- **Descrição:** API keys armazenadas sem flag de device-only. Podem ser extraídas via backup.
- **Fix:** Adicionar `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

### L7 — Voice transcription sem sanitização (prompt injection)

- **Arquivo:** `TarsyiOS/Sources/Views/Components/VoiceInputManager.swift:119`
- **Descrição:** Transcrição de voz vai direto como mensagem para o AI agent sem sanitização. Áudio ambiente pode manipular o agente.
- **Fix:** Separar claramente user input de system directives.

### L8 — Supabase anon key hardcoded no source

- **Arquivo:** `TarsyShared/Sources/TarsyShared/Config.swift:5`
- **Descrição:** Key `sb_publishable_*` no código-fonte commitado. É publishable por design, mas não pode ser rotacionada sem novo release.
- **Fix:** Aceitável se RLS estiver sólido. Considerar xcconfig para rotação mais fácil.

### L9 — `push_tokens` sem policy de UPDATE

- **Arquivo:** `supabase/migrations/001_*.sql`
- **Descrição:** Sem UPDATE policy. Token refresh requer delete+insert.
- **Fix:** Adicionar UPDATE policy ou documentar como intencional.

### L10 — URL hardcoded do Supabase em trigger

- **Arquivo:** `supabase/migrations/010_*.sql:30`
- **Descrição:** `https://xtblbghhlkroskzljqcl.supabase.co/functions/v1/send-email` hardcoded no trigger.
- **Fix:** Ler URL de `private_config` ou usar variável de ambiente do Supabase.

---

## Componentes Auditados — Sem Problemas

| Componente | Status |
|-----------|--------|
| RLS em `machines`, `workspaces`, `agent_tasks`, `profiles` | PASS — scoped a `auth.uid()` |
| Edge function `delete-account` | PASS — valida JWT, só deleta própria conta |
| Edge function `send-email` | PASS — valida auth, escapa HTML |
| Git commands via `Process` com array args | PASS — sem shell interpolation |
| Todos os modelos `Codable` | PASS — defensivos, sem force-unwrap |
| `.gitignore` | PASS — cobre `.env`, `Secrets.xcconfig`, `.pem`, `.p12`, `.p8` |
| Nenhum secret commitado no git | PASS — confirmado via `git log` |
| Website (Next.js) | PASS — estático, sem secrets |
| Info.plist (ambas plataformas) | PASS — sem dados sensíveis |
| Relay user isolation | PASS — routing por `userId` do JWT |
| Chat rendering (SwiftUI `Text`) | PASS — sem XSS |

---

## Plano de Ação Prioritário

### Prioridade 1 — Eliminar CRITICAL + simplificar

1. **Deletar `MJPEGStreamServer.swift`** e migrar LAN para H.264 via WebSocket (porta 8642, já tem auth). Elimina C1 inteiro.

### Prioridade 2 — Fixes HIGH

2. **H1:** Verificar `user.id == machine.user_id` no WebSocket LAN auth
3. **H2/H3:** Sanitizar paths com `URL.standardized` + validação de prefixo
4. **H4:** Trocar `runShellCommand` por `Process` com array args para `gh`
5. **H5:** Criptografia E2E para sudo password
6. **H6:** Allowlist de hosts no proxy handler
7. **H7:** Server-side subscription validation
8. **H8:** Ownership persistente no UltraContext proxy

### Prioridade 3 — Fixes MEDIUM

9. Habilitar RLS em `private_config`
10. Ownership check no UltraContext delete
11. Validação UUID no UltraContext
12. Auth explícita no `send-push`
13. Remover legacy token-in-URL do relay
14. Validação de Origin no relay WebSocket
15. `wss://` na LAN
16. Fix quoting no idb
17. `["checkout", "--", branch]` no git
18. CSP no WKWebView
19. PKCE explícito no OAuth
