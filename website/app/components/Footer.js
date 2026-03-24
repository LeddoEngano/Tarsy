import Link from "next/link";
import styles from "./Footer.module.css";

export default function Footer() {
  return (
    <footer className={styles.footer}>
      <div className={styles.links}>
        <Link href="/privacy">Privacy Policy</Link>
        <Link href="/terms">Terms of Use</Link>
        <Link href="/contact">Contact Us</Link>
      </div>
      <div className={styles.copyright}>
        &copy; 2026 OPALLOO INOVACOES LTDA. All rights reserved.
      </div>
    </footer>
  );
}
