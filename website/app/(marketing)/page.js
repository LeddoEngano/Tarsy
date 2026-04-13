import ScrollReveal from "../components/ScrollReveal";
import HeroDevices from "../components/HeroDevices";
import FeatureGrid from "../components/FeatureGrid";
import {
  SoftwareApplicationJsonLd,
  WebPageJsonLd,
  FAQJsonLd,
} from "../components/JsonLd";
import FAQ from "../components/FAQ";

const steps = [
  {
    num: "01",
    title: "Install Tarsy on your Mac",
    desc: "Download the companion macOS app. It runs as a lightweight menu bar daemon in the background — no dock icon, no intrusive windows. Supports Apple Silicon and Intel Macs running macOS 14 or later.",
  },
  {
    num: "02",
    title: "Open Tarsy on your iPhone",
    desc: "Sign in and your Mac appears automatically. Tarsy tries your local network first (under 3 seconds), then falls back to the encrypted relay server. No port forwarding, no VPN, no configuration needed.",
  },
  {
    num: "03",
    title: "Stream, chat, build",
    desc: "Watch your Mac screen in real time, send prompts to AI coding agents, manage your workspaces, review diffs, and ship code — all from your iPhone, wherever you are.",
  },
];

export default function Home() {
  return (
    <>
      <SoftwareApplicationJsonLd />
      <WebPageJsonLd
        url="https://www.tarsy.dev"
        name="Tarsy — Remote Dev Environment Control for Mac & iPhone"
        description="Stream, control, and manage your Mac dev environment from your iPhone. Live screen streaming, AI coding agents, and end-to-end encrypted remote access."
        breadcrumbs={[{ name: "Home", url: "https://www.tarsy.dev" }]}
      />
      <FAQJsonLd />

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
                  Tarsy is a remote desktop and AI coding agent platform for the Apple ecosystem.
                  Control your Mac dev environment from your iPhone — live screen streaming,
                  AI coding agents like Claude Code and Gemini CLI, and end-to-end encrypted
                  remote access, wherever you are.
                </p>
              </ScrollReveal>
              <ScrollReveal delay={0.3}>
                <div className="flex flex-wrap gap-3 mt-10">
                  <a
                    href="https://apps.apple.com/us/app/tarsy/id6761079923"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-block w-[260px] text-center bg-amber/10 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline border border-amber/30 transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
                  >
                    Download for iPhone
                  </a>
                  <a
                    href="/download/macos"
                    className="inline-block w-[260px] text-center border border-amber/30 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
                  >
                    Download for Mac
                  </a>
                </div>
                <p className="text-[11px] text-taupe/50 mt-4 tracking-wide">
                  Available on the App Store
                </p>
                <p className="text-[11px] text-taupe/40 mt-2 tracking-wide">
                  macOS 14+ &middot; Apple Silicon &amp; Intel &middot; iOS 17+
                </p>
              </ScrollReveal>
            </div>

            <div className="flex justify-center lg:justify-end scale-[0.65] -my-16 lg:scale-100 lg:my-0 order-first lg:order-last">
              <HeroDevices />
            </div>
          </div>
        </div>
      </section>

      {/* What is Tarsy */}
      <section className="py-20 md:py-28">
        <div className="max-w-4xl mx-auto px-6">
          <ScrollReveal>
            <span className="text-[11px] uppercase tracking-[0.2em] text-amber">
              What is Tarsy
            </span>
            <h2 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream mt-3">
              Remote Mac control from your iPhone
            </h2>
          </ScrollReveal>
          <ScrollReveal delay={0.1}>
            <div className="mt-8 space-y-4 text-sm text-taupe leading-relaxed max-w-3xl">
              <p>
                Tarsy streams your Mac screen to your iPhone in real time using hardware-accelerated
                H.264 encoding via ScreenCaptureKit and VideoToolbox. You get adaptive bitrate
                streaming — 6 Mbps at 30 fps on your local network, and 2 Mbps at 20 fps over the
                internet relay — with latency low enough to interact with your IDE, terminal, or
                browser naturally.
              </p>
              <p>
                Beyond screen streaming, Tarsy lets you run and interact with AI coding agents
                directly from your iPhone. Send prompts, review output, approve or deny permission
                requests, and monitor token usage for Claude Code, Gemini CLI, Codex CLI, Aider, or
                any custom CLI tool. Each agent runs as a local process on your Mac — Tarsy never
                sends your code to its own servers.
              </p>
              <p>
                All communication between your iPhone and Mac is end-to-end encrypted using TOFU
                (trust-on-first-use) key pinning. The relay server at Fly.io forwards encrypted
                packets without the ability to read them. Screen frames are never stored or logged on
                any server. Your code and your screen stay yours.
              </p>
            </div>
          </ScrollReveal>
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
              What you can do with Tarsy
            </h2>
            <p className="text-sm text-taupe mt-4 max-w-2xl leading-relaxed">
              Live screen streaming, multi-engine AI agents, voice input, workspace management,
              git safety nets, and remote file browsing — all from your iPhone.
            </p>
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
              How to set up remote development
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

      {/* FAQ */}
      <section id="faq" className="py-24 md:py-32">
        <div className="max-w-4xl mx-auto px-6">
          <ScrollReveal>
            <span className="text-[11px] uppercase tracking-[0.2em] text-amber">
              Questions
            </span>
            <h2 className="font-display text-3xl md:text-4xl font-bold tracking-tight text-cream mt-3">
              Frequently asked questions
            </h2>
          </ScrollReveal>
          <FAQ />
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
              Download Tarsy and start controlling your Mac dev environment from your iPhone today.
              Free to get started, no credit card required.
            </p>
            <div className="flex flex-wrap justify-center gap-3 mt-8">
              <a
                href="https://apps.apple.com/us/app/tarsy/id6761079923"
                target="_blank"
                rel="noopener noreferrer"
                className="inline-block w-[260px] text-center bg-amber/10 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline border border-amber/30 transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
              >
                Download for iPhone
              </a>
              <a
                href="/download/macos"
                className="inline-block w-[260px] text-center border border-amber/30 text-amber text-sm font-semibold py-3.5 rounded-xl no-underline transition-all duration-200 hover:opacity-100 hover:-translate-y-0.5 hover:bg-amber/[0.07] hover:border-amber/50 active:translate-y-0 active:scale-[0.98]"
              >
                Download for Mac
              </a>
            </div>
            <p className="text-[11px] text-taupe/50 mt-4 tracking-wide">
              Available on the App Store
            </p>
          </ScrollReveal>
        </div>
      </section>
    </>
  );
}
