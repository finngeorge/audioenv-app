import SwiftUI

/// Review queue for bounce -> project predictions. One card per bounce, its
/// predicted projects listed best-first. Keyboard-driven:
///   → link to the selected project   ← none of these   ↑↓ choose a project
///   Space play/pause   S skip   ⇧→ link the whole group   ⌘Z undo
/// Cards can also be dragged left/right.
struct LinkBouncesView: View {
    @ObservedObject var queue: LinkQueueService
    @EnvironmentObject var audioPlayer: AudioPlayerService

    private enum Mode: String, CaseIterable { case review = "Review", recent = "Recently linked" }
    @State private var mode: Mode = .review
    @State private var exitDirection: SwipeDirection = .right
    @State private var dragOffset: CGFloat = 0
    @FocusState private var cardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .review: review
            case .recent: recentList
            }
        }
        .task {
            await queue.refresh()
            cardFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Link Bounces").font(.title2).bold()
                Text(queue.remainingCount == 0
                     ? "No suggestions waiting"
                     : "\(queue.remainingCount.formatted()) bounces in \(queue.groups.count.formatted()) songs to review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: mode) { _, newMode in
                if newMode == .recent { Task { await queue.loadRecent() } } else { cardFocused = true }
            }
            Button {
                withAnimation(.spring(duration: 0.3)) { queue.undo() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!queue.canUndo)
            .help("Undo the last decision (⌘Z)")
            Button {
                Task { await queue.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(queue.isLoading)
            .help("Refresh suggestions")
        }
        .padding()
    }

    // MARK: - Review

    @ViewBuilder
    private var review: some View {
        if queue.isLoading && queue.groups.isEmpty {
            Spacer()
            ProgressView("Loading suggestions…")
            Spacer()
        } else if queue.groups.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                groupList
                    .frame(width: 240)
                Divider()
                VStack(spacing: 0) {
                    if let error = queue.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(.red.opacity(0.85)))
                            .padding(.top, 8)
                    }
                    cardArea
                    keyHints
                }
            }
        }
    }

    private var groupList: some View {
        List(selection: Binding(
            get: { queue.currentGroup?.id },
            set: { id in
                if let id, let i = queue.groups.firstIndex(where: { $0.id == id }) { queue.selectGroup(i) }
                cardFocused = true
            }
        )) {
            ForEach(queue.groups) { group in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.projectName).lineLimit(1)
                        if let best = group.items.first?.predictions.first?.score {
                            Text("up to \(Int(best * 100))%").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(group.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(group.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var cardArea: some View {
        ZStack {
            if let item = queue.currentItem, let group = queue.currentGroup {
                BounceLinkCard(
                    item: item,
                    selectedIndex: queue.predictionIndex,
                    groupName: group.projectName,
                    remainingInGroup: group.items.count,
                    isPlaying: audioPlayer.isPlaying && audioPlayer.currentBounce?.id == item.id,
                    onSelect: { queue.predictionIndex = $0 },
                    onPlay: { togglePlay(item) },
                    dragOffset: dragOffset
                )
                .id(item.id)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                    removal: .modifier(
                        active: SwipeExit(direction: exitDirection, progress: 1),
                        identity: SwipeExit(direction: exitDirection, progress: 0))
                ))
                .gesture(dragGesture)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    private var keyHints: some View {
        HStack(spacing: 16) {
            hint("→", "Link")
            hint("←", "None of these")
            hint("↑↓", "Choose project")
            hint("Space", "Play")
            hint("S", "Skip")
            hint("⇧→", "Link whole song")
            hint("⌘Z", "Undo")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
            Text(label)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.seal").font(.system(size: 40)).foregroundStyle(.green)
            Text("All caught up").font(.headline)
            Text("New suggestions appear here after your next scan or sync.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Recently linked

    private var recentList: some View {
        Group {
            if queue.recent.isEmpty {
                VStack { Spacer(); Text("No links in the last 30 days").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                List(queue.recent) { link in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.fileName).lineLimit(1).truncationMode(.middle)
                            Text("→ \(link.projectName) · \(link.createdAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Undo") { Task { await queue.unlink(link) } }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .rightArrow:
            press.modifiers.contains(.shift) ? decideGroup() : decide(.right)
        case .leftArrow:
            decide(.left)
        case .upArrow:
            queue.movePrediction(by: -1)
        case .downArrow:
            queue.movePrediction(by: 1)
        case .space:
            if let item = queue.currentItem { togglePlay(item) }
        default:
            guard press.characters.lowercased() == "s" else { return .ignored }
            exitDirection = .up
            withAnimation(.easeOut(duration: 0.2)) { queue.skip() }
        }
        return .handled
    }

    private func decide(_ direction: SwipeDirection) {
        guard queue.currentItem != nil else { return }
        exitDirection = direction
        stopIfPlayingCurrent()
        // Let the new exit direction render before the card is removed
        DispatchQueue.main.async {
            withAnimation(.easeIn(duration: 0.25)) {
                if direction == .right { queue.confirmCurrent() } else { queue.rejectCurrent() }
                dragOffset = 0
            }
        }
    }

    private func decideGroup() {
        exitDirection = .right
        stopIfPlayingCurrent()
        DispatchQueue.main.async {
            withAnimation(.easeIn(duration: 0.25)) { queue.confirmGroup() }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { dragOffset = $0.translation.width }
            .onEnded { value in
                let dx = value.translation.width
                if dx > 120 {
                    decide(.right)
                } else if dx < -120 {
                    decide(.left)
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private func togglePlay(_ item: LinkQueueItem) {
        if audioPlayer.currentBounce?.id == item.id {
            audioPlayer.togglePlayPause()
        } else {
            audioPlayer.play(bounce: item.bounce.asBounce)
        }
    }

    private func stopIfPlayingCurrent() {
        if let item = queue.currentItem, audioPlayer.currentBounce?.id == item.id, audioPlayer.isPlaying {
            audioPlayer.pause()
        }
    }
}

// MARK: - Card

enum SwipeDirection { case left, right, up }

/// Card exit: slides off with a slight tilt and a LINKED / NOPE stamp.
private struct SwipeExit: ViewModifier {
    let direction: SwipeDirection
    let progress: CGFloat

    func body(content: Content) -> some View {
        let dx: CGFloat = direction == .right ? 700 : direction == .left ? -700 : 0
        let dy: CGFloat = direction == .up ? -400 : 0
        content
            .overlay(alignment: direction == .right ? .topLeading : .topTrailing) {
                if direction != .up {
                    SwipeStamp(linked: direction == .right).opacity(Double(progress))
                }
            }
            .rotationEffect(.degrees(Double(progress) * (direction == .right ? 10 : direction == .left ? -10 : 0)))
            .offset(x: dx * progress, y: dy * progress)
            .opacity(1 - Double(progress) * 0.6)
    }
}

private struct SwipeStamp: View {
    let linked: Bool

    var body: some View {
        Text(linked ? "LINKED" : "NOPE")
            .font(.system(size: 28, weight: .heavy, design: .rounded))
            .foregroundStyle(linked ? .green : .red)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(linked ? .green : .red, lineWidth: 3))
            .rotationEffect(.degrees(linked ? -14 : 14))
            .padding(24)
    }
}

private struct BounceLinkCard: View {
    let item: LinkQueueItem
    let selectedIndex: Int
    let groupName: String
    let remainingInGroup: Int
    let isPlaying: Bool
    let onSelect: (Int) -> Void
    let onPlay: () -> Void
    let dragOffset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)
                .help("Play / pause (Space)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.bounce.fileName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(remainingInGroup) left in \(groupName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("Which project is this from?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(Array(item.predictions.enumerated()), id: \.element.id) { index, prediction in
                    PredictionRow(prediction: prediction, rank: index + 1, isSelected: index == selectedIndex)
                        .onTapGesture { onSelect(index) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(dragTint.opacity(0.8), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .offset(x: dragOffset)
        .rotationEffect(.degrees(Double(dragOffset) / 40))
    }

    private var dragTint: Color {
        dragOffset > 40 ? .green : dragOffset < -40 ? .red : .clear
    }

    private var metadata: String {
        var parts = [item.bounce.format.uppercased()]
        if let d = item.bounce.durationSeconds {
            parts.append(Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
        }
        if let bpm = item.bounce.bpm { parts.append("\(bpm) BPM") }
        parts.append(item.bounce.fileModifiedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

private struct PredictionRow: View {
    let prediction: LinkPrediction
    let rank: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(Int(prediction.score * 100))%")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(scoreColor)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(prediction.projectName)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                FlowChips(reasons: prediction.reasons)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.green)
                    .help("Press → to link")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    private var scoreColor: Color {
        prediction.score >= 0.8 ? .green : prediction.score >= 0.6 ? .blue : .orange
    }
}

/// Reason chips; negative evidence (tempo/key mismatch) is shown in red.
private struct FlowChips: View {
    let reasons: [LinkReason]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(reasons, id: \.self) { reason in
            Text(reason.label)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((reason.weight < 0 ? Color.red : Color.secondary).opacity(0.12)))
                .foregroundStyle(reason.weight < 0 ? .red : .primary)
        }
    }
}
