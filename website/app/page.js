import styles from "./page.module.css";

const features = [
  { icon: "\u25B6", title: "Live screen streaming", desc: "Stream your Mac screen to your iPhone in real time. See your IDE, terminal, and browser as you work." },
  { icon: "\uD83D\uDC41", title: "Screenshot to AI", desc: "Capture your screen and send it to Claude for vision-powered analysis and code suggestions." },
  { icon: "\uD83C\uDF10", title: "Remote access via relay", desc: "Access your Mac from anywhere. No port forwarding or VPN needed thanks to our relay infrastructure." },
  { icon: "\uD83E\uDDE0", title: "Multi AI engines", desc: "Switch between Claude, GPT, Gemini, and Grok. Use the best model for each task." },
  { icon: "\uD83C\uDF99", title: "Voice to text", desc: "Press and hold to dictate prompts. Pick your language and let AI handle the rest." },
  { icon: "\uD83D\uDCC2", title: "Workspace management", desc: "Create and manage multiple workspaces with different projects, branches, and dev server configs." },
];

const steps = [
  { num: "01", title: "Install Tarsy on your Mac", desc: "Download the companion macOS app. It runs as a lightweight daemon in the background." },
  { num: "02", title: "Open Tarsy on your iPhone", desc: "Sign in and your Mac appears automatically. Local network or remote, it just connects." },
  { num: "03", title: "Stream, chat, build", desc: "Watch your screen live, ask AI for help, manage your workspace, and ship code from anywhere." },
];

const proFeatures = [
  "Unlimited workspaces",
  "Remote access via relay",
  "All AI engines",
  "Git checkpoints & rollback",
  "File explorer",
  "Voice to text",
];

export default function Home() {
  return (
    <>
      <section className={styles.hero}>
        <img src="/icon.png" alt="Tarsy" className={styles.heroIcon} />
        <h1 className={styles.heroTitle}>TARSY</h1>
        <div className={styles.tagline}>&lt; / &gt;</div>
        <p className={styles.heroDesc}>
          Control your Mac dev environment from your iPhone. Live streaming, AI assistance, and remote access in your pocket.
        </p>
        <a href="https://apps.apple.com/app/tarsy" className={styles.cta}>
          Download on the App Store
        </a>
      </section>

      <section className={styles.features} id="features">
        <h2 className={styles.sectionTitle}>FEATURES</h2>
        <div className={styles.featuresGrid}>
          {features.map((f) => (
            <div key={f.title} className={styles.featureCard}>
              <div className={styles.featureIcon}>{f.icon}</div>
              <h3>{f.title}</h3>
              <p>{f.desc}</p>
            </div>
          ))}
        </div>
      </section>

      <section className={styles.howItWorks} id="how">
        <h2 className={styles.sectionTitle}>HOW IT WORKS</h2>
        <div className={styles.steps}>
          {steps.map((s) => (
            <div key={s.num} className={styles.step}>
              <div className={styles.stepNum}>{s.num}</div>
              <div>
                <h3>{s.title}</h3>
                <p>{s.desc}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section className={styles.pricing} id="pricing">
        <h2 className={styles.sectionTitle}>PRICING</h2>
        <div className={styles.priceCards}>
          <div className={styles.priceCard}>
            <div className={styles.planName}>MONTHLY</div>
            <div className={styles.price}>$14.99<span>/month</span></div>
            <div className={styles.cancel}>cancel anytime</div>
            <ul>
              {proFeatures.map((f) => (
                <li key={f}>{f}</li>
              ))}
            </ul>
            <a href="https://apps.apple.com/app/tarsy" className={styles.ctaBlock}>
              Get Tarsy Pro
            </a>
          </div>
          <div className={`${styles.priceCard} ${styles.priceCardFeatured}`}>
            <div className={styles.badge}>SAVE 33%</div>
            <div className={styles.planName}>ANNUAL</div>
            <div className={styles.price}>$9.99<span>/month</span></div>
            <div className={styles.cancel}>$119.99 billed annually</div>
            <ul>
              {proFeatures.map((f) => (
                <li key={f}>{f}</li>
              ))}
            </ul>
            <a href="https://apps.apple.com/app/tarsy" className={styles.ctaBlock}>
              Get Tarsy Pro
            </a>
          </div>
        </div>
      </section>
    </>
  );
}
