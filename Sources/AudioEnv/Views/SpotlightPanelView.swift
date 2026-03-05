import SwiftUI

/// The SwiftUI view rendered inside the floating spotlight panel.
/// Provides a search field, grouped results, keyboard navigation, and command execution.
struct SpotlightPanelView: View {
    @ObservedObject var searchService: SpotlightSearchService
    @ObservedObject var audioPlayer: AudioPlayerService
    let onExecute: (SpotlightVerb?, SpotlightResult) -> Void
    let onNavigateSection: (AppSection) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex = 0
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            contentArea
            Divider()
            footerBar
        }
        .frame(width: 680, height: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear {
            isTextFieldFocused = true
            selectedIndex = 0
        }
        .onChange(of: searchService.results) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: searchService.parsedInput.verb != nil ? "terminal" : "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            if let verb = searchService.parsedInput.verb {
                verbBadge(verb)
            }

            TextField("Search or type a command...", text: $searchService.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .light))
                .focused($isTextFieldFocused)
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
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

            Picker("", selection: $searchService.searchMode) {
                ForEach(SpotlightSearchService.SearchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            if searchService.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                        HStack(spacing: 6) {
                            Image(systemName: group.type.icon)
                                .font(.system(size: 10))
                            Text(group.type.label)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        ForEach(group.results) { result in
                            let index = currentGlobalIndex(for: result)
                            resultRow(result, isSelected: selectedIndex == index)
                                .id("result-\(result.id)")
                                .onTapGesture {
                                    selectedIndex = index
                                    executeSelected()
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
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

    private func resultRow(_ result: SpotlightResult, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            // Type badge
            Text(result.type.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }

            Spacer()

            if let format = result.format {
                Text(format.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
            }

            if isSelected {
                Image(systemName: searchService.parsedInput.verb?.icon ?? "return")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Go Targets

    private var goTargetsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SpotlightGoTarget.all.enumerated()), id: \.element.id) { index, target in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(selectedIndex == index ? .white : .secondary)

                        Text(target.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedIndex == index ? .white : .primary)

                        Spacer()

                        if selectedIndex == index {
                            Image(systemName: "return")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedIndex == index ? Color.accentColor : Color.clear)
                            .padding(.horizontal, 8)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onNavigateSection(target.section)
                        onDismiss()
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Verb Hints (empty state)

    private var verbHintsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Commands")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                ForEach(SpotlightVerb.allCases, id: \.rawValue) { verb in
                    HStack(spacing: 10) {
                        Image(systemName: verb.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(verb.label)
                                .font(.system(size: 13, weight: .medium))
                            Text(verb.hint)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchService.query = verb.rawValue + " "
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                Text("Or just type to search across plugins, projects, bounces, and collections.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
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
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9))
                Text("Navigate")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)

            HStack(spacing: 4) {
                Image(systemName: "return")
                    .font(.system(size: 9))
                Text("Select")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)

            HStack(spacing: 4) {
                Text("esc")
                    .font(.system(size: 9, design: .monospaced))
                Text("Close")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)

            Spacer()

            Text("⌃Space")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func verbBadge(_ verb: SpotlightVerb) -> some View {
        Text(verb.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
            )
    }

    private func moveSelection(_ delta: Int) {
        let count: Int
        if searchService.parsedInput.verb == .go && searchService.parsedInput.searchQuery.isEmpty {
            count = SpotlightGoTarget.all.count
        } else {
            count = searchService.flatResults.count
        }
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func executeSelected() {
        // Handle "go" targets
        if searchService.parsedInput.verb == .go && searchService.parsedInput.searchQuery.isEmpty {
            let targets = SpotlightGoTarget.all
            guard selectedIndex >= 0 && selectedIndex < targets.count else { return }
            onNavigateSection(targets[selectedIndex].section)
            onDismiss()
            return
        }

        // Handle search/command results
        let flat = searchService.flatResults
        guard selectedIndex >= 0 && selectedIndex < flat.count else { return }
        let result = flat[selectedIndex]
        onExecute(searchService.parsedInput.verb, result)
    }

    private func currentGlobalIndex(for result: SpotlightResult) -> Int {
        searchService.flatResults.firstIndex(where: { $0.id == result.id }) ?? 0
    }
}
