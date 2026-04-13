import styles from "../../legal.module.css";

export const metadata = {
  title: "Privacy Policy",
  description:
    "How Tarsy handles your data. End-to-end encrypted screen streaming, no tracking, no third-party analytics. LGPD, GDPR, and CCPA compliant.",
  alternates: {
    canonical: "https://www.tarsy.dev/privacy",
  },
};

export default function Privacy() {
  return (
    <div className={styles.page}>
      <h1>PRIVACY POLICY</h1>
      <p className={styles.lastUpdated}>Last updated: March 28, 2026</p>

      <p>
        OPALLOO INOVACOES LTDA, registered under CNPJ 53.284.020/0001-06,
        located at Avenida Brigadeiro Faria Lima, 1811 - Cj 115, Jardim
        America, CEP 01452-001, São Paulo - SP, Brazil (&quot;Tarsy&quot;,
        &quot;we&quot;, &quot;us&quot;, or &quot;our&quot;) operates the Tarsy
        iOS application, the Tarsy macOS companion application, the relay
        server infrastructure, and the website at{" "}
        <a href="https://tarsy.dev">tarsy.dev</a> (collectively, the
        &quot;Service&quot;).
      </p>
      <p>
        This Privacy Policy explains what information we collect, how we use
        and share it, and your choices regarding your information. By using the
        Service, you acknowledge that you have read and understood this Privacy
        Policy. This Privacy Policy is incorporated into and subject to our{" "}
        <a href="/terms">Terms of Use</a>.
      </p>

      <h2>1. Information We Collect</h2>

      <h3>1.1 Account Information</h3>
      <p>When you create an account, we collect:</p>
      <ul>
        <li>
          <strong>Email address</strong> (provided directly or obtained from
          your Apple ID or GitHub account)
        </li>
        <li>
          <strong>Display name</strong> and <strong>avatar URL</strong>{" "}
          (obtained from your Apple ID or GitHub profile, or provided by you
          during onboarding when we ask how you would like to be called — used
          solely to personalize your in-app experience)
        </li>
        <li>
          <strong>Authentication credentials</strong> — passwords are hashed
          and managed by our authentication provider (Supabase). We never store
          plaintext passwords. If you sign in via Apple or GitHub, we receive
          only an authentication token and basic profile information from those
          providers.
        </li>
      </ul>

      <h3>1.2 Profile and Preferences</h3>
      <ul>
        <li>
          <strong>Voice language preference</strong> (your selected language for
          voice-to-text input)
        </li>
        <li>
          <strong>AI agent permission settings</strong> (your chosen permission
          mode per AI engine — e.g., auto or safe mode)
        </li>
        <li>
          <strong>Onboarding status</strong> (whether you have completed the
          setup flow)
        </li>
      </ul>

      <h3>1.3 Machine and Device Information</h3>
      <p>
        When you connect your Mac to the Service, we collect device metadata to
        enable connectivity and display it in the app:
      </p>
      <ul>
        <li>Machine name, model, platform (e.g., macOS), and OS version</li>
        <li>CPU core count and memory size (in GB)</li>
        <li>Local IP address (for connectivity)</li>
        <li>
          Heartbeat timestamps (to show online/offline status in the iOS app)
        </li>
      </ul>
      <p>
        On the iOS side, we access standard device properties (device model, OS
        version, screen dimensions) solely for rendering and coordinate mapping
        purposes. This information is not transmitted to our servers.
      </p>

      <h3>1.4 Workspace and Repository Metadata</h3>
      <p>
        To let you manage projects remotely, the macOS app scans standard
        development directories (e.g., ~/Desktop, ~/Documents, ~/Projects,
        ~/Developer) for Git repositories. We collect:
      </p>
      <ul>
        <li>Repository name and local file path</li>
        <li>Git remote URL (e.g., your GitHub origin)</li>
        <li>Current branch name</li>
        <li>
          Detected stack type (e.g., web, mobile, backend — based on config
          file presence)
        </li>
      </ul>
      <p>
        This metadata is stored in your account to display your workspaces. We
        do not read, index, or store the contents of your source code files on
        our servers.
      </p>

      <h3>1.5 Chat Messages and Terminal Data</h3>
      <ul>
        <li>
          <strong>Chat messages:</strong> Messages you send to AI agents and
          the responses you receive are stored in our database to provide
          conversation history and continuity. Messages include text content,
          sender role (user or assistant), and timestamps.
        </li>
        <li>
          <strong>Terminal session data:</strong> When you run AI coding agents
          through Tarsy, the commands sent and output received are transmitted
          via WebSocket between your devices. Terminal output may be
          transiently processed to display in the iOS app but is not
          permanently stored on our servers beyond chat message records.
        </li>
      </ul>

      <h3>1.6 Subscription and Billing Data</h3>
      <p>
        Subscription purchases are processed entirely by Apple through the App
        Store and StoreKit. We do <strong>not</strong> collect, process, or
        store your credit card number, billing address, or any payment
        instrument details. We only receive and store:
      </p>
      <ul>
        <li>
          Subscription status (active, cancelled, or expired), synced from
          StoreKit
        </li>
        <li>Subscription expiration date</li>
        <li>
          Whether your account is on the Pro plan (a boolean flag on your
          profile)
        </li>
      </ul>

      <h3>1.7 Push Notification Tokens</h3>
      <p>
        If you enable push notifications, we store your Apple Push Notification
        service (APNs) device token so we can deliver notifications (e.g., when
        an AI agent needs your input or a task completes). You can disable push
        notifications at any time in your device settings.
      </p>

      <h3>1.8 Voice Input</h3>
      <p>
        Tarsy offers voice-to-text functionality using Apple&apos;s
        SFSpeechRecognizer framework. Audio is processed{" "}
        <strong>on your device</strong> whenever on-device recognition is
        available. Tarsy does not record, transmit, or store audio files. Only
        the resulting transcribed text is sent as a message to the AI agent.
      </p>

      <h3>1.9 Agent Task Data</h3>
      <p>
        When you dispatch tasks to AI coding agents, we store task metadata
        including task description, status (running, waiting, completed, error),
        the AI engine used, error messages (if any), and timestamps. This data
        is used to display task history and enable task continuity across
        sessions.
      </p>

      <h2>2. Screen Streaming and Remote Control</h2>

      <h3>2.1 Screen Capture</h3>
      <p>
        The macOS app captures your screen using Apple&apos;s ScreenCaptureKit
        framework and encodes the video (H.264 or MJPEG) for real-time
        streaming to the iOS app. Screen data is:
      </p>
      <ul>
        <li>
          Transmitted directly over your local network (LAN) when both devices
          are on the same Wi-Fi, <strong>or</strong>
        </li>
        <li>
          Routed through our relay server when using remote access over the
          internet.
        </li>
      </ul>
      <p>
        Screen frames are <strong>not stored, recorded, or logged</strong> by
        us — not on the relay server, not in any database. The relay server
        acts as a forwarding server that does not store or inspect your
        content. We do not have access to the visual content of your screen.
      </p>

      <h3>2.2 Remote Input</h3>
      <p>
        The iOS app sends touch, scroll, keyboard, and gesture input events to
        the macOS app to enable remote control. These input events (tap
        coordinates, scroll deltas, keystrokes, drag paths) are transmitted via
        WebSocket and are <strong>not stored or logged</strong> by us or by the
        relay server.
      </p>

      <h3>2.3 Sudo Password Handling</h3>
      <p>
        Certain operations on your Mac may require administrator (sudo)
        privileges. When this occurs, the macOS app requests your sudo password
        via the iOS app. The password is transmitted over the encrypted
        WebSocket connection, used once to execute the privileged command, and
        cached locally on your Mac for a maximum of 60 seconds before being
        discarded. Your sudo password is{" "}
        <strong>never transmitted to or stored on our servers</strong>.
      </p>

      <h2>3. AI Services and Third-Party Data Processing</h2>

      <h3>3.1 AI Coding Agents</h3>
      <p>
        Tarsy supports multiple AI coding agents, including Claude (Anthropic),
        Gemini CLI (Google), Codex CLI (OpenAI), Aider, and custom CLI tools.
        When you use these agents:
      </p>
      <ul>
        <li>
          Your prompts, messages, screenshots, file contents, and terminal
          output may be sent to the respective third-party AI provider.
        </li>
        <li>
          Each AI provider processes your data under their own privacy policy
          and terms of service. We strongly encourage you to review the privacy
          policies of any AI provider you use through Tarsy.
        </li>
        <li>
          AI agents run as local processes on your Mac. Tarsy facilitates
          communication between your iOS device and those local processes but
          does not independently send your data to AI providers — the AI CLI
          tools do.
        </li>
        <li>
          We are not responsible for how third-party AI providers process,
          store, or use the data that their tools transmit.
        </li>
      </ul>

      <h3>3.2 UltraContext</h3>
      <p>
        Tarsy integrates with the UltraContext API for enhanced AI context
        management. When this feature is active, conversation messages (role
        and text content) may be sent to the UltraContext service through a
        secure server-side proxy. Your authentication token is never exposed to
        UltraContext directly. UltraContext processes data under its own privacy
        policy.
      </p>

      <h3>3.3 OpenClaw (Local Processing)</h3>
      <p>
        When available, Tarsy can interface with OpenClaw, a local AI model
        gateway that runs entirely on your Mac. All data processed through
        OpenClaw remains on your device and is never transmitted to external
        servers by Tarsy.
      </p>

      <h2>4. How We Use Your Information</h2>
      <p>We use the information we collect to:</p>
      <ul>
        <li>Provide, operate, and maintain the Service</li>
        <li>
          Authenticate your identity and manage your account and subscription
        </li>
        <li>
          Enable real-time connectivity and screen streaming between your
          devices
        </li>
        <li>
          Deliver push notifications when AI agents require your input or tasks
          complete
        </li>
        <li>
          Send transactional emails (e.g., welcome emails, subscription
          notifications)
        </li>
        <li>Display your workspace and machine information in the app</li>
        <li>Maintain conversation history for AI agent interactions</li>
        <li>Monitor and improve the reliability and performance of the Service</li>
        <li>Respond to your support requests and communications</li>
        <li>Enforce our Terms of Use and protect against misuse</li>
        <li>Comply with legal obligations</li>
      </ul>
      <p>
        We do <strong>not</strong> use your information for advertising,
        profiling, or automated decision-making.
      </p>

      <h2>5. How We Share Your Information</h2>
      <p>
        We do <strong>not</strong> sell, rent, or trade your personal
        information. We share your data only in the following circumstances:
      </p>

      <h3>5.1 Service Providers</h3>
      <p>
        We use the following third-party service providers to operate the
        Service:
      </p>
      <ul>
        <li>
          <strong>Supabase</strong> — Authentication, database hosting,
          real-time subscriptions, and serverless edge functions.
        </li>
        <li>
          <strong>Apple (App Store, StoreKit, APNs)</strong> — Subscription
          billing, payment processing, and push notification delivery.
        </li>
        <li>
          <strong>Fly.io</strong> — Hosting our WebSocket relay server
          infrastructure for remote connectivity.
        </li>
        <li>
          <strong>Resend</strong> — Transactional email delivery (welcome
          emails, billing notifications).
        </li>
        <li>
          <strong>AI Providers</strong> — Claude (Anthropic), Gemini (Google),
          Codex (OpenAI), and others as selected by you. Data is sent to these
          providers only when you actively use the corresponding AI agent, and
          is sent directly from your Mac, not through our servers.
        </li>
        <li>
          <strong>UltraContext</strong> — AI context management, accessed via a
          server-side proxy.
        </li>
      </ul>

      <h3>5.2 Legal Requirements</h3>
      <p>
        We may disclose your information if required to do so by law, or in
        the good-faith belief that such action is necessary to comply with
        applicable law, respond to a court order or legal process, or protect
        the rights, property, or safety of Tarsy, our users, or the public.
      </p>

      <h3>5.3 Business Transfers</h3>
      <p>
        If we are involved in a merger, acquisition, or sale of all or a
        portion of our assets, your information may be transferred as part of
        that transaction. We will notify you via email or a prominent notice on
        the Service before your information is transferred and becomes subject
        to a different privacy policy.
      </p>

      <h2>6. Data Storage, Security, and International Transfers</h2>

      <h3>6.1 Data Storage</h3>
      <p>
        Your account data is stored on Supabase-hosted infrastructure. The
        relay server (hosted on Fly.io in São Paulo, Brazil) does not persist
        any data — it only forwards WebSocket messages in real-time. Local data
        (authentication tokens, preferences) is stored securely on your device
        using the system Keychain and standard app storage.
      </p>

      <h3>6.2 Security Measures</h3>
      <p>We implement industry-standard security measures, including:</p>
      <ul>
        <li>TLS/SSL encryption for all data in transit</li>
        <li>
          End-to-end encryption (E2E) for all communication between your iOS
          and macOS devices, with trust-on-first-use (TOFU) key pinning — the
          relay server cannot read your data even in transit
        </li>
        <li>
          Row-Level Security (RLS) on all database tables, ensuring users can
          only access their own data
        </li>
        <li>
          JWT-based authentication with token refresh for all API and WebSocket
          connections
        </li>
        <li>
          Server-side API key proxying for third-party services (keys are never
          exposed to client apps)
        </li>
        <li>Encrypted WebSocket connections (WSS) for screen streaming and remote input</li>
        <li>
          Machine secret verification and action allowlists on the relay
          server to prevent unauthorized access
        </li>
        <li>
          Rate limiting on the relay server (120 messages per second per
          connection)
        </li>
      </ul>
      <p>
        While we take reasonable precautions, no method of electronic
        transmission or storage is 100% secure. We cannot guarantee absolute
        security.
      </p>

      <h3>6.3 International Transfers</h3>
      <p>
        Your data may be processed in countries other than your country of
        residence, including the United States and Brazil, where our service
        providers operate. By using the Service, you consent to the transfer of
        your information to these countries. We ensure that any such transfers
        comply with applicable data protection laws, including the use of
        Standard Contractual Clauses (SCCs) approved by the European Commission
        where required.
      </p>

      <h2>7. Data Retention</h2>
      <ul>
        <li>
          <strong>Account data:</strong> Retained for as long as your account
          is active. Upon account deletion, your personal information is
          deleted within 30 days, except where retention is required by law.
        </li>
        <li>
          <strong>Chat messages and agent tasks:</strong> Retained for as long
          as your account is active. Deleted upon account deletion.
        </li>
        <li>
          <strong>Screen streaming data:</strong> Never stored. Transmitted in
          real-time only.
        </li>
        <li>
          <strong>Remote input data:</strong> Never stored. Transmitted in
          real-time only.
        </li>
        <li>
          <strong>Push notification tokens:</strong> Deleted upon account
          deletion or when you disable notifications.
        </li>
        <li>
          <strong>Subscription records:</strong> Retained for up to 7 years
          after account deletion for tax and legal compliance purposes.
        </li>
        <li>
          <strong>Transactional emails:</strong> Email delivery records may be
          retained by our email provider (Resend) in accordance with their
          retention policies.
        </li>
      </ul>

      <h2>8. Your Rights</h2>
      <p>
        Depending on your location, you may have the following rights
        regarding your personal data:
      </p>

      <h3>8.1 General Rights</h3>
      <ul>
        <li>
          <strong>Access:</strong> Request a copy of the personal data we hold
          about you.
        </li>
        <li>
          <strong>Rectification:</strong> Request correction of inaccurate or
          incomplete data.
        </li>
        <li>
          <strong>Deletion:</strong> Request deletion of your personal data. You
          can delete your account directly within the iOS app (Profile &gt;
          Delete Account), or by contacting us.
        </li>
        <li>
          <strong>Portability:</strong> Request your data in a structured,
          commonly used, machine-readable format.
        </li>
        <li>
          <strong>Objection:</strong> Object to or restrict certain processing
          of your data.
        </li>
        <li>
          <strong>Withdrawal of consent:</strong> Where processing is based on
          consent, withdraw your consent at any time.
        </li>
      </ul>
      <p>
        To exercise any of these rights, contact our Data Protection Officer
        at{" "}
        <a href="mailto:privacy@tarsy.dev">privacy@tarsy.dev</a>. We will
        respond to your request within 30 days, or sooner if required by
        applicable law.
      </p>

      <h3>8.2 Brazil (LGPD)</h3>
      <p>
        If you are located in Brazil, you have the rights provided under the
        Lei Geral de Proteção de Dados (LGPD), including the right to
        confirmation of processing, access, correction, anonymization,
        blocking, or deletion of unnecessary data, portability, information
        about shared data, and the right to revoke consent. You may also file
        a complaint with the Autoridade Nacional de Proteção de Dados (ANPD).
      </p>

      <h3>8.3 European Economic Area (GDPR)</h3>
      <p>
        If you are located in the EEA, you have the rights provided under the
        General Data Protection Regulation, including the rights listed above
        and the right to lodge a complaint with your local data protection
        supervisory authority. Our legal basis for processing your data
        includes: performance of a contract (providing the Service), legitimate
        interests (improving the Service, security), and consent (where
        applicable). You may also use the European Commission&apos;s Online
        Dispute Resolution platform at{" "}
        <a
          href="https://ec.europa.eu/consumers/odr"
          target="_blank"
          rel="noopener noreferrer"
        >
          ec.europa.eu/consumers/odr
        </a>.
      </p>

      <h3>8.4 California (CCPA/CPRA)</h3>
      <p>
        If you are a California resident, you have the right to know what
        personal information we collect, request its deletion, and opt out of
        the sale or sharing of personal information. We do{" "}
        <strong>not</strong> sell or share your personal information as defined
        under the CCPA/CPRA. To exercise your rights, contact us at{" "}
        <a href="mailto:support@tarsy.dev">support@tarsy.dev</a>.
      </p>

      <h2>9. System Permissions</h2>
      <p>The Service requests the following device permissions:</p>

      <h3>9.1 iOS App</h3>
      <ul>
        <li>
          <strong>Microphone:</strong> For voice-to-text input to send commands
          to AI agents. Audio is processed on-device and is not recorded or
          transmitted.
        </li>
        <li>
          <strong>Speech Recognition:</strong> To convert your voice into text
          commands using Apple&apos;s on-device speech recognition.
        </li>
        <li>
          <strong>Camera:</strong> To capture and send images to AI agents as
          context for coding tasks.
        </li>
        <li>
          <strong>Photo Library:</strong> To save screenshots from the screen
          stream or attach images to AI agent messages.
        </li>
        <li>
          <strong>Local Network:</strong> To discover and connect to your Mac
          on the same Wi-Fi network for direct, low-latency streaming.
        </li>
        <li>
          <strong>Push Notifications:</strong> To alert you when AI agents need
          your input, tasks complete, or errors occur.
        </li>
        <li>
          <strong>Live Activities:</strong> To display real-time AI agent status
          on your Lock Screen and Dynamic Island while a session is active. No
          additional data is collected — Live Activities use information already
          present in the app.
        </li>
      </ul>

      <h3>9.2 macOS App</h3>
      <ul>
        <li>
          <strong>Screen Recording:</strong> To capture and stream your screen
          to the iOS app using ScreenCaptureKit.
        </li>
        <li>
          <strong>Accessibility:</strong> To simulate keyboard and mouse input
          for remote control functionality.
        </li>
        <li>
          <strong>Local Network:</strong> For direct device-to-device
          communication on LAN.
        </li>
      </ul>
      <p>
        All permissions are optional and requested only when the corresponding
        feature is used. You can revoke permissions at any time in your device
        settings. The Service will continue to function with reduced
        functionality if permissions are not granted.
      </p>

      <h2>10. Analytics and Tracking</h2>
      <p>
        Tarsy does <strong>not</strong> use third-party analytics SDKs,
        advertising trackers, or fingerprinting technologies. We do not
        participate in cross-app tracking. We do not collect or use the Apple
        Advertising Identifier (IDFA). We do not use cookies in our native
        applications. Our website does not use tracking cookies or third-party
        analytics scripts.
      </p>

      <h2>11. Children&apos;s Privacy</h2>
      <p>
        The Service is not directed to anyone under the age of 18. We do not
        knowingly collect personal information from children under 18. If we
        learn that we have collected personal information from a child under
        18, we will take steps to delete that information promptly. If you
        believe a child under 18 has provided us with personal information,
        please contact us at{" "}
        <a href="mailto:support@tarsy.dev">support@tarsy.dev</a>.
      </p>

      <h2>12. Changes to This Privacy Policy</h2>
      <p>
        We may update this Privacy Policy from time to time. We will notify you
        of material changes by posting the updated policy on this page,
        updating the &quot;Last updated&quot; date, and, where appropriate,
        sending you a notification via email or in-app notice. Your continued
        use of the Service after such changes constitutes your acceptance of
        the updated Privacy Policy.
      </p>

      <h2>13. Language</h2>
      <p>
        This Privacy Policy may be made available in multiple languages for
        convenience. In the event of any discrepancy between the English version
        and any translation, the English version shall prevail.
      </p>

      <h2>14. Contact Us</h2>
      <p>
        If you have any questions about this Privacy Policy, wish to exercise
        your data rights, or have concerns about how your information is
        handled, please contact us:
      </p>
      <ul>
        <li>
          <strong>Support:</strong>{" "}
          <a href="mailto:support@tarsy.dev">support@tarsy.dev</a>
        </li>
        <li>
          <strong>Data Protection Officer:</strong>{" "}
          <a href="mailto:privacy@tarsy.dev">privacy@tarsy.dev</a>
        </li>
        <li>
          <strong>General inquiries:</strong>{" "}
          <a href="mailto:contact@tarsy.dev">contact@tarsy.dev</a>
        </li>
        <li>
          <strong>Website:</strong>{" "}
          <a href="https://tarsy.dev">https://tarsy.dev</a>
        </li>
        <li>
          <strong>Company:</strong> OPALLOO INOVACOES LTDA, CNPJ
          53.284.020/0001-06
        </li>
        <li>
          <strong>Address:</strong> Avenida Brigadeiro Faria Lima, 1811 - Cj
          115, Jardim America, CEP 01452-001, São Paulo - SP, Brazil
        </li>
      </ul>
    </div>
  );
}
