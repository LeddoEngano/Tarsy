/** @type {import('next').NextConfig} */
const nextConfig = {
  async redirects() {
    return [
      {
        source: "/download/macos",
        destination:
          "https://xtblbghhlkroskzljqcl.supabase.co/storage/v1/object/public/tarsy-releases/Tarsy-1.1.0.dmg",
        permanent: false,
      },
    ];
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(self), microphone=(self), geolocation=()" },
          { key: "Content-Security-Policy", value: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; media-src 'self' https://*.supabase.co; connect-src 'self' https://*.supabase.co wss://tarsy-relay.fly.dev wss://*.supabase.co; frame-ancestors 'none'" },
        ],
      },
    ];
  },
};

export default nextConfig;
