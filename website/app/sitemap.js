export default function sitemap() {
  const baseUrl = "https://www.tarsy.dev";

  return [
    {
      url: baseUrl,
      lastModified: new Date("2026-04-13"),
      changeFrequency: "weekly",
      priority: 1.0,
    },
    {
      url: `${baseUrl}/download/macos`,
      lastModified: new Date("2026-04-13"),
      changeFrequency: "monthly",
      priority: 0.8,
    },
    {
      url: `${baseUrl}/contact`,
      lastModified: new Date("2026-04-13"),
      changeFrequency: "monthly",
      priority: 0.5,
    },
    {
      url: `${baseUrl}/privacy`,
      lastModified: new Date("2026-03-28"),
      changeFrequency: "yearly",
      priority: 0.3,
    },
    {
      url: `${baseUrl}/terms`,
      lastModified: new Date("2026-03-28"),
      changeFrequency: "yearly",
      priority: 0.3,
    },
  ];
}
