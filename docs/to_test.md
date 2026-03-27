# Tarsy — Checklist de Testes

> Gerado em: 2026-03-27
> Referência: `docs/prd_features.md` (pendências resolvidas)

---

## 1. Push Notifications — Deep Link

- [ ] Receber push quando agent faz pergunta → tap abre o workspace correto
- [ ] Receber push quando agent completa task → tap abre o workspace correto
- [ ] Receber push quando agent dá erro → tap abre o workspace correto
- [ ] Push em foreground mostra banner e tap navega corretamente
- [ ] Push com app fechado (cold start) → abre direto no workspace certo
- [ ] Verificar que `workspace_id` está presente no payload APNs (migration 008)
- [ ] Testar com múltiplos workspaces — cada push leva ao workspace certo

## 2. Tasks Persistentes — Completude

- [ ] Dashboard mostra tasks ativas com status correto (running/waiting/completed/error)
- [ ] Tap na task no Dashboard → navega para o workspace/chat correspondente
- [ ] Responder pergunta do agent → task status muda de `waiting` para `running`
- [ ] Criar task com Claude Code → task aparece no Dashboard
- [ ] Criar task com Gemini CLI → task aparece no Dashboard
- [ ] Criar task com Codex CLI → task aparece no Dashboard
- [ ] Criar task com Aider → task aparece no Dashboard
- [ ] Fechar e reabrir o app → tasks persistem (Supabase)

## 3. Quick Dispatch

- [ ] Botão "bolt" visível no header do Dashboard
- [ ] Sheet abre com seletor de workspace + campo de comando
- [ ] Selecionar workspace, digitar comando, enviar → sheet fecha automaticamente
- [ ] Agent começa a executar o comando no Mac
- [ ] Push notification chega quando agent precisa de input
- [ ] Push notification chega quando agent termina

## 4. UltraContext — Sessões

- [ ] `AppSettingsView` → campo de API key do UltraContext aparece (SecureField)
- [ ] Salvar API key → persiste em UserDefaults, usado pelo client
- [ ] Botão "sessions" no header do Dashboard → abre `ActiveSessionsView`
- [ ] `ActiveSessionsView` lista sessões capturadas pelo daemon
- [ ] Tap numa sessão → abre detail view com mensagens
- [ ] Botão "continue session" no detail → cria tab Claude com contexto da sessão
- [ ] Verificar que daemon inicia automaticamente no boot do macOS (se instalado)
- [ ] `ultracontext:status` WSAction retorna status correto do daemon
- [ ] Testar com UltraContext hosted free tier (base URL correta)

## 5. Auto-detectar Agents

- [ ] macOS detecta agents instalados no boot (Claude, Gemini, Codex, Aider)
- [ ] iOS recebe packet `agents:detected` ao conectar
- [ ] Seletor de nova tab ("+") mostra apenas engines instaladas no Mac
- [ ] Engine não instalada no Mac NÃO aparece no seletor

## 6. Modo de Permissão por Agent

- [ ] `PermissionOnboardingView` aparece na primeira vez (fullScreenCover)
- [ ] Escolher "auto" → agents rodam com skip-permissions / full-auto
- [ ] Escolher "safe" → agents pedem confirmação
- [ ] `AppSettingsView` → toggle de permissão por agent funciona
- [ ] Salvar permissão → sincroniza com Supabase (profiles.agent_permissions)
- [ ] macOS: `DaemonManager` usa fallback do profile quando payload não tem permissionMode
- [ ] Claude Code: `--dangerously-skip-permissions` só aparece no modo `.dangerous`
- [ ] Codex: `full-auto` vs `suggest` respeita modo de permissão
- [ ] Aider: auto vs safe respeita modo de permissão

## 7. Profiles

- [ ] Novo user → profile criado automaticamente (trigger `on_auth_user_created`)
- [ ] User existente → profile existe (backfill)
- [ ] iOS carrega profile após autenticação
- [ ] `DashboardView` mostra avatar + nome/email do user
- [ ] `AppSettingsView` → seção "Profile" com avatar, nome editável, email
- [ ] Editar display name → salva no Supabase
- [ ] Alterar voice language → sincroniza com profiles
- [ ] `SubscriptionManager` confirma Pro → `syncWithProfile()` atualiza `is_pro`, `subscription_status`
- [ ] macOS: `DaemonManager` carrega profile no boot
- [ ] macOS: profile usado como fallback para permissões de agent

## 8. Chat Improvements

### 8a. Paginacao de mensagens
- [ ] Abrir workspace com muitas mensagens → carrega apenas ultimas 50
- [ ] Scroll up → botão "Load earlier messages" aparece
- [ ] Tap "Load earlier" → mensagens antigas carregam, scroll position preservado
- [ ] Workspace com < 50 mensagens → botão NÃO aparece

### 8b. Estado isolado por tab
- [ ] Agent da tab A faz pergunta → trocar para tab B → pergunta da tab A NÃO aparece
- [ ] Voltar para tab A → pergunta reaparece
- [ ] `isAgentThinking` isolado por tab
- [ ] `interactiveQuestions` isolado por tab
- [ ] `interactiveOptions` isolado por tab

### 8c. Todo/task premature completion fix
- [ ] Responder pergunta de multipla escolha → task NÃO marca como concluida prematuramente
- [ ] Agent continua trabalhando apos resposta → task permanece como `running`
- [ ] Agent realmente termina → task marca como `completed`
- [ ] Deferred completion (5s) funciona: se engineOutput chega, cancela completion

---

## Testes de integracao cross-platform

- [ ] Login com Apple no iOS → mesmo user no macOS
- [ ] Login com GitHub no iOS → mesmo user no macOS
- [ ] Login com email/password no iOS → mesmo user no macOS
- [ ] Permissões salvas no iOS → macOS respeita (via profile Supabase)
- [ ] Subscription confirmada no iOS → profile atualizado → macOS ve user como Pro

---

## Infraestrutura a verificar

- [ ] Migration 008 (workspace_id em push_notifications) deployada no Supabase
- [ ] Edge Function `send-push` atualizada com workspace_id no payload
- [ ] Database Webhook ativo para push_notifications
- [ ] UltraContext instalado no Mac (`npm install -g ultracontext`)
- [ ] APNs Key (p8) valida e secrets configurados no Supabase
