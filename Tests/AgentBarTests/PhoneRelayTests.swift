import Foundation
import Testing
@testable import AgentBar

/// Approvals on the phone. The relay is the one path where a decision comes from
/// outside the Mac, so what is tested here is mostly what must *not* happen: an
/// Allow offered for something the person could not read, a reply that answers a
/// request it was not sent for, a server reached in cleartext across the internet.
@Suite struct PhoneRelayTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-phone-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func request(_ name: String = "r.json", tool: String = "Bash",
                         context: [String: Any]? = nil, hookPid: Int = 2,
                         raw: String? = nil) throws -> ApprovalRequest {
        let url = dir.appendingPathComponent(name)
        if let raw {
            try Data(raw.utf8).write(to: url)
        } else {
            var o: [String: Any] = ["sessionId": "a", "agent": "claude", "toolName": tool,
                                    "display": "\(tool): something", "toolInputPretty": "{}",
                                    "pid": 1, "hookPid": hookPid, "ts": 1_000]
            if let context { o["context"] = context }
            try JSONSerialization.data(withJSONObject: o).write(to: url)
        }
        return try #require(ApprovalRequest(fileURL: url))
    }

    private func bash(_ command: String, hookPid: Int = 2) throws -> ApprovalRequest {
        try request(context: ["kind": "bash", "command": command], hookPid: hookPid)
    }

    // MARK: - You cannot approve what you cannot read

    @Test func aShortCommandOffersAllowAndDeny() throws {
        #expect(PhoneRelay.verbs(for: try bash("git push origin main"), detail: .full) == ["allow", "deny"])
    }

    @Test func privateModeNeverOffersAllow() throws {
        #expect(PhoneRelay.verbs(for: try bash("ls"), detail: .privately) == ["deny"])
        let body = PhoneRelay.body(for: try bash("cat ~/.ssh/id_ed25519"), project: "AgentBar",
                                   agentName: "Claude", detail: .privately)
        #expect(!body.contains("ssh"))
        #expect(body.contains("AgentBar"))
    }

    @Test func aCommandTooLongToReadWholeGetsDenyOnly() throws {
        let long = String(repeating: "a", count: PhoneRelay.commandLimit + 1)
        #expect(PhoneRelay.verbs(for: try bash(long), detail: .full) == ["deny"])
        let body = PhoneRelay.body(for: try bash(long), project: "", agentName: "Claude", detail: .full)
        #expect(body.contains("on the Mac"))
    }

    @Test func invisibleOrControlCharactersGetDenyOnly() throws {
        #expect(PhoneRelay.verbs(for: try bash("r\u{200B}m -rf build"), detail: .full) == ["deny"])
        #expect(PhoneRelay.verbs(for: try bash("echo \u{1B}[2Jhi"), detail: .full) == ["deny"])
        #expect(PhoneRelay.verbs(for: try bash("echo \u{202E}txt.exe"), detail: .full) == ["deny"])
        // Line breaks and tabs are what a heredoc is made of, and they read fine.
        #expect(PhoneRelay.verbs(for: try bash("cat <<EOF\n\tok\nEOF"), detail: .full) == ["allow", "deny"])
    }

    @Test func aFileTheHookJSONStrippedABOMFromGetsDenyOnly() throws {
        let raw = #"{"sessionId":"a","agent":"claude","toolName":"Bash","display":"Bash: ls","#
            + #""pid":1,"hookPid":2,"ts":1000,"context":{"kind":"bash","command":"﻿ls"}}"#
        let r = try request(raw: raw)
        #expect(r.droppedInvisible)
        #expect(PhoneRelay.verbs(for: r, detail: .full) == ["deny"])
    }

    @Test func editsWritesAndPlansAreDeniedFromThePhoneOnly() throws {
        let edit = try request(tool: "Edit", context: ["kind": "diff", "old": "a", "new": "b"])
        #expect(PhoneRelay.verbs(for: edit, detail: .full) == ["deny"])
        let fetch = try request(tool: "WebFetch")
        #expect(PhoneRelay.verbs(for: fetch, detail: .full) == ["deny"])
        let plan = try request(tool: "ExitPlanMode", context: ["kind": "plan", "plan": "1. do it"])
        #expect(PhoneRelay.verbs(for: plan, detail: .full) == ["deny"])
    }

    @Test func aQuestionIsNeverPushed() throws {
        let q = try request(tool: "AskUserQuestion", context: [
            "kind": "question",
            "questions": [["question": "Which?", "header": "Pick", "multiSelect": false,
                           "options": [["label": "A", "description": ""]]]],
        ])
        #expect(PhoneRelay.verbs(for: q, detail: .full).isEmpty)
    }

    @Test func theCommandGoesAlongWhole() throws {
        let command = "cat <<EOF > notes.md\nline one\nEOF"
        let body = PhoneRelay.body(for: try bash(command), project: "AgentBar",
                                   agentName: "Claude", detail: .full)
        #expect(body.hasSuffix(command))
    }

    // MARK: - A reply answers one request, once

    @Test func aReplyAnswersOnlyTheRequestItsPushWasFor() throws {
        let r = try bash("ls", hookPid: 2)
        let p = PhoneRelay.Pending(fileName: r.fileName, identity: r.identity, verbs: ["allow", "deny"])
        let allow = PhoneRelay.Reply(id: "x", verb: "allow", nonce: String(repeating: "a", count: 32))
        #expect(PhoneRelay.target(of: allow, pending: p, requests: [r])?.identity == r.identity)
        // The next tool of the turn reuses the file name with a new hook pid.
        let successor = try bash("rm -rf ~", hookPid: 3)
        #expect(PhoneRelay.target(of: allow, pending: p, requests: [successor]) == nil)
        // A nonce this Mac never issued, or already spent.
        #expect(PhoneRelay.target(of: allow, pending: nil, requests: [r]) == nil)
    }

    @Test func aVerbThePushDidNotOfferAnswersNothing() throws {
        let r = try bash(String(repeating: "a", count: PhoneRelay.commandLimit + 1))
        let p = PhoneRelay.Pending(fileName: r.fileName, identity: r.identity, verbs: ["deny"])
        let forged = PhoneRelay.Reply(id: "x", verb: "allow", nonce: String(repeating: "b", count: 32))
        #expect(PhoneRelay.target(of: forged, pending: p, requests: [r]) == nil)
        let deny = PhoneRelay.Reply(id: "y", verb: "deny", nonce: String(repeating: "b", count: 32))
        #expect(PhoneRelay.target(of: deny, pending: p, requests: [r]) != nil)
    }

    @Test func onlyWellFormedRepliesParse() {
        let nonce = String(repeating: "0f", count: 16)
        let lines = [
            #"{"event":"open","id":"o"}"#,
            #"{"event":"message","id":"1","message":"allow \#(nonce)"}"#,
            #"{"event":"message","id":"2","message":"always \#(nonce)"}"#,
            #"{"event":"message","id":"3","message":"allow \#(nonce.uppercased())"}"#,
            #"{"event":"message","id":"4","message":"deny \#(nonce) extra"}"#,
            #"{"event":"message","id":"5","message":"deny \#(nonce.prefix(31))"}"#,
            "not json",
            #"{"event":"message","id":"6","message":"deny \#(nonce)"}"#,
        ].joined(separator: "\n")
        let replies = PhoneRelay.parseReplies(Data(lines.utf8))
        #expect(replies == [PhoneRelay.Reply(id: "1", verb: "allow", nonce: nonce),
                            PhoneRelay.Reply(id: "6", verb: "deny", nonce: nonce)])
    }

    // MARK: - The topic and the server

    @Test func topicsAreLongRandomAndValid() {
        let a = PhoneRelay.newTopic(), b = PhoneRelay.newTopic()
        #expect(a != b)
        #expect(a.count == "agentbar-".count + 26)
        #expect(PhoneRelay.validTopic(a))
        #expect(!PhoneRelay.validTopic("agentbar"))
        #expect(!PhoneRelay.validTopic("agentbar-Has-Capitals-123456"))
        #expect(PhoneRelay.newNonce().count == 32)
    }

    @Test func cleartextOnlyToThisMachineOrAPrivateNetwork() {
        #expect(PhoneRelay.serverURL("https://ntfy.sh/") != nil)
        #expect(PhoneRelay.serverURL("http://ntfy.sh") == nil)
        #expect(PhoneRelay.serverURL("http://192.168.1.20:8080") != nil)
        #expect(PhoneRelay.serverURL("http://100.101.1.2") != nil)
        #expect(PhoneRelay.serverURL("http://box.tail1234.ts.net") != nil)
        #expect(PhoneRelay.serverURL("http://172.32.0.1") == nil)
        #expect(PhoneRelay.serverURL("http://10.0.0.1.evil.com") == nil)
        #expect(PhoneRelay.serverURL("https://user@ntfy.sh") == nil)
        #expect(PhoneRelay.serverURL("https://ntfy.sh?x=1") == nil)
        #expect(PhoneRelay.serverURL("ftp://ntfy.sh") == nil)
    }

    @Test func awayMeansLockedOrUntouchedForTwoMinutes() {
        #expect(!PhoneRelay.shouldPush(when: .away, idle: 30, locked: false))
        #expect(PhoneRelay.shouldPush(when: .away, idle: 30, locked: true))
        #expect(PhoneRelay.shouldPush(when: .away, idle: 121, locked: false))
        #expect(PhoneRelay.shouldPush(when: .always, idle: 0, locked: false))
    }

    @Test func theButtonsPostTheVerbAndNonceToTheReplyTopic() throws {
        let server = try #require(URL(string: "https://ntfy.sh"))
        let body = PhoneRelay.publishBody(topic: "agentbar-abc", server: server, title: "t", message: "m",
                                          verbs: ["allow", "deny"], nonce: "n", plan: false, token: "tk")
        let actions = try #require(body["actions"] as? [[String: Any]])
        #expect(actions.map { $0["label"] as? String } == ["Allow", "Deny"])
        #expect(actions.allSatisfy { $0["url"] as? String == "https://ntfy.sh/agentbar-abc-answers" })
        #expect(actions.map { $0["body"] as? String } == ["allow n", "deny n"])
        #expect((actions[0]["headers"] as? [String: String])?["Authorization"] == "Bearer tk")
        #expect(PhoneRelay.subscribeLink(server: "https://ntfy.sh", topic: "agentbar-abc") == "ntfy://ntfy.sh/agentbar-abc")
        #expect(PhoneRelay.subscribeLink(server: "http://10.0.0.2:81", topic: "t") == "ntfy://10.0.0.2:81/t?secure=false")
    }
}
