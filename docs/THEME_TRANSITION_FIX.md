# LocalConvert — Theme-Transition Fix (`System` Appearance Synchronization)

**Date:** 2026-11-21  
**Phase:** Phase 47 Final Closure  
**Status:** Verified & Accepted (`21 / 21` focused tests passed)

---

## 1. Root Cause

When switching from an explicit `Light` or `Dark` appearance to `System`, SwiftUI received `.preferredColorScheme(nil)` and relinquished its explicit appearance override. AppKit immediately changed `NSWindow.appearance` to the system appearance, while SwiftUI's content appearance updated later. This caused a temporary mismatch between the window chrome and application content.

---

## 2. Implementation

- Added `SystemAppearanceMonitor` to observe the macOS effective appearance.
- Added `AppearanceMode.resolvedColorScheme(system:)`.
- `System` mode now resolves to the current macOS `Light` or `Dark` color scheme and passes that explicit value to `.preferredColorScheme(...)` so AppKit window chrome and SwiftUI content update together.
- Added `isApplyingChrome` re-entrancy guard in `OpaqueWindowChromeHost` to prevent recursive chrome application during appearance updates.
- Retained the `System` appearance option in `Settings → Appearance`.

---

## 3. Verification Matrix

| Check | Scope | Result | Notes |
|---|---|---|---|
| **Focused Theme-Transition Verification** | `SystemAppearanceMonitor`, `AppearanceMode.resolvedColorScheme(system:)`, `OpaqueWindowChromeHost.isApplyingChrome`, `System ↔ Light ↔ Dark` transitions | **21 / 21 passed** | Post-47.1.4 focused verification |
| **Historical Phase 47.1.4 Full Regression** | Full `LocalConvertTests` (`77` suites) | **602 / 602 passed** (`0` skipped, `0` warnings) | Executed during Phase 47.1.4 prior to this theme-transition fix |
| **User Acceptance** | Live `System ↔ Light ↔ Dark` transitions | **Accepted** | `System` appearance option retained |
