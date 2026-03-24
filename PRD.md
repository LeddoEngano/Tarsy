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
- Revisar codigo gerado pelo agent sem abrir o laptop

### Solucao

Dois apps Swift nativos que transformam o Mac do usuario em um server de desenvolvimento controlavel pelo iPhone, com streaming de video em tempo real, chat integrado com multiplos agentes de IA, ferramentas de safety net (checkpoints, diffs, rollback), file explorer com syntax highlighting, e voice input.

### Modelo de Negocio

- **Preco**: $9/mes (assinatura via App Store)
- **O que o user paga**: o app Tarsy (iOS + macOS)
- **O que o user traz**: seus proprios CLIs de IA ja configurados no Mac (Claude Code, Gemini, Codex, Aider)
- **Zero custo de LLM para o Tarsy**: os CLIs usam a autenticacao que ja esta no Mac do user
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

## 4. Features v2 - Implementadas

### 4.1 Multi-Provider (Claude first-class, outros suportados) [DONE]

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
- `AIEngineProtocol` no macOS que abstrai o ciclo de vida de qualquer CLI
- `ClaudeCodeSession` implementa o protocolo com parser rico
- `GenericCLIEngine` implementa o protocolo com output basico (funciona pra qualquer CLI)
- iOS: menu selector de engine ao criar nova tab (Claude, Gemini, Codex, Aider)
- Protocolo `engine:create/message/output/complete/close/ask_user/user_response`

**Nota sobre API Keys**: Os CLIs de IA usam a autenticacao ja configurada no Mac (ex: `claude login`, env vars). O iOS nao precisa gerenciar keys — so envia comandos, o Mac executa.

### 4.2 Git (Checkpoints + Safety Net) [DONE]

**Objetivo**: Dar seguranca pro dev experimentar com agentes de IA sem medo de quebrar o projeto.

**Features implementadas**:
- **Checkpoint com 1 tap**: botao na toolbar com icone de shield+branch. `git add -A && git commit` com feedback haptico e toast animado
- **Aba Changes**: lista de arquivos modificados com status colorido (M=ambar, A=verde, D=vermelho)
- **Aba History**: ultimos 30 commits com hash, mensagem, data relativa. Checkpoints marcados com icone
- **Rollback**: tap num commit na history -> confirmation dialog -> `git reset --hard`
- **UI**: acessivel via menu "..." > "Git" (icone de branch) ou botao de checkpoint na toolbar

**Protocolo WebSocket**: `git:checkpoint`, `git:diff`, `git:rollback`, `git:history` + respectivos results

### 4.3 Voice to Text [DONE]

**Objetivo**: Ditar prompts e comandos em vez de digitar.

**Implementacao**:
- Apple Speech framework (on-device quando disponivel)
- Botao de microfone na input bar (tap to record, tap to stop)
- Transcricao inserida no campo de input (editavel antes de enviar)
- Deteccao automatica de idioma
- Icone pulsa em vermelho enquanto grava

### 4.4 App Settings [DONE]

- Tela de settings acessivel via icone de gear no Dashboard
- Secao About com versao do app

---

## 5. Features v2 - A Implementar

### 5.1 Tunneling Transparente

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

### 5.2 Git - Diff Viewer e Branch Management

**Objetivo**: Expandir o Git para que o user possa revisar codigo e gerenciar branches pelo iPhone.

**Diff Viewer** (dentro da aba Changes do Git):
- Tap num arquivo modificado -> abre diff estilo GitHub
- Mostra apenas os **hunks** (trechos que mudaram) com 3 linhas de contexto ao redor
- Linhas adicionadas em verde, removidas em vermelho
- Numero da linha a esquerda
- Scroll vertical, font monospaced
- Compacto para tela de iPhone — nao mostra o arquivo inteiro

**Branch Management**:
- Lista de branches locais e remotas
- Trocar de branch com tap
- Indicador da branch atual
- **Pull com 1 tap**: icone de seta pra baixo ao lado do nome da branch na info bar

**Implementacao**:
- macOS: novos handlers `git:branches`, `git:checkout`, `git:pull`, `git:file_diff`
- iOS: UI integrada na tela de Git existente

### 5.3 File Explorer

**Objetivo**: Navegar e ler qualquer arquivo do projeto pelo iPhone. Essencial quando o chefe pede uma informacao que esta num arquivo, ou pra entender a estrutura do projeto.

**Acesso**: Menu "..." do workspace > "File Explorer"

**Features**:
- **Tree view**: navegacao por pastas com lazy loading
- **Respeita .gitignore**: nao mostra node_modules, .git, etc
- **Search**: busca por **nome de arquivo** (filtro em tempo real na arvore)
- **File preview**: abre arquivo com **syntax highlighting** por linguagem (Swift, JS, Python, TS, JSON, etc)
- **Read-only**: sem edicao — o agent faz isso

**UI**:
- Tela fullscreen com barra de search no topo
- Lista de pastas/arquivos com icones por tipo
- Pastas expandem ao tocar
- Tap no arquivo abre preview com syntax highlighting
- Back button pra voltar a arvore

**Implementacao**:
- macOS: handlers `file:tree` (respeita .gitignore), `file:read`
- `file:tree` retorna arvore JSON com nome, tipo (file/dir), path, tamanho
- `file:read` retorna conteudo do arquivo + linguagem detectada pela extensao
- iOS: TreeView com lazy loading + syntax highlighted preview
- Syntax highlighting: usar lib como `Splash` ou `Highlightr` para Swift

### 5.4 Info Bar (Status do Workspace)

**Objetivo**: Mostrar informacoes importantes do workspace de forma compacta e acessivel, sem ocupar espaco.

**Posicao**: Barra fina abaixo do campo de input.

**Layout**:
```
 main ↓  |  Claude Code - Opus 4.6  |  45% ctx
```

**Elementos**:
- **Branch atual** + icone de seta pra baixo (↓): tap na seta faz `git pull` na branch atual. Tap no nome da branch abre branch switcher
- **Engine + modelo**: mostra o engine ativo e o modelo especifico (ex: "Claude Code - Opus 4.6", "Gemini - 2.0 Flash")
- **Context window %**: porcentagem de uso da janela de contexto do modelo

**Obtencao dos dados**:
- **Branch**: via `git rev-parse --abbrev-ref HEAD` (ja existe no workspace)
- **Engine/modelo**: Claude Code emite no stream-json metadata do modelo. Parsear campo `model` dos eventos
- **Context %**: Claude Code emite eventos `usage` com `input_tokens` e `output_tokens`. Calcular `total / context_window_size * 100`. Contexto window size por modelo e conhecido (200k para Sonnet, 1M para Opus, etc)
- **Para engines genericos** (Gemini, Codex): mostrar engine name sem modelo/context por enquanto. Investigar no futuro

**Implementacao**:
- macOS: parsear eventos `usage` e `model` do stream-json, enviar via novo WSAction `engine:status`
- iOS: barra compacta com 3 seções, tap actions para pull e branch switch

### 5.5 Paywall ($9/mes)

**Objetivo**: Monetizar o app via assinatura mensal.

**Stack**: RevenueCat + StoreKit 2

**Modelo**:
- **Free**:
  - 1 workspace
  - Todos os engines
  - Relay/tunnel incluso
  - Todas as features (git, voice, file explorer, etc)
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

### 5.6 MCP/Tool Store (Guided Setup)

**Objetivo**: Facilitar a configuracao de MCPs e ferramentas para o agente de IA. Iniciantes nao precisam editar JSON nem saber o que e um MCP.

**Conceito**: Uma "loja" curada de integracoes dentro do Tarsy. O user toca em "GitHub", faz auth, e pronto — o agente ja pode usar. O processo deve ser o mais simples possivel — idealmente one tap para integracoes sem auth.

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

## 6. Telas - Tarsy iOS (v2)

### 6.1 Onboarding

1. Splash com animacao do Tarsier
2. "Welcome to Tarsy" - breve explicacao do produto
3. Login (Supabase Auth: email, Apple, Google)
4. "Install Tarsy on your Mac" - QR code ou link direto
5. Aguarda conexao automatica via tunnel
6. Dashboard (com 1 workspace free pra comecar)

### 6.2 Dashboard (atualizado)

Cards de workspace com informacoes adicionais:
- Engine ativo (icone: Claude/Gemini/Codex)
- Ultimo checkpoint (timestamp)
- Status do agente (idle/running/waiting)

Header:
- "TARSY" + mac online/offline status
- Botoes: "+" (novo workspace), gear (settings), sign out

Botao "+" pra criar workspace:
- Free: se ja tem 1 -> paywall
- Pro: cria normalmente

### 6.3 Workspace (atualizado)

Layout:
```
+---------------------------+
|     Stream de Video       |
|   (touch interativo)      |
+---------------------------+
| [Claude▼][Gemini][+]     |  <- tabs (+ abre menu de engines)
+---------------------------+
|                           |
|   Chat area               |
|                           |
|   [floating question card]|
+---------------------------+
| [+][mic] [input field][^] |  <- input bar
| main↓ | Opus 4.6 | 45%ctx|  <- info bar
+---------------------------+
```

Toolbar:
- Titulo: nome do workspace + status
- Botao shield+branch: checkpoint com 1 tap
- Menu "...": Git, File Explorer, AI Context, Settings

### 6.4 Git (sheet)

- **Icone**: branch (nao shield)
- **Aba Changes**: lista de arquivos modificados. Tap no arquivo -> diff viewer (hunks com contexto)
- **Aba History**: commits com hash, mensagem, data. Tap -> rollback com confirmacao
- **Branch switcher**: lista de branches, tap pra trocar
- **Botao checkpoint**: no topo do sheet

### 6.5 File Explorer (tela separada)

- Barra de search no topo (busca por nome de arquivo)
- Tree view de pastas/arquivos
- Tap em pasta -> expande
- Tap em arquivo -> preview com syntax highlighting
- Read-only
- Respeita .gitignore

### 6.6 Settings

- **Account**: email, subscription status, manage subscription
- **Integrations (MCPs)**: tool store com catalogo curado
- **About**: versao, links, support

---

## 7. Tunneling - Decisao Tecnica (a definir)

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

## 8. Supabase Schema (atualizado)

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

## 9. Design Visual

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
- Git: icone de branch, checkpoint button com shield+branch
- Info bar: compacta, monospaced, 3 secoes separadas por |
- File Explorer: tree view com icones por tipo de arquivo
- Diff viewer: verde/vermelho estilo GitHub, hunks compactos
- Tool store: grid com icones, status claro (connected/not configured)

---

## 10. Seguranca

- Tunnel: criptografia end-to-end independente da tecnologia escolhida
- Auth tokens Supabase validados em todos os pontos (iOS, tunnel, macOS)
- MCP tokens: armazenados criptografados, enviados ao macOS sob demanda
- Conexao direta LAN quando possivel (menor superficie de ataque)
- Chat history criptografado at rest no Supabase
- RevenueCat: server-side validation de receipts
- File Explorer: read-only, respeita .gitignore (nao expoe arquivos sensiveis)

---

## 11. Fases de Desenvolvimento (v2)

### Fase 1 - Tunneling Transparente
- [ ] Investigar opcoes (Tailscale embedded vs relay vs WireGuard)
- [ ] Implementar solucao escolhida
- [ ] macOS: conectar automaticamente ao iniciar
- [ ] iOS: conectar via tunnel em vez de config manual
- [ ] Deteccao de LAN para conexao direta
- [ ] Reconexao automatica ao mudar de rede
- [ ] Testar latencia do stream

### Fase 2 - Multi-Provider [DONE]
- [x] Definir `AIEngineProtocol` no macOS
- [x] Refatorar `ClaudeCodeSession` para implementar o protocolo
- [x] Implementar `GenericCLIEngine` (funciona pra Gemini/Codex/Aider)
- [x] iOS: selector de engine por tab (menu no +)
- [x] Protocolo `engine:*` no WebSocket

### Fase 3 - Git [PARCIAL]
- [x] macOS: handlers `git:checkpoint`, `git:diff`, `git:rollback`, `git:history`
- [x] iOS: botao de checkpoint com feedback
- [x] iOS: aba Changes (lista de arquivos modificados)
- [x] iOS: aba History com rollback
- [ ] iOS: diff viewer por hunks (tap no arquivo -> diff estilo GitHub)
- [ ] iOS: branch switcher (lista branches, trocar, pull)
- [ ] Renomear para "Git" com icone de branch
- [ ] Icone de checkpoint: shield com mini branch

### Fase 4 - Voice to Text [DONE]
- [x] Integrar Apple Speech framework
- [x] Botao de mic na input bar
- [x] Transcricao inserida no campo de input
- [x] Deteccao automatica de idioma

### Fase 5 - File Explorer
- [ ] macOS: handler `file:tree` (respeita .gitignore)
- [ ] macOS: handler `file:read` (retorna conteudo + linguagem)
- [ ] iOS: TreeView com lazy loading
- [ ] iOS: search por nome de arquivo
- [ ] iOS: file preview com syntax highlighting
- [ ] Acessivel via menu "..." > "File Explorer"

### Fase 6 - Info Bar
- [ ] macOS: parsear eventos `usage` e `model` do stream-json do Claude Code
- [ ] macOS: enviar `engine:status` com model, tokens, context %
- [ ] iOS: info bar abaixo do input (branch ↓ | engine - model | ctx %)
- [ ] iOS: tap na seta da branch -> git pull
- [ ] iOS: tap no nome da branch -> branch switcher

### Fase 7 - Paywall
- [ ] Integrar RevenueCat SDK no iOS
- [ ] Configurar produto no App Store Connect ($9/mes)
- [ ] Paywall screen no iOS (aparece ao criar 2o workspace)
- [ ] Supabase: tabela de subscriptions + webhook RevenueCat
- [ ] Enforcar limite do free tier (1 workspace)
- [ ] Restore purchases flow

### Fase 8 - MCP/Tool Store
- [ ] Definir catalogo inicial de integracoes
- [ ] macOS: auto-setup de MCPs (escreve config, instala server)
- [ ] iOS: UI de tool store (grid com icones)
- [ ] Fluxo de OAuth para GitHub, Slack
- [ ] Fluxo de API key para Linear, Jira, Sentry
- [ ] Health check de MCPs (validar que esta funcionando)

### Fase 9 - Polish & Launch
- [ ] Performance tuning do stream
- [ ] Error handling e recovery robusto
- [ ] Onboarding flow completo
- [ ] App Store listing (screenshots, descricao, keywords)
- [ ] Landing page (tarsy.app)
- [ ] Distribuicao macOS (DMG + Homebrew)

---

## 12. Metricas de Sucesso

- **Onboarding completion rate**: % de users que completam setup (meta: >80%)
- **Free to paid conversion**: % de free users que fazem upgrade (meta: >20%)
- **DAU**: usuarios ativos diarios
- **Session duration**: tempo medio por sessao
- **Tunnel latency**: latencia p95 do stream (meta: <200ms)
- **Churn rate**: % de cancelamento mensal (meta: <8%)
- **Checkpoint usage**: % de sessions que usam checkpoint (indica confianca no produto)
- **File Explorer usage**: % de sessions que abrem file explorer (indica review de codigo)

---

## 13. Questoes em Aberto

1. **Tunneling**: qual tecnologia usar? (Tailscale embedded vs relay vs WireGuard vs hibrido)
2. **iPad support**: adicionar no futuro? (tela maior seria ideal pra stream)
3. **Android**: roadmap futuro com Kotlin/Compose?
4. **Colaboracao**: no futuro, permitir que dois devs vejam o mesmo workspace?
5. **Gravacao**: salvar replays das sessions pra review depois?
6. **Marketplace de MCPs**: abrir pra community contribuir integracoes?
7. **Self-hosted**: permitir que users enterprise rodem infra propria?
8. **Context window para engines genericos**: Gemini/Codex expõem token usage de forma estruturada?
