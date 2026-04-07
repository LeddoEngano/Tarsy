/** @type {import('next').NextConfig} */
const nextConfig = {
  async redirects() {
    return [
      {
        source: "/download/macos",
        destination:
          "https://xtblbghhlkroskzljqcl.supabase.co/storage/v1/object/public/tarsy-releases/Tarsy-1.0.18.dmg",
        permanent: false,
      },
    ];
  },
};

export default nextConfig;
