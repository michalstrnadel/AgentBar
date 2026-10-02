import AVFoundation

/// Your own sounds: a file in `~/.agentbar/sounds/` named after a cue replaces that
/// cue, and a cue with no file keeps the synthesized one.
///
/// The names are the cues' raw values and they are a contract, the way a check id
/// in Diagnostics is — somebody's folder of files depends on them:
///
/// | file stem    | plays when                                         |
/// |--------------|----------------------------------------------------|
/// | `permission` | a session starts waiting on an approval            |
/// | `question`   | a session asks a question                          |
/// | `done`       | a working session finishes (and the Test button)   |
/// | `ack`        | an answer you gave actually reached disk           |
///
/// …with one of `aiff`, `wav`, `caf`, `mp3`, `m4a`. Nothing about *when* a cue plays
/// changes: `SoundCenter` still decides that — edges only, a cooldown, silent while
/// the screen is locked, off by default — and this file only answers "which sound".
///
/// Two ceilings, because a folder is a place people drop whatever they have. A
/// file over **2 MB** is never opened, and one longer than **3 seconds** is never
/// played: a cue is a knock on the door, and a ten-minute mp3 renamed `done.mp3`
/// would otherwise be a ten-minute song after every turn, with no way to stop it
/// short of quitting. Either way the cue falls back to the synthesized one rather
/// than going silent — a sound you did not expect beats missing the approval it
/// was for — and Settings says which file was passed over and why.
enum SoundPack {
    typealias Cue = SoundCenter.Cue

    /// In the order they are preferred when one cue has more than one file.
    /// Uncompressed first: nothing to decode, nothing to go wrong.
    static let extensions = ["aiff", "wav", "caf", "mp3", "m4a"]
    static let maxBytes = 2 * 1024 * 1024
    static let maxSeconds = 3.0

    static var directory: URL {
        AgentBarHome.url("sounds", isDirectory: true)
    }

    /// One file in the folder, as much of it as choosing needs. The modification
    /// time is part of it so a file replaced by another of the same size is noticed.
    struct Entry: Equatable {
        let name: String
        let size: Int
        var modified: TimeInterval = 0
    }

    /// Why a file that is named right is still not played.
    enum Refusal: Error, Equatable {
        case tooLarge, tooLong, unreadable

        var words: String {
            switch self {
            case .tooLarge:   return "over 2 MB"
            case .tooLong:    return "longer than 3 s"
            case .unreadable: return "not a sound macOS can play"
            }
        }
    }

    enum Choice: Equatable {
        /// This file is the cue, as far as a listing can tell.
        case file(Entry)
        /// Named for the cue, and refused before it was ever opened.
        case refused(Entry, Refusal)
    }

    // MARK: - Choosing (pure)

    /// Directory listing → which file each cue would use.
    ///
    /// Case does not matter (`Done.WAV` is `done.wav`; most Mac volumes do not tell
    /// them apart either), hidden files and anything not named for a cue are
    /// ignored, and where one cue has several files the first acceptable one in
    /// `extensions` order wins. A cue whose only files are too large says so rather
    /// than disappearing from the answer, because "why is my sound not playing" is
    /// the question this has to be able to answer.
    static func resolve(_ entries: [Entry]) -> [Cue: Choice] {
        var candidates: [Cue: [(rank: Int, entry: Entry)]] = [:]
        for entry in entries where !entry.name.hasPrefix(".") {
            let ns = entry.name as NSString
            let ext = ns.pathExtension.lowercased()
            guard let rank = extensions.firstIndex(of: ext),
                  let cue = Cue(rawValue: ns.deletingPathExtension.lowercased())
            else { continue }
            candidates[cue, default: []].append((rank, entry))
        }
        var out: [Cue: Choice] = [:]
        for (cue, list) in candidates {
            let ordered = list.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.entry.name < $1.entry.name }
            if let fits = ordered.first(where: { $0.entry.size <= maxBytes }) {
                out[cue] = .file(fits.entry)
            } else if let first = ordered.first {
                out[cue] = .refused(first.entry, .tooLarge)
            }
        }
        return out
    }

    /// What is in the folder now. A missing folder is an empty one — that is the
    /// state every install starts in.
    static func listing(of dir: URL = directory, fileManager: FileManager = .default) -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return Entry(name: url.lastPathComponent, size: values.fileSize ?? 0,
                         modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
    }

    // MARK: - Opening

    /// Reads the file's header only — its length and layout, not its samples — and
    /// says whether it would be played. What Settings uses, so opening the window
    /// never decodes anybody's music.
    static func probe(_ url: URL) -> Refusal? {
        guard let file = try? AVAudioFile(forReading: url) else { return .unreadable }
        return check(file)
    }

    private static func check(_ file: AVAudioFile) -> Refusal? {
        let format = file.processingFormat
        // Mono or stereo: the player node is connected at the buffer's own layout,
        // and a file with a dozen channels is not a cue anybody made on purpose.
        guard format.sampleRate > 0, (1...2).contains(format.channelCount), file.length > 0
        else { return .unreadable }
        return Double(file.length) / format.sampleRate > maxSeconds ? .tooLong : nil
    }

    /// The file as a buffer ready for the player, or why not.
    ///
    /// The duration is checked from the header **before** a sample is read, so a
    /// long file costs a header parse and nothing more. The same 10 ms of silence
    /// the synthesized cues open with goes in front: it absorbs the engine spinning
    /// up and a Bluetooth route waking, which otherwise eat the start of the sound.
    static func load(_ url: URL) -> Result<AVAudioPCMBuffer, Refusal> {
        guard let file = try? AVAudioFile(forReading: url) else { return .failure(.unreadable) }
        if let refusal = check(file) { return .failure(refusal) }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let leadIn = AVAudioFrameCount(format.sampleRate * 0.010)
        guard let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: read)) != nil, read.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: leadIn + read.frameLength),
              let src = read.floatChannelData, let dst = out.floatChannelData
        else { return .failure(.unreadable) }
        out.frameLength = leadIn + read.frameLength
        for ch in 0..<Int(format.channelCount) {
            dst[ch].update(repeating: 0, count: Int(leadIn))
            (dst[ch] + Int(leadIn)).update(from: src[ch], count: Int(read.frameLength))
        }
        return .success(out)
    }

    // MARK: - Saying so

    /// The line under "Your own sounds" in Settings: which cues are yours, and
    /// which files were passed over and why. `probe` is injectable so the wording
    /// can be tested without audio files.
    static func summary(_ entries: [Entry],
                        probe: (Entry) -> Refusal? = { SoundPack.probe(directory.appendingPathComponent($0.name)) })
        -> String {
        var yours: [String] = []
        var passed: [String] = []
        let choices = resolve(entries)
        for cue in Cue.allCases {
            switch choices[cue] {
            case .file(let entry)?:
                if let refusal = probe(entry) {
                    passed.append("\(entry.name) (\(refusal.words))")
                } else {
                    yours.append(cue.rawValue)
                }
            case .refused(let entry, let refusal)?:
                passed.append("\(entry.name) (\(refusal.words))")
            case nil:
                break
            }
        }
        var line = yours.isEmpty
            ? "All four are AgentBar's. Name a file permission, question, done or ack "
              + "(.aiff, .wav, .caf, .mp3, .m4a) to replace one."
            : "Yours: \(list(yours)). The rest are AgentBar's."
        if !passed.isEmpty {
            line += " Passed over, so AgentBar's plays instead: \(list(passed))."
        }
        return line
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
