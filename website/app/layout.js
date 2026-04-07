import { Outfit, JetBrains_Mono } from "next/font/google";
import "./globals.css";

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
  title: "Tarsy — Remote dev environment control",
  description:
    "Stream, control, and manage your development workspace remotely. Live screen streaming, AI coding agents, and remote access from anywhere.",
  icons: {
    icon: "/eyes.png",
    apple: "/eyes.png",
  },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en" data-scroll-behavior="smooth" className={`${outfit.variable} ${jetbrains.variable}`}>
      <body>
        {children}
      </body>
    </html>
  );
}
