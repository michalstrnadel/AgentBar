import Foundation

/// A Claude Code row that says "working" long after the turn stopped.
///
/// A turn can end without its `Stop` hook ever being recorded: the hook's write
/// fails on a full disk, or the turn dies on an error the hook never hears about.
/// The row then animates "Running command" for as long as the terminal stays
/// open. The transcript knows better. When the row has not moved for
/// `quiet`, the transcript has not either, and nothing in it is still running —
/// no tool call without its result — the turn is over, and the row decays to done
/// the way Antigravity's quiet rows do: a watchdog's guess, marked `decayed`.
///
/// A long build, a slow test run or a subagent is a tool call still waiting for
/// its result, so it is never mistaken for a stall however long it takes.
enum StalledTurn {
    static let quiet: TimeInterval = 10 * 60
    /// How much of the transcript's end is read: far more than one turn's tail.
    static let tailBytes = 512 * 1024

    /// Whether a tool call in these transcript lines (oldest first) is still
    /// waiting for its result.
    static func toolOutstanding(_ lines: [Substring]) -> Bool {
        var open = Set<String>()
        for line in lines {
            guard line.contains("\"tool_use\"") || line.contains("\"tool_result\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = o["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String { open.insert(id) }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { open.remove(id) }
                default:
                    break
                }
            }
        }
        return !open.isEmpty
    }

    /// The decision, from plain values.
    static func isStalled(working: Bool, rowAge: TimeInterval, transcriptAge: TimeInterval?,
                          toolOutstanding: Bool) -> Bool {
        guard working, rowAge >= quiet, let transcriptAge, transcriptAge >= quiet else { return false }
        return !toolOutstanding
    }

    private static var cache: [String: (mtime: Date, outstanding: Bool)] = [:]

    /// Reads what it needs for a Claude Code row that has been quiet for `quiet`.
    static func check(_ s: Session, now: Date = Date()) -> Bool {
        let rowAge = now.timeIntervalSince1970 - s.ts
        guard s.agentID == "claude", s.state.isWorking, rowAge >= quiet,
              let url = WeightReader.transcript(sessionId: s.id, cwd: s.cwd),
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return false }
        let age = now.timeIntervalSince(mtime)
        guard age >= quiet else { return false }
        let outstanding: Bool
        if let hit = cache[url.path], hit.mtime == mtime {
            outstanding = hit.outstanding
        } else {
            outstanding = toolOutstanding(tail(url))
            cache[url.path] = (mtime, outstanding)
        }
        return isStalled(working: true, rowAge: rowAge, transcriptAge: age, toolOutstanding: outstanding)
    }

    private static func tail(_ url: URL) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        // Lossy: a read that began mid-character must not lose the whole tail.
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A read that began mid-line starts with half of one.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
