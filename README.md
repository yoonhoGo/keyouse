# keyouse

Control macOS **with the keyboard only**. A hotkey opens a search panel; every clickable UI element on screen gets a number hint. Press the number to click / right-click, or type a label to filter and jump. An accessibility-based navigator in the spirit of Shortcat / Homerow / Vimac.

Swift + AppKit, built on the macOS Accessibility API (`AXUIElement`). Ships as a single executable — no app bundle.

한국어 문서: [docs/README.ko.md](docs/README.ko.md)

## Requirements

- macOS 13+ (the Liquid Glass panel uses `NSGlassEffectView` on macOS 26+, falling back to `NSVisualEffectView` below)
- Swift 6 toolchain (Command Line Tools is enough; Xcode.app not required)
- **Accessibility** permission is required. Using `⌘Tab` window switching may also need **Input Monitoring**.

## Install

```bash
xcode-select --install                    # if you don't have the Command Line Tools yet
brew install yoonhoGo/tap/keyouse
```

Built from source on install (no code signing needed — Gatekeeper doesn't block a locally built binary; `swift build` ad-hoc signs it). If Homebrew asks you to trust the tap, follow its prompt (`brew trust --formula yoonhoGo/tap/keyouse`).

Then grant **Accessibility** permission (System Settings › Privacy & Security › Accessibility) and run `keyouse`.

## Build / run from source

```bash
make run          # build release and run (the terminal returns immediately)
make install      # install to /usr/local/bin/keyouse (sudo) → run `keyouse` anywhere
make uninstall
```

On first launch, grant permission in **System Settings › Privacy & Security › Accessibility** to the running host (Terminal or keyouse), then run again.

A menu-bar icon appears. Launched from a terminal, the process detaches so the prompt returns right away; running it again keeps a single instance. Quit via the menu-bar icon or `pkill -f keyouse`.

## Usage

Default trigger **`⌘⇧Space`** opens the search panel.

| Key | Action |
|-----|--------|
| type text | filter elements by label (IME/CJK supported) |
| `num` | left-click that hinted element |
| `⇧num` | right-click |
| `⏎` / `⇧⏎` | left / right click the selected element |
| `↑` `↓` | move selection |
| `⇧↑` `⇧↓` | scroll (a third of the scroll area) |
| `⌘` (while held) | show buttons only |
| `⌃` (while held) | show form fields only (text / checkbox / radio) |
| `⌘L` | links only (toggle) |
| `⌃I` | focus the first input field |
| `⌘Tab` | window picker · next (`⇧⌘Tab` prev, `⌘←→↑↓` move, release `⌘` to choose) |
| `⌘R` | rescan hints |
| `⌘,` | settings |
| `esc` | cancel |

- Menu-bar and Dock elements are hinted too, not just the front app.
- While a modifier is held or a number is being entered, the panel gets out of the way (configurable).
- After scrolling, hints are re-scanned shortly.
- Clicking another window with the mouse dismisses the panel.

## Settings (`⌘,`)

- **Language** (English / 한국어)
- **Trigger shortcut** (record a new combo)
- **Start at login** (LaunchAgent)
- **Shortcut guide** visibility and font size
- **Panel opacity while typing** (0 = hidden)
- **Rescan delay after scrolling**
- **Roles shown for the `⌘` / `⌃` filters** (AX-role checkboxes)
- **Reset to defaults**

Settings persist in `UserDefaults`. Font/guide-visibility changes apply the next time the panel opens.

## Build from source

```bash
swift build -c release      # → .build/release/keyouse
```

See `CLAUDE.md` for architecture.

## Releasing (maintainers)

Distribution is a **Homebrew tap** ([yoonhoGo/homebrew-tap](https://github.com/yoonhoGo/homebrew-tap)) whose formula builds from source, so no Apple Developer account, code signing, or notarization is involved.

Cutting a release is automated by `.github/workflows/release.yml` — push a tag and it creates the GitHub release and bumps the tap formula (`url` + `sha256`):

```bash
git tag v0.2.0 && git push origin v0.2.0
```

One-time setup: the workflow needs a Personal Access Token with write access to the tap repo, stored as the repo secret **`TAP_GITHUB_TOKEN`** (the default `GITHUB_TOKEN` can't push to another repo).

