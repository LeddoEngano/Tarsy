"use client";

import { ConnectionProvider } from "../lib/tarsy/ConnectionProvider";

export default function Providers({ children }) {
  return (
    <ConnectionProvider>
      {children}
    </ConnectionProvider>
  );
}
