import { Link } from 'react-router-dom'
import styles from './Footer.module.css'

export default function Footer() {
  return (
    <footer className={styles.footer}>
      <div className={styles.links}>
        <Link to="/privacy">Privacy Policy</Link>
        <Link to="/terms">Terms of Use</Link>
        <Link to="/contact">Contact Us</Link>
      </div>
      <div className={styles.copyright}>
        &copy; 2026 OPALLOO INOVACOES LTDA. All rights reserved.
      </div>
    </footer>
  )
}
