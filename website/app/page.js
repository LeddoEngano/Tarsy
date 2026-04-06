import ScrollReveal from "./components/ScrollReveal";
import HeroDevices from "./components/HeroDevices";
import FeatureGrid from "./components/FeatureGrid";

const steps = [
  {
    num: "01",
    title: "Install Tarsy on your Mac",
    desc: "Download the companion macOS app. It runs as a lightweight daemon in the background.",
  },
  {
    num: "02",
    title: "Open Tarsy on your iPhone",
    desc: "Sign in and your Mac appears automatically. Local network or remote — it just connects.",
  },
  {
    num: "03",
    title: "Stream, chat, build",
    desc: "Watch your screen live, ask AI for help, manage your workspace, and ship code from anywhere.",
  },
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
      {/* Hero */}
      <section className="min-h-[100dvh] flex items-center pt-14 relative">
        <div className="absolute top-0 inset-x-0 h-[500px] bg-amber/[0.02] blur-[100px] pointer-events-none" />

        <div className="relative max-w-6xl mx-auto px-6 w-full">
          <div className="grid grid-cols-1 lg:grid-cols-[1fr_1.3fr] gap-12 lg:gap-20 items-center">
            <div>
              <ScrollReveal>
                <span className="inline-block text-[11px] uppercase tracking-[0.2em] text-amber border border-amber/20 rounded-full px-4 py-1.5">
                  Remote dev, redefined
                </span>
              </ScrollReveal>
              <ScrollReveal delay={0.1}>
                <h1 className="font-display text-[clamp(2.5rem,6vw,4.5rem)] font-extrabold tracking-tight leading-[0.95] text-cream mt-8">
                  Ship code
                  <br />
                  from your
                  <br />
                  <span className="text-amber">pocket</span>
                </h1>
              </ScrollReveal>
              <ScrollReveal delay={0.2}>
                <p className="text-sm text-taupe leading-relaxed max-w-[420px] mt-8">
                  Control your Mac dev environment from your iPhone. Live
                  streaming, AI coding agents, and remote access — wherever you
                  are.
                </p>
              </ScrollReveal>
              <ScrollReveal delay={0.3}>
                <div className="flex flex-wrap gap-3 mt-10">
                  <a
                    href="https://testflight.apple.com/join/vDUvPDPe"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-block w-[260px] text-center bg-amber/10 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline border border-amber/30 transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
                  >
                    iPhone — TestFlight Beta
                  </a>
                  <a
                    href="/download/macos"
                    className="inline-block w-[260px] text-center border border-amber/30 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
                  >
                    Download for Mac
                  </a>
                </div>
                <p className="text-[11px] text-taupe/50 mt-4 tracking-wide">
                  Beta — limited TestFlight spots available
                </p>
                <p className="text-[11px] text-taupe/40 mt-2 tracking-wide">
                  macOS 14+ &middot; Apple Silicon &amp; Intel
                </p>
              </ScrollReveal>
            </div>

            <div className="flex justify-center lg:justify-end scale-[0.65] -my-16 lg:scale-100 lg:my-0 order-first lg:order-last">
              <HeroDevices />
            </div>
          </div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="py-24 md:py-32">
        <div className="max-w-6xl mx-auto px-6">
          <ScrollReveal>
            <span className="text-[11px] uppercase tracking-[0.2em] text-amber">
              Capabilities
            </span>
            <h2 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream mt-3">
              Everything you need
            </h2>
          </ScrollReveal>
          <FeatureGrid />
        </div>
      </section>

      {/* How It Works */}
      <section id="how" className="py-24 md:py-32">
        <div className="max-w-5xl mx-auto px-6">
          <ScrollReveal>
            <span className="text-[11px] uppercase tracking-[0.2em] text-amber">
              Getting started
            </span>
            <h2 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream mt-3">
              Three steps to remote dev
            </h2>
          </ScrollReveal>

          <div className="mt-16 md:border-t md:border-surface-overlay/30 md:pt-10 grid grid-cols-1 md:grid-cols-3 gap-10 md:gap-12">
            {steps.map((s, i) => (
              <ScrollReveal key={s.num} delay={i * 0.12}>
                <div>
                  <span className="font-display text-5xl font-bold text-amber/[0.08] leading-none select-none">
                    {s.num}
                  </span>
                  <h3 className="text-sm font-semibold text-cream mt-4">
                    {s.title}
                  </h3>
                  <p className="text-xs text-taupe leading-relaxed mt-2">
                    {s.desc}
                  </p>
                </div>
              </ScrollReveal>
            ))}
          </div>
        </div>
      </section>

      {/* Pricing */}
      <section id="pricing" className="py-24 md:py-32">
        <div className="max-w-5xl mx-auto px-6 text-center">
          <ScrollReveal>
            <span className="text-[11px] uppercase tracking-[0.2em] text-amber">
              Pricing
            </span>
            <h2 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream mt-3">
              Start free, go Pro
            </h2>
            <p className="text-sm text-taupe mt-3">
              One workspace is free, forever. Upgrade for the full toolkit.
            </p>
          </ScrollReveal>

          <div className="mt-16 grid grid-cols-1 sm:grid-cols-2 gap-4 max-w-[780px] mx-auto">
            <ScrollReveal delay={0.1} className="h-full">
              <div className="bg-surface-raised/80 border border-surface-overlay/40 rounded-2xl p-8 h-full flex flex-col text-left">
                <div className="text-[11px] uppercase tracking-[0.15em] text-amber mb-6">
                  Monthly
                </div>
                <div className="flex items-baseline gap-1">
                  <span className="font-display text-4xl font-bold text-cream">
                    $14.99
                  </span>
                  <span className="text-xs text-taupe">/month</span>
                </div>
                <p className="text-[11px] text-taupe/60 mt-1">
                  Cancel anytime
                </p>
                <ul className="mt-8 space-y-0 flex-1">
                  {proFeatures.map((f) => (
                    <li
                      key={f}
                      className="flex items-center gap-3 py-2.5 border-b border-surface-overlay/30 last:border-0"
                    >
                      <span className="w-1.5 h-1.5 rounded-full bg-amber shrink-0" />
                      <span className="text-[13px] text-cream">{f}</span>
                    </li>
                  ))}
                </ul>
                <span
                  className="block text-center bg-surface-overlay/50 text-taupe text-sm font-semibold px-6 py-3 rounded-xl mt-8 cursor-not-allowed select-none"
                >
                  Coming Soon
                </span>
              </div>
            </ScrollReveal>

            <ScrollReveal delay={0.2} className="h-full">
              <div className="relative bg-surface-raised border border-amber/20 rounded-2xl p-8 h-full flex flex-col text-left shadow-lg shadow-amber/[0.02]">
                <div className="absolute -top-3 left-1/2 -translate-x-1/2 bg-amber text-surface text-[10px] font-bold uppercase tracking-wider px-3.5 py-1 rounded-full whitespace-nowrap">
                  Save 33%
                </div>
                <div className="text-[11px] uppercase tracking-[0.15em] text-amber mb-6">
                  Annual
                </div>
                <div className="flex items-baseline gap-1">
                  <span className="font-display text-4xl font-bold text-cream">
                    $9.99
                  </span>
                  <span className="text-xs text-taupe">/month</span>
                </div>
                <p className="text-[11px] text-taupe/60 mt-1">
                  $119.99 billed annually
                </p>
                <ul className="mt-8 space-y-0 flex-1">
                  {proFeatures.map((f) => (
                    <li
                      key={f}
                      className="flex items-center gap-3 py-2.5 border-b border-surface-overlay/30 last:border-0"
                    >
                      <span className="w-1.5 h-1.5 rounded-full bg-amber shrink-0" />
                      <span className="text-[13px] text-cream">{f}</span>
                    </li>
                  ))}
                </ul>
                <span
                  className="block text-center bg-amber/10 text-taupe text-sm font-semibold px-6 py-3 rounded-xl mt-8 cursor-not-allowed select-none border border-amber/10"
                >
                  Coming Soon
                </span>
              </div>
            </ScrollReveal>
          </div>
        </div>
      </section>

      {/* Final CTA */}
      <section className="py-20 md:py-28">
        <div className="max-w-6xl mx-auto px-6 text-center">
          <ScrollReveal>
            <h2 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream">
              Ready to code from anywhere?
            </h2>
            <p className="text-sm text-taupe mt-4 max-w-md mx-auto">
              Download Tarsy and start shipping code from your pocket today.
            </p>
            <div className="flex flex-wrap justify-center gap-3 mt-8">
              <a
                href="https://testflight.apple.com/join/vDUvPDPe"
                target="_blank"
                rel="noopener noreferrer"
                className="inline-block w-[260px] text-center bg-amber/10 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline border border-amber/30 transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
              >
                iPhone — TestFlight Beta
              </a>
              <a
                href="/download/macos"
                className="inline-block w-[260px] text-center border border-amber/30 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
              >
                Download for Mac
              </a>
            </div>
            <p className="text-[11px] text-taupe/50 mt-4 tracking-wide">
              Beta — vagas limitadas no TestFlight
            </p>
          </ScrollReveal>
        </div>
      </section>
    </>
  );
}
