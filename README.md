# keyouse

Control macOS **with the keyboard only**. A hotkey opens a search panel; every clickable UI element on screen gets a number hint. Press the number to click / right-click, or type a label to filter and jump. An accessibility-based navigator in the spirit of Shortcat / Homerow / Vimac.

Swift + AppKit, built on the macOS Accessibility API (`AXUIElement`). Ships as a single executable — no app bundle.

한국어 문서: [docs/README.ko.md](docs/README.ko.md)

## Requirements

- macOS 13+ (the Liquid Glass panel uses `NSGlassEffectView` on macOS 26+, falling back to `NSVisualEffectView` below)
- Swift 6 toolchain (Command Line Tools is enough; Xcode.app not required)
- **Accessibility** permission is required. Using `⌘Tab` window switching may also need **Input Monitoring**.

## Install / run

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
