import AppKit
import Testing
@testable import AgentBar

/// The Trust Receipt: a till slip of the recap, the same every time it is drawn,
/// and with no name on it that the shared card would not carry.
@MainActor
@Suite struct ReceiptRendererTests {
    private let wrap = WrapDemo.wrap(.today)

    private func pixels(_ rep: NSBitmapImageRep) -> Data {
        Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func text(_ lines: [ReceiptRenderer.Line]) -> String {
        lines.map { line -> String in
            switch line {
            case .title(let s), .center(let s), .note(let s): return s
            case .pair(let a, let b), .item(let a, let b), .total(let a, let b): return a + " " + b
            case .rule, .gap, .clawd: return ""
            }
        }.joined(separator: "\n")
    }

    @Test func theSameRecapPrintsTheSameSlip() throws {
        let a = try #require(ReceiptRenderer.bitmap(wrap))
        let b = try #require(ReceiptRenderer.bitmap(wrap))
        #expect(a.pixelsWide == 576)
        #expect(a.pixelsHigh == b.pixelsHigh)
        #expect(pixels(a) == pixels(b))
        #expect(WrapExport.png(a)?.isEmpty == false)
    }

    @Test func itIsAsLongAsWhatItSays() throws {
        let empty = DayWrap.make(.today, history: [], ledger: [])
        let short = try #require(ReceiptRenderer.bitmap(empty))
        let long = try #require(ReceiptRenderer.bitmap(wrap))
        #expect(long.pixelsHigh > short.pixelsHigh + 300)
    }

    @Test func itSaysWhatWasDecidedAndWhatWasStopped() {
        let lines = ReceiptRenderer.lines(wrap)
        let all = text(lines)
        #expect(lines.contains { if case .total("TOTAL DECISIONS", _) = $0 { return true }; return false })
        #expect(lines.contains(.item("stopped by auto mode", "3")))
        #expect(lines.contains(.item("denied by you", "2")))
        #expect(all.contains("TOOL CALLS"))
        #expect(all.contains("RISKIEST STOPPED"))
        #expect(all.contains("$ curl"))
        #expect(all.contains("COST, API PRICES"))
        #expect(all.contains("measured on 2 of"))
        #expect(lines.last == .center("AgentBar · free and open source"))
    }

    /// Shared, it names no project, no command line and no file — the reach and
    /// the counts are the point of posting it.
    @Test func aSharedSlipNamesNothing() {
        let shared = text(ReceiptRenderer.lines(wrap.shareSafe()))
        for name in ["AgentBar\n", "landing-site", "api", "ml-notebooks", "curl", "get.example.dev", "Auth.swift"] {
            #expect(!shared.contains(name), "\(name) leaked")
        }
        #expect(shared.contains("Project A"))
        #expect(shared.contains("(command not shown)"))
        #expect(shared.contains("pipes into a shell"))
        #expect(shared.contains("the same file"))
    }

    /// Everything the slip says was stopped is in its total: Claude Code's own
    /// refusals too, beside auto mode's and never as yours.
    @Test func theTotalCountsWhatClaudeCodeStopped() {
        var r = DecisionLedger.Record()
        r.ts = wrap.start + 60; r.via = "claude"; r.by = "rule"; r.decision = "deny"; r.tool = "Bash"
        r.display = "Bash: sudo rm -r /opt/x"; r.shape = "bash:sudo"
        let s = Int(wrap.start)
        let one = try! #require(HistoryStore.Record(jsonLine:
            #"{"agent":"claude","sessionId":"x","startedAt":\#(s + 10),"endedAt":\#(s + 600),"state":"done"}"#))
        let w = DayWrap.make(.today, history: [one], ledger: [r], now: wrap.start + 3_600)
        let lines = ReceiptRenderer.lines(w)
        #expect(w.receipt.claudeStopped == 1)
        #expect(lines.contains(.item("stopped by Claude Code", "1")))
        #expect(lines.contains(.total("TOTAL DECISIONS", "1")))
        #expect(ReceiptRenderer.toolName("mcp__github__create_issue") == "github · create_issue")
        #expect(ReceiptRenderer.toolName("mcp__docket__docket") == "docket (MCP)")
        #expect(ReceiptRenderer.toolName("Bash") == "Bash")
    }

    @Test func longWordsWrapAtTheColumn() {
        #expect(ReceiptRenderer.wrap("stopped by auto mode", 10) == ["stopped by", "auto mode"])
        #expect(ReceiptRenderer.wrap("abcdefghijkl", 5) == ["abcde", "fghij", "kl"])
    }
}
