import Link from "next/link";

export default function Footer() {
  return (
    <footer className="border-t border-surface-overlay/30 mt-12">
      <div className="max-w-6xl mx-auto px-6 py-10 flex flex-col sm:flex-row items-center justify-between gap-4">
        <div className="flex items-center gap-2.5">
          <span className="text-sm font-bold text-amber tracking-[0.15em]">
            tarsy
          </span>
          <span className="text-[10px] text-taupe/30">|</span>
          <span className="text-[10px] text-taupe/50">
            &copy; 2026 OPALLOO INOVACOES LTDA
          </span>
        </div>
        <div className="flex items-center gap-5">
          <Link
            href="/privacy"
            className="text-[10px] uppercase tracking-wider text-taupe/60 no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Privacy
          </Link>
          <Link
            href="/terms"
            className="text-[10px] uppercase tracking-wider text-taupe/60 no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Terms
          </Link>
          <Link
            href="/contact"
            className="text-[10px] uppercase tracking-wider text-taupe/60 no-underline transition-colors duration-200 hover:text-amber hover:opacity-100"
          >
            Contact
          </Link>
        </div>
      </div>
    </footer>
  );
}
