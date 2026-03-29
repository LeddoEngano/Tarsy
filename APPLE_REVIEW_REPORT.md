# Apple App Store Review — Tarsy iOS Readiness Report

**Data: 28 de março de 2026**
**App: Tarsy (com.tarsy.ios)**
**Versao atual: 0.1.0 (Build 1)**

---

## Resumo Executivo

O app esta ~75% pronto para submissao. Ha **4 bloqueios criticos** que causarao rejeicao imediata, **8 itens importantes** que provavelmente serao flagged pelo review, e **6 recomendacoes** de boas praticas. Este documento cobre iOS e macOS (companion app).

---

## CRITICO — Rejeicao Garantida

### 1. `UIRequiredDeviceCapabilities: armv7` — Rejeicao Imediata

**Arquivo:** `TarsyiOS/project.yml` (linha 32)
**Problema:** O projeto declara `armv7` como capability obrigatoria. ARMv7 foi descontinuado no iOS 11. Com deployment target iOS 17.0, isso e contraditoriao e a Apple rejeitara automaticamente.

**Fix:** Remover a key inteira ou trocar para `arm64`:
```yaml
UIRequiredDeviceCapabilities:
  - arm64
```

### 2. Privacy Manifest (PrivacyInfo.xcprivacy) — Ausente

**Problema:** Desde abril de 2024, a Apple **exige** um Privacy Manifest para apps que acessam "required reason APIs" (UserDefaults, file timestamp, etc.) e para declarar dados coletados. O Tarsy nao tem nenhum `PrivacyInfo.xcprivacy`.

**O que declarar no manifest:**
- `NSPrivacyTracking: false`
- `NSPrivacyTrackingDomains: []`
- `NSPrivacyCollectedDataTypes`: email, name, user ID, device ID, purchase history
- `NSPrivacyAccessedAPITypes`: UserDefaults (`NSPrivacyAccessedAPICategoryUserDefaults`), reason `CA92.1`

**Fix:** Criar `TarsyiOS/Sources/PrivacyInfo.xcprivacy` com todas as declaracoes. Tambem verificar se `supabase-swift` inclui o proprio manifest (se nao, declarar os APIs que ele usa).

### 3. `aps-environment: development` — Push Nao Funciona em Producao

**Arquivos:**
- `TarsyiOS/project.yml` (linha 59)
- `TarsyiOS/TarsyiOS.entitlements` (linha 9-10)

**Problema:** O entitlement de push esta em `development`. Em producao (App Store), push notifications simplesmente nao chegam. A Apple pode rejeitar se testar push e nao funcionar.

**Fix:** Mudar para `production` nos dois arquivos. O Xcode automaticamente usa `development` para Debug e `production` para Release se configurado corretamente via build settings, mas como esta hardcoded, precisa ser corrigido.

### 4. Login Obrigatorio Sem Demo/Explicacao — Guideline 5.1.1

**Arquivo:** `TarsyiOS/Sources/Views/LoginView.swift`

**Problema:** O app exige login imediato sem:
- Explicar o que o app faz (nenhum onboarding pre-login)
- Mostrar value proposition ou screenshots
- Oferecer modo demo/preview

A LoginView mostra apenas "TARSY" + "remote agent controller" + botoes de auth. O reviewer da Apple nao tem um Mac com o companion app instalado. Sem conseguir ver nada alem da tela de login, vai rejeitar por "insufficient functionality demonstrated" ou exigir conta demo.

**Fix (opcoes):**
1. **Conta demo no App Store Connect** — Fornecer credenciais de teste + video do fluxo
2. **Telas de onboarding pre-login** — 3-4 telas mostrando features antes do login
3. **Modo preview** — Permitir navegar pelo app com dados mockados antes de autenticar
4. **Video attachment** no review notes mostrando o fluxo completo iOS + macOS

**Recomendacao:** Implementar (1) + (2). Criar 3-4 onboarding pages com screenshots/animacoes mostrando: streaming remoto, AI chat, git safety net, file explorer. E fornecer conta demo no App Review Information.

---

## IMPORTANTE — Provavel Rejeicao ou Pedido de Correcao

### 5. Push Notification Pedida no App Launch — Guideline 5.1.1(iv)

**Arquivo:** `TarsyiOS/Sources/TarsyiOSApp.swift` (linha 17)

**Problema:** `UNUserNotificationCenter.requestAuthorization` e chamada em `didFinishLaunchingWithOptions`, ANTES de qualquer UI aparecer. O usuario ve o system dialog de push antes mesmo da splash screen. Apple exige que push seja pedida em contexto, com explicacao do valor.

**Fix:** Mover o request para DEPOIS do onboarding, idealmente quando o usuario cria o primeiro workspace ou realiza uma acao que justifique notificacoes. Adicionar uma tela pre-permissao explicando: "Get notified when your AI agent needs input or finishes a task".

### 6. Versao 0.1.0 — Sinal de Beta

**Arquivo:** `TarsyiOS/project.yml` (linhas 27-28)

**Problema:** `CFBundleShortVersionString: "0.1.0"` e `CFBundleVersion: "1"`. Versao 0.x sinaliza beta/pre-release. Reviewers podem questionar se o app esta pronto para producao.

**Fix:** Mudar para `1.0.0` (ou `1.0`) antes da submissao.

### 7. Nenhuma Tela Pre-Permissao para Microfone/Camera/Photos

**Problema:** O app pede permissoes de microfone e speech recognition diretamente via system dialog quando o usuario toca no botao de voz, sem explicacao previa. Camera e Photos tambem nao tem tela pre-permissao.

Apple raramente rejeita por isso sozinho, mas e uma best practice forte e melhora a taxa de aceitacao dos usuarios.

**Fix:** Adicionar "primer screens" antes de cada permissao critica:
- **Microfone/Speech:** "Tarsy uses your voice to send commands to AI agents. Audio is processed on-device and never stored."
- **Camera:** "Take a photo to share context with the AI agent."
- **Photos:** "Save screenshots from your remote stream."

### 8. Encryption Export Compliance — `ITSAppUsesNonExemptEncryption`

**Problema:** Nenhuma declaracao de `ITSAppUsesNonExemptEncryption` no Info.plist. O App Store Connect vai perguntar durante o upload se o app usa encryption. O Tarsy usa:
- TLS/WSS (standard)
- E2E encryption customizada (`E2ECrypto`)
- Self-signed TLS certificates no macOS companion

**Fix:** Adicionar ao Info.plist no project.yml:
```yaml
ITSAppUsesNonExemptEncryption: true
ITSEncryptionExportComplianceCode: ""  # Preencher com o codigo correto
```

O E2E encryption customizado provavelmente requer um ERN (Encryption Registration Number) ou auto-classificacao. Verificar se se qualifica para a excecao de "authentication/digital signatures" ou se precisa de classificacao BIS.

### 9. NSBonjourServices Ausente para Local Network

**Problema:** O app declara `NSLocalNetworkUsageDescription` e `NSAllowsLocalNetworking`, mas nao declara `NSBonjourServices`. Desde iOS 14, apps que acessam a rede local para qualquer coisa alem de HTTP/HTTPS devem declarar os servicos Bonjour ou o tipo de protocolo.

**Fix:** Se o app usa WebSocket direto (sem Bonjour), o `NSLocalNetworkUsageDescription` e suficiente. Mas se em algum momento faz discovery via Bonjour, precisa adicionar:
```yaml
NSBonjourServices:
  - _tarsy._tcp
```

Verificar se `Network.framework` NWBrowser ou NWListener usa Bonjour internamente.

### 10. Companion App Nao Sandboxed (macOS)

**Problema:** O macOS app tem `com.apple.security.app-sandbox: false`. Se for distribuido pela Mac App Store, sandbox e obrigatorio. Se for distribuido fora da App Store (website), precisa de notarizacao.

**Fix:** Decidir o canal de distribuicao do macOS:
- **Mac App Store:** Precisa sandboxar (complexo, dado que o app precisa de Screen Recording, Accessibility, file access)
- **Direct download (recomendado):** Notarizar via `xcrun notarytool` e distribuir pelo site. Mais flexivel para as permissoes necessarias.

### 11. Free Tier Muito Restritivo — Risco de Guideline 3.1.2(a)

**Problema:** Free tier permite apenas 1 workspace. Sem workspace, o app basicamente nao faz nada. Se o reviewer nao tiver um Mac com o companion app, ele ve: login → dashboard vazio → criar workspace → paywall (se tentar criar segundo). Apple pode considerar "app doesn't do enough in free tier".

**Fix:**
- Garantir que com 1 workspace free o reviewer consiga ver todas as features core (chat, stream, git, files)
- Na conta demo fornecida ao reviewer, ter 1 workspace pre-configurado com um repo
- Considerar permitir 2 workspaces no free tier durante o review inicial

### 12. Conteudo Gerado por IA — Guideline 4.7

**Problema:** Desde 2024, Apple exige que apps com AI generativo:
- Identifiquem claramente que o conteudo e gerado por IA
- Tenham mecanismo para reportar conteudo problematico
- Nao gerem conteudo objetionaavel

O Tarsy exibe respostas de AI agents (Claude, Gemini, etc.) diretamente no chat. Nao ha:
- Label "AI-generated" nas respostas
- Botao de report/feedback em mensagens
- Filtro de conteudo

**Fix:**
- Mensagens de AI ja vem com role `assistant` — garantir que o UI diferencia visualmente (icone de bot, label)
- Adicionar algum mecanismo de feedback (mesmo que simples, como long-press → "Report issue")
- Na App Review notes, explicar que o AI roda localmente no Mac do usuario e Tarsy e apenas o controle remoto

---

## RECOMENDACOES — Boas Praticas

### 13. App Store Screenshots e Metadata

Preparar antes da submissao:
- 6.5" screenshots (iPhone 15 Pro Max): 1290x2796
- 6.7" screenshots (iPhone 16 Pro Max): 1320x2868
- 5.5" screenshots (iPhone 8 Plus): 1242x2208 (se suportar)
- iPad screenshots se suportar iPad
- App preview video (30 segundos mostrando o fluxo)
- Descricao, keywords, categorias
- **Categoria sugerida:** Developer Tools (primary), Productivity (secondary)

### 14. Age Rating

O app deve ser marcado como **17+** ou pelo menos **12+** por:
- Acesso irrestrito a internet (via streaming e browser embutido)
- Execucao de comandos no sistema (via AI agents)
- Conteudo gerado por IA sem filtro

### 15. App Review Notes — Template Sugerido

```
Tarsy is a remote desktop + AI coding agent platform. The iOS app
connects to a companion macOS app to stream the desktop and interact
with AI coding agents.

DEMO ACCOUNT:
Email: reviewer@tarsy.dev
Password: [password]

TESTING REQUIREMENTS:
The macOS companion app must be running on a Mac for full functionality.
A demo workspace with a sample repository is pre-configured on this account.

The app uses end-to-end encryption for all communication between devices.
AI agents (Claude, Gemini, etc.) run locally on the user's Mac — Tarsy
only provides the remote control interface.

VIDEO WALKTHROUGH: [attach video showing full flow]
```

### 16. Localizacao

O app parece ser 100% em ingles. Se o mercado principal e Brasil, considerar adicionar portugues. Apple da prioridade a apps localizados nos mercados-alvo.

### 17. Accessibility (a11y)

Verificar antes da submissao:
- VoiceOver labels em todos os botoes e icones
- Dynamic Type support (fontes monospaced podem ter problemas)
- Contraste suficiente (TarsyTheme tem bom contraste, mas verificar com Accessibility Inspector)

### 18. App Icon

Verificar que `AppIcon.png` tem 1024x1024 sem transparencia e sem cantos arredondados (iOS aplica automaticamente). O asset catalog mostra apenas 1 arquivo — garantir que e suficiente para o Xcode gerar todos os tamanhos.

---

## Checklist de Submissao

| # | Item | Status | Prioridade |
|---|------|--------|-----------|
| 1 | Remover armv7 de UIRequiredDeviceCapabilities | Pendente | CRITICO |
| 2 | Criar PrivacyInfo.xcprivacy | Pendente | CRITICO |
| 3 | Mudar aps-environment para production | Pendente | CRITICO |
| 4 | Onboarding pre-login + conta demo | Pendente | CRITICO |
| 5 | Mover push permission para contexto | Pendente | IMPORTANTE |
| 6 | Versao 1.0.0 | Pendente | IMPORTANTE |
| 7 | Telas pre-permissao | Pendente | IMPORTANTE |
| 8 | Declarar encryption export compliance | Pendente | IMPORTANTE |
| 9 | Verificar NSBonjourServices | Pendente | IMPORTANTE |
| 10 | Decidir distribuicao macOS (App Store vs direct) | Pendente | IMPORTANTE |
| 11 | Garantir free tier demonstravel | Pendente | IMPORTANTE |
| 12 | AI content guidelines compliance | Pendente | IMPORTANTE |
| 13 | Screenshots e metadata do App Store | Pendente | RECOMENDADO |
| 14 | Definir age rating correto | Pendente | RECOMENDADO |
| 15 | Preparar App Review notes com conta demo | Pendente | RECOMENDADO |
| 16 | Avaliar localizacao pt-BR | Pendente | RECOMENDADO |
| 17 | Audit de accessibility (VoiceOver, Dynamic Type) | Pendente | RECOMENDADO |
| 18 | Validar app icon 1024x1024 | Pendente | RECOMENDADO |

---

## O Que JA Esta Correto

- StoreKit 2 implementado corretamente com server-side verification
- Restore Purchases acessivel no PaywallView e no ProfileView
- Terms of Use e Privacy Policy linkados no paywall e no perfil
- Delete Account implementado com confirmacao (digitar "DELETE")
- Manage Subscription redireciona para App Store settings
- Nenhum SDK de analytics/tracking (sem PostHog, Mixpanel, etc.)
- Nenhum metodo de pagamento externo
- Usage descriptions claras para todas as permissoes
- App Transport Security configurado corretamente (apenas local networking)
- Sign in with Apple implementado corretamente
- Push notification handling com deep linking
- Widget extension (Live Activities) configurada e embutida
- Dados nao sao vendidos ou compartilhados para ads
- Code signing automatico com team ID
