import "./globals.css";
import Navbar from "./components/Navbar";
import Footer from "./components/Footer";

export const metadata = {
  title: "Tarsy - Control your Mac dev environment from your iPhone",
  description:
    "Tarsy lets you stream, control, and manage your Mac development workspace from your iPhone. Live screen streaming, AI-powered assistance, and remote access.",
  icons: {
    icon: "/icon.png",
  },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <Navbar />
        {children}
        <Footer />
      </body>
    </html>
  );
}
