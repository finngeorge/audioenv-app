# AudioEnv

Native macOS app for audio production dependency management. Scans your system for plugins and DAW projects, tracks dependencies, backs up your production environment, and syncs across devices.

## Features

- **Plugin Scanning** — Discovers AU, VST, VST3, and AAX plugins across your system
- **Project Discovery** — Finds and parses Ableton Live, Logic Pro, and Pro Tools projects
- **Dependency Tracking** — Maps which plugins each project uses
- **Cloud Backup** — S3-based backup for plugins and projects with deduplication
- **Cloud Sync** — Sync scan data across devices via the AudioEnv API
- **Collections** — Organize projects and bounces into shareable collections
- **Bounce Management** — Scan bounce folders, auto-link bounces to projects, playback
- **Session Monitoring** — Live monitoring of open DAW sessions via FSEvents
- **Project Sharing** — Share project plugin requirements and check compatibility
- **Spotlight / Command Palette** — Global search and command launcher for quick navigation

## Requirements

- macOS 14+
- Swift 5.9+
- Xcode (for building via .xcodeproj)

## Getting Started

```bash
# Generate Xcode project
xcodegen generate

# Open in Xcode and build (Cmd+B), or:
swift build
```

### Running

```bash
# Recommended: build and launch as .app bundle
./run-app.sh

# Or manually
./create-app-bundle.sh debug
open AudioEnv.app
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Space` | Open Spotlight / command palette (configurable) |
| `Cmd+R` | Rescan plugins and projects |
| `Cmd+F` | Focus search field |
| `Cmd+P` | Manage scan paths |

## Project Structure

```
Sources/AudioEnv/
├── App.swift                # Entry point
├── Views/                   # SwiftUI views (18 views)
├── Models/                  # Codable data models
├── Services/                # Business logic services
└── Utilities/               # DAW parsers (Ableton, Logic, Pro Tools)
```

## License

Proprietary — AudioEnv
