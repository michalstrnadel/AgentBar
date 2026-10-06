import Cocoa

/// The break game's pictures, drawn the way Clawd's scenes are (`ClawdSceneArt`):
/// text art, one character per pixel, edited by editing the picture. Rendered once
/// to `CGImage`s and drawn without smoothing, so the pixels stay pixels.
///
/// | Mark | Drawn as |
/// | --- | --- |
/// | `o` `O` | Clawd's body, in shade |
/// | `#` | eye |
/// | `r` | antenna tip, wasp red |
/// | `y` `Y` | amber, deep amber |
/// | `v` `V` | drone blue, deep blue |
/// | `g` `G` | wing green, deep green |
/// | `p` `P` | boss purple, deep purple |
/// | `w` | white |
/// | `.` | empty |
enum BreakGameArt {
    static let palette: [Character: UInt32] = [
        "o": 0xd77757, "O": 0xbd674b, "#": 0x000000, "r": 0xe5534b,
        "y": 0xf5c542, "Y": 0xf08a2b, "v": 0x8ab4f8, "V": 0x4f6e9c,
        "g": 0x5fd38d, "G": 0x2f8f5b, "p": 0xb48cf2, "P": 0x7a52c4, "w": 0xffffff,
    ]

    /// Clawd as the ship: antenna up, eyes forward, legs as the exhaust.
    static let ship = """
    .....r.....
    .....o.....
    ...ooooo...
    ..oo#o#oo..
    .ooooooooo.
    ooooooooooo
    O.O.O.O.O.O
    """

    /// Two wing beats per bug, alternated as the formation sways.
    static let bugs: [BreakGame.Kind: [String]] = [
        .drone: ["""
        ..v.....v..
        ...v...v...
        ..vvvvvvv..
        .vv#vvv#vv.
        vvvvvvvvvvv
        V.vvvvvvv.V
        V.V.....V.V
        """, """
        ..v.....v..
        V..v...v..V
        V.vvvvvvv.V
        Vvv#vvv#vvV
        .vvvvvvvvv.
        ..vvvvvvv..
        .V.......V.
        """],
        .wasp: ["""
        ...r...r...
        ....r.r....
        g.yyyyyyy.g
        gGy#yyy#yGg
        gGyyyyyyyGg
        g..YyyyY..g
        ....Y.Y....
        """, """
        ...r...r...
        ....r.r....
        ..yyyyyyy..
        .gy#yyy#yg.
        gGyyyyyyyGg
        gG.YyyyY.Gg
        ....Y.Y....
        """],
        .boss: ["""
        ....y.y....
        ...ppppp...
        ..pp#p#pp..
        Ppppppppppp
        PPpppppppPP
        P.pPpppPp.P
        ..P.....P..
        """, """
        ....y.y....
        ...ppppp...
        ..pp#p#pp..
        .ppppppppp.
        PPpppppppPP
        PPpPpppPpPP
        .P.......P.
        """],
    ]

    /// A burst, big to small.
    static let burst = ["""
    ...y...
    .y.Y.y.
    ..YwY..
    yYwwwYy
    ..YwY..
    .y.Y.y.
    ...y...
    """, """
    y..Y..y
    .Y...Y.
    ...w...
    Y.w.w.Y
    ...w...
    .Y...Y.
    y..Y..y
    """]

    /// A token: what a diving bug drops now and then.
    static let token = """
    ..yyy..
    .yYYYy.
    yYyyyYy
    yYyYyYy
    yYyyyYy
    .yYYYy.
    ..yyy..
    """

    /// Rendered at `pixel` points to a pixel, `scale` device pixels to a point, in
    /// `colors` (this game's palette unless another game passes its own).
    static func image(_ art: String, pixel: CGFloat, scale: CGFloat = 2,
                      colors: [Character: UInt32] = palette) -> CGImage? {
        let lines = art.split(separator: "\n").map(Array.init)
        let rows = lines.count
        let cols = lines.map(\.count).max() ?? 0
        let w = Int(CGFloat(cols) * pixel * scale), h = Int(CGFloat(rows) * pixel * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let p = pixel * scale
        for (y, line) in lines.enumerated() {
            for (x, mark) in line.enumerated() {
                guard let rgb = colors[mark] else { continue }
                ctx.setFillColor(red: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                                 blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
                ctx.fill(CGRect(x: CGFloat(x) * p, y: CGFloat(rows - 1 - y) * p, width: p, height: p))
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Pixel font

    /// Three by five, rows top to bottom, `#` lit. Enough for the stats and banners.
    static let glyphs: [Character: String] = [
        "A": ".#.#.#####.##.#", "B": "##.#.###.#.###.", "C": ".###..#..#...##", "D": "##.#.##.##.###.",
        "E": "####..##.#..###", "F": "####..##.#..#..", "G": ".###..#.##.#.##", "H": "#.##.#####.##.#",
        "I": "###.#..#..#.###", "J": "..#..#..##.#.#.", "K": "#.##.###.#.##.#", "L": "#..#..#..#..###",
        "M": "#.########.##.#", "N": "##.#.##.##.##.#", "O": ".#.#.##.##.#.#.", "P": "##.#.###.#..#..",
        "Q": ".#.#.##.###..##", "R": "##.#.###.#.##.#", "S": ".###...#...###.", "T": "###.#..#..#..#.",
        "U": "#.##.##.##.####", "V": "#.##.##.##.#.#.", "W": "#.##.########.#", "X": "#.##.#.#.#.##.#",
        "Y": "#.##.#.#..#..#.", "Z": "###..#.#.#..###", "0": "####.##.##.####", "1": ".#.##..#..#.###",
        "2": "##...#.#.#..###", "3": "##...#.#...###.", "4": "#.##.####..#..#", "5": "####..##...###.",
        "6": ".###..####.####", "7": "###..#.#..#..#.", "8": "####.#####.####", "9": "####.####..###.",
        " ": "...............", "-": "......###......", ":": "....#.....#....", "!": ".#..#..#.....#.",
        ".": ".............#.", "·": ".......#.......", "<": "..#.#.#...#...#", ">": "#...#...#.#.#..",
        "=": "...###...###...",
    ]

    /// The lit cells of a glyph, as (column, row) with row 0 at the top. A glyph
    /// table entry of the wrong length draws nothing rather than garbage.
    static func cells(_ c: Character) -> [(Int, Int)] {
        let upper = Character(c.uppercased())
        guard let g = glyphs[upper], g.count == 15 else { return [] }
        return g.enumerated().compactMap { i, ch in ch == "#" ? (i % 3, i / 3) : nil }
    }

    /// Width in points of `text` at `pixel` points to a font pixel: three lit
    /// columns and one gap per character, no gap after the last.
    static func textWidth(_ text: String, pixel: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(text.count * 4 - 1) * pixel
    }
}
