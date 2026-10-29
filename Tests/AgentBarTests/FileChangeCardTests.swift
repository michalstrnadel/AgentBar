import Foundation
import Testing
@testable import AgentBar

/// A MultiEdit shows every edit it can fit, and a Write says what it does to the file.
@Suite struct FileChangeCardTests {
    typealias C = ApprovalRequest.Context

    @Test func everyEditOfAMultiEditIsShown() {
        let c = C.diff(old: "a", new: "b", more: 2, rest: [.init(old: "c", new: "d"), .init(old: "e", new: "f")])
        let t = ApprovalContextView.texts(for: c)
        #expect(t.contains("edit 1 of 3") && t.contains("edit 3 of 3"))
        #expect(t.contains("f"))
        #expect(!t.contains { $0.contains("more edit") })
    }

    @Test func editsTheHookDidNotSendAreCounted() {
        let c = C.diff(old: "a", new: "b", more: 6, rest: [.init(old: "c", new: "d")])
        #expect(ApprovalContextView.texts(for: c).last == "+5 more edits")
    }

    @Test func replaceAllIsSaid() {
        let t = ApprovalContextView.texts(for: .diff(old: "foo", new: "bar", more: 0, all: true))
        #expect(t.first == "every occurrence in the file")
    }

    @Test func aWriteSaysWhetherItMakesOrReplaces() {
        #expect(C.WriteTarget(exists: false, oldLines: nil, lines: 42).text == "new file · 42 lines")
        #expect(C.WriteTarget(exists: true, oldLines: 120, lines: 42).text == "replaces 120 lines with 42")
        #expect(C.WriteTarget(exists: true, oldLines: nil, lines: 1).text == "overwrites the file · 1 line")
        #expect(C.WriteTarget(exists: nil, oldLines: nil, lines: 3).text == "3 lines")
        let t = ApprovalContextView.texts(for: .write("x", target: .init(exists: false, oldLines: nil, lines: 1)))
        #expect(t.first == "new file · 1 line")
    }
}
