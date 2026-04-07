import Navbar from "../components/Navbar";
import Footer from "../components/Footer";

export const metadata = {
  title: "Tarsy — Control your dev environment remotely",
  description:
    "Stream, control, and manage your development workspace from your iPhone. Live screen streaming, AI coding agents, and remote access in your pocket.",
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
