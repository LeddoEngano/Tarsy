import { Outfit, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { OrganizationJsonLd } from "./components/JsonLd";

const outfit = Outfit({
  subsets: ["latin"],
  variable: "--font-outfit",
  display: "swap",
});

const jetbrains = JetBrains_Mono({
  subsets: ["latin"],
  variable: "--font-jetbrains",
  display: "swap",
});

export const metadata = {
  metadataBase: new URL("https://www.tarsy.dev"),
  title: {
    template: "%s | Tarsy",
    default: "Tarsy — Remote Dev Environment Control for Mac & iPhone",
  },
  description:
    "Stream, control, and manage your Mac dev environment from your iPhone. Live screen streaming, AI coding agents (Claude Code, Gemini CLI, Codex, Aider), and end-to-end encrypted remote access.",
  icons: {
    icon: "/eyes.png",
    apple: "/eyes.png",
  },
  alternates: {
    canonical: "https://www.tarsy.dev",
  },
  openGraph: {
    type: "website",
    locale: "en_US",
    url: "https://www.tarsy.dev",
    siteName: "Tarsy",
    title: "Tarsy — Remote Dev Environment Control for Mac & iPhone",
    description:
      "Stream, control, and manage your Mac dev environment from your iPhone. Live screen streaming, AI coding agents, and end-to-end encrypted remote access.",
    images: [
      {
        url: "/og-image.png",
        width: 1200,
        height: 630,
        alt: "Tarsy — Control your Mac dev environment from your iPhone",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Tarsy — Remote Dev Environment Control for Mac & iPhone",
    description:
      "Stream, control, and manage your Mac dev environment from your iPhone. AI coding agents, live streaming, and encrypted remote access.",
    images: ["/og-image.png"],
  },
  robots: {
    index: true,
    follow: true,
  },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en" data-scroll-behavior="smooth" className={`${outfit.variable} ${jetbrains.variable}`}>
      <body>
        <OrganizationJsonLd />
        {children}
      </body>
    </html>
  );
}
