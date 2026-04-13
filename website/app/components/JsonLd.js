export function OrganizationJsonLd() {
  const schema = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Organization",
        "@id": "https://www.tarsy.dev/#organization",
        name: "Tarsy",
        legalName: "OPALLOO INOVACOES LTDA",
        url: "https://www.tarsy.dev",
        logo: {
          "@type": "ImageObject",
          url: "https://www.tarsy.dev/eyes.png",
        },
        contactPoint: {
          "@type": "ContactPoint",
          email: "support@tarsy.dev",
          contactType: "customer support",
        },
        sameAs: [
          "https://apps.apple.com/us/app/tarsy/id6761079923",
          "https://github.com/LeddoEngano/Tarsy",
        ],
        address: {
          "@type": "PostalAddress",
          streetAddress: "Avenida Brigadeiro Faria Lima, 1811 - Cj 115",
          addressLocality: "São Paulo",
          addressRegion: "SP",
          postalCode: "01452-001",
          addressCountry: "BR",
        },
      },
      {
        "@type": "WebSite",
        "@id": "https://www.tarsy.dev/#website",
        url: "https://www.tarsy.dev",
        name: "Tarsy",
        description:
          "Remote dev environment control platform for the Apple ecosystem",
        publisher: {
          "@id": "https://www.tarsy.dev/#organization",
        },
      },
    ],
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
    />
  );
}

export function SoftwareApplicationJsonLd() {
  const schema = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "@id": "https://www.tarsy.dev/#app",
    name: "Tarsy",
    description:
      "Control your Mac dev environment from your iPhone. Live screen streaming, AI coding agents (Claude Code, Gemini CLI, Codex, Aider), and end-to-end encrypted remote access.",
    url: "https://www.tarsy.dev",
    applicationCategory: "DeveloperApplication",
    applicationSubCategory: "Remote Development",
    operatingSystem: ["iOS 17.0", "macOS 14.0"],
    offers: [
      {
        "@type": "Offer",
        name: "Free",
        price: "0",
        priceCurrency: "USD",
      },
      {
        "@type": "Offer",
        name: "Tarsy Pro Monthly",
        price: "14.99",
        priceCurrency: "USD",
      },
      {
        "@type": "Offer",
        name: "Tarsy Pro Annual",
        price: "119.99",
        priceCurrency: "USD",
      },
    ],
    downloadUrl: "https://apps.apple.com/us/app/tarsy/id6761079923",
    installUrl: "https://apps.apple.com/us/app/tarsy/id6761079923",
    publisher: {
      "@id": "https://www.tarsy.dev/#organization",
    },
    featureList: [
      "Live screen streaming from Mac to iPhone",
      "AI coding agent control (Claude Code, Gemini CLI, Codex CLI, Aider)",
      "End-to-end encrypted remote access",
      "Voice-to-text prompt input in 9 languages",
      "Multi-workspace management",
      "Git checkpoint and rollback",
      "LAN and relay connectivity",
    ],
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
    />
  );
}

export function WebPageJsonLd({ url, name, description, breadcrumbs }) {
  const schema = {
    "@context": "https://schema.org",
    "@type": "WebPage",
    url,
    name,
    description,
    isPartOf: {
      "@id": "https://www.tarsy.dev/#website",
    },
    publisher: {
      "@id": "https://www.tarsy.dev/#organization",
    },
    breadcrumb: {
      "@type": "BreadcrumbList",
      itemListElement: breadcrumbs.map((item, i) => ({
        "@type": "ListItem",
        position: i + 1,
        name: item.name,
        item: item.url,
      })),
    },
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
    />
  );
}

export function FAQJsonLd() {
  const schema = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: [
      {
        "@type": "Question",
        name: "What is Tarsy?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Tarsy is a remote development platform for the Apple ecosystem. It lets developers stream their Mac screen, control their Mac, and run AI coding agents (Claude Code, Gemini CLI, Codex CLI, Aider) remotely from their iPhone. All communication is end-to-end encrypted.",
        },
      },
      {
        "@type": "Question",
        name: "How does Tarsy connect my iPhone to my Mac?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Tarsy uses a smart-connect system that tries your local network first (LAN, port 8642) with a 3-second timeout, then automatically falls back to an encrypted relay server. No port forwarding or VPN is required.",
        },
      },
      {
        "@type": "Question",
        name: "Is the screen streaming secure?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Yes. All communication between your iPhone and Mac is end-to-end encrypted using TOFU (trust-on-first-use) key pinning. The relay server forwards packets without being able to read them. Screen frames are never stored or logged.",
        },
      },
      {
        "@type": "Question",
        name: "Which AI coding agents does Tarsy support?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Tarsy supports Claude Code (Anthropic), Gemini CLI (Google), Codex CLI (OpenAI), Aider, and any custom CLI-based AI tool. Each agent runs as a local process on your Mac — Tarsy does not send your code to its own servers.",
        },
      },
      {
        "@type": "Question",
        name: "What does Tarsy cost?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Tarsy is free to use with 1 workspace. The Pro plan is $14.99 per month or $119.99 per year (approximately $9.99 per month), and includes unlimited workspaces and OpenClaw local AI access.",
        },
      },
      {
        "@type": "Question",
        name: "What Mac and iPhone versions does Tarsy require?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Tarsy requires macOS 14.0 or later (Apple Silicon and Intel) for the Mac companion app, and iOS 17.0 or later for the iPhone app.",
        },
      },
    ],
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
    />
  );
}
