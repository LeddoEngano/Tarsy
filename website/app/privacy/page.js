import styles from "../legal.module.css";

export const metadata = {
  title: "Privacy Policy - Tarsy",
};

export default function Privacy() {
  return (
    <div className={styles.page}>
      <h1>PRIVACY POLICY</h1>
      <p className={styles.lastUpdated}>Last updated: March 24, 2026</p>

      <p>OPALLOO INOVACOES LTDA (&quot;we&quot;, &quot;us&quot;, or &quot;our&quot;) operates the Tarsy mobile application and companion macOS application (the &quot;Service&quot;). This page informs you of our policies regarding the collection, use, and disclosure of personal information when you use our Service.</p>

      <h2>1. Information We Collect</h2>
      <p>We collect the following types of information:</p>
      <ul>
        <li><strong>Account Information:</strong> When you create an account, we collect your email address and authentication credentials.</li>
        <li><strong>Usage Data:</strong> We may collect information about how you access and use the Service, including your device type, operating system, and app interactions.</li>
        <li><strong>Subscription Data:</strong> Payment and subscription information is processed and stored by Apple through the App Store. We do not store your payment details.</li>
      </ul>

      <h2>2. Screen Streaming & Data Transfer</h2>
      <p>Tarsy streams your Mac screen to your iPhone. Screen data is transmitted:</p>
      <ul>
        <li>Directly over your local network when both devices are on the same Wi-Fi, or</li>
        <li>Through our relay servers when using remote access.</li>
      </ul>
      <p>Screen data transmitted through relay servers is encrypted in transit and is not stored, recorded, or logged by us. We do not have access to the content of your screen.</p>

      <h2>3. AI Services</h2>
      <p>When you use AI features (Claude, GPT, Gemini, Grok), your prompts and screenshots are sent to the respective third-party AI provider. Each provider processes your data under their own privacy policy. We do not store your AI conversations on our servers.</p>

      <h2>4. How We Use Your Information</h2>
      <ul>
        <li>To provide and maintain the Service</li>
        <li>To manage your account and subscription</li>
        <li>To enable connectivity between your devices</li>
        <li>To improve and optimize the Service</li>
        <li>To communicate with you about updates or support</li>
      </ul>

      <h2>5. Data Storage & Security</h2>
      <p>We use Supabase for authentication and account data storage. All data is encrypted in transit using TLS. We implement industry-standard security measures to protect your information.</p>

      <h2>6. Data Retention</h2>
      <p>We retain your account data for as long as your account is active. If you delete your account, we will delete your personal information within 30 days, except where retention is required by law.</p>

      <h2>7. Third-Party Services</h2>
      <p>Our Service integrates with the following third-party services:</p>
      <ul>
        <li><strong>Apple App Store:</strong> For subscription management and payments</li>
        <li><strong>Supabase:</strong> For authentication and data storage</li>
        <li><strong>AI Providers:</strong> Claude (Anthropic), GPT (OpenAI), Gemini (Google), Grok (xAI)</li>
        <li><strong>Fly.io:</strong> For relay server infrastructure</li>
      </ul>

      <h2>8. Children&apos;s Privacy</h2>
      <p>Our Service is not directed to anyone under the age of 13. We do not knowingly collect personal information from children under 13.</p>

      <h2>9. Your Rights</h2>
      <p>You have the right to:</p>
      <ul>
        <li>Access and receive a copy of your personal data</li>
        <li>Rectify or update your personal data</li>
        <li>Request deletion of your personal data</li>
        <li>Object to or restrict processing of your data</li>
      </ul>

      <h2>10. Changes to This Policy</h2>
      <p>We may update this Privacy Policy from time to time. We will notify you of any changes by posting the new Privacy Policy on this page and updating the &quot;Last updated&quot; date.</p>

      <h2>11. Contact Us</h2>
      <p>If you have any questions about this Privacy Policy, please contact us at <a href="mailto:support@tarsy.app">support@tarsy.app</a>.</p>
    </div>
  );
}
