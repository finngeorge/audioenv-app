# AudioEnv

Audio production environment scanner and manager for macOS.

## Running the App

### ⚠️ Important: Text Input Fix

SwiftUI apps run from the terminal can't receive keyboard input properly. Use the provided script to create and launch a proper .app bundle:

```bash
./run-app.sh
```

This will:
1. Build the app
2. Create a proper AudioEnv.app bundle
3. Launch it with `open` (fully detached from terminal)
4. ✅ Text input will work correctly!

### Manual Build

```bash
# Create the .app bundle
./create-app-bundle.sh debug

# Launch it
open AudioEnv.app
```

### Development (⚠️ text input won't work)

```bash
swift run  # WARNING: keyboard input will go to terminal, not the app
```

## Features

- **Plugin Scanning**: Automatically discovers AU, VST, VST3, and AAX plugins
- **Project Discovery**: Finds and analyzes Ableton Live, Logic Pro, and Pro Tools projects
- **Plugin Catalog**: Shows plugin icons and details
- **Project Analysis**: Extracts tracks, clips, samples, and used plugins
- **Manual Parsing**: Parse individual project sessions on demand
- **Backup System**: S3-based backup for plugins and projects (in development)
- **Smart Caching**: Timestamp-based cache to avoid unnecessary rescans

## Navigation

- **Summary**: Overview of all scanned plugins and projects
- **Plugins**: Browse and filter your installed plugins
- **Projects**: View all DAW projects with details
  - Parse button for unparsed sessions
  - Project-level details with session breakdown
- **Scan**: Configure scan settings and manage cache
- **Backup**: Set up cloud backup (requires S3 credentials)
- **Profile**: User account and authentication

## Features

### Project Detail View
- View all sessions for a project
- Parse individual unparsed sessions with one click
- Show/hide backup sessions
- Quick access to project folder

### Search & Filter
- Search plugins by name
- Filter by format (AU, VST, VST3, AAX)
- Search projects by name
- Filter by DAW (Ableton, Logic, Pro Tools)

## Keyboard Shortcuts

- `Cmd+R`: Trigger rescan (with confirmation)
- `Cmd+P`: Manage scan paths
- `Cmd+F`: Focus search field
- `Cmd+Shift+?`: Show scan help

## Development

Built with:
- Swift 5.9+
- SwiftUI for macOS 14+
- SwiftPM for package management

### Project Structure

```
Sources/AudioEnv/
├── App.swift              # App entry point
├── Views/                 # SwiftUI views
│   ├── ContentView.swift  # Main navigation
│   ├── SummaryView.swift  # Dashboard
│   ├── PluginBrowserView.swift
│   ├── SessionBrowserView.swift
│   ├── ProjectDetailView.swift  # Project sessions & parse
│   ├── ScanView.swift     # Scan settings
│   └── ...
├── Services/              # Business logic
│   ├── ScannerService.swift
│   ├── BackupService.swift
│   ├── DAWIconLoader.swift
│   └── ...
└── Models/                # Data models
    ├── AudioPlugin.swift
    ├── AudioSession.swift
    └── ...
```

## Known Issues

- Pro Tools and Logic Pro parsing is limited due to proprietary formats
- Large project scans can be slow (caching helps)

## Recent Improvements

- ✅ DAW icons now display properly
- ✅ Search fields work correctly
- ✅ Manual parse button for projects
- ✅ Parsed badge uses blue (not green) to avoid color conflict
- ✅ Summary tab performance optimized with caching
- ✅ Rescan confirmation dialog
- ✅ Dedicated Scan settings tab

## License

TBD
