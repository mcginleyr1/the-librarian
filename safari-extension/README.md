# Safari Web Clipper

The actual extension (manifest, popup, background script) lives in
`extension/`. The Xcode project in `TheLibrarian/` is just Apple's required
wrapper app — it references the files in `extension/` by relative path, so
**editing `extension/*` is enough; there is nothing to copy into Xcode**.
Rebuilding the wrapper picks the changes up.

## Rebuild + reinstall (macOS)

**Preferred: `just clipper`** (from the repo root). It builds Release with
xcodebuild, signs with the configured dev team, installs to
`/Applications/TheLibrarian.app`, and launches it once to register with
Safari. A signed app in /Applications survives Safari's periodic purge of
unsigned/DerivedData dev builds — this is why we stopped using plain ⌘R.
Then: Safari → Settings → Extensions → enable, and paste the API token
(app Settings → AI → API Access) into the popup.

Manual fallback via Xcode:

1. `open TheLibrarian/TheLibrarian.xcodeproj`
2. In the scheme picker (top bar), select **TheLibrarian (macOS)** with
   destination **My Mac**.
3. **Product → Run** (⌘R). This builds the app, launches it, and registers the
   bundled extension with Safari. The wrapper app window itself is just a
   landing page — you can quit it after it opens once.
4. Safari → **Settings → Extensions** → tick **TheLibrarian Extension**.
   - If it's missing from the list and you're building without a paid
     developer cert: enable the Develop menu (Safari → Settings → Advanced →
     "Show features for web developers"), then **Develop → Allow Unsigned
     Extensions**, and check the Extensions list again. Safari resets that
     switch on every restart, so re-enable it after relaunching Safari.
5. First clip on a site: Safari asks to grant the extension access — allow.

An existing older install is replaced automatically (same bundle id). If
Safari seems to hold onto a stale copy, quit Safari fully and Run again.

Note: the built app lives in Xcode's DerivedData; deleting DerivedData
removes the extension from Safari. To make it survive cleanups, after a
build drag the built `TheLibrarian.app` (Product → Show Build Folder in
Finder) into `/Applications` and launch it once from there.

## Configure after install

Open the extension popup on any page and fill in:

- **API URL** — e.g. `https://librarian.<your-tailnet>.ts.net`
- **API Token** — generate/reveal it in the app under
  **Settings → AI → API Access**. The clip API rejects requests without it.

Regenerating the token in Settings invalidates the old one immediately —
paste the new value into the popup afterwards.

## iOS

The project also has iOS targets (`TheLibrarian (iOS)`); building those
requires selecting your device and a development team in Signing &
Capabilities, then enabling the extension in iOS Settings → Apps → Safari →
Extensions. Same popup configuration applies.
