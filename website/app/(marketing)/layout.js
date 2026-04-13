import Navbar from "../components/Navbar";
import Footer from "../components/Footer";

export const metadata = {
  title: "Control Your Dev Environment Remotely",
  description:
    "Stream, control, and manage your Mac dev environment from your iPhone. Live screen streaming, AI coding agents (Claude Code, Gemini CLI, Codex, Aider), and end-to-end encrypted remote access.",
  alternates: {
    canonical: "https://www.tarsy.dev",
  },
};

export default function MarketingLayout({ children }) {
  return (
    <>
      <Navbar />
      {children}
      <Footer />
    </>
  );
}
