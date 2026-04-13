import { WebPageJsonLd } from "../../../components/JsonLd";

const DOWNLOAD_URL =
  `${process.env.NEXT_PUBLIC_SUPABASE_URL || "https://xtblbghhlkroskzljqcl.supabase.co"}/storage/v1/object/public/tarsy-releases/Tarsy-1.1.3.dmg`;

export const metadata = {
  title: "Download Tarsy for Mac",
  description:
    "Download the Tarsy macOS companion app. Lightweight menu bar daemon for remote screen streaming and AI coding agent control from your iPhone. Requires macOS 14+.",
  alternates: {
    canonical: "https://www.tarsy.dev/download/macos",
  },
};

export default function DownloadMacOS() {
  return (
    <>
      <WebPageJsonLd
        url="https://www.tarsy.dev/download/macos"
        name="Download Tarsy for Mac"
        description="Download the Tarsy macOS companion app for remote development."
        breadcrumbs={[
          { name: "Home", url: "https://www.tarsy.dev" },
          { name: "Download for Mac", url: "https://www.tarsy.dev/download/macos" },
        ]}
      />

      <section className="min-h-[80dvh] flex items-center py-20">
        <div className="max-w-2xl mx-auto px-6 w-full">
          <span className="text-[11px] uppercase tracking-[0.2em] text-amber">
            macOS companion
          </span>
          <h1 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream mt-3">
            Download Tarsy for Mac
          </h1>
          <p className="text-sm text-taupe leading-relaxed mt-6 max-w-lg">
            The macOS companion app runs as a lightweight menu bar daemon. It handles screen
            capture, AI agent processes, and the WebSocket connection to your iPhone.
          </p>

          {/* Download card */}
          <div className="mt-10 bg-surface-raised/80 border border-surface-overlay/40 rounded-2xl p-8">
            <div className="flex items-start justify-between flex-wrap gap-6">
              <div>
                <h2 className="text-lg font-semibold text-cream">
                  Tarsy for macOS
                </h2>
                <div className="mt-3 space-y-1.5">
                  <p className="text-xs text-taupe">
                    <span className="text-taupe/60">Version:</span>{" "}
                    <span className="text-cream/80">1.1.3</span>
                  </p>
                  <p className="text-xs text-taupe">
                    <span className="text-taupe/60">Requires:</span>{" "}
                    <span className="text-cream/80">macOS 14.0 or later</span>
                  </p>
                  <p className="text-xs text-taupe">
                    <span className="text-taupe/60">Architecture:</span>{" "}
                    <span className="text-cream/80">Universal (Apple Silicon &amp; Intel)</span>
                  </p>
                  <p className="text-xs text-taupe">
                    <span className="text-taupe/60">Format:</span>{" "}
                    <span className="text-cream/80">DMG (signed &amp; notarized)</span>
                  </p>
                </div>
              </div>
              <a
                href={DOWNLOAD_URL}
                className="inline-block text-center bg-amber/10 text-amber text-sm font-semibold py-3.5 px-8 rounded-xl no-underline border border-amber/30 transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98] shrink-0"
              >
                Download DMG
              </a>
            </div>
          </div>

          {/* Installation steps */}
          <div className="mt-10">
            <h2 className="text-sm font-semibold text-cream">Installation</h2>
            <ol className="mt-4 space-y-3 text-xs text-taupe leading-relaxed list-decimal list-inside">
              <li>Open the downloaded DMG file</li>
              <li>Drag Tarsy to your Applications folder</li>
              <li>Launch Tarsy — it will appear in your menu bar</li>
              <li>Grant Screen Recording and Accessibility permissions when prompted</li>
              <li>Sign in with the same account you use on the iPhone app</li>
            </ol>
          </div>

          {/* Security note */}
          <div className="mt-8 border border-surface-overlay/20 rounded-xl p-5">
            <h3 className="text-xs font-semibold text-cream">Security</h3>
            <p className="text-xs text-taupe leading-relaxed mt-2">
              This DMG is signed with a Developer ID certificate and notarized by Apple.
              macOS will verify the signature automatically before installation. All network
              communication is end-to-end encrypted.
            </p>
          </div>

          {/* Also available */}
          <div className="mt-10 text-center">
            <p className="text-xs text-taupe/60">
              Also available:{" "}
              <a
                href="https://apps.apple.com/us/app/tarsy/id6761079923"
                target="_blank"
                rel="noopener noreferrer"
                className="text-amber/60 hover:text-amber transition-colors no-underline"
              >
                Tarsy for iPhone on the App Store
              </a>
            </p>
          </div>
        </div>
      </section>
    </>
  );
}
