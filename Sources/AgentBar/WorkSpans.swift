import Foundation

/// When an agent was actually working — not how long its session was open.
///
/// A session's own span is the wrong number for "agent time": a Claude Code window
/// left open from morning to night is one session of fourteen hours, nearly all of
/// it waiting at the prompt. Summed over three such windows that is a 52-hour day.
/// What counts is the stretches in which the agent was doing something.
///
/// Two sources, in order of trust:
/// - **Claude Code's transcript**, which stamps every prompt, every assistant step
///   and every tool result. A turn runs from a prompt to the last step before the
///   next prompt, and a silence longer than `maxGap` inside it ends the stretch —
///   an agent waiting twenty minutes on a permission is not working for them. It
///   also says when *you* were active: every prompt you typed has its time.
/// - **What AgentBar saw**: the stretches a row spent in thinking or tool, recorded
///   by `HistoryStore` as they happen. For every agent, but only from the moment
///   AgentBar started watching that session.
///
/// A session with neither has no time at all, and the recap says so rather than
/// borrowing the session's span.
enum WorkSpans {
    struct Span: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var seconds: TimeInterval { max(0, end - start) }
    }

    struct Read: Equatable {
        var spans: [Span] = []
        /// When the person typed a prompt.
        var prompts: [TimeInterval] = []
    }

    /// Inside a turn, a silence longer than this is waiting, not work.
    static let maxGap: TimeInterval = 5 * 60
    /// Two stretches closer than this are one.
    static let joinGap: TimeInterval = 20

    // MARK: - Claude Code's transcript

    /// The stretches and prompts in a transcript's lines. Pure.
    static func claude<S: Sequence>(lines: S) -> Read where S.Element == Substring {
        var scan = ClaudeScan()
        for line in lines {
            var bytes = Array(line.utf8)
            bytes.withUnsafeBytes { scan.feed($0) }
        }
        return scan.result
    }

    /// Reads a transcript one line at a time, in bytes.
    ///
    /// A long Claude Code session leaves a transcript of a hundred megabytes and
    /// more, nearly all of it tool output inside assistant lines. Decoding all of
    /// that as one String and then every line as JSON made opening Your Day take
    /// eighteen seconds on a working machine, with a blank card for all of them.
    /// So a line is first looked at as bytes: only the top-level keys matter —
    /// `type`, `timestamp`, `isSidechain` — and those are found by searching for
    /// their exact, unescaped spelling, which text inside a JSON string can never
    /// have (its quotes are escaped). Only a user line that is not a tool result —
    /// a prompt, which is small — is parsed whole, because whether it counts as
    /// typed depends on its content.
    ///
    /// The state survives between calls, so a transcript that grew since the last
    /// read is read from where it stopped (`claude(sessionId:cwd:)`).
    struct ClaudeScan {
        private(set) var out = Read()
        private var open: Span?

        var result: Read {
            var r = out
            if let s = open, s.end > s.start { r.spans.append(s) }
            r.spans = joined(r.spans)
            return r
        }

        private mutating func close() {
            if let s = open, s.end > s.start { out.spans.append(s) }
            open = nil
        }

        mutating func feed(_ line: UnsafeRawBufferPointer) {
            guard let at = Self.timestamp(line) else { return }
            let isUser = Self.contains(line, Self.typeUser)
            guard isUser || Self.contains(line, Self.typeAssistant) else { return }
            if Self.contains(line, Self.sidechain) { return }
            if isUser, !Self.contains(line, Self.toolResult), Self.isTypedPrompt(line) {
                close()
                out.prompts.append(at)
                open = Span(start: at, end: at)
                return
            }
            // A step of the turn: an assistant line or a tool result.
            guard var s = open else { return }
            if at - s.end > maxGap {
                close()
                s = Span(start: at, end: at)
            }
            s.end = max(s.end, at)
            open = s
        }

        private static let typeUser = Array(#""type":"user""#.utf8)
        private static let typeAssistant = Array(#""type":"assistant""#.utf8)
        private static let sidechain = Array(#""isSidechain":true"#.utf8)
        private static let toolResult = Array(#""type":"tool_result""#.utf8)
        private static let stampKey = Array(#""timestamp":""#.utf8)

        static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
            guard let base = hay.baseAddress, hay.count >= needle.count else { return false }
            return needle.withUnsafeBytes { n in memmem(base, hay.count, n.baseAddress, n.count) != nil }
        }

        /// The line's own timestamp: the last one in it, because the top-level key
        /// comes after `message`, where a tool's input could carry a key of the same
        /// name.
        static func timestamp(_ line: UnsafeRawBufferPointer) -> TimeInterval? {
            guard let base = line.baseAddress else { return nil }
            var from = 0
            var found: Int?
            while from < line.count,
                  let hit = stampKey.withUnsafeBytes({ n in
                      memmem(base + from, line.count - from, n.baseAddress, n.count)
                  }) {
                let at = base.distance(to: UnsafeRawPointer(hit))
                found = at + stampKey.count
                from = at + 1
            }
            guard let valueStart = found else { return nil }
            var end = valueStart
            while end < line.count, line[end] != UInt8(ascii: "\""), end - valueStart < 40 { end += 1 }
            guard end < line.count, end > valueStart else { return nil }
            return iso(UnsafeRawBufferPointer(rebasing: line[valueStart..<end]))
        }

        /// `2026-10-07T10:00:20.123Z`, the shape Claude Code writes, without a
        /// formatter; anything else goes to the formatter.
        static func iso(_ b: UnsafeRawBufferPointer) -> TimeInterval? {
            func num(_ r: Range<Int>) -> Int? {
                var v = 0
                for i in r {
                    let c = b[i]
                    guard c >= 48, c <= 57 else { return nil }
                    v = v * 10 + Int(c - 48)
                }
                return v
            }
            if b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
               b[b.count - 1] == 90,
               let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
               let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19),
               (1...12).contains(mo), (1...31).contains(d) {
                var frac = 0.0
                if b.count > 21, b[19] == 46, let f = num(20..<(b.count - 1)) {
                    frac = Double(f) / pow(10, Double(b.count - 21))
                }
                // Days from the civil date (Howard Hinnant's algorithm), in UTC.
                let yy = mo <= 2 ? y - 1 : y
                let era = (yy >= 0 ? yy : yy - 399) / 400
                let yoe = yy - era * 400
                let mp = (mo + 9) % 12
                let doy = (153 * mp + 2) / 5 + d - 1
                let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
                let days = era * 146_097 + doe - 719_468
                return Double(days * 86_400 + h * 3_600 + mi * 60 + sec) + frac
            }
            guard let s = String(bytes: b, encoding: .utf8) else { return nil }
            return WeightReader.parseISO(s)?.timeIntervalSince1970
        }

        /// A user line that is not a tool result: typed, unless it is meta or has
        /// no text or image in it.
        static func isTypedPrompt(_ line: UnsafeRawBufferPointer) -> Bool {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  o["isMeta"] as? Bool != true else { return false }
            return isPrompt(o["message"])
        }
    }

    /// A prompt the person typed, as opposed to a tool result fed back in.
    private static func isPrompt(_ message: Any?) -> Bool {
        guard let m = message as? [String: Any] else { return false }
        if let s = m["content"] as? String { return !s.isEmpty }
        guard let parts = m["content"] as? [[String: Any]] else { return false }
        return !parts.contains { $0["type"] as? String == "tool_result" }
            && parts.contains { ["text", "image"].contains($0["type"] as? String ?? "") }
    }

    private struct CacheEntry {
        var size: UInt64
        var mtime: Date
        /// Bytes consumed: the end of the last complete line.
        var offset: UInt64
        var scan: ClaudeScan
    }
    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    /// A Claude session's stretches, from its transcript. Memoised on the file's
    /// size and time, and a transcript that only grew — they are append-only — is
    /// read from where the last read stopped, so reopening Your Day while a long
    /// session runs costs the new lines, not the whole file. Blocking file I/O:
    /// off the main queue.
    static func claude(sessionId: String, cwd: String,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Read? {
        guard let url = WeightReader.transcript(sessionId: sessionId, cwd: cwd, home: home),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        cacheLock.lock()
        let cached = cache[url.path]
        cacheLock.unlock()
        if let c = cached, c.size == size, c.mtime == mtime { return c.scan.result }
        var entry = CacheEntry(size: 0, mtime: mtime, offset: 0, scan: ClaudeScan())
        if let c = cached, size >= c.offset { entry = c }   // grew: resume
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: entry.offset) } catch { return nil }
        // In chunks, so a hundred-megabyte file is never one allocation.
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            let consumed: Int = carry.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return 0 }
                var lineStart = 0
                while lineStart < buf.count,
                      let nl = memchr(base + lineStart, 10, buf.count - lineStart) {
                    let i = base.distance(to: UnsafeRawPointer(nl))
                    if i > lineStart { entry.scan.feed(UnsafeRawBufferPointer(rebasing: buf[lineStart..<i])) }
                    lineStart = i + 1
                }
                return lineStart
            }
            entry.offset += UInt64(consumed)
            if consumed > 0 { carry = carry.subdata(in: consumed..<carry.count) }
        }
        // A last line without its newline yet is read next time, once it is whole.
        entry.size = size
        entry.mtime = mtime
        cacheLock.lock(); cache[url.path] = entry; cacheLock.unlock()
        return entry.scan.result
    }

    // MARK: - Shared

    /// Sorted, with overlapping or nearly touching stretches made one.
    static func joined(_ spans: [Span], gap: TimeInterval = joinGap) -> [Span] {
        var out: [Span] = []
        for s in spans.sorted(by: { $0.start < $1.start }) where s.end > s.start {
            if let last = out.last, s.start - last.end <= gap {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// The part of each stretch inside `[from, to]`.
    static func clipped(_ spans: [Span], from: TimeInterval, to: TimeInterval) -> [Span] {
        spans.compactMap { s in
            let a = max(s.start, from), b = min(s.end, to)
            return b > a ? Span(start: a, end: b) : nil
        }
    }

    /// For the history line: `[[start, end], …]` in whole seconds.
    static func json(_ spans: [Span]) -> [[Int]] { spans.map { [Int($0.start), Int($0.end)] } }

    static func spans(fromJSON any: Any?) -> [Span]? {
        guard let rows = any as? [[Any]] else { return nil }
        return rows.compactMap { r in
            guard r.count == 2, let a = (r[0] as? NSNumber)?.doubleValue,
                  let b = (r[1] as? NSNumber)?.doubleValue, b >= a else { return nil }
            return Span(start: a, end: b)
        }
    }
}
