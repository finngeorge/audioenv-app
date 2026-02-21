import AVFoundation
import Foundation
import os.log

/// Fast-changing playback time state, isolated so only PlayerBarView re-renders on tick.
@MainActor
class PlaybackTimeObserver: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

/// Manages audio playback of bounce files with queue support.
@MainActor
class AudioPlayerService: NSObject, ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "AudioPlayer")

    // MARK: - Published State

    @Published var currentBounce: Bounce?
    @Published var queue: [Bounce] = []
    @Published var isPlaying = false
    @Published var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }

    /// Time state split out so high-frequency updates don't invalidate all observers.
    let timeObserver = PlaybackTimeObserver()

    // MARK: - Private State

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Index of the currently playing bounce within the queue, or nil if not queued.
    private var currentQueueIndex: Int?

    // MARK: - Playback Controls

    /// Play a single bounce (replaces current playback, does not affect queue).
    func play(bounce: Bounce) {
        guard bounce.isLocallyAvailable else {
            logger.warning("Cannot play bounce that is not locally available: \(bounce.fileName)")
            return
        }

        let url = URL(fileURLWithPath: bounce.filePath)
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = volume

            stopTimer()
            player?.stop()

            player = newPlayer
            currentBounce = bounce
            timeObserver.duration = newPlayer.duration
            timeObserver.currentTime = 0

            newPlayer.play()
            isPlaying = true
            startTimer()

            logger.info("Playing: \(bounce.fileName)")
        } catch {
            logger.error("Failed to play \(bounce.fileName): \(error)")
        }
    }

    /// Pause current playback.
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    /// Resume paused playback.
    func resume() {
        guard player != nil else { return }
        player?.play()
        isPlaying = true
        startTimer()
    }

    /// Toggle play/pause state.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Play the next bounce in the queue.
    func next() {
        guard !queue.isEmpty else { return }

        if let idx = currentQueueIndex {
            let nextIdx = idx + 1
            if nextIdx < queue.count {
                currentQueueIndex = nextIdx
                play(bounce: queue[nextIdx])
            } else {
                // End of queue
                stop()
            }
        } else if let current = currentBounce,
                  let idx = queue.firstIndex(of: current) {
            let nextIdx = idx + 1
            if nextIdx < queue.count {
                currentQueueIndex = nextIdx
                play(bounce: queue[nextIdx])
            } else {
                stop()
            }
        }
    }

    /// Play the previous bounce in the queue, or restart current track.
    func previous() {
        // If more than 3 seconds in, restart current track
        if timeObserver.currentTime > 3 {
            seek(to: 0)
            return
        }

        guard !queue.isEmpty else { return }

        if let idx = currentQueueIndex {
            let prevIdx = idx - 1
            if prevIdx >= 0 {
                currentQueueIndex = prevIdx
                play(bounce: queue[prevIdx])
            } else {
                seek(to: 0)
            }
        }
    }

    /// Seek to a specific time in seconds.
    func seek(to time: TimeInterval) {
        player?.currentTime = time
        timeObserver.currentTime = time
    }

    /// Play all provided bounces as a queue starting from the first.
    func playAll(bounces: [Bounce]) {
        let playable = bounces.filter(\.isLocallyAvailable)
        guard !playable.isEmpty else { return }

        queue = playable
        currentQueueIndex = 0
        play(bounce: playable[0])
    }

    /// Add a bounce to the end of the queue.
    func addToQueue(bounce: Bounce) {
        guard bounce.isLocallyAvailable else { return }
        queue.append(bounce)

        // If nothing is playing, start playback
        if currentBounce == nil {
            currentQueueIndex = queue.count - 1
            play(bounce: bounce)
        }
    }

    /// Clear the playback queue.
    func clearQueue() {
        queue.removeAll()
        currentQueueIndex = nil
    }

    // MARK: - Private Helpers

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentBounce = nil
        timeObserver.currentTime = 0
        timeObserver.duration = 0
        currentQueueIndex = nil
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.timeObserver.currentTime = player.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()

            // Auto-advance queue
            if let idx = self.currentQueueIndex, idx + 1 < self.queue.count {
                self.currentQueueIndex = idx + 1
                self.play(bounce: self.queue[idx + 1])
            } else {
                self.currentBounce = nil
                self.timeObserver.currentTime = 0
                self.timeObserver.duration = 0
                self.currentQueueIndex = nil
            }
        }
    }
}
