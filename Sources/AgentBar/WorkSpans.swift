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
        var out = Read()
        var open: Span?
        func close() {
            if let s = open, s.end > s.start { out.spans.append(s) }
            open = nil
        }
        for line in lines {
            // Cheap filter before parsing: only stamped user and assistant lines matter.
            guard line.contains("\"timestamp\""),
                  line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let stamp = o["timestamp"] as? String,
                  let at = WeightReader.parseISO(stamp)?.timeIntervalSince1970
            else { continue }
            if o["isSidechain"] as? Bool == true { continue }
            let type = o["type"] as? String
            if type == "user", o["isMeta"] as? Bool != true, isPrompt(o["message"]) {
                close()
                out.prompts.append(at)
                open = Span(start: at, end: at)
                continue
            }
            // A step of the turn: an assistant line or a tool result.
            guard var s = open else { continue }
            if at - s.end > maxGap {
                close()
                s = Span(start: at, end: at)
            }
            s.end = max(s.end, at)
            open = s
        }
        close()
        out.spans = joined(out.spans)
        return out
    }

    /// A prompt the person typed, as opposed to a tool result fed back in.
    private static func isPrompt(_ message: Any?) -> Bool {
        guard let m = message as? [String: Any] else { return false }
        if let s = m["content"] as? String { return !s.isEmpty }
        guard let parts = m["content"] as? [[String: Any]] else { return false }
        return !parts.contains { $0["type"] as? String == "tool_result" }
            && parts.contains { ["text", "image"].contains($0["type"] as? String ?? "") }
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: (size: UInt64, mtime: Date, read: Read)] = [:]

    /// A Claude session's stretches, from its transcript, memoised on the file's
    /// size and time. Blocking file I/O: off the main queue.
    static func claude(sessionId: String, cwd: String,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Read? {
        guard let url = WeightReader.transcript(sessionId: sessionId, cwd: cwd, home: home),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        cacheLock.lock()
        if let c = cache[url.path], c.size == size, c.mtime == mtime { cacheLock.unlock(); return c.read }
        cacheLock.unlock()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let read = claude(lines: text.split(separator: "\n", omittingEmptySubsequences: true))
        cacheLock.lock(); cache[url.path] = (size, mtime, read); cacheLock.unlock()
        return read
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
