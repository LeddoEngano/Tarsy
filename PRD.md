# Tarsy - Product Requirements Document

> "Grandes olhos pra ver tudo que esta acontecendo" - Inspirado no Tarsier

## 1. Visao Geral

Tarsy e um sistema de dois apps nativos (iOS + macOS) que transforma o iPhone em uma IDE mobile completa para controlar agentes de IA rodando no Mac. O usuario ve em tempo real o resultado visual do trabalho (browser, simulador iOS, terminal), interage via chat com multiplos provedores de IA, faz checkpoints do codigo, e faz tudo isso de qualquer lugar do mundo — da praia, do supermercado, do sofa.

### Problema

Desenvolvedores que usam agentes de IA para codificar precisam estar na frente do computador para acompanhar o trabalho. Nao ha uma forma eficiente de:
- Disparar tasks de qualquer lugar
- Ver o resultado visual (UI/frontend) remotamente
- Manter contexto de IA por projeto sem depender de arquivos no repo
- Ter seguranca de poder voltar atras quando algo quebra

### Solucao

Dois apps Swift nativos que transformam o Mac do usuario em um server de desenvolvimento controlavel pelo iPhone, com streaming de video em tempo real, chat integrado com multiplos agentes de IA, e ferramentas de safety net (checkpoints, diffs, rollback).

### Modelo de Negocio

- **Preco**: $9/mes (assinatura via App Store)
- **O que o user paga**: o app Tarsy (iOS + macOS)
- **O que o user traz**: suas proprias API keys dos provedores de IA (Claude, Gemini, OpenAI, etc)
- **BYOK (Bring Your Own Key)**: zero custo de LLM para o Tarsy
- **Free tier**: 1 workspace, todas as features (incluindo relay remoto)
- **Pro**: workspaces ilimitados
- **Sem trial**: o free tier ja permite experimentar o produto completo

---

## 2. Arquitetura

### Atual (v1)
```
[iPhone - Tarsy iOS]
  |
  | (Tailscale mesh VPN)
  |
[Mac - Tarsy macOS]
  |
  | (sync)
  |
[Supabase - Backend]
```

### Target (v2)
```
[iPhone - Tarsy iOS]
  |
  | (WebSocket over TLS)
  |
[Tarsy Tunnel] (transparente pro user)
  |
  | (persistent connection)
  |
[Mac - Tarsy macOS]
  |
  | (sync)
  |
[Supabase - Backend]
```

**Nota sobre tunneling**: O objetivo e que o user nunca saiba como a conexao funciona. Pode ser Tailscale embedded, WireGuard, relay proprio, ou qualquer outra tecnologia — o que importa e: login no Tarsy -> tudo conecta automaticamente. Zero config de rede.

### Stack

| Componente       | Tecnologia                          |
|------------------|-------------------------------------|
| Tarsy iOS        | Swift + SwiftUI                     |
| Tarsy macOS      | Swift + SwiftUI (menu bar app)      |
| Backend          | Supabase (Auth, DB, Realtime, Push) |
| Tunneling        | Transparente (Tailscale embedded / relay / WireGuard) |
| Payments         | RevenueCat + StoreKit 2             |
| Video Stream     | MJPEG (atual), WebRTC (futuro)      |
| Terminal Mgmt    | PTY sessions                        |
| AI Engines       | Claude Code (first-class), Gemini CLI, Codex CLI, Aider |

### Monorepo Swift

Um unico repositorio com targets compartilhados:
- `TarsyShared` - Models, Supabase client, networking, protocolos
- `TarsyiOS` - App iPhone
- `TarsymacOS` - App Mac (menu bar)

---

## 3. Features Existentes (v1 - Concluido)

### iOS
- [x] Login via Supabase Auth
- [x] Dashboard com workspaces em cards
- [x] Tela de trabalho: stream de video + chat
- [x] Sistema de tabs (multiplos terminais)
- [x] Chat com Claude Code (output em tempo real)
- [x] Interactive questions (multipla escolha, card paginado flutuante estilo Anthropic)
- [x] AI Context editor (CLAUDE.md remoto)
- [x] Thinking indicator e agent activity
- [x] Controle remoto: touch, swipe, pinch no stream
- [x] Push notifications (agent completa task, PR criada, etc)
- [x] Splash screen com animacao

### macOS
- [x] Menu bar app com status
- [x] WebSocket server para comunicacao com iOS
- [x] Screen capture (ScreenCaptureKit) com MJPEG streaming
- [x] Terminal session manager (PTY)
- [x] Claude Code session management
- [x] Remote input service (touch, drag, pinch via CGEvent)
- [x] Workspace orchestrator (clone, setup, cold start)
- [x] Deteccao de subnet (local vs Tailscale IP)
- [x] OpenClaw integration

---

## 4. Features Novas (v2 - MVP Comercial)

### 4.1 Tunneling Transparente

**Objetivo**: O user instala Tarsy, faz login, e tudo conecta. Zero config de rede, zero apps terceiros visiveis.

**Principio**: A tecnologia de tunnel e um detalhe de implementacao, nao um produto. O user nunca ve "Tailscale", "WireGuard", ou "relay" — so ve "conectado" ou "desconectado".

**Opcoes de implementacao** (a decidir):
- Tailscale embedded (SDK) — funciona, mas pode ter limitacoes de licenca
- Relay server proprio (Fly.io) — mais controle, mais trabalho
- WireGuard embedded — lightweight, open source
- Hibrido: LAN direta quando possivel, relay quando remoto

**Fluxo de onboarding**:
1. User instala Tarsy macOS, faz login
2. Conexao estabelecida automaticamente (background)
3. User instala Tarsy iOS, faz login
4. Ve seus workspaces imediatamente

**Requisitos**:
- Latencia aceitavel para stream de video (<200ms p95)
- Reconexao automatica quando muda de rede (wifi -> 4G -> wifi)
- Funcionar atras de NAT, firewalls corporativos, etc
- Zero configuracao pelo user

### 4.2 Multi-Provider (Claude first-class, outros suportados)

**Objetivo**: Tarsy nao e preso a um provider. Suporta qualquer CLI de agente de IA, mas Claude e o cidadao de primeira classe.

**Providers**:
| Provider    | CLI                | Nivel de suporte                       |
|-------------|--------------------|-----------------------------------------|
| Claude      | `claude`           | First-class: parser completo, interactive questions, thinking indicator, todas as features |
| Gemini      | `gemini`           | Suportado: output em tempo real, comandos basicos |
| Codex       | `codex`            | Suportado: output em tempo real, comandos basicos |
| Aider       | `aider`            | Suportado: output em tempo real, comandos basicos |
| Custom      | qualquer CLI       | User configura o comando, output raw    |

**Arquitetura**:
- `AIEngineProtocol` no macOS que abstrai o ciclo de vida de qualquer CLI:
  - `start(workingDir:)` -> spawna o processo
  - `send(message:)` -> envia input
  - `onOutput(_ handler:)` -> callback de output
  - `onAskUser(_ handler:)` -> callback de pergunta interativa (Claude-only inicialmente)
  - `stop()` -> mata o processo
- `ClaudeCodeEngine` (existente, refatorar) — parser rico
- `GenericCLIEngine` — parser basico que funciona pra Gemini/Codex/Aider/qualquer CLI
- iOS: selector de engine por workspace ou por tab

**Config no iOS**:
- Settings: user adiciona API keys por provider
- Keys ficam no Keychain do iOS e sao enviadas ao macOS sob demanda
- Workspace settings: escolhe qual engine usar como default
- Pode ter tabs com engines diferentes no mesmo workspace

### 4.3 Paywall ($9/mes)

**Objetivo**: Monetizar o app via assinatura mensal.

**Stack**: RevenueCat + StoreKit 2

**Modelo**:
- **Free**:
  - 1 workspace
  - Todos os engines
  - Relay/tunnel incluso
  - Todas as features (git, voice, MCPs, etc)
  - Sem limitacoes artificiais — o user experimenta o produto completo
- **Pro ($9/mes)**:
  - Workspaces ilimitados

**Gatilho do paywall**: user tenta criar o segundo workspace -> paywall hard. Nesse ponto o user ja sabe que o produto funciona e entrega valor.

**Implementacao**:
- RevenueCat SDK no iOS para gerenciar assinaturas
- Supabase armazena status da subscription (synced via webhook RevenueCat)
- Paywall screen com design clean, foco no valor ("Unlimited workspaces for all your projects")
- Restore purchases flow
- Sem trial — free tier ja e a experiencia completa

### 4.4 Git Safety Net (Checkpoints)

**Objetivo**: Dar seguranca pro dev experimentar com agentes de IA sem medo de quebrar o projeto. Nao e um git client completo — e uma safety net.

**Conceito**: Checkpoint = "aqui esta funcionando". O user salva o estado atual com um tap, experimenta a vontade, e pode voltar atras se algo quebrar.

**Features**:
- **Checkpoint** (botao principal): `git add -A && git commit -m "checkpoint"` com um tap
  - Icone de "shield" ou "save" sempre visivel
  - Feedback haptico ao salvar
  - Badge mostrando quantos arquivos foram salvos
- **Ver mudancas**: diff desde o ultimo checkpoint (o que mudou?)
  - Lista de arquivos modificados com +/- lines count
  - Tap no arquivo para ver diff (verde/vermelho)
- **Rollback**: voltar pro ultimo checkpoint se algo quebrou
  - Confirmacao antes de executar ("Isso vai desfazer X arquivos modificados")
- **Historico de checkpoints**: lista dos ultimos checkpoints com timestamp
- **Commit "de verdade"**: quando satisfeito, user pede pro Claude commitar e criar PR via chat (fluxo existente, nao precisa de UI nova)

**UI**:
- Botao de checkpoint flutuante ou na toolbar do workspace
- Sheet/modal para ver mudancas e historico
- Nao precisa de tab dedicada — e leve e acessivel de qualquer lugar

**Implementacao**:
- macOS: handlers WebSocket `git:checkpoint`, `git:diff`, `git:rollback`, `git:history`
- iOS: UI minimalista focada em seguranca, nao em git management

### 4.5 Voice to Text

**Objetivo**: Ditar prompts e comandos em vez de digitar. Essencial para uso no dia a dia quando o user esta longe do teclado.

**Implementacao**:
- Apple Speech framework (on-device, sem API externa, sem custo)
- Botao de microfone no input bar (hold to record, release to send)
- Preview do texto transcrito antes de enviar (editavel)
- Suporte a multiplos idiomas (detecta automatico)
- Funciona offline (on-device processing)

**UX**:
- Hold no mic -> gravando (feedback visual: onda de audio)
- Release -> mostra transcricao no campo de input (user pode editar antes de enviar)
- Tap no send -> envia
- Swipe down no mic (enquanto segura) -> cancela

### 4.6 MCP/Tool Store (Guided Setup)

**Objetivo**: Facilitar a configuracao de MCPs e ferramentas para o agente de IA. Iniciantes nao precisam editar JSON nem saber o que e um MCP.

**Conceito**: Uma "loja" curada de integracoes dentro do Tarsy. O user toca em "GitHub", faz auth, e pronto — o agente ja pode usar.

**Catalogo curado** (inicial):
| Integracao  | Auth necessario          | Taps estimados |
|-------------|--------------------------|----------------|
| Filesystem  | Nenhum                   | 1 (toggle)     |
| Browser     | Nenhum                   | 1 (toggle)     |
| GitHub      | OAuth                    | 2-3            |
| Slack       | OAuth                    | 2-3            |
| Linear      | API key (com link direto)| 2              |
| Jira        | API key                  | 2              |
| Sentry      | API key                  | 2              |
| Custom MCP  | User configura           | 3-4            |

**Fluxo por tipo de auth**:
- **Sem auth** (filesystem, browser): toggle on/off, one tap
- **OAuth** (GitHub, Slack): tap "Connect" -> abre browser -> auth -> volta pro app, automatico
- **API key** (Linear, Jira, Sentry): tap "Connect" -> tela com campo de key + link "Get your key here" -> cola -> salvo

**O que acontece por baixo**:
- Tarsy macOS recebe a config e escreve no `~/.claude.json` ou `claude_desktop_config.json` automaticamente
- Instala o MCP server se necessario (`npx`, `pip`, etc)
- Valida que esta funcionando (health check)
- User nunca ve um JSON

**UI**:
- Acessivel via workspace settings ou tab dedicada
- Grid/lista de integracoes com icones
- Status: "Connected" (verde), "Not configured" (cinza)
- Toggle pra ativar/desativar por workspace
- Detail view pra configurar auth

---

## 5. Telas - Tarsy iOS (v2)

### 5.1 Onboarding

1. Splash com animacao do Tarsier
2. "Welcome to Tarsy" - breve explicacao do produto
3. Login (Supabase Auth: email, Apple, Google)
4. "Install Tarsy on your Mac" - QR code ou link direto
5. Aguarda conexao automatica via tunnel
6. Dashboard (com 1 workspace free pra comecar)

### 5.2 Dashboard (atualizado)

Cards de workspace com informacoes adicionais:
- Engine ativo (icone: Claude/Gemini/Codex)
- Ultimo checkpoint (timestamp)
- Status do agente (idle/running/waiting)

Botao "+" pra criar workspace:
- Free: se ja tem 1 -> paywall
- Pro: cria normalmente

### 5.3 Workspace (atualizado)

Layout:
```
+---------------------------+
|     Stream de Video       |
|   (touch interativo)      |
+---------------------------+
| [Claude] [Term2] [+]     |  <- tabs
+---------------------------+
|                           |
|   Chat area               |
|                           |
|   [floating question card]|
+---------------------------+
| [mic] [input field] [send]|  <- input bar
|          [checkpoint btn] |  <- safety net
+---------------------------+
```

Novos elementos:
- Botao de checkpoint sempre acessivel
- Botao de mic no input bar
- Selector de engine no "+" (criar tab com engine diferente)

### 5.4 Settings

- **Account**: email, subscription status, manage subscription
- **AI Providers**: adicionar/remover API keys por provider
  - Cada provider com campo de key + instrucoes + link "Get key"
- **Integrations (MCPs)**: tool store com catalogo curado
- **About**: versao, links, support

---

## 6. Tunneling - Decisao Tecnica (a definir)

O tunneling e a feature mais critica do v2. A decisao de implementacao impacta:
- Latencia do stream
- Complexidade de onboarding
- Custo de infra
- Confiabilidade

### Opcoes

**Opcao A: Tailscale Embedded**
- Pro: ja funciona, battle-tested, NAT traversal excelente
- Contra: dependencia de terceiro, possivel custo de licenca pra uso embedded
- Viabilidade: investigar Tailscale SDK / headscale (open source)

**Opcao B: Relay Server Proprio**
- Pro: controle total, sem dependencias
- Contra: mais codigo pra manter, custo de infra, latencia do hop extra
- Stack: Fly.io + Hono/Bun, WS proxy puro

**Opcao C: WireGuard Embedded**
- Pro: open source, lightweight, protocolo provado
- Contra: precisa de coordination server pra NAT traversal
- Stack: WireGuard Go/Swift bindings + coordination server proprio

**Opcao D: Hibrido**
- LAN direta quando na mesma rede (melhor latencia)
- Relay/WireGuard quando remoto
- Pro: melhor experiencia possivel em cada cenario
- Contra: mais complexidade

### Requisitos independente da opcao
- Zero config pelo user
- Reconexao automatica
- Funcionar atras de NAT/firewall
- TLS/criptografia em todo o caminho
- Latencia <200ms p95 para stream

---

## 7. Supabase Schema (atualizado)

### Novas tabelas

```sql
-- Subscriptions
subscriptions (
  id uuid PK
  user_id uuid FK -> users
  revenue_cat_id text
  plan text -- 'free' | 'pro'
  status text -- 'active' | 'expired'
  current_period_ends_at timestamp
  created_at timestamp
  updated_at timestamp
)

-- API Keys (encrypted)
api_keys (
  id uuid PK
  user_id uuid FK -> users
  provider text -- 'anthropic' | 'google' | 'openai' | 'custom'
  encrypted_key text -- encrypted at rest
  created_at timestamp
)

-- MCP Configs
mcp_configs (
  id uuid PK
  workspace_id uuid FK -> workspaces
  name text
  type text -- 'browser' | 'filesystem' | 'github' | 'slack' | 'linear' | 'custom'
  config jsonb -- auth tokens, settings
  enabled boolean
  created_at timestamp
)
```

### Tabelas existentes
- `users`
- `machines`
- `workspaces` (adicionar campo `default_engine text`)
- `chat_messages`
- `push_tokens`

---

## 8. Design Visual

### Identidade

- **Dark mode only**
- Paleta inspirada nos tons terrosos do Claude Code, estetica anos 70
- Cores primarias: ambar, terracota, marrom quente
- Backgrounds: preto suave (#1a1a1a), cinza escuro (#2a2a2a)
- Textos: off-white (#e8e0d4), ambar (#d4a574)
- Acentos: terracota (#c4704b), verde musgo (#7a8b6f)
- Tipografia: monospace para terminais, sans-serif clean para UI
- Cantos arredondados, sombras suaves
- Icone do app: olhos do Tarsier estilizados

### Componentes

- Cards com bordas sutis em tons de ambar
- Tabs com indicador ativo em terracota
- Chat bubbles com fundo diferenciado por role
- Stream com borda sutil e cantos arredondados
- Status badges coloridos (verde=running, ambar=starting, cinza=idle)
- Interactive questions: card paginado flutuante estilo Anthropic
- Paywall: clean, sem overwhelm, uma unica proposta ("Unlimited workspaces")
- Checkpoint button: prominente, sensacao de seguranca
- Tool store: grid com icones, status claro (connected/not configured)

---

## 9. Seguranca

- Tunnel: criptografia end-to-end independente da tecnologia escolhida
- Auth tokens Supabase validados em todos os pontos (iOS, tunnel, macOS)
- API keys: criptografadas at rest no Supabase, Keychain no iOS
- MCP tokens: armazenados criptografados, enviados ao macOS sob demanda
- Conexao direta LAN quando possivel (menor superficie de ataque)
- Chat history criptografado at rest no Supabase
- RevenueCat: server-side validation de receipts

---

## 10. Fases de Desenvolvimento (v2)

### Fase 1 - Tunneling Transparente
- [ ] Investigar opcoes (Tailscale embedded vs relay vs WireGuard)
- [ ] Implementar solucao escolhida
- [ ] macOS: conectar automaticamente ao iniciar
- [ ] iOS: conectar via tunnel em vez de config manual
- [ ] Deteccao de LAN para conexao direta
- [ ] Reconexao automatica ao mudar de rede
- [ ] Testar latencia do stream

### Fase 2 - Multi-Provider
- [ ] Definir `AIEngineProtocol` no macOS
- [ ] Refatorar `ClaudeCodeSession` para implementar o protocolo
- [ ] Implementar `GenericCLIEngine` (funciona pra Gemini/Codex/Aider)
- [ ] iOS: selector de engine por tab/workspace
- [ ] iOS: tela de API keys no Settings
- [ ] Armazenamento seguro de keys (Keychain + Supabase encrypted)

### Fase 3 - Paywall
- [ ] Integrar RevenueCat SDK no iOS
- [ ] Configurar produto no App Store Connect ($9/mes)
- [ ] Paywall screen no iOS (aparece ao criar 2o workspace)
- [ ] Supabase: tabela de subscriptions + webhook RevenueCat
- [ ] Enforcar limite do free tier (1 workspace)
- [ ] Restore purchases flow

### Fase 4 - Voice to Text
- [ ] Integrar Apple Speech framework
- [ ] Botao de mic no input bar (hold to record)
- [ ] Preview de transcricao editavel
- [ ] Deteccao automatica de idioma

### Fase 5 - Git Safety Net (Checkpoints)
- [ ] macOS: handlers `git:checkpoint`, `git:diff`, `git:rollback`, `git:history`
- [ ] iOS: botao de checkpoint
- [ ] iOS: view de mudancas desde ultimo checkpoint
- [ ] iOS: rollback com confirmacao
- [ ] iOS: historico de checkpoints

### Fase 6 - MCP/Tool Store
- [ ] Definir catalogo inicial de integracoes
- [ ] macOS: auto-setup de MCPs (escreve config, instala server)
- [ ] iOS: UI de tool store (grid com icones)
- [ ] Fluxo de OAuth para GitHub, Slack
- [ ] Fluxo de API key para Linear, Jira, Sentry
- [ ] Health check de MCPs (validar que esta funcionando)

### Fase 7 - File Browser (nice to have)
- [ ] macOS: `file:tree` endpoint (respeita .gitignore)
- [ ] macOS: `file:read` endpoint
- [ ] iOS: TreeView com lazy loading
- [ ] File preview com syntax highlighting

### Fase 8 - Polish & Launch
- [ ] Performance tuning do stream
- [ ] Error handling e recovery robusto
- [ ] Onboarding flow completo
- [ ] App Store listing (screenshots, descricao, keywords)
- [ ] Landing page (tarsy.app)
- [ ] Distribuicao macOS (DMG + Homebrew)

---

## 11. Metricas de Sucesso

- **Onboarding completion rate**: % de users que completam setup (meta: >80%)
- **Free to paid conversion**: % de free users que fazem upgrade (meta: >20%)
- **DAU**: usuarios ativos diarios
- **Session duration**: tempo medio por sessao
- **Tunnel latency**: latencia p95 do stream (meta: <200ms)
- **Churn rate**: % de cancelamento mensal (meta: <8%)
- **Checkpoint usage**: % de sessions que usam checkpoint (indica confianca no produto)

---

## 12. Questoes em Aberto

1. **Tunneling**: qual tecnologia usar? (Tailscale embedded vs relay vs WireGuard vs hibrido)
2. **iPad support**: adicionar no futuro? (tela maior seria ideal pra stream)
3. **Android**: roadmap futuro com Kotlin/Compose?
4. **Colaboracao**: no futuro, permitir que dois devs vejam o mesmo workspace?
5. **Gravacao**: salvar replays das sessions pra review depois?
6. **Marketplace de MCPs**: abrir pra community contribuir integracoes?
7. **Self-hosted**: permitir que users enterprise rodem infra propria?
