import styles from "./contact.module.css";

export const metadata = {
  title: "Contact Us - Tarsy",
};

export default function Contact() {
  return (
    <div className={styles.section}>
      <h1>CONTACT US</h1>
      <p className={styles.subtitle}>
        Have questions, feedback, or need support? We&apos;d love to hear from you.
      </p>
      <div className={styles.card}>
        <div className={styles.item}>
          <div className={styles.label}>Email</div>
          <div className={styles.value}>
            <a href="mailto:support@tarsy.app">support@tarsy.app</a>
          </div>
        </div>
        <div className={styles.item}>
          <div className={styles.label}>Company</div>
          <div className={styles.value}>OPALLOO INOVACOES LTDA</div>
        </div>
        <div className={styles.item}>
          <div className={styles.label}>Response Time</div>
          <div className={styles.value}>We typically respond within 24 hours</div>
        </div>
      </div>
    </div>
  );
}
