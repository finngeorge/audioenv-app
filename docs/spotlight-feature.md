# Global Spotlight / Command Palette

A Raycast/Alfred-style floating search panel triggered by **Ctrl+Space** from any app. Search plugins, projects, bounces, and collections without leaving your DAW.

## How It Works

Press **Ctrl+Space** anywhere (even while Ableton/Logic/Pro Tools has focus) to open a floating panel. Type to search or use command verbs. The panel never steals focus from the frontmost app.

## Search Modes

- **Local** (default): Instant search against in-memory data from scanner, bounce, and collection services
- **Cloud**: Hits the `/api/search` API endpoint (toggle via segmented control)

Both modes support 200ms debounced input with relevance-scored results grouped by type.

## Command Verbs

Type a verb followed by a space to lock it in as a badge. The verb text is stripped from the input field so you can immediately type your search query.

| Verb | Aliases | Targets | Example |
|------|---------|---------|---------|
| `play` | `p` | Bounces | `play midnight sun` |
| `queue` | `q`, `add` | Bounces | `queue demo v2` |
| `download` | `d`, `dl` | Bounces | `dl master final` |
| `go` | `g`, `open` | All sections | `go plugins` |
| `share` | `sh` | Projects | `share my song` |

Backspace on an empty field clears the active verb. Escape clears verb first, then closes panel.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **⌃Space** | Toggle spotlight panel |
| **↑↓** | Navigate results |
| **↩** | Execute (play bounce, navigate to item) |
| **⌘↩** | Show in Finder (bounces, projects, plugins) |
| **⌥↩** | Open in DAW (projects — auto-detects Ableton/Logic/Pro Tools, opens latest non-backup session) |
| **⇧↩** | Quick Look (bounces, projects) |
| **esc** | Close panel (or clear active verb) |

## Default Actions (Enter with no verb)

- **Bounces** → Play
- **Projects** → Navigate to project in main window (auto-scrolls list)
- **Plugins** → Navigate to plugins view
- **Collections** → Navigate to collection

## Architecture

```
HotkeyManager (Carbon RegisterEventHotKey)
    ↓ Notification
SpotlightPanelController (NSPanel lifecycle, command execution)
    ↓ hosts
SpotlightPanelView (SwiftUI in NSHostingView)
    ↓ uses
SpotlightSearchService (debounce, local/API search, verb parsing)
```

The panel is an `NSPanel` with `.nonactivatingPanel` style — it floats above all windows without activating the app. Services are injected via `configure()` (not `@EnvironmentObject`) since the panel lives outside the SwiftUI window hierarchy.

## Files

### New (7)
- `Models/SpotlightTypes.swift` — Verbs, result types, input parser, quick actions, go targets
- `Views/SpotlightPanel.swift` — Non-activating NSPanel subclass
- `Views/SpotlightPanelView.swift` — SwiftUI view with search, results, keyboard nav
- `Services/HotkeyManager.swift` — Carbon global hotkey (configurable, persisted to UserDefaults)
- `Services/SpotlightSearchService.swift` — Local + API search with debounce and verb detection
- `Services/SpotlightPanelController.swift` — Panel lifecycle, command execution, quick actions

### Modified (4)
- `App.swift` — Added `SpotlightPanelController` + `HotkeyManager` as `@StateObject`, preloads bounces/collections on login
- `KeyboardCommands.swift` — Added notification names, "Spotlight Search" menu command
- `MenuBarManager.swift` — Added "Quick Search" to status bar dropdown
- `Views/SessionBrowserView.swift` — Auto-scrolls project list when navigating from spotlight
- `Views/ContentView.swift` — Handles `.navigateToSection` notification, centered window positioning

## Requirements

- macOS 14+ (Sonoma)
- Authentication required (opens login gate if not signed in)
- No external dependencies (Carbon HIToolbox is a system framework)
- Hotkey configurable, default **Ctrl+Space** (stored in UserDefaults)
