import { Outfit, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import Navbar from "./components/Navbar";
import Footer from "./components/Footer";

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
  title: "Tarsy — Control your Mac dev environment from your iPhone",
  description:
    "Stream, control, and manage your Mac development workspace from your iPhone. Live screen streaming, AI coding agents, and remote access in your pocket.",
  icons: {
    icon: "/eyes.png",
    apple: "/eyes.png",
  },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en" data-scroll-behavior="smooth" className={`${outfit.variable} ${jetbrains.variable}`}>
      <body>
        <Navbar />
        {children}
        <Footer />
      </body>
    </html>
  );
}
