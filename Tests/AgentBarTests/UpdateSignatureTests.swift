import Foundation
import Security
import Testing
@testable import AgentBar

/// An install nobody clicked is gated on one question: was the staged bundle signed
/// by whoever signed the running one. These sign two throwaway copies of a system
/// tool so the question can be asked for real, with nothing faked.
@Suite struct UpdateSignatureTests {
    /// A copy of `/usr/bin/true`, made different from any other copy by `salt` (an
    /// extra signing identifier changes the code directory, so the cdhash) and
    /// signed ad hoc. Returns the copy and its designated requirement as text.
    private func signedCopy(_ salt: String) throws -> (URL, String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bin)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "-s", "-", "--identifier", "agentbar.test.\(salt)", bin.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(bin as CFURL, [], &code) == errSecSuccess)
        var req: SecRequirement?
        try #require(SecCodeCopyDesignatedRequirement(code!, [], &req) == errSecSuccess)
        var text: CFString?
        try #require(SecRequirementCopyString(req!, [], &text) == errSecSuccess)
        return (bin, text! as String)
    }

    @Test func aRequirementCompilesOrIsRefused() {
        #expect(UpdateSignature.requirement(#"identifier "com.michalstrnadel.agentbar""#) != nil)
        #expect(UpdateSignature.requirement("this is not a requirement") == nil)
    }

    /// A successor typed wrong would refuse every release after the bridge, so a
    /// typo in the list fails here rather than in the field.
    @Test func everySuccessorCompiles() {
        for text in UpdateSignature.successors {
            #expect(UpdateSignature.requirement(text) != nil, "\(text)")
        }
    }

    @Test func anotherSignerIsRefused() throws {
        let (a, reqA) = try signedCopy("a")
        let (b, _) = try signedCopy("b")
        let pinned = try #require(UpdateSignature.requirement(reqA))
        #expect(UpdateSignature.check(a, against: pinned) == nil)
        #expect(UpdateSignature.check(b, against: pinned) != nil)
        #expect(UpdateSignature.check(b, against: pinned, successors: []) != nil)
    }

    /// The bridge: a signer named in the list is accepted alongside the pinned one,
    /// and one that is not named still is not.
    @Test func aNamedSuccessorIsAccepted() throws {
        let (_, reqA) = try signedCopy("a")
        let (b, reqB) = try signedCopy("b")
        let (c, _) = try signedCopy("c")
        let pinned = try #require(UpdateSignature.requirement(reqA))
        #expect(UpdateSignature.check(b, against: pinned, successors: [reqB]) == nil)
        #expect(UpdateSignature.check(c, against: pinned, successors: [reqB]) != nil)
        #expect(UpdateSignature.check(b, against: pinned, successors: ["junk", reqB]) == nil)
    }
}
