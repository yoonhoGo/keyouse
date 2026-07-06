# keyouse

Control macOS **with the keyboard only**. A hotkey opens a search panel; every clickable UI element on screen gets a number hint. Press the number to click / right-click, or type a label to filter and jump. An accessibility-based navigator in the spirit of Shortcat / Homerow / Vimac.

Swift + AppKit, built on the macOS Accessibility API (`AXUIElement`). Ships as a single executable — no app bundle.

한국어 문서: [docs/README.ko.md](docs/README.ko.md)

## Requirements

- macOS 13+ (the Liquid Glass panel uses `NSGlassEffectView` on macOS 26+, falling back to `NSVisualEffectView` below)
- **Accessibility** permission. Using `⌘Tab` window switching may also need **Input Monitoring**.
- No Xcode/toolchain needed to install — a prebuilt universal binary is downloaded. (Building from source needs the Swift 6 Command Line Tools.)

## Install

```bash
brew install yoonhoGo/tap/keyouse
```

Installs a prebuilt universal binary — no build, no Xcode. No code signing/notarization is involved: the binary is ad-hoc signed by `swift build` and a Homebrew formula download isn't quarantined, so Gatekeeper allows it. If Homebrew asks you to trust the tap, follow its prompt (`brew trust --formula yoonhoGo/tap/keyouse`).

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

Default trigger **`⌘⇧Space`** opens the search panel. Rebind it to any combo — or to a **double-tapped modifier** like `⌘⌘` (Settings).

Each modifier has one concept: **`⌘` filter (clickables) + commands** · **`⌃` filter (form fields)** · **`⇧` amplify the key's base action** (click→new tab, move→scroll, ←→→history) · **`⌥` right-click**.

| Key | Action |
|-----|--------|
| type text | filter elements by label (IME/CJK supported) |
| `num` | click that hinted element |
| `⇧num` | open in a new tab (`⌘`-click) |
| `⌥num` | right-click |
| `⏎` | click the selected element (`⇧⏎` new tab · `⌥⏎` right-click) |
| `↑` `↓` *(or `⇧K` `⇧J`)* | move selection |
| `⇧↑` `⇧↓` *(or `⇧U` `⇧D`)* | scroll (a third of the scroll area) |
| `⇧←` `⇧→` *(or `⇧H` `⇧L`)* | history back / forward (`⌘[` / `⌘]`) |
| `⌘` (while held) | show buttons only |
| `⌃` (while held) | show form fields only (text / checkbox / radio) |
| `⌘L` | links only (toggle) |
| `⌃I` | focus the first input field |
| `/w` `/t` `/s` | search open windows / tabs / every pressable element |
| `>` | command palette — search & run the front app's menu commands (shortcut shown; `⏎`/`num` runs) |
| `⌘Q` | quit the front app |
| `⌘W` / `⌘⇧W` | close the current tab / window |
| `⌘Tab` | window picker · next (`⇧⌘Tab` prev, `⌘←→↑↓` move, release `⌘` to choose) |
| `⌘R` | rescan hints |
| `⌘S` | toggle deep search mode (hint every pressable element) |
| `⌘,` | settings |
| `esc` | cancel |

- The `⇧`/`⌥`-letter navigation keys are opt-in — pick **Arrows** or **⇧HJKL** in Settings.
- Menu-bar and Dock elements are hinted too, not just the front app.
- While a modifier is held or a number is being entered, the panel gets out of the way (configurable).
- After scrolling, hints are re-scanned shortly.
- Clicking another window with the mouse dismisses the panel.

## Settings (`⌘,`)

- **Language** (English / 한국어)
- **Panel shortcut** (record a combo, or double-tap a modifier like `⌘⌘`)
- **Start at login** (LaunchAgent)
- **Navigation keys** (Arrows or ⇧HJKL)
- **Shortcut guide** visibility and font size
- **Panel opacity while typing** (0 = hidden)
- **Rescan delay after scrolling**
- **Roles shown for the `⌘` / `⌃` filters** (AX-role checkboxes)
- **Version / check for updates** (in-app update from the Homebrew tap)
- **Reset to defaults**

Settings persist in `UserDefaults`. Font/guide-visibility changes apply the next time the panel opens.

## Build from source

```bash
swift build -c release      # → .build/release/keyouse
```

See `CLAUDE.md` for architecture.

## Releasing (maintainers)

Distribution is a **Homebrew tap** ([yoonhoGo/homebrew-tap](https://github.com/yoonhoGo/homebrew-tap)) whose formula installs a **prebuilt universal binary** from the GitHub release. No Apple Developer account, code signing, or notarization is involved (ad-hoc signed, formula downloads aren't quarantined).

Cutting a release is automated by `.github/workflows/release.yml` — push a tag and it builds the universal binary, publishes the release with it, and bumps the tap formula (`url` + `sha256` + `version`):

```bash
git tag v0.2.0 && git push origin v0.2.0
```

One-time setup: the workflow needs a Personal Access Token with write access to the tap repo, stored as the repo secret **`TAP_GITHUB_TOKEN`** (the default `GITHUB_TOKEN` can't push to another repo).

