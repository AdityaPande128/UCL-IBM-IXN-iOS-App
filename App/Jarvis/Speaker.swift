import AVFoundation

// Plays the daemon's spoken replies in arrival order. speak_start opens a
// fresh utterance window: an earlier stop() silences everything queued, but
// never a reply that began after the user's interruption.
final class Speaker: NSObject, AVAudioPlayerDelegate {
    private var queue: [Data] = []
    private var player: AVAudioPlayer?
    private var interrupted = false

    func begin() {
        interrupted = false
    }

    func enqueue(_ data: Data) {
        guard !interrupted else { return }
        queue.append(data)
        playNext()
    }

    func stop() {
        interrupted = true
        queue.removeAll()
        player?.stop()
        player = nil
    }

    private func playNext() {
        guard player == nil, !queue.isEmpty else { return }
        let data = queue.removeFirst()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let next = try? AVAudioPlayer(data: data) else {
            playNext()
            return
        }
        player = next
        next.delegate = self
        next.play()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playNext()
    }
}
