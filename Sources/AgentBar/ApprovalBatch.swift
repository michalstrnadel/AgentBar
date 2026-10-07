import Foundation

/// Allow every pending request that asks exactly the same thing, in one click.
///
/// Three agents waiting on the same `npm test` are one decision the person has to
/// make three times. This makes it one — and stays a click, not a rule: it answers
/// only what is on screen when the click lands, never what arrives afterwards, and
/// every request it answers is written to the ledger as its own decision, made by
/// the person (CLAUDE.md rule 3).
///
/// "The same thing" is strict: the same tool, the **whole** input byte for byte
/// (not its shape — `git push origin main` and `git push --force` share one), and
/// the same directory, because a command that is routine in one checkout can be
/// the opposite in another. Plans and questions never batch: a plan is approved in
/// its own dialog, and a question has answers, not a yes.
enum ApprovalBatch {
    /// What two requests must share to be answered together; nil when `r` never
    /// batches.
    static func key(_ r: ApprovalRequest, cwd sessionCwd: String = "") -> String? {
        guard !r.isPlanRequest, r.questions == nil, !r.toolName.isEmpty else { return nil }
        let input = r.toolInputPretty.isEmpty ? r.display : r.toolInputPretty
        guard !input.isEmpty else { return nil }
        let cwd = r.cwd.isEmpty ? sessionCwd : r.cwd
        guard !cwd.isEmpty else { return nil }
        return [r.toolName, cwd, input].joined(separator: "\u{0}")
    }

    /// Every pending request that asks what `r` asks, `r` included, oldest first —
    /// or just `[r]` when nothing else does. `cwd` maps a request to its session's
    /// directory when the request does not carry one.
    static func alike(_ r: ApprovalRequest, in pending: [ApprovalRequest],
                      cwd: (ApprovalRequest) -> String = { _ in "" }) -> [ApprovalRequest] {
        guard let k = key(r, cwd: cwd(r)) else { return [r] }
        let same = pending.filter { key($0, cwd: cwd($0)) == k }
        let all = same.contains { $0.identity == r.identity } ? same : [r] + same
        return all.sorted { $0.ts < $1.ts }
    }

    /// The requests to answer when the click lands: those that were on screen
    /// (`shown`, by identity) and are still waiting. A request that arrived after
    /// the button was drawn was never seen, so it is not part of the click.
    static func stillPending(_ shown: [String], in pending: [ApprovalRequest]) -> [ApprovalRequest] {
        let ids = Set(shown)
        return pending.filter { ids.contains($0.identity) }
    }

    /// "Allow all 3".
    static func title(_ count: Int) -> String { "Allow all \(count)" }
}
