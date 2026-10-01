import Foundation

/// Two versions of a file, turned into the lines that actually differ.
///
/// The mini-diff on an approval card used to show the **first three lines of the
/// old text and the first three of the new**, which for a change in the middle of a
/// function shows neither — three identical lines of context twice over, and the
/// edit itself off the bottom. You were approving a change you could not see.
///
/// So: a real line diff, and only the parts that moved, with a line of context
/// either side. Sizes here are tiny by construction — the hook caps each side at
/// 4 KB before it ever reaches a frontend — so the plain O(n·m) table is the right
/// amount of machinery, and its worst case is a few hundred lines.
enum LineDiff {
    enum Kind: Equatable { case same, add, del, gap }

    struct Row: Equatable {
        let text: String
        let kind: Kind
        /// The characters that differ, when this row is one half of a one-line
        /// replacement. Everything outside it is shared with the other half, and
        /// drawing it dimmer is what makes a one-character change findable.
        var emphasis: Range<Int>?

        init(_ text: String, _ kind: Kind, emphasis: Range<Int>? = nil) {
            self.text = text
            self.kind = kind
            self.emphasis = emphasis
        }
    }

    /// The rows worth showing: every changed line, `context` unchanged lines around
    /// each run of them, and a `.gap` marker wherever something was skipped.
    static func rows(old: [String], new: [String], context: Int = 1,
                     limit: Int = 10) -> [Row] {
        let full = align(old: old, new: new)
        let kept = trim(full, context: context)
        return cap(kept, limit: limit)
    }

    // MARK: - Alignment

    /// Longest common subsequence over whole lines, walked back into a unified
    /// sequence. Deletions come before insertions at the same position, which is
    /// the order every diff tool prints and therefore the order people read.
    static func align(old: [String], new: [String]) -> [Row] {
        let n = old.count, m = new.count
        if n == 0 { return new.map { Row($0, .add) } }
        if m == 0 { return old.map { Row($0, .del) } }

        // table[i][j] = LCS length of old[i...] and new[j...]
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var out: [Row] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                out.append(Row(old[i], .same)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(Row(old[i], .del)); i += 1
            } else {
                out.append(Row(new[j], .add)); j += 1
            }
        }
        while i < n { out.append(Row(old[i], .del)); i += 1 }
        while j < m { out.append(Row(new[j], .add)); j += 1 }
        return emphasiseSingleLineReplacements(out)
    }

    /// A deletion immediately followed by one insertion is somebody editing a line,
    /// not replacing it. Mark the middle that actually changed so a renamed variable
    /// or a flipped comparison is visible at a glance instead of being two lines
    /// that look identical.
    static func emphasiseSingleLineReplacements(_ rows: [Row]) -> [Row] {
        var out = rows
        var i = 0
        while i + 1 < out.count {
            defer { i += 1 }
            guard out[i].kind == .del, out[i + 1].kind == .add,
                  i + 2 >= out.count || out[i + 2].kind != .add,
                  i == 0 || out[i - 1].kind != .del
            else { continue }
            let (a, b) = (out[i].text, out[i + 1].text)
            guard let ranges = changedMiddle(a, b) else { continue }
            out[i].emphasis = ranges.0
            out[i + 1].emphasis = ranges.1
            i += 1     // the pair is handled
        }
        return out
    }

    /// The part of each string left once the shared start and the shared end are
    /// taken off. Nil when the two share nothing at either edge (a whole-line
    /// rewrite, where emphasising everything would emphasise nothing).
    static func changedMiddle(_ a: String, _ b: String) -> (Range<Int>, Range<Int>)? {
        let ac = Array(a), bc = Array(b)
        var prefix = 0
        while prefix < ac.count, prefix < bc.count, ac[prefix] == bc[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < ac.count - prefix, suffix < bc.count - prefix,
              ac[ac.count - 1 - suffix] == bc[bc.count - 1 - suffix] { suffix += 1 }
        guard prefix > 0 || suffix > 0 else { return nil }
        return (prefix..<(ac.count - suffix), prefix..<(bc.count - suffix))
    }

    // MARK: - Trimming to what changed

    /// Drops runs of unchanged lines longer than `context * 2`, leaving a `.gap`
    /// where they were. A file that changed in two places reads as two places.
    static func trim(_ rows: [Row], context: Int) -> [Row] {
        guard rows.contains(where: { $0.kind != .same }) else { return [] }
        var keep = [Bool](repeating: false, count: rows.count)
        for (i, row) in rows.enumerated() where row.kind != .same {
            for j in max(0, i - context)...min(rows.count - 1, i + context) { keep[j] = true }
        }
        var out: [Row] = []
        var skipped = 0
        for (i, row) in rows.enumerated() {
            if keep[i] {
                if skipped > 0 {
                    out.append(Row("⋯ \(skipped) unchanged line\(skipped == 1 ? "" : "s")", .gap))
                    skipped = 0
                }
                out.append(row)
            } else {
                skipped += 1
            }
        }
        // A tail of unchanged lines needs no marker: nothing follows it to separate.
        return out
    }

    /// Slides a too-long line so the part that changed is inside the first `width`
    /// characters.
    ///
    /// Without this the emphasis is pointless on exactly the lines that need it: a
    /// 90-character line whose only change is at column 70 truncates at the right
    /// edge, and the card shows two identical-looking lines and an ellipsis where
    /// the difference was. Text is dropped from the **front**, with a marker, since
    /// the front is the part both versions share.
    static func window(_ text: String, emphasis: Range<Int>?, width: Int)
    -> (text: String, emphasis: Range<Int>?) {
        slide(text, emphasis: emphasis, by: windowStart(text, emphasis: emphasis, width: width))
    }

    /// How many characters would have to go from the front for the change to be
    /// visible. Zero when the line already fits or has nothing to point at.
    ///
    /// Exposed separately so a `−`/`+` pair can be slid by the **same** amount:
    /// computed independently they land at different offsets, and two lines meant
    /// to be compared column by column stop lining up, which is most of what makes
    /// a diff readable.
    static func windowStart(_ text: String, emphasis: Range<Int>?, width: Int) -> Int {
        let chars = Array(text)
        guard let emphasis, width > 12, chars.count > width, emphasis.upperBound > width
        else { return 0 }
        // A little of the shared text stays visible, so the change has somewhere to
        // sit rather than starting flush against the marker.
        let lead = 6
        return max(0, min(emphasis.lowerBound - lead, chars.count - width + 1))
    }

    static func slide(_ text: String, emphasis: Range<Int>?, by start: Int)
    -> (text: String, emphasis: Range<Int>?) {
        guard start > 0 else { return (text, emphasis) }
        let chars = Array(text)
        guard start < chars.count else { return (text, emphasis) }
        let shifted = "…" + String(chars[start...])
        let offset = 1 - start
        guard let emphasis else { return (shifted, nil) }
        return (shifted, max(0, emphasis.lowerBound + offset)..<max(0, emphasis.upperBound + offset))
    }

    /// How many lines each side of the change actually moved, which is what a
    /// summary should say. Counting the whole old and new blocks instead reports a
    /// one-character edit inside an eight-line window as "+8 −8".
    static func counts(old: [String], new: [String]) -> (added: Int, removed: Int) {
        var out = (added: 0, removed: 0)
        for row in align(old: old, new: new) {
            switch row.kind {
            case .add: out.added += 1
            case .del: out.removed += 1
            default: break
            }
        }
        return out
    }

    // MARK: - Unified text

    /// The same alignment, printed the way `diff -u` prints it: `---`/`+++` headers,
    /// `@@ -a,b +c,d @@` hunks, `context` unchanged lines around each change.
    ///
    /// This is what the installer shows for a settings file it wrote, and it has to be
    /// the *whole* truth rather than the card's trimmed glance — no cap, no gap rows,
    /// so a person can check every line that moved, or paste it into `patch -R`.
    /// Empty when the two texts are identical.
    ///
    /// Lines are compared with their newline attached, which is how a file that only
    /// gained a trailing newline still shows a change (and the `\ No newline at end of
    /// file` marker `diff` prints for it) instead of an empty diff over a file that did
    /// change on disk.
    static func unified(old: String, new: String, oldLabel: String, newLabel: String,
                        context: Int = 3) -> String {
        let a = tokens(old), b = tokens(new)
        guard a != b else { return "" }
        let rows = alignLarge(old: a, new: b)

        // Hunks as inclusive row ranges, merged when their context would touch.
        var hunks: [ClosedRange<Int>] = []
        for (i, row) in rows.enumerated() where row.kind != .same {
            let lo = max(0, i - context), hi = min(rows.count - 1, i + context)
            if let last = hunks.last, lo <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...max(last.upperBound, hi)
            } else {
                hunks.append(lo...hi)
            }
        }

        // Line numbers before each row, on either side.
        var oldBefore = [Int](repeating: 0, count: rows.count + 1)
        var newBefore = [Int](repeating: 0, count: rows.count + 1)
        for (i, row) in rows.enumerated() {
            oldBefore[i + 1] = oldBefore[i] + (row.kind == .add ? 0 : 1)
            newBefore[i + 1] = newBefore[i] + (row.kind == .del ? 0 : 1)
        }
        // `diff` writes a one-line range as just its start, and an empty one as the
        // line *before* it — `@@ -0,0 +1,3 @@` is a file that did not exist.
        func range(_ start: Int, _ count: Int) -> String {
            let first = count == 0 ? start : start + 1
            return count == 1 ? "\(first)" : "\(first),\(count)"
        }

        var out = ["--- \(oldLabel)", "+++ \(newLabel)"]
        for h in hunks {
            let oldCount = oldBefore[h.upperBound + 1] - oldBefore[h.lowerBound]
            let newCount = newBefore[h.upperBound + 1] - newBefore[h.lowerBound]
            out.append("@@ -\(range(oldBefore[h.lowerBound], oldCount)) "
                       + "+\(range(newBefore[h.lowerBound], newCount)) @@")
            for row in rows[h] {
                let mark = row.kind == .add ? "+" : row.kind == .del ? "-" : " "
                if row.text.hasSuffix("\n") {
                    out.append(mark + row.text.dropLast())
                } else {
                    out.append(mark + row.text)
                    out.append("\\ No newline at end of file")
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A file's lines with their newline kept, the last one without it when the file
    /// does not end in one.
    static func tokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        let terminated = lines.last == ""
        if terminated { lines.removeLast() }
        return lines.enumerated().map { i, line in
            i < lines.count - 1 || terminated ? line + "\n" : line
        }
    }

    /// `align`, made safe for whole config files rather than 4 KB snippets.
    ///
    /// Two things keep it cheap. The shared head and tail are taken off first — a
    /// hook block appended to a 2,000-line `config.toml` leaves a middle of a few
    /// dozen lines for the table, not four million cells. And a middle that is still
    /// too big for the table is printed as everything removed, then everything added:
    /// a worse-looking diff, never a wrong one, and never a quarter of a gigabyte
    /// allocated on a launch.
    static func alignLarge(old: [String], new: [String], maxCells: Int = 4_000_000) -> [Row] {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let a = Array(old[head..<(old.count - tail)]), b = Array(new[head..<(new.count - tail)])
        let middle = a.count * b.count > maxCells
            ? a.map { Row($0, .del) } + b.map { Row($0, .add) }
            : align(old: a, new: b)
        return old[..<head].map { Row($0, .same) } + middle
            + old[(old.count - tail)...].map { Row($0, .same) }
    }

    /// Never taller than `limit`, and the truncation says how much it took —
    /// silently showing the first few and stopping is how the old mini-diff hid
    /// the edit in the first place.
    static func cap(_ rows: [Row], limit: Int) -> [Row] {
        guard rows.count > limit, limit > 1 else { return rows }
        var out = Array(rows.prefix(limit - 1))
        let hidden = rows.count - out.count
        out.append(Row("⋯ \(hidden) more line\(hidden == 1 ? "" : "s")", .gap))
        return out
    }
}
