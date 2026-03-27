import styles from "../legal.module.css";

export const metadata = {
  title: "Terms of Use - Tarsy",
};

export default function Terms() {
  return (
    <div className={styles.page}>
      <h1>TERMS OF USE</h1>
      <p className={styles.lastUpdated}>Last updated: March 27, 2026</p>

      <p>
        These Terms of Use (&quot;Terms&quot;) constitute a legally binding
        agreement between you (&quot;you&quot; or &quot;User&quot;) and OPALLOO
        INOVACOES LTDA, registered under CNPJ 53.284.020/0001-06, located at
        Avenida Brigadeiro Faria Lima, 1811 - Cj 115, Jardim America, CEP
        01452-001, São Paulo - SP, Brazil (&quot;Tarsy&quot;, &quot;we&quot;,
        &quot;us&quot;, or &quot;our&quot;), governing your access to and use of
        the Tarsy iOS application, the Tarsy macOS companion application, the
        relay server infrastructure, the website at{" "}
        <a href="https://tarsy.dev">tarsy.dev</a>, and any related services
        (collectively, the &quot;Service&quot;).
      </p>
      <p>
        By downloading, installing, creating an account, or otherwise using the
        Service, you acknowledge that you have read, understood, and agree to be
        bound by these Terms and our{" "}
        <a href="/privacy">Privacy Policy</a>, which is incorporated herein by
        reference. If you do not agree to these Terms, you must not access or
        use the Service.
      </p>

      <h2>1. Eligibility</h2>
      <p>
        You must be at least 18 years old to use the Service. By agreeing to
        these Terms, you represent and warrant that you are at least 18 years of
        age and have the legal capacity to enter into this agreement. If you are
        using the Service on behalf of an organization, you represent that you
        have the authority to bind that organization to these Terms.
      </p>

      <h2>2. Description of Service</h2>
      <p>
        Tarsy is a remote desktop and AI coding agent platform for the Apple
        ecosystem. It enables you to stream your Mac screen, remotely control
        your Mac, and run and interact with AI coding agents from your iPhone or
        iPad. The Service includes:
      </p>
      <ul>
        <li>
          A <strong>macOS companion application</strong> that captures your
          screen, accepts remote input, and runs AI coding agent processes
          locally on your Mac.
        </li>
        <li>
          An <strong>iOS application</strong> that displays the remote stream,
          sends input commands, and provides a chat interface for AI agents.
        </li>
        <li>
          A <strong>relay server</strong> infrastructure for remote connectivity
          when your devices are not on the same local network.
        </li>
        <li>
          Integration with <strong>third-party AI coding agents</strong>{" "}
          (including Claude by Anthropic, Gemini CLI by Google, Codex CLI by
          OpenAI, Aider, and custom CLI tools) that run as local processes on
          your Mac.
        </li>
      </ul>

      <h2>3. Account Registration and Security</h2>
      <p>
        You must create an account to use the Service. You may register using
        Sign in with Apple, GitHub OAuth, or email and password. You agree to:
      </p>
      <ul>
        <li>Provide accurate, current, and complete registration information.</li>
        <li>
          Maintain the confidentiality and security of your account credentials.
        </li>
        <li>
          Immediately notify us at{" "}
          <a href="mailto:support@tarsy.dev">support@tarsy.dev</a> of any
          unauthorized use of your account.
        </li>
        <li>
          Accept full responsibility for all activities that occur under your
          account, whether or not authorized by you.
        </li>
      </ul>
      <p>
        We reserve the right to suspend or terminate accounts that appear to be
        compromised or used in violation of these Terms.
      </p>

      <h2>4. Subscriptions and Payments</h2>

      <h3>4.1 Plans</h3>
      <p>
        Tarsy offers a free tier (limited to 1 workspace) and a paid
        subscription plan, Tarsy Pro (unlimited workspaces), at a price
        displayed at the time of purchase.
      </p>

      <h3>4.2 Billing</h3>
      <ul>
        <li>
          Subscriptions are billed monthly through the Apple App Store and
          processed via Apple&apos;s payment infrastructure.
        </li>
        <li>
          Payment is charged to your Apple ID account at confirmation of
          purchase.
        </li>
        <li>
          Your subscription automatically renews unless you cancel it at least
          24 hours before the end of the current billing period.
        </li>
        <li>
          You can manage and cancel your subscription at any time in your Apple
          ID account settings (Settings &gt; [Your Name] &gt; Subscriptions).
        </li>
      </ul>

      <h3>4.3 Refunds</h3>
      <p>
        All subscription payments are processed by Apple. Refund requests are
        subject to Apple&apos;s refund policies. We do not directly process
        refunds. To request a refund, visit{" "}
        <a href="https://reportaproblem.apple.com">
          reportaproblem.apple.com
        </a>.
      </p>

      <h3>4.4 Price Changes</h3>
      <p>
        We may change subscription prices at any time. Price changes will take
        effect at the start of your next billing period after notice is provided
        through the App Store.
      </p>

      <h2>5. Your Content and Data</h2>

      <h3>5.1 Ownership</h3>
      <p>
        You retain all rights, title, and interest in and to your code, files,
        repositories, projects, and any other content that you access, create, or
        modify through the Service (&quot;Your Content&quot;). We do not claim
        any ownership over Your Content.
      </p>

      <h3>5.2 License to Us</h3>
      <p>
        By using the Service, you grant us a limited, non-exclusive,
        royalty-free license to transmit, process, and temporarily cache Your
        Content solely as necessary to provide the Service (e.g., relaying
        screen frames through our server, storing chat messages for conversation
        history). This license terminates when you delete your account.
      </p>

      <h3>5.3 Your Responsibility for Content</h3>
      <p>
        You are solely responsible for Your Content and any consequences of
        transmitting it through the Service. You represent and warrant that you
        have all necessary rights and permissions to use, transmit, and process
        any content you access through the Service, including source code,
        proprietary information, and trade secrets. If you use the Service to
        access content belonging to your employer or clients, you are
        responsible for ensuring you have proper authorization.
      </p>

      <h2>6. Remote Control, Screen Streaming, and Code Execution</h2>

      <h3>6.1 Nature of the Service</h3>
      <p>
        The Service provides remote access to and control of your Mac,
        including screen streaming, keyboard and mouse input, terminal command
        execution, and AI agent interaction. You acknowledge that:
      </p>
      <ul>
        <li>
          The Service enables real-time remote control of your Mac, including
          the ability to execute commands, modify files, install or remove
          software, and perform administrative actions.
        </li>
        <li>
          AI coding agents run with the permissions of your macOS user account
          and can read, write, create, and delete files on your system.
        </li>
        <li>
          Granting elevated (sudo/administrator) privileges to AI agents or
          through remote commands can result in significant system changes.
        </li>
      </ul>

      <h3>6.2 User Responsibility</h3>
      <p>
        <strong>
          You assume full and sole responsibility for all actions performed on
          your Mac through the Service, including but not limited to:
        </strong>
      </p>
      <ul>
        <li>
          Commands executed by AI coding agents, whether automatically or in
          response to your prompts.
        </li>
        <li>
          Code changes, file modifications, deletions, or system configuration
          changes.
        </li>
        <li>
          Any damage to your files, projects, system, or data resulting from
          remote control or AI agent activity.
        </li>
        <li>
          The decision to use &quot;auto&quot; vs. &quot;safe&quot; permission
          modes for AI agents and any consequences thereof.
        </li>
        <li>
          Ensuring your Mac is adequately secured and that appropriate backups
          are maintained.
        </li>
      </ul>
      <p>
        We strongly recommend maintaining regular backups of your code and data,
        using version control (Git), and reviewing AI agent actions before
        approving them.
      </p>

      <h3>6.3 No Guarantee of AI Output</h3>
      <p>
        AI coding agents are third-party tools that generate output
        autonomously. We do not control, review, endorse, or guarantee the
        accuracy, safety, completeness, or suitability of any code, commands, or
        output produced by AI agents. AI-generated code may contain errors,
        security vulnerabilities, or unintended behavior. You are responsible
        for reviewing, testing, and validating all AI-generated output before
        deploying it in any environment.
      </p>

      <h2>7. Third-Party Services and AI Providers</h2>

      <h3>7.1 AI Provider Terms</h3>
      <p>
        The Service integrates with third-party AI coding agents, including but
        not limited to Claude (Anthropic), Gemini CLI (Google), Codex CLI
        (OpenAI), and Aider. When you use these agents:
      </p>
      <ul>
        <li>
          Your prompts, messages, file contents, terminal output, and
          screenshots may be sent directly from your Mac to the respective AI
          provider.
        </li>
        <li>
          Your use of each AI provider is governed by that provider&apos;s own
          terms of service and privacy policy.
        </li>
        <li>
          You are responsible for complying with the terms of any AI provider
          you use through the Service.
        </li>
        <li>
          We are not responsible for the availability, accuracy, output, or
          conduct of any third-party AI service.
        </li>
      </ul>

      <h3>7.2 Other Third-Party Services</h3>
      <p>
        The Service relies on third-party infrastructure providers, including
        Supabase (authentication and database), Fly.io (relay server hosting),
        Apple (App Store, StoreKit, APNs), and Resend (transactional email). We
        are not responsible for outages, data loss, or service interruptions
        caused by third-party providers.
      </p>

      <h2>8. Acceptable Use</h2>
      <p>You agree not to use the Service to:</p>
      <ul>
        <li>
          Violate any applicable law, regulation, or third-party rights.
        </li>
        <li>
          Access or control any computer, device, or system that you do not own
          or have explicit authorization to access.
        </li>
        <li>
          Transmit malicious code, malware, viruses, or any harmful software
          through the Service.
        </li>
        <li>
          Attempt to reverse engineer, decompile, disassemble, or derive the
          source code of the Service.
        </li>
        <li>
          Interfere with, disrupt, or overload the Service, relay servers, or
          related infrastructure.
        </li>
        <li>
          Circumvent any security, authentication, or access control mechanisms.
        </li>
        <li>
          Share your account credentials with third parties or allow others to
          access the Service through your account.
        </li>
        <li>
          Resell, sublicense, redistribute, or commercially exploit the Service
          without our prior written consent.
        </li>
        <li>
          Use the Service to process, store, or transmit content that infringes
          any intellectual property rights or violates any law.
        </li>
        <li>
          Use the Service to mine cryptocurrency, perform distributed computing,
          or for any purpose unrelated to software development.
        </li>
      </ul>

      <h2>9. Intellectual Property</h2>
      <p>
        The Service, including its software, design, logos, trademarks, and all
        associated content, is owned by OPALLOO INOVACOES LTDA and is protected
        by applicable intellectual property laws. Subject to these Terms, we
        grant you a limited, non-exclusive, non-transferable, revocable license
        to use the Service for your personal or professional software
        development purposes. This license does not permit you to modify,
        distribute, or create derivative works based on the Service.
      </p>

      <h2>10. Account Deletion</h2>
      <p>
        You may delete your account at any time directly within the iOS app
        (Profile &gt; Delete Account) or by contacting us at{" "}
        <a href="mailto:support@tarsy.dev">support@tarsy.dev</a>. Upon account
        deletion:
      </p>
      <ul>
        <li>
          Your profile, workspaces, chat messages, machine records, agent tasks,
          and push notification data will be permanently deleted within 30 days.
        </li>
        <li>
          Subscription billing records may be retained for up to 7 years for tax
          and legal compliance purposes.
        </li>
        <li>
          Active subscriptions must be cancelled separately through your Apple
          ID account settings. Deleting your Tarsy account does not
          automatically cancel your App Store subscription.
        </li>
      </ul>

      <h2>11. Disclaimer of Warranties</h2>
      <p>
        THE SERVICE IS PROVIDED &quot;AS IS&quot; AND &quot;AS AVAILABLE&quot;
        WITHOUT WARRANTIES OF ANY KIND, WHETHER EXPRESS, IMPLIED, STATUTORY, OR
        OTHERWISE. TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, WE
        DISCLAIM ALL WARRANTIES, INCLUDING BUT NOT LIMITED TO IMPLIED WARRANTIES
        OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND
        NON-INFRINGEMENT.
      </p>
      <p>Without limiting the foregoing, we do not warrant that:</p>
      <ul>
        <li>
          The Service will be uninterrupted, timely, secure, or error-free.
        </li>
        <li>
          The relay server or network connectivity will be available at all
          times.
        </li>
        <li>
          Screen streaming or remote input will be free of latency, artifacts,
          or disconnections.
        </li>
        <li>
          AI agent output will be accurate, complete, safe, secure, or suitable
          for any particular purpose.
        </li>
        <li>
          The Service will be compatible with all system configurations,
          software versions, or network environments.
        </li>
        <li>
          Any defects in the Service will be corrected.
        </li>
      </ul>

      <h2>12. Limitation of Liability</h2>
      <p>
        TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT SHALL
        OPALLOO INOVACOES LTDA, ITS OFFICERS, DIRECTORS, EMPLOYEES, AGENTS, OR
        AFFILIATES BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL,
        CONSEQUENTIAL, EXEMPLARY, OR PUNITIVE DAMAGES, INCLUDING BUT NOT
        LIMITED TO:
      </p>
      <ul>
        <li>
          Loss of data, source code, projects, files, or any digital content.
        </li>
        <li>Loss of profits, revenue, or business opportunities.</li>
        <li>
          Damage to your computer, devices, software, or operating system.
        </li>
        <li>
          System corruption, data breaches, or security incidents arising from
          remote access or AI agent activity.
        </li>
        <li>
          Unauthorized access to your Mac resulting from compromised account
          credentials.
        </li>
        <li>
          Any actions taken by AI coding agents, including but not limited to
          file deletion, code modification, package installation, or system
          configuration changes.
        </li>
        <li>
          Downtime, service interruptions, or connection failures.
        </li>
        <li>
          Costs of procuring substitute goods or services.
        </li>
      </ul>
      <p>
        IN NO EVENT SHALL OUR TOTAL AGGREGATE LIABILITY TO YOU FOR ALL CLAIMS
        ARISING OUT OF OR RELATING TO THESE TERMS OR THE SERVICE EXCEED THE
        AMOUNT YOU HAVE PAID US IN THE TWELVE (12) MONTHS PRECEDING THE EVENT
        GIVING RISE TO THE CLAIM, OR FIFTY US DOLLARS (USD $50.00), WHICHEVER
        IS GREATER.
      </p>
      <p>
        THE LIMITATIONS IN THIS SECTION APPLY REGARDLESS OF THE THEORY OF
        LIABILITY, WHETHER BASED ON WARRANTY, CONTRACT, TORT (INCLUDING
        NEGLIGENCE), STRICT LIABILITY, OR ANY OTHER LEGAL THEORY, EVEN IF WE
        HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
      </p>

      <h2>13. Indemnification</h2>
      <p>
        You agree to indemnify, defend, and hold harmless OPALLOO INOVACOES
        LTDA, its officers, directors, employees, agents, and affiliates from
        and against any and all claims, damages, losses, liabilities, costs, and
        expenses (including reasonable attorneys&apos; fees) arising out of or
        relating to:
      </p>
      <ul>
        <li>Your use of the Service.</li>
        <li>
          Any actions performed on your Mac through the Service, including
          actions taken by AI agents.
        </li>
        <li>Your violation of these Terms.</li>
        <li>
          Your violation of any applicable law, regulation, or third-party
          right.
        </li>
        <li>
          Your Content, including any claim that Your Content infringes
          third-party intellectual property rights.
        </li>
        <li>
          Any unauthorized use of the Service through your account.
        </li>
      </ul>

      <h2>14. Termination</h2>

      <h3>14.1 Termination by You</h3>
      <p>
        You may stop using the Service and delete your account at any time.
        Active subscriptions must be cancelled separately through the App Store.
      </p>

      <h3>14.2 Termination by Us</h3>
      <p>
        We reserve the right to suspend or terminate your account and access to
        the Service at any time, with or without notice, for any reason,
        including but not limited to violation of these Terms, suspected
        fraudulent activity, or extended periods of inactivity.
      </p>

      <h3>14.3 Effect of Termination</h3>
      <p>
        Upon termination, your right to use the Service ceases immediately.
        Sections 5.3, 6, 11, 12, 13, 16, 17, and 18 shall survive termination.
      </p>

      <h2>15. Changes to Terms</h2>
      <p>
        We may modify these Terms at any time by posting the updated version on
        this page and updating the &quot;Last updated&quot; date. For material
        changes, we will make reasonable efforts to notify you via email or
        in-app notice. Your continued use of the Service after the effective
        date of any changes constitutes your acceptance of the revised Terms. If
        you do not agree to the updated Terms, you must stop using the Service.
      </p>

      <h2>16. Governing Law and Dispute Resolution</h2>

      <h3>16.1 Governing Law</h3>
      <p>
        These Terms shall be governed by and construed in accordance with the
        laws of the Federative Republic of Brazil, without regard to its
        conflict of law provisions. If you are a consumer in the European Union,
        mandatory consumer protection laws of your country of residence shall
        apply to the extent they provide greater protection.
      </p>

      <h3>16.2 Jurisdiction</h3>
      <p>
        Any disputes arising out of or relating to these Terms or the Service
        shall be submitted to the exclusive jurisdiction of the courts of the
        city of São Paulo, State of São Paulo, Brazil, and you consent to the
        personal jurisdiction of such courts.
      </p>

      <h3>16.3 Informal Resolution</h3>
      <p>
        Before initiating any formal legal proceedings, you agree to first
        contact us at{" "}
        <a href="mailto:support@tarsy.dev">support@tarsy.dev</a> and attempt to
        resolve the dispute informally for at least 30 days.
      </p>

      <h3>16.4 United States — Arbitration and Class Action Waiver</h3>
      <p>
        IF YOU ARE A RESIDENT OF THE UNITED STATES, YOU AGREE THAT ANY DISPUTE,
        CLAIM, OR CONTROVERSY ARISING OUT OF OR RELATING TO THESE TERMS OR THE
        SERVICE SHALL BE RESOLVED BY BINDING INDIVIDUAL ARBITRATION, RATHER
        THAN IN COURT, EXCEPT THAT EITHER PARTY MAY SEEK EQUITABLE RELIEF IN
        COURT FOR INFRINGEMENT OR MISUSE OF INTELLECTUAL PROPERTY RIGHTS.
      </p>
      <p>
        YOU AND OPALLOO INOVACOES LTDA AGREE THAT EACH MAY BRING CLAIMS
        AGAINST THE OTHER ONLY IN YOUR OR ITS INDIVIDUAL CAPACITY, AND NOT AS
        A PLAINTIFF OR CLASS MEMBER IN ANY PURPORTED CLASS, CONSOLIDATED, OR
        REPRESENTATIVE PROCEEDING. IF THIS CLASS ACTION WAIVER IS FOUND TO BE
        UNENFORCEABLE, THEN THE ENTIRETY OF THIS ARBITRATION PROVISION SHALL
        BE NULL AND VOID.
      </p>

      <h2>17. Jurisdiction-Specific Provisions</h2>

      <h3>17.1 Brazil</h3>
      <p>
        If you are a consumer located in Brazil, the protections of the
        Código de Defesa do Consumidor (CDC) apply to your use of the Service
        and cannot be waived by these Terms. You have a 7-day withdrawal right
        from the date of purchase per Article 49 of the CDC for digital
        purchases made outside a commercial establishment.
      </p>

      <h3>17.2 European Union</h3>
      <p>
        If you are a consumer located in the European Union, mandatory EU
        consumer protection laws apply and supersede any conflicting provisions
        in these Terms. You have a 14-day withdrawal right per EU consumer law
        for digital purchases, subject to applicable exceptions. Nothing in
        these Terms excludes or limits our liability for death or personal
        injury caused by our negligence, or for fraud or fraudulent
        misrepresentation. You may use the European Commission&apos;s Online
        Dispute Resolution platform at{" "}
        <a
          href="https://ec.europa.eu/consumers/odr"
          target="_blank"
          rel="noopener noreferrer"
        >
          ec.europa.eu/consumers/odr
        </a>.
      </p>

      <h3>17.3 United States</h3>
      <p>
        The arbitration clause and class action waiver in Section 16.4 are
        enforceable to the maximum extent permitted by applicable law. Some
        states may not allow certain limitations of liability or warranty
        exclusions — in such cases, our liability shall be limited to the
        greatest extent permitted by law.
      </p>

      <h2>18. General Provisions</h2>

      <h3>18.1 Entire Agreement</h3>
      <p>
        These Terms, together with our Privacy Policy, constitute the entire
        agreement between you and us regarding the Service and supersede all
        prior agreements, understandings, and communications.
      </p>

      <h3>18.2 Severability</h3>
      <p>
        If any provision of these Terms is held to be invalid, illegal, or
        unenforceable, the remaining provisions shall remain in full force and
        effect.
      </p>

      <h3>18.3 Waiver</h3>
      <p>
        Our failure to enforce any right or provision of these Terms shall not
        constitute a waiver of such right or provision.
      </p>

      <h3>18.4 Assignment</h3>
      <p>
        You may not assign or transfer your rights or obligations under these
        Terms without our prior written consent. We may assign our rights and
        obligations without restriction.
      </p>

      <h3>18.5 Force Majeure</h3>
      <p>
        We shall not be liable for any failure or delay in performance resulting
        from causes beyond our reasonable control, including but not limited to
        natural disasters, acts of government, internet or infrastructure
        failures, or third-party service outages.
      </p>

      <h3>18.6 Apple-Specific Terms</h3>
      <p>
        If you access the Service through an application downloaded from the
        Apple App Store, you acknowledge and agree that: (a) these Terms are
        between you and OPALLOO INOVACOES LTDA only, not with Apple; (b) Apple
        has no obligation to provide maintenance or support for the application;
        (c) in the event of any failure of the application to conform to any
        applicable warranty, you may notify Apple for a refund of the purchase
        price (if any), and Apple has no other warranty obligation; (d) Apple is
        not responsible for addressing any claims relating to the application or
        your use of it; (e) in the event of any third-party claim that the
        application infringes a third party&apos;s intellectual property rights,
        Apple is not responsible for the investigation, defense, settlement, or
        discharge of such claim; and (f) Apple and its subsidiaries are
        third-party beneficiaries of these Terms and may enforce them against
        you.
      </p>

      <h3>18.7 Language</h3>
      <p>
        These Terms may be made available in multiple languages for convenience.
        In the event of any discrepancy between the English version and any
        translation, the English version shall prevail.
      </p>

      <h2>19. Contact Us</h2>
      <p>
        If you have any questions about these Terms, please contact us:
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
