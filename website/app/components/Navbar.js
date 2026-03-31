import Link from "next/link";

export default function Navbar() {
  return (
    <nav className="fixed top-0 left-0 right-0 z-50 bg-surface/90 backdrop-blur-xl border-b border-surface-overlay/40">
      <div className="max-w-6xl mx-auto px-6 h-14 flex items-center justify-between">
        <Link href="/" className="flex items-center gap-2.5 no-underline">
          <img src="/icon.png" alt="Tarsy" className="w-7 h-7 rounded-lg" />
          <span className="text-base font-bold text-amber tracking-[0.15em]">
            TARSY
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
            href="/#pricing"
            className="text-[11px] uppercase tracking-wider text-taupe no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Pricing
          </Link>
          <Link
            href="/contact"
            className="text-[11px] uppercase tracking-wider text-taupe no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Contact
          </Link>
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
