import Cocoa
import Testing
@testable import AgentBar

/// `docs/protocol.md` lets any tool write a row under any id. Before generic agents an id
/// AgentBar did not know resolved to `Agent.all[0]`, so an `aider` row wore
/// Claude's crab, colour, verbs and open action. These pin what a stranger gets
/// instead, and that the agents AgentBar ships with are untouched by it.
@Suite struct AgentsTests {
    @Test func everyKnownIdIsStillItself() {
        for agent in Agent.all {
            let got = Agent.byID(agent.id, name: "Something Else")
            #expect(got.id == agent.id)
            #expect(got.name == agent.name, "a known agent ignores agent_name")
            #expect(got.approveKeys == agent.approveKeys)
        }
    }

    /// A row with no `agent` key is Claude Code's — its hooks predate the field.
    @Test func noIdIsClaude() {
        #expect(Agent.byID("").id == "claude")
    }

    @Test func anUnknownIdIsAGenericAgentOfItsOwn() {
        let a = Agent.byID("aider")
        #expect(a.id == "aider")
        #expect(a.name == "Aider")
        #expect(Agent.byID("my-agent").name == "My Agent")
        #expect(Agent.byID("my-agent", name: "Robo").name == "Robo")
        if case .monogram(let letter) = a.artwork { #expect(letter == "A") }
        else { Issue.record("a generic agent draws a monogram") }
        if case .monogram(let letter) = Agent.byID("x", name: "robo").artwork { #expect(letter == "R") }
        else { Issue.record("a generic agent draws a monogram") }
    }

    /// The things a stranger must never get: keys to type into its terminal, a
    /// command to start it, a place in the launcher.
    @Test func aGenericAgentPromisesNothingItCannotKeep() {
        let a = Agent.byID("aider")
        #expect(a.approveKeys == nil)
        #expect(a.cli == nil)
        #expect(a.takesPrompt == false)
        if case .terminal = a.open {} else { Issue.record("a generic agent opens the terminal") }
        #expect(!Agent.all.contains { $0.id == "aider" })
    }

    /// Same id, same colour, on every launch — FNV over the bytes, not the
    /// per-process seeded `hashValue`. Different ids mostly differ.
    @Test func theBrandIsStableAndMuted() throws {
        let one = try #require(Agent.byID("aider").brand.usingColorSpace(.sRGB))
        let two = try #require(Agent.byID("aider", name: "Other").brand.usingColorSpace(.sRGB))
        #expect(one == two)
        #expect(Agent.hue(for: "aider").hueComponent == Agent.hue(for: "aider").hueComponent)
        let hues = Set(["aider", "goose", "amp", "cline", "roo"].map { Int(Agent.hue(for: $0).hueComponent * 360) })
        #expect(hues.count > 1)
        // Readable on the island without the dark-lift kicking in.
        #expect(one.brightnessComponent >= 0.55)
        #expect(one.saturationComponent < 0.6)
    }

    @Test func aGenericSpriteHasInkInBothModes() throws {
        let sprite = IconRenderer.shared.sprite(for: Agent.byID("aider-test-sprite"))
        #expect(!sprite.colorFrames.isEmpty)
        #expect(!sprite.templateFrames.isEmpty)
        #expect(sprite.restingTemplate.isTemplate)
        #expect(!sprite.restingColor.isTemplate)
        for image in [sprite.restingColor, sprite.restingTemplate] {
            #expect(image.size.width > 0 && image.size.height > 0)
            #expect(try opaquePixels(image) > 0)
        }
        // The letter is a hole: fewer opaque pixels than the plain square would have.
        let plain = try opaquePixels(IconRenderer.monogram(" ", height: 15))
        let lettered = try opaquePixels(IconRenderer.monogram("A", height: 15))
        #expect(lettered < plain)
        // And it fits the menu's box like everybody else's mark.
        let mark = MenuBuilder.menuMark(for: Agent.byID("aider-test-sprite"))
        #expect(mark.size == MenuBuilder.menuMark(for: Agent.byID("codex")).size)
    }

    /// A rename under the same id must redraw the letter, not reuse the cache.
    @Test func aRenameRedrawsTheLetter() {
        let a = IconRenderer.shared.sprite(for: Agent.byID("renamed-bot", name: "Alpha")).restingColor
        let b = IconRenderer.shared.sprite(for: Agent.byID("renamed-bot", name: "Beta")).restingColor
        #expect(a !== b)
    }

    private func opaquePixels(_ image: NSImage) throws -> Int {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { n += 1 }
        }
        return n
    }
}
