import Foundation
import Testing
@testable import AgentBar

/// A session's context on its row: silent until it matters, then louder as it
/// fills — the same thresholds on the island and in the menu.
struct ContextGaugeTests {
    @Test func thresholds() {
        #expect(ContextGauge.level(nil) == .hidden)
        #expect(ContextGauge.level(0) == .hidden)
        #expect(ContextGauge.level(69) == .hidden)
        #expect(ContextGauge.level(70) == .notice)
        #expect(ContextGauge.level(84) == .notice)
        #expect(ContextGauge.level(85) == .high)
        #expect(ContextGauge.level(94) == .high)
        #expect(ContextGauge.level(95) == .critical)
        #expect(ContextGauge.level(100) == .critical)
    }

    @Test func theWords() {
        #expect(ContextGauge.text(nil) == nil)
        #expect(ContextGauge.text(50) == nil)
        #expect(ContextGauge.text(82) == "ctx 82%")
        #expect(ContextGauge.spoken(82) == "context 82% full")
    }

    private func session(context: Int?) throws -> Session {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-ctx-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let o: [String: Any] = ["agent": "claude", "state": "thinking", "label": "Thinking…",
                                "project": "myapp", "started": true, "pid": 0,
                                "ts": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        var s = try #require(Session(fileURL: url))
        s.contextPercent = context
        s.modSeen = context != nil
        return s
    }

    /// The menu row carries it beside the time, and a screen reader hears it.
    @Test func theMenuRowSaysItOnlyWhenTheModReported() throws {
        let quiet = SessionRowView.content(for: try session(context: nil))
        #expect(quiet.context.isEmpty)
        #expect(!SessionRowView.plainTitle(quiet).contains("context"))

        let full = SessionRowView.content(for: try session(context: 96))
        #expect(full.context == "ctx 96%")
        #expect(full.contextLevel == .critical)
        #expect(SessionRowView.plainTitle(full) == "myapp, Thinking…, context 96% full, CLAUDE")
        // It takes its room from the detail, never from the name.
        #expect(SessionRowView.idealWidth(full) > SessionRowView.idealWidth(quiet)
                || SessionRowView.idealWidth(quiet) == SessionRowView.minWidth)
        let narrow = SessionRowView.textLayout(full, width: SessionRowView.minWidth)
        let roomy = SessionRowView.textLayout(quiet, width: SessionRowView.minWidth)
        #expect(narrow.name == roomy.name)
        #expect(narrow.detail <= roomy.detail)
    }

    @Test func anEndedRowSaysNothingAboutIt() throws {
        let c = SessionRowView.content(for: try session(context: 96), ended: true)
        #expect(c.context.isEmpty)
    }
}
