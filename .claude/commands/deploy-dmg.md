Build, sign, notarize, and deploy a new TarsymacOS DMG release to Supabase Storage.

## Instructions

You are deploying a new version of the macOS app. Follow these steps:

### 1. Determine the version

Ask the user for:
- **Version number** (semver, e.g. `1.1.0`)
- **Release notes** (optional, e.g. "Bug fixes and performance improvements")

Check the current version in `TarsymacOS/project.yml` (CFBundleShortVersionString) and confirm the bump with the user before proceeding.

### 2. Run the deploy script

```bash
./scripts/deploy-dmg.sh <version> "<release_notes>"
```

This script handles everything:
1. Bumps version in `project.yml` (version + build number)
2. Regenerates the Xcode project via `xcodegen`
3. Builds, signs, and notarizes the DMG via `build-dmg.sh`
4. Uploads versioned DMG (`Tarsy-<version>.dmg`) to Supabase bucket with immutable cache
5. Updates `Tarsy.dmg` in bucket with 60s cache
6. Updates `website/app/api/latest-version/route.js` with new version
7. Updates `website/next.config.mjs` redirect to versioned URL

### 3. Monitor the build

The build + notarization process takes several minutes. Monitor each step and report errors immediately. Common failure points:
- Xcode build errors (check Swift compilation)
- Code signing (Developer ID certificate must be valid)
- Notarization (Apple may reject for hardened runtime issues)

### 4. Post-deploy

After the script succeeds:
1. Show the user the deploy summary (version, URL, size)
2. Ask if they want to commit the changes (`project.yml`, `route.js`, `next.config.mjs`)
3. Remind them the website needs to be deployed for the API/redirect changes to take effect (Vercel auto-deploys on push to main)
