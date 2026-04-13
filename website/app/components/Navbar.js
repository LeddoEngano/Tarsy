import Link from "next/link";

export default function Navbar() {
  return (
    <nav className="fixed top-0 left-0 right-0 z-50 bg-surface/90 backdrop-blur-xl border-b border-surface-overlay/40">
      <div className="max-w-6xl mx-auto px-6 h-14 flex items-center justify-between">
        <Link href="/" className="flex items-center gap-2.5 no-underline">
          <img src="/eyes.png" alt="tarsy" className="w-7 h-7" />
          <span className="text-base font-bold text-amber tracking-[0.15em]">
            tarsy
          </span>
        </Link>
        <div className="flex items-center gap-6">
          <Link
            href="/#features"
            className="text-[11px] uppercase tracking-wider text-taupe no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Features
          </Link>
          <Link
            href="/contact"
            className="text-[11px] uppercase tracking-wider text-taupe no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Contact
          </Link>
          <a
            href="https://github.com/LeddoEngano/Tarsy"
            target="_blank"
            rel="noopener noreferrer"
            className="text-taupe no-underline transition-colors duration-200 hover:text-amber"
            aria-label="GitHub"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z"/>
            </svg>
          </a>
          <Link
            href="/download/macos"
            className="hidden sm:inline-block text-[11px] uppercase tracking-wider bg-amber text-surface font-semibold px-4 py-1.5 rounded-full no-underline transition-all duration-200 hover:opacity-100 hover:shadow-md hover:shadow-amber/20 active:scale-[0.97]"
          >
            Download
          </Link>
        </div>
      </div>
    </nav>
  );
}
