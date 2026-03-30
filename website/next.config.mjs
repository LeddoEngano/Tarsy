/** @type {import('next').NextConfig} */
const nextConfig = {
  async redirects() {
    return [
      {
        source: "/download/macos",
        destination:
          "https://xtblbghhlkroskzljqcl.supabase.co/storage/v1/object/public/tarsy-releases/Tarsy.dmg",
        permanent: false,
      },
    ];
  },
};

export default nextConfig;
