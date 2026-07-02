# CLAUDE.md — keyouse

An accessibility-based keyboard navigator for macOS UI. **Swift + AppKit, an SPM single executable** (no app bundle). User docs: `README.md` (English), `docs/README.ko.md` (Korean).

> Note: the repo folder is named `shott`, but the program/target is `keyouse`.

## Build · run · verify

```bash
swift build -c release        # or: make build
make run                      # build & launch (detaches, returns immediately)
make install / uninstall      # /usr/local/bin/keyouse (sudo)
```

- It's a GUI app with global hotkeys / an event tap, so **interactive behavior can't be verified headlessly**. After a change, confirm it compiles with `swift build -c release`; the user checks real behavior (panel, click, scroll, ⌘Tab) via `make run`.
- To just check it launches: run, then `pgrep -fl release/keyouse`. Clean up before testing with `pkill -9 -f keyouse; rm -f "${TMPDIR}keyouse.lock"` (single-instance means a second launch exits immediately if one is alive).

## Layout (Sources/keyouse/)

| File | Responsibility |
|------|----------------|
| `AX.swift` | Accessibility scan/actions. `Hit` (element+pid+role+subrole+frame), `WindowInfo`. `scan` (front app + menu bar + Dock), `scanWindow`, `windows` (open windows), `press`/`rightClick`/`scroll`/`focus`/`raise`. `actionableRoles` (what to collect), `chromeSubroles` (always excluded, e.g. traffic-light buttons) |
| `Overlay.swift` | `OverlayWindow` (fullscreen, transparent, key-capable), `HighlightView` (element highlights + number badges; dims non-matching prefixes while typing) |
| `Panel.swift` | `PanelView` (glass search field + count + grouped guide grid), `Panel.makeGlass` (`NSGlassEffectView` on macOS 26+, `NSVisualEffectView` fallback), `Panel.size` |
| `Picker.swift` | `WindowPickerView` (⌘Tab window list) |
| `Settings.swift` | `Settings` (UserDefaults accessors + `reset`), `LoginItem` (LaunchAgent plist), `SettingsWindow` (programmatic settings window) |
| `Strings.swift` | `Lang`, `L.t(en, ko)` — in-code localization (English default) |
| `main.swift` | `AppController` (orchestration) + entry point (detach · single instance · status bar) |

## Conventions / gotchas

- **Swift 6 strict concurrency.** `AppController`/`SettingsWindow` are `@MainActor`. `NSEvent` global/local monitors and the `CGEventTap` C callback run nonisolated, so inside them extract **only Sendable values (keyCode, Bool, String)** and hop via `MainActor.assumeIsolated { ... }`. Never pass non-Sendable objects (`NSEvent`, `NSRunningApplication`) across the closure boundary.
- **Coordinates.** AX/CG use a top-left origin; Cocoa uses bottom-left. Highlights convert with `screenHeight - y`, and only the **primary display** is handled (multi-monitor not implemented). CG coords for click/scroll share AX's top-left origin, so no conversion there.
- **Clicking.** `AXPress` first, else a synthesized `CGEvent` click. **Right-click / scroll** have no AX action → `CGEvent`. Scroll follows Vimac: find the largest `AXScrollArea`, warp the cursor to its center, post a wheel event to `.cghidEventTap`.
- **Key routing.** The panel is the key window and search text goes through an `NSTextField` (first responder) for IME. A local `keyDown` monitor consumes only control keys/digits and passes text to the field (`handleKeyDown` returns a Bool "consumed"). `⌘Tab` is grabbed by the system switcher first, so it's intercepted via a **`CGEventTap` (only while the panel is open)**.
- **Filters.** `⌘` → `Settings.cmdVisibleRoles`, `⌃` → `Settings.ctrlVisibleRoles` (momentary, while held); `⌘L` → sticky links toggle. Updated from modifier `flagsChanged`.
- **Panel visibility.** While a modifier is held or a number is being entered, apply `Settings.panelActiveOpacity` (0 → `isHidden` for a true removal).
- **Localization.** English is default; every user-facing string is `L.t("English", "한국어")`. Language is a `Settings` value; the settings window rebuilds and the status menu is rebuilt on change. Panel/guide text applies on next open.
- **Entry point.** Without `KEYOUSE_DETACHED`, it relaunches itself as a child and the parent `exit(0)`s (terminal returns). The child `setsid()`s and takes an exclusive `flock` on `${TMPDIR}keyouse.lock` for single-instance.
- **Permissions.** Accessibility required. If `CGEventTap` creation fails it only logs and continues (⌘Tab disabled).

## Distribution / release

- Distributed via a **Homebrew tap** (`yoonhoGo/homebrew-tap`, `Formula/keyouse.rb`) that **builds from source**. No app bundle, no signing/notarization, no Apple Developer account — a locally built binary is ad-hoc signed by `swift build` and isn't quarantined, so Gatekeeper allows it. Mac App Store is impossible (sandbox forbids the Accessibility API / `CGEventTap`).
- The formula has **no `depends_on xcode`** — it builds with the Command Line Tools' `swift` (`swift build -c release --disable-sandbox`).
- `packaging/keyouse.rb` is the reference copy of the formula in this repo.
- **Release automation**: `.github/workflows/release.yml` runs on `v*` tag push — creates the GitHub release and rewrites the tap formula's `url`/`sha256`. Cut a release with `git tag vX.Y.Z && git push origin vX.Y.Z`. Requires repo secret **`TAP_GITHUB_TOKEN`** (PAT with write access to the tap; default `GITHUB_TOKEN` can't push cross-repo). The workflow only uses built-in env (`$GITHUB_REF_NAME`) and a computed sha in `run:` — no untrusted `${{ }}` interpolation.

## Code style

- Match surrounding tone when editing. Mark deliberate simplifications with a `ponytail:` comment stating the reason/ceiling (see existing examples).
- When adding a shortcut/setting, update all of: key handling (`handleKeyDown`/tap) + state reset (`dismiss`) + guide text (`PanelView.groups`) + `Settings`/settings window as needed, and wrap new user-facing strings in `L.t`.
