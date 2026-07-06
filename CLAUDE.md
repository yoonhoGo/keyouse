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
- To just check it launches: run, then `pgrep -fl release/keyouse`. Relaunching **takes over**: a new launch SIGTERMs the pid stored in `${TMPDIR}keyouse.lock` and takes the lock, so `make run` alone replaces a running instance (no manual pkill needed).

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
- **Coordinates.** AX/CG use a top-left origin; Cocoa uses bottom-left. The session opens on the **cursor's display** (`⌘<`/`⌘>` hops displays); `axRect(of:)` converts a screen's Cocoa frame to AX coords, and `HighlightView.axScreen` maps element AX frames to view-local. CG coords for click/scroll share AX's top-left origin, so no conversion there.
- **Clicking.** `AXPress` first, else a synthesized `CGEvent` click. **Right-click / scroll** have no AX action → `CGEvent`. Scroll follows Vimac: find the largest `AXScrollArea`, warp the cursor to its center, post a wheel event to `.cghidEventTap`.
- **Key routing.** The panel is the key window and search text goes through an `NSTextField` (first responder) for IME. A local `keyDown` monitor consumes only control keys/digits and passes text to the field (`handleKeyDown` returns a Bool "consumed"). `⌘Tab` is grabbed by the system switcher first, so it's intercepted via a **`CGEventTap` (only while the panel is open)**.
- **Filters.** `⌘` → `Settings.cmdVisibleRoles`, `⌃` → `Settings.ctrlVisibleRoles` (momentary, while held); `⌘L` → sticky links toggle. Updated from modifier `flagsChanged`.
- **Panel visibility.** While a modifier is held or a number is being entered, apply `Settings.panelActiveOpacity` (0 → `isHidden` for a true removal).
- **Localization.** English is default; every user-facing string is `L.t("English", "한국어")`. Language is a `Settings` value; the settings window rebuilds and the status menu is rebuilt on change. Panel/guide text applies on next open.
- **Entry point.** Without `KEYOUSE_DETACHED`, it relaunches itself as a child and the parent `exit(0)`s (terminal returns). The child `setsid()`s and takes an exclusive `flock` on `${TMPDIR}keyouse.lock` for single-instance, writing its pid into the file; a new launch that can't get the lock SIGTERMs that pid and takes over.
- **Permissions.** Accessibility required. If `CGEventTap` creation fails it only logs and continues (⌘Tab disabled).

## Distribution / release

- Distributed via a **Homebrew tap** (`yoonhoGo/homebrew-tap`, `Formula/keyouse.rb`) that installs a **prebuilt universal binary** from the GitHub release (no build on the user's machine, no Xcode/CLT). No signing/notarization/Apple Developer — the binary is ad-hoc signed by `swift build` and formula downloads aren't quarantined, so Gatekeeper allows it. Mac App Store is impossible (sandbox forbids the Accessibility API / `CGEventTap`). `zap` is Cask-only — never put it in this Formula.
- `packaging/keyouse.rb` is the reference copy of the formula. The universal binary is built with `swift build --arch arm64 --arch x86_64` (needs full Xcode → only on the CI runner; local CLT-only builds are native-arch).
- **Release automation**: `.github/workflows/release.yml` runs on `v*` tag push (macos-latest) — builds the universal binary, publishes the release with `keyouse-macos.tar.gz`, and rewrites the tap formula's `url`/`sha256`/`version`. Cut a release with `git tag vX.Y.Z && git push origin vX.Y.Z`. Requires repo secret **`TAP_GITHUB_TOKEN`** (PAT with write access to the tap; default `GITHUB_TOKEN` can't push cross-repo). Uses only built-in env + computed sha in `run:` — no untrusted `${{ }}`.
- **`formula-check.yml`**: on `packaging/keyouse.rb` change, `brew readall`/`style`/`audit` — `readall` actually loads the Ruby, catching errors `brew style` (static) misses (e.g. a Cask-only `zap` in a Formula).

## Code style

- Match surrounding tone when editing. Mark deliberate simplifications with a `ponytail:` comment stating the reason/ceiling (see existing examples).
- When adding a shortcut/setting, update all of: key handling (`handleKeyDown`/tap) + state reset (`dismiss`) + guide text (`PanelView.groups`) + `Settings`/settings window as needed, and wrap new user-facing strings in `L.t`.
