import Foundation

/// What `JSONSerialization` lets through that JSON — and the CLI's `JSON.parse` —
/// does not. Two files are read by both halves and must be read the same way by
/// both: `rules.json`, where a disagreement is a rule one half applies and the other
/// lists as void, and the agents' JSON settings, where it is a file one half
/// rewrites and the other refuses to touch. Run on bytes that already parsed.
/// `Scripts/cli/agentbar` holds the other half; `Tests/Fixtures/` holds both to it.
enum StrictJSON {
    /// A `,` with nothing after it but `}` or `]`. JSONSerialization accepts
    /// `{"v":1,}`; JSON does not, and neither does the CLI.
    static func hasTrailingComma(_ data: Data) -> Bool {
        var lastSignificant: UInt8 = 0
        var i = 0
        let b = [UInt8](data)
        while i < b.count {
            let c = b[i]
            if c == quote {
                i = endOfString(b, from: i) + 1
                lastSignificant = quote
                continue
            }
            if (c == UInt8(ascii: "}") || c == UInt8(ascii: "]")) && lastSignificant == UInt8(ascii: ",") {
                return true
            }
            if ![0x20, 0x09, 0x0A, 0x0D].contains(c) { lastSignificant = c }
            i += 1
        }
        return false
    }

    /// The first key any object repeats, or nil. Keys are compared decoded — as
    /// JSONSerialization decodes them, so `"a"` and `"a"` are one key, and so
    /// are two that differ only by the leading U+FEFF it drops. Readers disagree about which
    /// of two equal keys wins (this one keeps the first, `JSON.parse` the last), so
    /// a file that has any is a file nobody can say the meaning of.
    static func repeatedKey(_ data: Data) -> String? {
        let b = [UInt8](data)
        var stack: [(keys: Set<String>, isObject: Bool, wantKey: Bool)] = []
        var i = 0
        while i < b.count {
            switch b[i] {
            case quote:
                let j = endOfString(b, from: i)
                if let top = stack.last, top.isObject, top.wantKey, j < b.count {
                    let token = Data(b[i...j])
                    let key = (try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed)) as? String ?? ""
                    if !stack[stack.count - 1].keys.insert(key).inserted { return key }
                    stack[stack.count - 1].wantKey = false
                }
                i = j + 1
                continue
            case UInt8(ascii: "{"): stack.append(([], true, true))
            case UInt8(ascii: "["): stack.append(([], false, false))
            case UInt8(ascii: "}"), UInt8(ascii: "]"): if !stack.isEmpty { stack.removeLast() }
            case UInt8(ascii: ","): if let top = stack.last, top.isObject { stack[stack.count - 1].wantKey = true }
            default: break
            }
            i += 1
        }
        return nil
    }

    private static let quote = UInt8(ascii: "\"")

    /// The index of the quote that closes the string opened at `start`.
    private static func endOfString(_ b: [UInt8], from start: Int) -> Int {
        var j = start + 1
        while j < b.count, b[j] != quote { j += b[j] == UInt8(ascii: "\\") ? 2 : 1 }
        return j
    }
}
