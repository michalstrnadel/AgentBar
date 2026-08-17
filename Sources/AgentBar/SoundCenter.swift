import AVFoundation

/// Synthesized retro-console cues for the moments a session wants the user:
/// needs approval, asks a question, finishes. No audio assets — four short
/// C-major motifs are rendered to PCM in code and played through one lazy
/// AVAudioEngine that is torn down again between cues. Off by default (a status
/// app must not start beeping after an update); silent while the screen is
/// locked; edges only, so a burst of ticks never becomes a drum roll.
final class SoundCenter {
    static let shared = SoundCenter()

    enum Cue: String, CaseIterable { case permission, question, done, ack }

    // MARK: - Settings (UserDefaults-backed, read live on every play)

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundsEnabled") }
    }

    /// 0…1; buffers are baked with clipless headroom, so this maps straight to
    /// the player node and never rebuilds anything.
    static var volume: Double {
        get { min(1, max(0, UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 0.5)) }
        set { UserDefaults.standard.set(min(1, max(0, newValue)), forKey: "soundVolume") }
    }

    // MARK: - Synthesis specs

    /// One note of a cue: band-limited square or triangle, linear attack,
    /// exponential decay, normalized to `peak` so unit master gain cannot clip.
    private struct Note {
        let freq: Double
        let square: Bool     // false = triangle
        let detune: Bool     // square shimmer: two oscillators ±3 cents
        let durMs: Double
        let gapMs: Double    // silence after the note
        let attackMs: Double
        let decayTauMs: Double
        let peak: Float
    }

    /// Four related motifs in C major. Permission and done share the square
    /// timbre (its C6→G5 is done's arpeggio top, reversed); question and ack
    /// share the triangle. Contours stay distinct: falling pair, rising pair,
    /// rising triple, single tick.
    private static let specs: [Cue: [Note]] = [
        .permission: [ // "knock": descending fourth, firm
            Note(freq: 1046.50, square: true, detune: true, durMs: 100, gapMs: 40,
                 attackMs: 3, decayTauMs: 60, peak: 0.28),
            Note(freq: 783.99, square: true, detune: true, durMs: 160, gapMs: 0,
                 attackMs: 3, decayTauMs: 90, peak: 0.26),
        ],
        .question: [ // "hm?": rising fourth, soft — rising reads as a question
            Note(freq: 659.25, square: false, detune: false, durMs: 90, gapMs: 30,
                 attackMs: 5, decayTauMs: 55, peak: 0.30),
            Note(freq: 880.00, square: false, detune: false, durMs: 180, gapMs: 0,
                 attackMs: 5, decayTauMs: 110, peak: 0.30),
        ],
        .done: [ // "ta-da": rising C-major arpeggio
            Note(freq: 523.25, square: true, detune: true, durMs: 70, gapMs: 0,
                 attackMs: 3, decayTauMs: 45, peak: 0.20),
            Note(freq: 659.25, square: true, detune: true, durMs: 70, gapMs: 0,
                 attackMs: 3, decayTauMs: 45, peak: 0.20),
            Note(freq: 783.99, square: true, detune: true, durMs: 190, gapMs: 0,
                 attackMs: 3, decayTauMs: 110, peak: 0.24),
        ],
        .ack: [ // tiny confirm tick for an answer that reached disk
            Note(freq: 1046.50, square: false, detune: false, durMs: 45, gapMs: 0,
                 attackMs: 2, decayTauMs: 18, peak: 0.22),
        ],
    ]

    private static let sampleRate = 44_100.0

    // MARK: - State

    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let audioQueue = DispatchQueue(label: "agentbar.soundcenter")
    /// Previous state per session id, for edge detection. `primed` guards the
    /// launch snapshot: sessions that already exist when the app starts are old
    /// news, not events.
    private var last: [String: Session.State] = [:]
    private var primed = false
    private var screenLocked = false
    private var lastPlayed: [Cue: TimeInterval] = [:]
    private var idleStop: Timer?
    /// Bumped per play (main thread). The idle-stop timer captures the value it
    /// was armed for and bails when a newer play slipped in before it fired —
    /// otherwise a stale timer could cut a cue scheduled in the same instant.
    private var playGeneration = 0

    // MARK: - Lifecycle

    /// Installs the screen-lock observers. Does NOT start the audio engine —
    /// that happens lazily on the first cue and stops again 10s later, so the
    /// app never holds the audio device while idle.
    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenLocked = true }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenLocked = false }
        // Output device switched: tear down; the next play rebuilds cleanly.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { self?.teardownEngine() }
        }
    }

    /// Edge detection over a fresh session snapshot; call on the main queue from
    /// the store's onChange. Edges observed while sounds are off or the screen
    /// is locked are swallowed, not queued — no burst on unlock.
    func observe(_ sessions: [Session]) {
        var now: [String: Session.State] = [:]
        for s in sessions where now[s.id] == nil { now[s.id] = s.state }
        defer { last = now }
        guard primed else { primed = true; return }

        var fired: Set<Cue> = []
        for (id, state) in now {
            let prev = last[id]
            // prev == nil counts: a session appearing mid-permission is news.
            if state == .permission, prev != .permission { fired.insert(.permission) }
            if state == .question, prev != .question { fired.insert(.question) }
            // Same condition as the mascot's done-hop; a file appearing already
            // done (or question→done) stays silent. A deleted file is no cue.
            if state == .done, prev?.isWorking == true { fired.insert(.done) }
        }
        // One tick, one sound — most urgent wins.
        for cue in [Cue.permission, .question, .done] where fired.contains(cue) {
            play(cue)
            break
        }
    }

    /// An answer from a surface actually reached disk. User-initiated, so no
    /// cooldown — but still silent when sounds are off or the screen is locked.
    func playAck() { play(.ack, cooldown: 0) }

    /// The Settings "Test" button and volume slider audition.
    func preview() { play(.done, cooldown: 0, force: true) }

    private func play(_ cue: Cue, cooldown: TimeInterval = 1.0, force: Bool = false) {
        guard force || Self.enabled else { return }
        guard !screenLocked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Coalesce sessions finishing on adjacent ticks (fs event + 2s poll can
        // split one "everyone finished" moment) into a single cue.
        if cooldown > 0, let t = lastPlayed[cue], now - t < cooldown { return }
        lastPlayed[cue] = now
        playGeneration += 1
        let volume = Float(Self.volume) * 0.9
        audioQueue.async { [weak self] in
            guard let self, let buffer = self.buffer(for: cue) else { return }
            guard let player = self.ensureEngine(format: buffer.format) else { return }
            player.volume = volume
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
            DispatchQueue.main.async { self.armIdleStop() }
        }
    }

    // MARK: - Engine

    private func ensureEngine(format: AVAudioFormat) -> AVAudioPlayerNode? {
        if let player, engine?.isRunning == true { return player }
        teardownEngine()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            NSLog("AgentBar: sound engine failed to start: \(error)")
            return nil
        }
        self.engine = engine
        self.player = player
        return player
    }

    private func teardownEngine() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    /// The app shouldn't hold the audio device between cues; 10s after the last
    /// play the engine goes away and the next cue rebuilds it (~ms).
    private func armIdleStop() {
        idleStop?.invalidate()
        let generation = playGeneration
        idleStop = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.playGeneration == generation else { return }
            self.audioQueue.async { self.teardownEngine() }
        }
    }

    // MARK: - Buffers

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        if let b = buffers[cue] { return b }
        let b = Self.buildBuffer(for: cue)
        buffers[cue] = b
        return b
    }

    /// Renders one cue to a mono Float32 buffer: 10ms lead-in silence (absorbs
    /// engine spin-up and Bluetooth route wake), then the notes back to back.
    static func buildBuffer(for cue: Cue) -> AVAudioPCMBuffer? {
        guard let notes = specs[cue],
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return nil }
        let leadIn = Int(sampleRate * 0.010)
        let total = leadIn + notes.reduce(0) {
            $0 + Int(sampleRate * ($1.durMs + $1.gapMs) / 1000)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(total)),
              let data = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        data.update(repeating: 0, count: total)

        var cursor = leadIn
        for note in notes {
            let n = Int(sampleRate * note.durMs / 1000)
            render(note, into: data + cursor, count: n)
            cursor += n + Int(sampleRate * note.gapMs / 1000)
        }
        return buffer
    }

    private static func render(_ note: Note, into out: UnsafeMutablePointer<Float>, count: Int) {
        let dur = Double(count) / sampleRate
        let attack = note.attackMs / 1000
        let tau = note.decayTauMs / 1000
        // Band-limited additive synthesis — harmonics stop at 12 kHz, which is
        // what keeps a square pleasant instead of aliased-harsh.
        func raw(_ f: Double, _ t: Double) -> Double {
            var v = 0.0
            var k = 1.0
            if note.square {
                while k * f <= 12_000 { v += sin(2 * .pi * k * f * t) / k; k += 2 }
            } else {
                var sign = 1.0
                while k * f <= 12_000 {
                    v += sign * sin(2 * .pi * k * f * t) / (k * k)
                    sign = -sign
                    k += 2
                }
            }
            return v
        }
        let fLow = note.freq * pow(2, -3.0 / 1200)
        let fHigh = note.freq * pow(2, 3.0 / 1200)
        var peak: Float = 0
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var env = t < attack ? t / attack : exp(-(t - attack) / tau)
            let remaining = dur - t
            if remaining < 0.008 { env *= max(0, remaining / 0.008) } // declick fade
            let sample = note.detune
                ? (raw(fLow, t) + raw(fHigh, t)) * 0.5
                : raw(note.freq, t)
            let v = Float(sample * env)
            out[i] = v
            peak = max(peak, abs(v))
        }
        // Normalize to the spec'd peak: sets loudness and guarantees headroom.
        guard peak > 0 else { return }
        let scale = note.peak / peak
        for i in 0..<count { out[i] *= scale }
    }

    // MARK: - Offline verification (never touches the audio device)

    /// Renders every cue through a manual-rendering engine into WAVs and asserts
    /// each is audible and unclipped. Wired to the `--render-sounds <dir>` launch
    /// flag so the night shift can verify without making a sound.
    static func renderAllForVerification(to dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var allOK = true
        for cue in Cue.allCases {
            guard let buffer = buildBuffer(for: cue) else { print("\(cue.rawValue): no buffer"); return false }
            let format = buffer.format
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
                try engine.start()
            } catch {
                print("\(cue.rawValue): engine failed: \(error)")
                return false
            }
            player.scheduleBuffer(buffer, at: nil)
            player.play()

            guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                             frameCapacity: engine.manualRenderingMaximumFrameCount),
                  let file = try? AVAudioFile(forWriting: dir.appendingPathComponent("\(cue.rawValue).wav"),
                                              settings: format.settings)
            else { print("\(cue.rawValue): output setup failed"); return false }

            var remaining = AVAudioFramePosition(buffer.frameLength) + 2048 // decay tail
            var peak: Float = 0
            var sumSquares = 0.0
            var samples = 0
            while remaining > 0 {
                let want = AVAudioFrameCount(min(4096, remaining))
                guard (try? engine.renderOffline(want, to: out)) == .success else { allOK = false; break }
                try? file.write(from: out)
                if let p = out.floatChannelData?[0] {
                    for i in 0..<Int(out.frameLength) {
                        let v = abs(p[i])
                        peak = max(peak, v)
                        sumSquares += Double(v * v)
                        samples += 1
                    }
                }
                remaining -= AVAudioFramePosition(out.frameLength)
            }
            engine.stop()
            let rms = (sumSquares / Double(max(samples, 1))).squareRoot()
            let ok = peak >= 0.10 && peak <= 0.95 && rms >= 0.005
            print("\(cue.rawValue): peak \(peak) rms \(rms) -> \(ok ? "OK" : "FAIL")")
            allOK = allOK && ok
        }
        return allOK
    }
}
