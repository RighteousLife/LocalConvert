# LocalConvert — Release Security & Distribution Audit

**Date:** 2026-11-26  
**Scope:** Milestone 4 (`LC-003` Packaging Pipeline Hardening, `LC-004` Release Bundled-Only Enforcement & Entitlements Audit, `LC-018` Runtime Pinning Validation).

---

## 1. Entitlements Audit (`LocalConvert/LocalConvert.entitlements`)

Current entitlements in [LocalConvert.entitlements](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/LocalConvert.entitlements):

```xml
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
```

### Key Findings & Constraints

1. **`com.apple.security.cs.disable-library-validation` (Currently Retained — Requires External Developer ID Validation to Remove):**
   - **Why present:** `LocalConvert.app` embeds dynamic libraries (`LocalConvert/Frameworks/libwebp.dylib`, `libsharpyuv.dylib`) and the bundled `LibreOffice` runtime (`Contents/Resources/LibreOffice/` + `LibreOfficePython.framework`).
   - **Under Hardened Runtime (`ENABLE_HARDENED_RUNTIME: true` / `codesign --options runtime`):** macOS Library Validation blocks loading any Mach-O dynamic library whose Code Signing Team ID differs from the host app's Team ID. For ad-hoc (`-`) local builds (`TeamIdentifier=not set`), or when third-party runtimes have mismatched Team IDs prior to unified Developer ID inside-out re-signing, removing `disable-library-validation` causes `dyld` library-load failures in `libwebp`/`libsharpyuv`/`soffice`.
   - **Hardening path:** When signing with a single Developer ID Application certificate (`--identity "Developer ID Application: ..."`), `scripts/package-release.sh` inside-out signs all embedded `.dylib`, `Frameworks`, `LibreOffice` Mach-O binaries, and `LibreOfficePython.framework` under the same Team ID. Removing `com.apple.security.cs.disable-library-validation` must be smoke-tested under a real Developer ID certificate (`soffice --headless --version`, WebP encode/decode, PDF/A export) before dropping it in production.

2. **App Sandbox (`com.apple.security.app-sandbox`) Feasibility & Direct Distribution Decision:**
   - **Not enabled:** LocalConvert is configured for direct macOS distribution (Developer ID + Hardened Runtime + Apple Notarization) rather than sandboxed Mac App Store distribution.
   - **Technical blockers for strict App Sandbox:**
     - Bundled headless LibreOffice (`soffice` -> `oosplash` / `soffice.bin` + `LibreOfficePython.framework`) spawns sub-processes and creates temporary UNO/profile state (`-env:UserInstallation=...`) and POSIX domain sockets that conflict with strict sandbox child-process inheritance rules (`com.apple.security.inherit`) unless LibreOffice itself is heavily patched/re-entitled.
     - Arbitrary user-selected Watch Folders, Batch Folder outputs, Finder Services, and sidecar file workflows require broad persistent filesystem access beyond single-file Open/Save panels.
   - **Compensating Controls Implemented:** Hardened Runtime (`--options runtime` applied inside-out across all nested Mach-O binaries and the outer app for Developer ID builds, and on the entitled outer app `flags=0x10002(adhoc,runtime)` for ad-hoc `-` builds while omitting it on unentitled nested helpers `flags=0x2(adhoc)` to avoid `dyld` Team ID mismatch in bundled `soffice`), URL scheme strict validation & explicit confirmation (`LC-002`), archive extraction traversal/special-file/disk-budget guards (`LC-008`), atomic writes (`LC-001`), and Release bundled-only binary enforcement (`LC-004`).

---

## 2. Release Bundled-Only Enforcement (`LC-004`)

- `BundledBinarySecurityPolicy` in [BundledFFmpegProvider.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Media/BundledFFmpegProvider.swift) evaluates `#if DEBUG` -> `false` and `#else` (Release) -> `true`.
- In `#if !DEBUG` (Release) builds:
  - Both `BundledFFmpegProvider` and `BundledLibreOfficeProvider` force `fallbackToSystem = false` even if `fallbackToSystem: true` is passed by a caller.
  - Environment overrides (`LOCALCONVERT_FFMPEG_PATH`, `LOCALCONVERT_FFPROBE_PATH`, `LOCALCONVERT_SOFFICE_PATH`) and developer fallback paths (`TEST_HOST`, `SRCROOT`, `#filePath`) are completely ignored.
  - All production `fallbackToSystem: true` sites across Media, Metadata, Subtitle, PDF/A, Office, and AudioToolbox views/engines now pass `BundledBinarySecurityPolicy.allowsSystemFallback` (zero literal `fallbackToSystem: true` sites remain in `LocalConvert/`).

---

## 3. Release Packaging Hardening (`LC-003` & `LC-018` Prep)

- [package-release.sh](file:///Users/cancan/Desktop/LocalConvert/scripts/package-release.sh):
  - Refuses dirty working trees by default unless `--allow-dirty` is explicitly passed.
  - Runs `xcodegen generate` strictly inside a temporary `/tmp` workspace (`XCODEGEN_WORKSPACE`), never mutating repository `LocalConvert.xcodeproj` or `project.yml`.
  - Separates `DerivedData` (`--derived-data` / `/tmp` workspace) from `--output-dir` (`./release`).
  - Stages `.app`, `.dmg`, `.zip`, `SHA256SUMS.txt`, and machine-readable `release-manifest.json` in a temporary directory and publishes via hidden sibling staging + `mv -f` **only after** build, inside-out `--options runtime` signing, `codesign --verify --deep --strict`, `verify-dependencies.sh --app`, optional notarization/stapling/`spctl`, and `shasum -a 256 -c` succeed.
  - Supports `--dry-run` and `--simulate-failure-before-publish` for non-destructive verification.
- [setup-runtime.sh](file:///Users/cancan/Desktop/LocalConvert/scripts/setup-runtime.sh):
  - Rejects unset `*_RELEASE_URL` / `*_SHA256`, placeholder URLs (`<owner>`, `<tag>`), non-HTTPS URLs, and malformed SHA-256 strings with non-zero exit codes without fabricating download URLs or hashes.

---

## 4. External Validation Gates

- **Developer ID Signing, Apple Notarization/Stapling (`xcrun notarytool`), Gatekeeper `spctl` Acceptance, and `disable-library-validation` Removal Smoke Test under a Real Team ID:**
  - **`BLOCKED — EXTERNAL VALIDATION REQUIRED`** (requires an Apple Developer ID Application certificate and `notarytool` keychain credentials not present in this offline sandbox).
