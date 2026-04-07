import Providers from "./Providers";

export const metadata = {
  title: {
    template: "%s — Tarsy",
    default: "Tarsy",
  },
};

export default function AppLayout({ children }) {
  return (
    <div className="app-shell">
      <Providers>
        {children}
      </Providers>
    </div>
  );
}
