import SwiftUI

/// 16×12 pixel art. The color keys are fixed, not tied to the user's accent.
/// Sockeye (Thermocline sampling/salmon): D/M/R flank shadow/mid/highlight,
/// J/O/L olive head shadow/mid/highlight, X eye (head shadow with OKLCH lightness lowered).
/// Macaw (Thermocline sampling/consensus.json and tokens): W/B/T wing shadow/deep blue/sky-lit,
/// C blue-green back, G green crown, P pale cheek, Y/D gold/shade, I throat and bill, K bill edge, E eye.
/// A dot leaves the layer beneath it unchanged. Frames read left to right in playback order.
enum SpriteArt: String {
    case salmon, macaw

    private static let salmonInk: [Character: UInt32] = [
        "D": 0x813032, "M": 0xAB3F42, "R": 0xC55050,
        "J": 0x4E5841, "O": 0x757C55, "L": 0x9D9E5D, "X": 0x27301B,
    ]
    private static let macawInk: [Character: UInt32] = [
        "W": 0x02516A, "B": 0x186377, "T": 0x4899AC, "C": 0x3A8699, "G": 0x6E9663,
        // Cheek: OKLab mean of the clean cheek mids in the existing macaw2 and macaw3 photos
        // (sampling/sel.json, 1920px source grids; crops [1464,229,1497,249] and [1470,560,1510,587]).
        "P": 0xDCDDE2, "Y": 0xF4B21F, "D": 0xDF8C07, "I": 0x13181D, "E": 0x22272B,
        // Bill edge: same method and photos, [1565,233,1580,247] and [1625,480,1647,498].
        "K": 0x515760,
    ]

    var ink: [Character: UInt32] { self == .salmon ? Self.salmonInk : Self.macawInk }
    var halo: Color { Color(uiColor: UIColor(hex: self == .salmon ? 0xC55050 : 0x4899AC)) }
    var frames: [[[Character]]] { self == .salmon ? Self.swim : Self.flap }

    static let width = 16
    static let height = 12

    private struct Layer {
        let x: Int, y: Int
        let rows: [String]
        init(_ x: Int, _ y: Int, _ rows: [String]) { self.x = x; self.y = y; self.rows = rows }
    }

    private static func compose(_ layers: Layer...) -> [[Character]] {
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        for layer in layers {
            for (dy, row) in layer.rows.enumerated() {
                for (dx, key) in row.enumerated() where key != "." {
                    grid[layer.y + dy][layer.x + dx] = key
                }
            }
        }
        return grid
    }

    private static let swim: [[[Character]]] = {
        let body = Layer(0, 2, [
            "......DR", ".....DRRR", "..LOOMRRRD", ".LXOLRRRMMMD", "OOOLMRRMMMMD",
            "J..OOMMMMD", ".JJJJDDDR", ".....D.D",
        ])
        // Pinned head, caudal peduncle bends first, then the forked tail follows through.
        let strokes = [
            Layer(10, 4, ["....DD", "..DMMD", "DMMMD", "..DMM", "....DD"]),
            Layer(10, 3, ["....DD", "...DRD", "..DRD", "MMMD", "..DMMD", "....D"]),
            Layer(10, 3, [".....D", "...DMD", "..RMD", "DMMMD", "...MD", "....D"]),
            Layer(10, 4, ["....DD", "...DRD", "DMMMD", ".DMM", "...DMD"]),
            Layer(10, 5, ["....DD", "DMMMMD", ".DMM", "..DMD", "....DD"]),
            Layer(10, 5, ["....D", "DMMD", ".DMMD", "..DMMD", "...DMD", ".....D"]),
            Layer(10, 5, [".....D", "DMMDMD", "..MMD", "...DMD", "....DD"]),
            Layer(10, 4, [".....D", "...DMD", "DMMMD", "..DMM", "...DMD"]),
        ]
        return strokes.map { compose($0, body) }
    }()

    private static let flap: [[[Character]]] = {
        let body = Layer(1, 1, [
            "..........GG", ".........CGGP", "........CBPEPK", ".......CBYYPIIK",
            "......CBYYYI.I", ".....CBYYYD", "....WBBYYD", "...WBBDDD",
            "..WBBT", ".WBBT", "WBT",
        ])
        // Far and near feathers are layered around the body so the face and chest stay readable.
        let far = [
            Layer(7, 0, ["W", "WB", ".WB", ".WBB", "..WB"]),
            Layer(6, 1, ["W", "WBB", ".WBBB", "..WBB"]),
            Layer(3, 3, ["WW", ".WWBB", "..WWBB"]),
            Layer(3, 6, ["...WB", ".WWB", "WWB", "W"]),
            Layer(4, 6, ["..WBB", ".WBB", ".WB", "WB", "W"]),
            Layer(5, 6, [".WBB", "WBB", "WB", "W"]),
            Layer(2, 4, ["WWBB", "..WWBB", "...WBB"]),
            Layer(5, 1, ["W", ".WB", "..WBB", "...WBB"]),
        ]
        let near = [
            Layer(2, 0, ["W", "WTW", "WTBBW", ".WTBBBW", "..WTBBCB", "...WTBC", "....WB"]),
            Layer(1, 1, ["W", "WTW", ".WTBBW", "..WTBBBW", "...WTBCB", ".....WB"]),
            Layer(0, 3, ["WTTW", "WWTBBW", ".WWTBCBB", "...WBTBCB", ".....WWB"]),
            Layer(0, 5, ["...WTBCB", ".WTBBCB", "WWTBBC", "WBBB", ".W"]),
            Layer(1, 5, ["....WTBC", "...WTBB", "..WTBB", ".WTBB", "WTBB", "WBB", "W"]),
            Layer(0, 5, ["....WTBCB", "..WTBBCB", ".WTBBC", "WTBBB", "WWBB", "W"]),
            Layer(0, 4, ["WWTTWW", ".WWTBBBC", "..WWTBCBB", "....WWB"]),
            Layer(1, 2, ["WTW", "WWTBBW", ".WWTBBBW", "..WWTBCB", ".....WB"]),
        ]
        return zip(far, near).map { compose($0.0, body, $0.1) }
    }()
}

struct PixelSprite: View {
    let art: SpriteArt
    let size: CGFloat
    let current: Color
    let thermocline: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fps: Double = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: reduceMotion)) { context in
            let frame = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * fps) % art.frames.count
            SpriteFrame(art: art, frame: frame, current: current, thermocline: thermocline)
                .frame(width: size, height: size * CGFloat(SpriteArt.height) / CGFloat(SpriteArt.width))
        }
        .accessibilityHidden(true)
    }
}

private struct SpriteFrame: View {
    let art: SpriteArt
    let frame: Int
    let current: Color
    let thermocline: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    @Environment(\.hmInsideGlow) private var insideGlow

    var body: some View {
        ZStack {
            if art == .salmon {
                Canvas { ctx, size in
                    // Rightward flow (the fish faces left); 2 pixels per frame, 16 pixels per loop.
                    for (row, start, length) in [(1, 1, 4), (10, 7, 4), (11, 2, 2)] {
                        for i in 0..<length {
                            let col = (start + 2 * frame + i) % SpriteArt.width
                            ctx.fill(pixel(col, row, size), with: .color(current.opacity(i == 0 ? 0.38 : 0.66)))
                        }
                    }
                }
            }
            Canvas { ctx, size in
                let ink = art.ink.mapValues { Color(uiColor: UIColor(hex: $0)) }
                for (row, keys) in art.frames[frame].enumerated() {
                    for (col, key) in keys.enumerated() {
                        if let color = ink[key] { ctx.fill(pixel(col, row, size), with: .color(color)) }
                    }
                }
            }
            .hmHalo(art.halo, active: thermocline && scheme == .dark && !insideGlow)
        }
    }

    private func pixel(_ x: Int, _ y: Int, _ size: CGSize) -> Path {
        // Snap every grid edge to a physical pixel, without overlapping neighbouring swatches.
        let w = size.width / CGFloat(SpriteArt.width), h = size.height / CGFloat(SpriteArt.height)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let left = snap(CGFloat(x) * w), top = snap(CGFloat(y) * h)
        return Path(CGRect(x: left, y: top, width: snap(CGFloat(x + 1) * w) - left, height: snap(CGFloat(y + 1) * h) - top))
    }
}

#if DEBUG
/// Offline audit of the exact Canvas frames used in Settings and chat. `-HMDemo 1 -HMSpriteFrames salmon|macaw`.
struct SpriteFrameStrip: View {
    let art: SpriteArt
    @Environment(\.thermoclineAccent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(art == .salmon ? "Salmon · upstream" : "Macaw · wingbeat").font(.title2.bold())
                Text("Eight frames · 16 × 12 pixels · 9 fps").font(HMType.data).foregroundStyle(HMDesign.text2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 18) {
                    ForEach(art.frames.indices, id: \.self) { frame in
                        VStack(alignment: .leading, spacing: 10) {
                            SpriteFrame(art: art, frame: frame, current: accent.tint(for: scheme), thermocline: HMTheme.isThermocline)
                                .aspectRatio(4 / 3, contentMode: .fit)
                            Text("FRAME 0\(frame + 1)").font(HMType.data).foregroundStyle(HMDesign.text2)
                        }
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .background(HMDesign.canvas.ignoresSafeArea())
    }
}
#endif
