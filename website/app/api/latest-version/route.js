import { NextResponse } from "next/server";

// Update these values when releasing a new version of the macOS app.
const LATEST_VERSION = "1.1.4";
const DOWNLOAD_URL = "https://www.tarsy.dev/download/macos";
const RELEASE_NOTES = "Multi-runner Build & Run for Expo and Flutter, monorepo sub-path support, improved process detection";

export async function GET() {
  return NextResponse.json(
    {
      version: LATEST_VERSION,
      downloadURL: DOWNLOAD_URL,
      releaseNotes: RELEASE_NOTES,
    },
    {
      headers: {
        "Cache-Control": "public, max-age=300, s-maxage=300",
      },
    }
  );
}
