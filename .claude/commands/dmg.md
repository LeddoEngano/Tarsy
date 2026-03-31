Build, sign, notarize, and package the TarsymacOS app into a distributable DMG.

Run the build-dmg script:

```bash
./scripts/build-dmg.sh
```

Monitor the output and report the result to the user. If any step fails (build, signing, notarization), diagnose the error and suggest a fix.

The final DMG will be at `build/Tarsy.dmg`.
