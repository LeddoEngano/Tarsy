import { NextResponse } from "next/server";

// Update these values when releasing a new version of the macOS app.
const LATEST_VERSION = "1.0.5";
const DOWNLOAD_URL = "https://www.tarsy.dev/download/macos";
const RELEASE_NOTES = "Fix app launch failure on macOS 26";

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
