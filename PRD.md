# Tarsy - Product Requirements Document

> "Grandes olhos pra ver tudo que esta acontecendo" - Inspirado no Tarsier

## 1. Visao Geral

Tarsy e um sistema de dois apps nativos (iOS + macOS) que permite a um desenvolvedor controlar remotamente agentes de IA rodando no seu Mac. O usuario ve em tempo real o resultado visual do trabalho (browser, simulador iOS, terminal) e interage via chat com instancias de Claude Code e OpenClaw.

### Problema

Desenvolvedores que usam agentes de IA para codificar precisam estar na frente do computador para acompanhar o trabalho. Nao ha uma forma eficiente de:
- Disparar tasks de qualquer lugar
- Ver o resultado visual (UI/frontend) remotamente
- Manter contexto de IA por projeto sem depender de arquivos no repo

### Solucao

Dois apps Swift nativos que transformam o Mac do usuario em um server de desenvolvimento controlavel pelo iPhone, com streaming de video em tempo real e chat integrado com agentes de IA.

---

## 2. Arquitetura

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
  - Auth
  - User config
  - Workspace metadata
  - AI Context (CLAUDE.md remoto)
  - Chat history
```

### Stack

| Componente       | Tecnologia                          |
|------------------|-------------------------------------|
| Tarsy iOS        | Swift + SwiftUI                     |
| Tarsy macOS      | Swift + SwiftUI (menu bar app)      |
| Backend          | Supabase (Auth, DB, Realtime, Push) |
| Networking       | Tailscale (mesh VPN)                |
| Video Stream     | WebRTC via ScreenCaptureKit         |
| Terminal Mgmt    | tmux / CMUX                         |
| AI Agents        | Claude Code, OpenClaw               |

### Monorepo Swift

Um unico repositorio com targets compartilhados:
- `TarsyShared` - Models, Supabase client, networking, protocolos
- `TarsyiOS` - App iPhone
- `TarsymacOS` - App Mac (menu bar)

---

## 3. Telas - Tarsy iOS

### 3.1 Login

- Autenticacao via Supabase Auth
- Providers: email/senha, Apple Sign-In, Google Sign-In
- Primeiro acesso:
  - Cria conta
  - Pede Tailscale address do Mac (ou detecta automaticamente se ambos ja estao na mesma Tailnet)
  - Testa conexao com Tarsy macOS

### 3.2 Dashboard (Workspaces)

Lista de workspaces em cards. Cada card mostra:
- Nome do projeto (ex: "EDONext", "fitless-landing")
- Status: `idle` | `starting` | `agent running` | `awaiting review`
- Branch atual do git
- Ultimo comando executado
- PR aberta (se houver)

**Acoes:**
- Tap no card -> abre Tela de Trabalho (com cold start se necessario)
- Botao "+" -> cria novo workspace
- Swipe -> editar config / deletar

**Criar workspace do zero:**
1. User informa: nome, repo URL (git), stack (web/mobile/backend)
2. Tarsy macOS recebe o comando e:
   - Clona o repo
   - Instala dependencias (detecta package manager)
   - Configura ambiente
3. Workspace aparece no dashboard como `idle`

**Cold start:**
Ao tocar num workspace que esta `idle`:
1. Tarsy macOS abre terminal no diretorio do projeto
2. Levanta dev server (detecta o comando via config ou convencao)
3. Abre browser/simulador conforme a stack
4. Stream inicia automaticamente
5. Status muda para `starting` -> `agent running`

### 3.3 Tela de Trabalho

Dividida em duas areas:

#### Area Superior - Stream de Video

- Stream WebRTC em tempo real da janela relevante:
  - Stack web -> janela do browser (Chrome/Safari)
  - Stack mobile -> simulador iOS
  - Stack backend -> terminal/logs
- Controles overlay:
  - Fullscreen (expand stream)
  - Screenshot (salva localmente no iPhone)
  - Refresh (recarrega browser/simulador)
- Aspect ratio adaptavel
- Indicador de latencia

#### Area Inferior - Tabs

Sistema de tabs na parte inferior da tela:

**Tabs dinamicas (terminais):**
- Cada tab corresponde a um terminal real (tmux session) no Mac
- Interface de chat: user digita texto, agent responde
- Instancias de Claude Code rodando
- Historico de mensagens persistido no Supabase
- Botao "+" pra criar nova tab/session
- Swipe pra fechar tab

**Tab fixa - OpenClaw:**
- Tab sempre presente com icone distinto
- Integracao com OpenClaw (formato a definir - WebView ou API nativa)
- Separada das sessions de Claude Code

**Comportamento do chat:**
- Campo de texto com send button
- Suporta texto livre (comandos ou conversacao com o agent)
- Mensagens do agent aparecem em tempo real
- Scroll automatico com opcao de pausar
- O agent pode executar qualquer comando sem confirmacao

---

## 4. Tarsy macOS - Menu Bar App

### 4.1 Instalacao e Onboarding

1. User baixa Tarsy macOS (DMG ou Homebrew)
2. Abre o app -> tela de login (Supabase)
3. App verifica se Tailscale esta instalado
   - Se nao: instala automaticamente (`brew install tailscale` ou download direto)
   - Guia o user pelo setup do Tailscale (login, join tailnet)
4. App registra o Mac no Supabase (tailscale IP, hostname)
5. Icone aparece na menu bar -> app roda em background

### 4.2 Menu Bar

- Icone do Tarsy na menu bar
- Click mostra dropdown:
  - Status: online/offline
  - Workspaces ativos (com status)
  - CPU/Memory usage
  - Preferencias
  - Quit

### 4.3 Servicos Internos

O app macOS roda os seguintes servicos:

**Stream Server:**
- Usa ScreenCaptureKit (macOS 13+) pra capturar janelas especificas
- Encode via VideoToolbox (hardware H.264)
- Transmite via WebRTC para o app iOS
- Seletor inteligente de janela baseado no workspace config

**Terminal Manager:**
- Cria e gerencia tmux/CMUX sessions
- Spawna instancias de Claude Code CLI
- Spawna instancia de OpenClaw
- Injeta comandos recebidos do iOS nas sessions corretas
- Captura output e envia de volta

**Workspace Manager:**
- Clone de repos (git)
- Deteccao automatica de stack e package manager
- Instalacao de dependencias
- Start de dev servers
- Abertura de browsers/simuladores
- Cold start orchestration

**API Server (WebSocket):**
- Escuta conexoes do app iOS (via Tailscale)
- Protocolo:
  - `workspace:list` - lista workspaces
  - `workspace:create` - cria novo
  - `workspace:start` - cold start
  - `stream:start` - inicia captura de janela
  - `stream:stop` - para captura
  - `terminal:create` - nova session
  - `terminal:input` - envia comando
  - `terminal:output` - recebe output (realtime)
- Autenticacao via token Supabase

**Sync Service:**
- Mantem estado sincronizado com Supabase
- Envia push notifications via APNs (through Supabase) quando:
  - Agent completa uma task
  - PR criada
  - Build falhou
  - Erro critico

---

## 5. Supabase Schema

### Tables

```sql
-- Users
users (
  id uuid PK (supabase auth)
  email text
  display_name text
  created_at timestamp
)

-- Machines (Mac do user)
machines (
  id uuid PK
  user_id uuid FK -> users
  hostname text
  tailscale_ip text
  status text -- 'online' | 'offline'
  last_seen_at timestamp
  created_at timestamp
)

-- Workspaces
workspaces (
  id uuid PK
  user_id uuid FK -> users
  machine_id uuid FK -> machines
  name text
  repo_url text
  local_path text
  stack text -- 'web' | 'mobile' | 'backend' | 'fullstack'
  status text -- 'idle' | 'starting' | 'running' | 'error'
  current_branch text
  dev_server_command text
  ai_context text -- o "CLAUDE.md remoto"
  config jsonb -- configuracoes extras
  created_at timestamp
  updated_at timestamp
)

-- Chat History
chat_messages (
  id uuid PK
  workspace_id uuid FK -> workspaces
  tab_id text -- identificador da tab/session
  role text -- 'user' | 'assistant'
  content text
  created_at timestamp
)

-- Push notification tokens
push_tokens (
  id uuid PK
  user_id uuid FK -> users
  device_token text
  created_at timestamp
)
```

### Realtime

- Subscriptions em `workspaces` para status updates
- Subscriptions em `machines` para online/offline

### Row Level Security

- Cada user so ve seus proprios dados
- Policies baseadas em `auth.uid() = user_id`

---

## 6. Design Visual

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

---

## 7. Seguranca

- Toda comunicacao iOS <-> macOS via Tailscale (criptografada, WireGuard)
- Auth tokens Supabase validados em ambos os lados
- O Mac so aceita conexoes de devices na mesma Tailnet autenticados
- Chat history criptografado at rest no Supabase
- Nenhuma porta exposta na internet publica

---

## 8. Requisitos Tecnicos

### Tarsy iOS
- iOS 17+
- iPhone apenas (sem iPad por enquanto)
- Swift 5.9+
- SwiftUI
- Dependencias: Supabase Swift SDK, WebRTC framework

### Tarsy macOS
- macOS 14+ (Sonoma) - necessario para ScreenCaptureKit avancado
- Swift 5.9+
- SwiftUI
- Dependencias: Supabase Swift SDK, WebRTC, ScreenCaptureKit
- Permissoes: Screen Recording, Accessibility (pra controle de janelas)

---

## 9. Fases de Desenvolvimento

### Fase 1 - Foundation
- [ ] Setup monorepo Swift (Xcode project com targets iOS + macOS)
- [ ] Supabase setup (auth, tables, RLS)
- [ ] Login flow em ambos os apps
- [ ] Tailscale auto-install no macOS
- [ ] Conexao iOS <-> macOS via WebSocket sobre Tailscale

### Fase 2 - Workspaces
- [ ] CRUD de workspaces (Supabase + UI)
- [ ] Dashboard no iOS
- [ ] Workspace manager no macOS (clone, setup, cold start)
- [ ] AI Context editor

### Fase 3 - Stream
- [ ] ScreenCaptureKit captura de janela especifica
- [ ] WebRTC streaming macOS -> iOS
- [ ] Controles de stream (fullscreen, screenshot, refresh)
- [ ] Selecao inteligente de janela por stack

### Fase 4 - Terminais e Chat
- [ ] tmux session management no macOS
- [ ] Sistema de tabs no iOS
- [ ] Chat interface com persistencia no Supabase
- [ ] Integracao com Claude Code CLI
- [ ] Push notifications

### Fase 5 - OpenClaw
- [ ] Tab fixa do OpenClaw
- [ ] Integracao (formato a definir)

### Fase 6 - Polish
- [ ] Refinamento visual (design system completo)
- [ ] Performance tuning do stream
- [ ] Error handling e recovery
- [ ] Distribuicao (TestFlight + DMG/Homebrew)

---

## 10. Questoes em Aberto

1. **OpenClaw integration**: WebView, API nativa, ou embedd do terminal do OpenClaw?
2. **iPad support**: adicionar no futuro? (tela maior seria ideal pra stream)
3. **Android**: roadmap futuro com Kotlin/Compose?
4. **Colaboracao**: no futuro, permitir que dois devs vejam o mesmo workspace?
5. **Gravacao**: salvar replays das sessions pra review depois?
