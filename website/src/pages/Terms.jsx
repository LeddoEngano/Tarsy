import styles from './Legal.module.css'

export default function Terms() {
  return (
    <div className={styles.page}>
      <h1>TERMS OF USE</h1>
      <p className={styles.lastUpdated}>Last updated: March 24, 2026</p>

      <p>These Terms of Use ("Terms") govern your use of the Tarsy application and related services (the "Service") provided by OPALLOO INOVACOES LTDA ("we", "us", or "our"). By using the Service, you agree to these Terms.</p>

      <h2>1. Acceptance of Terms</h2>
      <p>By downloading, installing, or using Tarsy, you agree to be bound by these Terms. If you do not agree, do not use the Service.</p>

      <h2>2. Description of Service</h2>
      <p>Tarsy is a development tool that allows you to stream, control, and manage your Mac development environment from your iPhone. The Service includes a macOS companion application, an iOS application, and relay infrastructure for remote connectivity.</p>

      <h2>3. Account Registration</h2>
      <p>You must create an account to use the Service. You are responsible for:</p>
      <ul>
        <li>Providing accurate account information</li>
        <li>Maintaining the security of your account credentials</li>
        <li>All activities that occur under your account</li>
      </ul>

      <h2>4. Subscriptions & Payments</h2>
      <p>Tarsy offers a subscription plan ("Tarsy Pro") with the following terms:</p>
      <ul>
        <li>Subscriptions are billed monthly through the Apple App Store</li>
        <li>Payment is charged to your Apple ID account at confirmation of purchase</li>
        <li>Subscription automatically renews unless canceled at least 24 hours before the end of the current period</li>
        <li>You can manage and cancel subscriptions in your App Store account settings</li>
        <li>No refunds are provided for partial subscription periods</li>
      </ul>

      <h2>5. Acceptable Use</h2>
      <p>You agree not to:</p>
      <ul>
        <li>Use the Service for any unlawful purpose</li>
        <li>Attempt to reverse engineer, decompile, or disassemble the Service</li>
        <li>Interfere with or disrupt the Service or servers</li>
        <li>Share your account credentials with third parties</li>
        <li>Use the Service to transmit malicious code or content</li>
        <li>Resell or redistribute the Service without authorization</li>
      </ul>

      <h2>6. Intellectual Property</h2>
      <p>The Service, including its code, design, logos, and content, is owned by OPALLOO INOVACOES LTDA and is protected by intellectual property laws. You are granted a limited, non-exclusive, non-transferable license to use the Service for personal or professional development purposes.</p>

      <h2>7. Your Content</h2>
      <p>You retain all rights to your code, files, and content that you access through the Service. We do not claim ownership over your development projects, source code, or any content on your Mac.</p>

      <h2>8. Third-Party Services</h2>
      <p>The Service integrates with third-party AI providers (Claude, GPT, Gemini, Grok). Your use of these services is subject to their respective terms and conditions. We are not responsible for the availability, accuracy, or output of third-party AI services.</p>

      <h2>9. Disclaimer of Warranties</h2>
      <p>The Service is provided "AS IS" and "AS AVAILABLE" without warranties of any kind, either express or implied. We do not warrant that the Service will be uninterrupted, error-free, or secure. You use the Service at your own risk.</p>

      <h2>10. Limitation of Liability</h2>
      <p>To the maximum extent permitted by law, OPALLOO INOVACOES LTDA shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising from your use of the Service, including but not limited to loss of data, loss of profits, or damage to your devices or code.</p>

      <h2>11. Termination</h2>
      <p>We reserve the right to suspend or terminate your account at any time for violation of these Terms. Upon termination, your right to use the Service ceases immediately. You may terminate your account at any time by canceling your subscription and contacting us.</p>

      <h2>12. Changes to Terms</h2>
      <p>We may modify these Terms at any time. Continued use of the Service after changes constitutes acceptance of the new Terms. We will make reasonable efforts to notify you of significant changes.</p>

      <h2>13. Governing Law</h2>
      <p>These Terms are governed by the laws of Brazil. Any disputes arising from these Terms shall be resolved in the courts of Brazil.</p>

      <h2>14. Contact</h2>
      <p>For questions about these Terms, contact us at <a href="mailto:support@tarsy.app">support@tarsy.app</a>.</p>
    </div>
  )
}
