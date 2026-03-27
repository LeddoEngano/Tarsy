# Tarsy — PRD: Agent Orchestration & Platform Features

> Data: 2026-03-26
> Última atualização: 2026-03-27

## Contexto

O Tarsy hoje opera no modo "conductor" — o user acompanha 1 agent em real-time pelo iPhone. Queremos evoluir para suportar também o modo "orchestrator" — despachar tasks, sair do app, e ser notificado quando precisa intervir. O user usa ambos os modos dependendo do contexto (ex: na fila do supermercado quer despachar rápido; sentado no Mac quer acompanhar em real-time).

### Pesquisa realizada
- **Conductor.build** (by Melty Labs) — macOS agent orchestrator com worktrees isoladas, code review, merge
- **Padrões de mercado** — conductor (síncrono, 1 agent) vs orchestrator (assíncrono, múltiplos agents)
- **UltraContext** — open-source context infrastructure para continuidade de sessões entre devices

### Decisões tomadas
- **Worktrees:** NÃO agora (merge no iPhone é UX ruim, complexidade alta para mobile)
- **Task decomposition automática:** FUTURO (user define o que cada agent faz por enquanto)
- **Review de resultado:** via chat (sem diff viewer mobile dedicado)
- **Continuar sessão Mac→iPhone:** via UltraContext (hosted free tier, futuro substituir por solução própria)
- **UltraContext:** usando hosted free tier (500 MB, unlimited calls) — self-host não vale a pena agora (sem docs para backend)

---

## Camada 1: Push Notifications ✅ COMPLETO

**Prioridade:** Máxima — habilita o modo orchestrator

**Eventos que disparam push:**
1. Agent precisa de resposta (pergunta/permissão)
2. Agent terminou a task
3. Agent deu erro

### O que foi implementado
- iOS: `AppDelegate` com `didRegisterForRemoteNotificationsWithDeviceToken`, upsert token no Supabase
- iOS: entitlements com `aps-environment`, Push Notifications capability no `project.yml`
- iOS: `UNUserNotificationCenterDelegate` para mostrar banners em foreground
- iOS: `didReceive response:` handler para deep link — extrai `workspace_id` do payload e navega via `DeepLinkRouter`
- macOS: `PushNotificationService` aceita `workspaceId` em todos os métodos e passa no payload
- macOS: `DaemonManager` chama push nos 3 eventos (question, complete, error) com `workspaceId`
- Supabase: Edge Function `send-push` inclui `workspace_id` no payload APNs
- Supabase: migration `008_push_notifications_workspace_id` adiciona coluna `workspace_id`
- Supabase: tabela `push_tokens` já existia na migration 001
- APNs Key (p8) criada, secrets configurados, Database Webhook ativo

---

## Camada 2: Tasks Persistentes ✅ COMPLETO

**Prioridade:** Alta — dá visibilidade ao user do que está rodando

**Conceito:** Comando ao agent vira task persistente no Supabase que sobrevive ao app fechar/reabrir.

### O que foi implementado
- Supabase: migration `005_agent_tasks` com tabela, RLS, indexes, trigger updated_at
- TarsyShared: `AgentTask` model + `AgentTaskService` (CRUD, cleanup)
- macOS: `DaemonManager` cria tasks no `engineCreate` para Claude E engines genéricos (Gemini, Codex, Aider)
- macOS: `DaemonManager` atualiza status em `onComplete`/`onAskUser` e volta para `running` quando user responde
- iOS: `DashboardView` mostra seção "active tasks" com status visual (running/waiting/completed/error)
- iOS: tap na task navega para o workspace correspondente via `NavigationLink`

---

## Camada 3: Quick Dispatch ✅ COMPLETO

**Prioridade:** Média — reduz fricção do modo orchestrator

### O que foi implementado
- iOS: `QuickDispatchView` — sheet com seletor de workspace + campo de comando + botão dispatch
- iOS: Botão "bolt" no header do Dashboard (ao lado do "+")
- Envia `engineCreate` com message inicial diretamente, sem entrar na workspace
- Dismiss automático após envio — user volta ao dashboard
- Push notification quando agent precisa de input ou termina

---

## Camada 4: Continuar sessão Mac → iPhone (UltraContext) ✅ COMPLETO

**Prioridade:** Média-alta — feature diferenciadora

### UltraContext — hosted (free tier)
- **Repo:** [github.com/ultracontext/ultracontext](https://github.com/ultracontext/ultracontext) (Apache 2.0)
- **Stack:** JS/TS + Python SDKs, daemon Node.js ≥ 22
- **Plano:** Free tier (500 MB, unlimited calls). Futuro: substituir por solução própria.

### O que foi implementado
- TarsyShared: `UltraContextClient` — REST client com models (`UltraContextSession`, `UltraContextMessage`), CRUD operations, configurable base URL + API key
- macOS: `UltraContextDaemon` — manages daemon lifecycle (`start`, `stop`, `status`, `isInstalled`, `findCLI`)
- macOS: `DaemonManager` inicia daemon automaticamente no boot se instalado
- macOS: WSAction `ultracontext:status` para iOS consultar status do daemon
- iOS: `ActiveSessionsView` — lista sessões capturadas, card com preview, detail view com mensagens
- iOS: Botão "sessions" no header do Dashboard
- iOS: `AppSettingsView` — campo de API key do UltraContext (SecureField, salva em UserDefaults)
- iOS: `SessionDetailView` — botão "continue session" que cria tab Claude com contexto da sessão

---

## Camada 5: Auto-detectar CLI agents ✅ COMPLETO

**Prioridade:** Alta (quick win) — melhora UX imediatamente

### O que foi implementado
- macOS: `AgentDetector` com `detectInstalledAgents()`, `agentPath(for:)`, `agentVersion(for:)`
- macOS: `DaemonManager` detecta no boot, envia via `WSPacket(action: .agentsDetected)`
- TarsyShared: `WSProtocol` com novos actions (`agents:detected`, `agent:settings`, `agent:settings_update`)
- iOS: `WorkspaceView` recebe packet `agents:detected`, parseia lista e armazena em `detectedAgents`
- iOS: seletor de nova tab (menu "+") filtra `ForEach(detectedAgents)` — mostra apenas engines instaladas no Mac

### Nice-to-have (futuro)
- Sugerir instalação para engines não detectadas (mostrar link/instrução)

---

## Camada 6: Modo de permissão por agent ✅ COMPLETO

**Prioridade:** Alta — segurança + onboarding

### O que foi implementado
- TarsyShared: `AgentPermissionConfig` model com `load()`/`save()` via UserDefaults + `hasBeenConfigured`
- macOS: `ClaudeCodeSession` usa `permissionMode` — `--dangerously-skip-permissions` só quando `.dangerous`
- macOS: `GenericCLIEngine` usa `permissionMode` — Codex `full-auto`/`suggest`, Aider auto/safe
- macOS: `TerminalSessionManager` passa `permissionMode` nos creates
- macOS: `DaemonManager` lê `permissionMode` do payload, com fallback para profile do Supabase
- iOS: `PermissionOnboardingView` — tela de first-time setup (auto vs safe)
- iOS: `AppSettingsView` — toggle de permissão por agent
- iOS: `ContentView` — mostra onboarding na primeira vez via `fullScreenCover`
- iOS: sync com Supabase — `AppSettingsView` e `PermissionOnboardingView` chamam `profileService.updateAgentPermissions()` ao salvar

---

## Camada 7: Profiles ✅ COMPLETO

**Prioridade:** Alta — infraestrutura essencial

**Conceito:** Tabela `profiles` como source of truth para dados do user, preferências e status de subscription.

### O que foi implementado
- Supabase: migration `006_profiles` com tabela, RLS, trigger `on_auth_user_created`, backfill de users existentes
- Supabase: realtime habilitado na tabela profiles
- TarsyShared: `Profile` model com helpers (`nameOrEmail`, `permissionMode(for:)`)
- TarsyShared: `ProfileService` com CRUD (load, updateDisplayName, updateVoiceLanguage, updateAgentPermissions, updateSubscription, markOnboarded, ensureProfileExists)
- iOS: `ProfileService` injetado como environmentObject no app
- iOS: profile carregado automaticamente após autenticação
- iOS: `AgentPermissionConfig` sincroniza com `profiles.agent_permissions` via ProfileService
- iOS: `voice_language` sincroniza com profiles via `profileService.updateVoiceLanguage()` no AppSettingsView
- iOS: `SubscriptionManager` sincroniza com profiles via `syncWithProfile()` (chamado após `refreshStatus` e `handle(transactionResult:)`)
- iOS: `DashboardView` mostra avatar + nome/email do user abaixo do header
- iOS: `AppSettingsView` — seção "Profile" com avatar, nome editável, e email
- macOS: `DaemonManager` carrega profile no boot via `ProfileService`, usa como fallback para permissões

### Schema
```sql
profiles (
  id uuid PK → auth.users(id),
  email text,
  display_name text,
  avatar_url text,
  voice_language text default 'en',
  agent_permissions jsonb,
  is_pro boolean default false,
  subscription_status text (inactive|trial|active|cancelled),
  subscription_end_date timestamptz,
  onboarded boolean default false,
  created_at, updated_at
)
```

---

## Camada 8: Chat Improvements ✅ COMPLETO

**Prioridade:** Alta — performance e UX

### 8a. Paginação de mensagens

**Problema:** `ChatService.loadMessages()` carrega ALL mensagens do Supabase sem `.limit()`. Com conversas longas, trocar de tab fica lento.

**Solução:** Carregar últimas 50 mensagens, load more ao scroll up (estilo WhatsApp).

**Implementação:**
- `ChatService.loadMessages()`: adicionar `.order("created_at", ascending: false).limit(50)`, depois reverter array
- Novo método `loadOlderMessages()`: cursor com `created_at < oldestMessage.createdAt`
- Published var `hasMoreMessages: Bool`
- UI: botão "Load earlier messages" no topo do chat quando `hasMoreMessages == true`
- Preservar scroll position ao prepend de mensagens antigas

**Arquivos:**
- `TarsyShared/Sources/TarsyShared/Networking/ChatService.swift`
- `TarsyiOS/Sources/Views/WorkspaceView.swift` (chatArea)

### 8b. Estado isolado por tab

**Problema:** Estados `isAgentThinking`, `interactiveQuestions`, `interactiveOptions` são globais no `WorkspaceView`. Quando agent da tab A faz pergunta e user troca para tab B, a pergunta da tab A continua visível.

**Solução:** Salvar/restaurar esses estados ao trocar de tab.

**Implementação:**
- Criar struct `TabState` com `isThinking`, `questions`, `options`, `agentActivity`
- Dicionário `[String: TabState]` indexado por `tabId`
- Ao trocar tab: salvar estado atual, restaurar estado da nova tab

**Arquivos:**
- `TarsyiOS/Sources/Views/WorkspaceView.swift`

### 8c. Todo/task premature completion fix

**Problema:** Ao responder pergunta de múltipla escolha, o componente de tarefas às vezes marca como concluído prematuramente.

**Estado atual:** Guard de `resumedAt` aplicado no fallback de `markCompleted()`, mas o match primário (por sessionId exato) não tem guard.

**Solução proposta:** Deferred completion — após responder pergunta, defer `markCompleted` por 5s. Se `engineOutput` chegar nesse período, cancelar a completion (agent está trabalhando). Se não, executar.

**Implementação:**
- Adicionar `deferredCompletionTask: Task?` no `VoiceTodoManager`
- `markCompleted`: se item tem `resumedAt` recente, defer em vez de completar imediatamente
- Novo método `confirmWorking(sessionId:)` chamado por `handleEngineOutput` que cancela deferred completion
- Limpar `resumedAt` quando `engineOutput` chega (prova de vida do agent)

**Arquivos:**
- `TarsyiOS/Sources/Views/Components/VoiceTodoManager.swift`
- `TarsyiOS/Sources/Views/WorkspaceView.swift` (handleEngineOutput)

---

## Ordem de implementação (final)

| # | Feature | Status |
|---|---|---|
| 1 | Push Notifications | ✅ Completo |
| 2 | Auto-detectar agents | ✅ Completo |
| 3 | Permission mode per agent | ✅ Completo |
| 4 | Tasks persistentes | ✅ Completo |
| 5 | Profiles | ✅ Completo |
| 6 | Chat pagination | ✅ Completo |
| 7 | Estado por tab | ✅ Completo |
| 8 | Todo premature completion | ✅ Completo |
| 9 | Quick dispatch | ✅ Completo |
| 10 | UltraContext | ✅ Completo |

---

## Steps manuais — todos concluídos ✅

- [x] Apple Developer Portal: APNs Key (p8), Key ID + Team ID
- [x] Supabase secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID
- [x] Supabase Database Webhook: insert em `push_notifications` → Edge Function `send-push`
- [x] Sign In with Apple: capability habilitada, Service ID, return URLs no Supabase
- [x] Sign In with GitHub (OAuth): GitHub OAuth App criado, Client ID + Secret no Supabase Auth
- [x] Supabase Auth Providers: Apple e GitHub OAuth configurados no Dashboard
- [x] Instalar UltraContext no Mac: `npm install -g ultracontext`
- [x] Deploy migration 008 (workspace_id em push_notifications)
- [x] Deploy Edge Function `send-push` atualizada

---

## Nice-to-have (futuro)

- Sugerir instalação para engines não detectadas (link/instrução no seletor)
- Substituir UltraContext hosted por solução própria de continuidade de sessão
- Worktrees isoladas para agents (merge no iPhone, code review mobile)
- Task decomposition automática (user não precisa definir o que cada agent faz)

---

## Referências

- [Conductor.build](https://www.conductor.build/) — macOS agent orchestrator, worktrees, code review
- [Addy Osmani: Future of Agentic Coding](https://addyosmani.com/blog/future-agentic-coding/) — conductor vs orchestrator patterns
- [UltraContext](https://github.com/ultracontext/ultracontext) — open-source context infra (Apache 2.0)
- [UltraContext Docs](https://ultracontext.ai/docs/api-reference/introduction) — API reference
- [Conductor Docs: Workflow](https://docs.conductor.build/workflow) — worktree lifecycle
