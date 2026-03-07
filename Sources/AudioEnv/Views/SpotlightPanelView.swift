import SwiftUI

/// The SwiftUI view rendered inside the floating spotlight panel.
/// Provides a search field, grouped results, keyboard navigation, and command execution.
/// Visual design matches the web landing page SpotlightDemo component.
struct SpotlightPanelView: View {
    @ObservedObject var searchService: SpotlightSearchService
    @ObservedObject var audioPlayer: AudioPlayerService
    let onExecute: (SpotlightVerb?, SpotlightResult) -> Void
    let onQuickAction: (SpotlightQuickAction, SpotlightResult) -> Void
    let onNavigateSection: (AppSection) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0
    @FocusState private var isTextFieldFocused: Bool
    @State private var fieldText = ""
    /// Tracks which plugin results are expanded to show format sub-items
    @State private var expandedPluginIds: Set<String> = []

    // MARK: - Design Constants (matching web tokens)

    private let accentBlue = Color(red: 0.145, green: 0.388, blue: 0.922)       // #2563eb
    private let accentBg = Color(red: 0.145, green: 0.388, blue: 0.922).opacity(0.10)
    private let accentText = Color(red: 0.420, green: 0.624, blue: 1.0).opacity(0.80)
    private let sidebarActive = Color(red: 0.145, green: 0.388, blue: 0.922).opacity(0.15)

    // Plugin format badge colors
    private let formatVST3 = Color(red: 0.494, green: 0.788, blue: 0.627)       // #7ec9a0
    private let formatAU = Color(red: 0.910, green: 0.643, blue: 0.784)         // #e8a4c8
    private let formatVST = Color(red: 0.478, green: 0.702, blue: 0.910)        // #7ab3e8
    private let formatAAX = Color(red: 0.831, green: 0.749, blue: 0.478)        // #d4bf7a

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.3)
            contentArea
            Divider().opacity(0.3)
            footerBar
        }
        .frame(width: 680, height: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onAppear {
            fieldText = ""
            isTextFieldFocused = true
            selectedIndex = 0
            cachedPreview = searchService.recentPreview().flatMap(\.results)
        }
        .onChange(of: searchService.activationCount) { _, _ in
            fieldText = ""
            isTextFieldFocused = true
            expandedPluginIds = []
            selectedIndex = 0
            cachedPreview = searchService.recentPreview().flatMap(\.results)
        }
        .onChange(of: searchService.results) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: searchService.activeVerb != nil ? "terminal" : "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.quaternary)
                .frame(width: 16)

            if let verb = searchService.activeVerb {
                verbBadge(verb)
                    .onTapGesture {
                        searchService.clearVerb()
                    }
            }

            TextField(searchService.activeVerb != nil ? "Type to search..." : "Search or type a command...", text: $fieldText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .focused($isTextFieldFocused)
                .onChange(of: fieldText) { _, newValue in
                    if searchService.activeVerb == nil {
                        let parsed = SpotlightInputParser.parse(newValue)
                        if let verb = parsed.verb, newValue.contains(" ") {
                            fieldText = parsed.searchQuery
                            searchService.activateVerb(verb, searchQuery: parsed.searchQuery)
                            return
                        }
                    }
                    searchService.query = newValue
                }
                .onKeyPress(.escape) {
                    if searchService.activeVerb != nil {
                        searchService.clearVerb()
                        fieldText = ""
                        return .handled
                    }
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.delete) {
                    if fieldText.isEmpty && searchService.activeVerb != nil {
                        searchService.clearVerb()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(characters: .init(charactersIn: "\u{7F}")) { _ in
                    if fieldText.isEmpty && searchService.activeVerb != nil {
                        searchService.clearVerb()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.return) {
                    executeSelected()
                    return .handled
                }

            if searchService.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if searchService.query.isEmpty && searchService.parsedInput.verb == nil {
            verbHintsView
        } else if searchService.parsedInput.verb == .go && searchService.parsedInput.searchQuery.isEmpty {
            goTargetsView
        } else if searchService.results.isEmpty && !searchService.isSearching && !searchService.query.isEmpty {
            emptyResultsView
        } else {
            resultsListView
        }
    }

    // MARK: - Results List

    private var resultsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(searchService.results) { group in
                        // Group header
                        Text(group.type.label.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.5)
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        ForEach(group.results) { result in
                            let index = currentGlobalIndex(for: result)
                            let isExpanded = expandedPluginIds.contains(result.id)

                            resultRow(result, isSelected: selectedIndex == index, isExpanded: isExpanded)
                                .id("result-\(result.id)")
                                .onTapGesture {
                                    selectedIndex = index
                                    executeSelected()
                                }

                            // Expanded format sub-items for plugins
                            if result.type == .plugin && isExpanded {
                                ForEach(result.formatVariants) { variant in
                                    formatVariantRow(variant, pluginName: result.name)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                let flat = searchService.flatResults
                if newIndex >= 0 && newIndex < flat.count {
                    proxy.scrollTo("result-\(flat[newIndex].id)", anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func resultRow(_ result: SpotlightResult, isSelected: Bool, isExpanded: Bool = false) -> some View {
        HStack(spacing: 10) {
            // Type badge — blue box with letter indicator
            Text(typeBadgeLetter(for: result))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accentText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(accentBg)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.quaternary)
                }
            }

            Spacer()

            // Stacked format badges for plugins
            if result.type == .plugin && !result.formats.isEmpty {
                HStack(spacing: 4) {
                    ForEach(result.formats, id: \.self) { format in
                        Text(format)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(formatBadgeColor(format))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(formatBadgeColor(format).opacity(0.12))
                            )
                    }
                }

                // Expand/collapse chevron
                if result.formatVariants.count > 1 {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }

            // Action badge on the right (Play, Share, Open in Ableton, etc.)
            if let badge = result.actionBadge(for: searchService.activeVerb) {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(result.actionBadgeColor(for: searchService.activeVerb))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(result.actionBadgeColor(for: searchService.activeVerb).opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? sidebarActive : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }

    /// Sub-row for an individual plugin format variant (shown when expanded)
    private func formatVariantRow(_ variant: SpotlightFormatVariant, pluginName: String) -> some View {
        HStack(spacing: 10) {
            // Indent spacer matching the type badge width
            Color.clear.frame(width: 24, height: 1)

            Text(variant.format)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(formatBadgeColor(variant.format))
                .frame(width: 36)

            Text(pluginName)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            // Show path's last component
            Text((variant.path as NSString).lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            let url = URL(fileURLWithPath: variant.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Returns the letter/icon for the type badge box
    private func typeBadgeLetter(for result: SpotlightResult) -> String {
        // When a verb is active, use the verb's icon character (like the web demo)
        if let verb = searchService.activeVerb {
            switch verb {
            case .play, .queue: return "\u{25B6}"   // ▶
            case .download: return "\u{2193}"        // ↓
            case .go: return "\u{2192}"              // →
            case .share: return "\u{2197}"           // ↗
            case .open: return result.type.badge
            }
        }
        return result.type.badge
    }

    // MARK: - Go Targets

    private var goTargetsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("PAGES")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(Array(SpotlightGoTarget.all.enumerated()), id: \.element.id) { index, target in
                    HStack(spacing: 10) {
                        Text("\u{2192}")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentText)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(accentBg)
                            )

                        Text(target.label)
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        Text("Go")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SpotlightVerb.go.badgeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(SpotlightVerb.go.badgeColor.opacity(0.12))
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedIndex == index ? sidebarActive : Color.clear)
                            .padding(.horizontal, 6)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onNavigateSection(target.section)
                        onDismiss()
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Verb Hints (empty state)

    private var verbHintsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("COMMANDS")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    ForEach(Array(SpotlightVerb.allCases.enumerated()), id: \.element.rawValue) { index, verb in
                        HStack(spacing: 10) {
                            Text(verbIconChar(verb))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(accentText)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(accentBg)
                                )

                            VStack(alignment: .leading, spacing: 1) {
                                Text(verb.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                Text(verbDescription(verb))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.quaternary)
                            }

                            Spacer()

                            Text(verb.aliases.joined(separator: ", "))
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedIndex == index ? sidebarActive : Color.clear)
                                .padding(.horizontal, 6)
                        )
                        .contentShape(Rectangle())
                        .id("hint-\(index)")
                        .onTapGesture {
                            searchService.activateVerb(verb, searchQuery: "")
                        }
                    }

                    // Recent items preview
                    if !cachedPreview.isEmpty {
                        Divider()
                            .padding(.vertical, 6)
                            .padding(.horizontal, 14)

                        Text("RECENT")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.5)
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)

                        let verbCount = SpotlightVerb.allCases.count
                        ForEach(Array(cachedPreview.enumerated()), id: \.element.id) { i, result in
                            let globalIndex = verbCount + i
                            recentPreviewRow(result, isSelected: selectedIndex == globalIndex)
                                .id("hint-\(globalIndex)")
                                .onTapGesture {
                                    selectedIndex = globalIndex
                                    executeSelected()
                                }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if isShowingVerbHints {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("hint-\(newIndex)", anchor: .center)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Cached recent preview items — only recomputed when results or activation changes
    @State private var cachedPreview: [SpotlightResult] = []

    /// Compact row for the recent items preview in the empty state
    private func recentPreviewRow(_ result: SpotlightResult, isSelected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(result.type.badge)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accentText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(accentBg)
                )

            Text(result.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            if let subtitle = result.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? sidebarActive : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }

    private func verbIconChar(_ verb: SpotlightVerb) -> String {
        switch verb {
        case .play: return "\u{25B6}"    // ▶
        case .download: return "\u{2193}" // ↓
        case .go: return "\u{2192}"       // →
        case .share: return "\u{2197}"    // ↗
        case .queue: return "+"
        case .open: return "\u{2750}"     // ❐
        }
    }

    private func verbDescription(_ verb: SpotlightVerb) -> String {
        switch verb {
        case .play: return "Play a bounce"
        case .download: return "Download a bounce"
        case .go: return "Navigate to a page or item"
        case .share: return "Share a project"
        case .queue: return "Add to play queue"
        case .open: return "Open project in its DAW"
        }
    }

    // MARK: - Empty Results

    private var emptyResultsView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("No results for \"\(searchService.parsedInput.searchQuery)\"")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text("Search across your entire library")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)

            Spacer()

            footerHint(key: "\u{2191}\u{2193}", label: "Navigate")
            footerHint(key: "\u{21B5}", label: "Open")
            footerHint(key: "esc", label: "Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func footerHint(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, design: .monospaced))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundStyle(.quaternary)
    }

    // MARK: - Helpers

    private func verbBadge(_ verb: SpotlightVerb) -> some View {
        Text(verb.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(accentBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(accentBlue.opacity(0.19), lineWidth: 1)
                    )
            )
    }

    private func formatBadgeColor(_ format: String) -> Color {
        switch format.uppercased() {
        case "VST3": return formatVST3
        case "AU", "AUDIOUNIT": return formatAU
        case "VST": return formatVST
        case "AAX": return formatAAX
        default: return .secondary
        }
    }

    /// Whether the empty-state commands list is showing
    private var isShowingVerbHints: Bool {
        searchService.query.isEmpty && searchService.parsedInput.verb == nil
    }

    private func moveSelection(_ delta: Int) {
        let count: Int
        if isShowingVerbHints {
            count = SpotlightVerb.allCases.count + cachedPreview.count
        } else if searchService.parsedInput.verb == .go && searchService.parsedInput.searchQuery.isEmpty {
            count = SpotlightGoTarget.all.count
        } else {
            count = searchService.flatResults.count
        }
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func executeSelected() {
        // Handle selecting a command or recent item from the verb hints list
        if isShowingVerbHints {
            let verbs = SpotlightVerb.allCases
            if selectedIndex < verbs.count {
                guard selectedIndex >= 0 else { return }
                searchService.activateVerb(verbs[selectedIndex], searchQuery: "")
                selectedIndex = 0
                return
            }
            // Recent item selected
            let recentIndex = selectedIndex - verbs.count
            let recents = cachedPreview
            guard recentIndex >= 0 && recentIndex < recents.count else { return }
            onExecute(nil, recents[recentIndex])
            return
        }

        if searchService.parsedInput.verb == .go && searchService.parsedInput.searchQuery.isEmpty {
            let targets = SpotlightGoTarget.all
            guard selectedIndex >= 0 && selectedIndex < targets.count else { return }
            onNavigateSection(targets[selectedIndex].section)
            onDismiss()
            return
        }

        let flat = searchService.flatResults
        guard selectedIndex >= 0 && selectedIndex < flat.count else { return }
        let result = flat[selectedIndex]

        // For plugins with multiple formats, Enter toggles expansion
        if result.type == .plugin && result.formatVariants.count > 1 {
            if expandedPluginIds.contains(result.id) {
                expandedPluginIds.remove(result.id)
            } else {
                expandedPluginIds.insert(result.id)
            }
            return
        }

        onExecute(searchService.parsedInput.verb, result)
    }

    private func executeQuickAction(_ action: SpotlightQuickAction) {
        let flat = searchService.flatResults
        guard selectedIndex >= 0 && selectedIndex < flat.count else { return }
        let result = flat[selectedIndex]
        guard SpotlightQuickAction.actions(for: result.type).contains(where: { $0.id == action.id }) else { return }
        onQuickAction(action, result)
    }

    private func currentGlobalIndex(for result: SpotlightResult) -> Int {
        searchService.flatResults.firstIndex(where: { $0.id == result.id }) ?? 0
    }
}
