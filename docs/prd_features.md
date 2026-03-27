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
- **Continuar sessão Mac→iPhone:** via UltraContext open-source
- **UltraContext:** usar o código open-source, não o serviço hosted

---

## Camada 1: Push Notifications ✅ IMPLEMENTADO

**Prioridade:** Máxima — habilita o modo orchestrator

**Eventos que disparam push:**
1. Agent precisa de resposta (pergunta/permissão)
2. Agent terminou a task
3. Agent deu erro

### O que foi implementado
- iOS: `AppDelegate` com `didRegisterForRemoteNotificationsWithDeviceToken`, upsert token no Supabase
- iOS: entitlements com `aps-environment`, Push Notifications capability no `project.yml`
- iOS: `UNUserNotificationCenterDelegate` para mostrar banners em foreground
- macOS: `notifyAgentQuestion()` adicionado ao `PushNotificationService`
- macOS: `DaemonManager` chama push nos 3 eventos (question, complete, error) para ambos handlers (legacy claude + engine)
- Supabase: Edge Function `send-push` deployada (gera JWT APNs, envia HTTP/2)
- Supabase: tabela `push_tokens` já existia na migration 001
- APNs Key (p8) criada, secrets configurados, Database Webhook ativo

### Pendente
- [ ] **Deep link:** tap na notificação abre workspace/tab correto — falta `didReceive response:` no AppDelegate, metadata no payload da notificação, e routing na navigation

---

## Camada 2: Tasks Persistentes ✅ IMPLEMENTADO

**Prioridade:** Alta — dá visibilidade ao user do que está rodando

**Conceito:** Comando ao agent vira task persistente no Supabase que sobrevive ao app fechar/reabrir.

### O que foi implementado
- Supabase: migration `005_agent_tasks` com tabela, RLS, indexes, trigger updated_at
- TarsyShared: `AgentTask` model + `AgentTaskService` (CRUD, cleanup)
- macOS: `DaemonManager` cria tasks no `engineCreate` e atualiza status em `onComplete`/`onAskUser`
- iOS: `DashboardView` mostra seção "active tasks" com status visual (running/waiting/completed/error)

### Pendente
- [ ] Tap na task → navegar para o chat/workspace correspondente
- [ ] Atualizar task status para `running` quando user responde pergunta
- [ ] Criar task também para engines genéricos (Gemini, Codex, Aider), não só Claude

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

## Camada 4: Continuar sessão Mac → iPhone (UltraContext) ✅ IMPLEMENTADO

**Prioridade:** Média-alta — feature diferenciadora

### UltraContext — open-source
- **Repo:** [github.com/ultracontext/ultracontext](https://github.com/ultracontext/ultracontext) (Apache 2.0)
- **Stack:** JS/TS + Python SDKs, daemon Node.js ≥ 22

### O que foi implementado
- TarsyShared: `UltraContextClient` — REST client com models (`UltraContextSession`, `UltraContextMessage`), CRUD operations, configurable base URL + API key
- macOS: `UltraContextDaemon` — manages daemon lifecycle (`start`, `stop`, `status`, `isInstalled`, `findCLI`)
- macOS: `DaemonManager` inicia daemon automaticamente no boot se instalado
- macOS: WSAction `ultracontext:status` para iOS consultar status do daemon
- iOS: `ActiveSessionsView` — lista sessões capturadas, card com preview, detail view com mensagens
- iOS: Botão "sessions" no header do Dashboard

### Pendente
- [ ] **Configuração de API key do UltraContext** — adicionar campo nas settings (AppSettingsView)
- [ ] **Continuar sessão** — botão "continue" no detail view que cria tab e conecta ao agent no Mac
- [ ] **User precisa instalar UltraContext** — `npm install -g ultracontext` no Mac (step manual)

---

## Camada 5: Auto-detectar CLI agents ✅ COMPLETO

**Prioridade:** Alta (quick win) — melhora UX imediatamente

### O que foi implementado
- macOS: `AgentDetector` com `detectInstalledAgents()`, `agentPath(for:)`, `agentVersion(for:)`
- macOS: `DaemonManager` detecta no boot, envia via `WSPacket(action: .agentsDetected)`
- TarsyShared: `WSProtocol` com novos actions (`agents:detected`, `agent:settings`, `agent:settings_update`)
- iOS: `WorkspaceView` recebe packet `agents:detected`, parseia lista e armazena em `detectedAgents`
- iOS: seletor de nova tab (menu "+") filtra `ForEach(detectedAgents)` — mostra apenas engines instaladas no Mac

### Não implementado (nice-to-have)
- Sugerir instalação para engines não detectadas (mostrar link/instrução)

---

## Camada 6: Modo de permissão por agent ✅ COMPLETO

**Prioridade:** Alta — segurança + onboarding

### O que foi implementado
- TarsyShared: `AgentPermissionConfig` model com `load()`/`save()` via UserDefaults + `hasBeenConfigured`
- macOS: `ClaudeCodeSession` usa `permissionMode` — `--dangerously-skip-permissions` só quando `.dangerous`
- macOS: `GenericCLIEngine` usa `permissionMode` — Codex `full-auto`/`suggest`, Aider auto/safe
- macOS: `TerminalSessionManager` passa `permissionMode` nos creates
- macOS: `DaemonManager` lê `permissionMode` do payload do packet
- iOS: `PermissionOnboardingView` — tela de first-time setup (auto vs safe)
- iOS: `AppSettingsView` — toggle de permissão por agent
- iOS: `ContentView` — mostra onboarding na primeira vez via `fullScreenCover`
- iOS: sync com Supabase — `AppSettingsView` e `PermissionOnboardingView` chamam `profileService.updateAgentPermissions()` ao salvar

---

## Camada 7: Profiles ✅ IMPLEMENTADO

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

### Pendente
- [ ] **Sincronizar `SubscriptionManager` com profiles** — método `updateSubscription()` existe no ProfileService mas nunca é chamado pelo SubscriptionManager quando StoreKit confirma Pro
- [ ] **Usar `displayName`/`avatarUrl` na UI** — helpers existem no model (`nameOrEmail`) mas não são usados na dashboard header nem settings
- [ ] **macOS: carregar profile** — para puxar preferências do user (permissions, etc)

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

## Ordem de implementação (atualizada)

| # | Feature | Status | Próximo passo |
|---|---|---|---|
| 1 | Push Notifications | ✅ Operacional | Deep link (tap → workspace) |
| 2 | Auto-detectar agents | ✅ Completo | — |
| 3 | Permission mode per agent | ✅ Completo | — |
| 4 | Tasks persistentes | ✅ Implementado | Navegação tap→workspace, engines genéricos |
| 5 | Profiles | ✅ Implementado | Sync subscription, displayName na UI, macOS profile |
| 6 | Chat pagination | ✅ Completo | — |
| 7 | Estado por tab | ✅ Completo | — |
| 8 | Todo premature completion | ✅ Completo | — |
| 9 | Quick dispatch | ✅ Completo | — |
| 10 | UltraContext | ✅ Implementado | Config API key, botão "continue session" |

---

## Steps manuais pendentes

### Infraestrutura
- [ ] Instalar UltraContext no Mac: `npm install -g ultracontext`

### Já concluídos ✅
- [x] Apple Developer Portal: APNs Key (p8), Key ID + Team ID
- [x] Supabase secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID
- [x] Supabase Database Webhook: insert em `push_notifications` → Edge Function `send-push`
- [x] Sign In with Apple: capability habilitada, Service ID, return URLs no Supabase
- [x] Sign In with GitHub (OAuth): GitHub OAuth App criado, Client ID + Secret no Supabase Auth
- [x] Supabase Auth Providers: Apple e GitHub OAuth configurados no Dashboard

---

## Resumo de pendências de código

| Pendência | Camada | Esforço |
|-----------|--------|---------|
| Deep link: tap notificação → workspace | Push (1) | Médio |
| Tap task → navegar para workspace | Tasks (2) | Baixo |
| Task status → running ao responder | Tasks (2) | Baixo |
| Tasks para engines genéricos | Tasks (2) | Baixo |
| SubscriptionManager → profiles sync | Profiles (7) | Baixo |
| displayName/avatarUrl na UI | Profiles (7) | Baixo |
| macOS carregar profile | Profiles (7) | Médio |
| UltraContext API key nas settings | UltraContext (4) | Baixo |
| UltraContext "continue session" | UltraContext (4) | Médio |

---

## Referências

- [Conductor.build](https://www.conductor.build/) — macOS agent orchestrator, worktrees, code review
- [Addy Osmani: Future of Agentic Coding](https://addyosmani.com/blog/future-agentic-coding/) — conductor vs orchestrator patterns
- [UltraContext](https://github.com/ultracontext/ultracontext) — open-source context infra (Apache 2.0)
- [UltraContext Docs](https://ultracontext.ai/docs/api-reference/introduction) — API reference
- [Conductor Docs: Workflow](https://docs.conductor.build/workflow) — worktree lifecycle
