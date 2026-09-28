// NowLyrics Havoc banner, "Apple-clean" direction, refined after judging.
// Renders a 1920x1080 PNG with AppKit only.  Run: swift final.swift [cross|dot] [outPath]
import AppKit
import CoreText

let base = "/private/tmp/claude-501/-Users-chxhua2k7-Projects-NowLyrics/05025344-54ea-4711-a5a1-65ab60d6fec6/scratchpad/banner"
let args = CommandLine.arguments
let leaderMode = args.count > 1 ? args[1] : "cross"     // "cross": leader runs to the highlight box; "dot": stops at the card edge
let outPath = args.count > 2 ? args[2] : base + "/out/noshot.png"

let W: CGFloat = 1920
let H: CGFloat = 1080

// MARK: - helpers ------------------------------------------------------------

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Rect from top-left coordinates (design space, y down) into AppKit space (y up).
func R(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: H - top - h, width: w, height: h)
}
func Y(_ top: CGFloat) -> CGFloat { H - top }

struct TextStyle {
    var font: NSFont
    var color: NSColor
    var kern: CGFloat = 0
}

func attributed(_ s: String, _ st: TextStyle) -> NSAttributedString {
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): st.font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): st.color.cgColor,
        NSAttributedString.Key(kCTKernAttributeName as String): st.kern,
    ]
    return NSAttributedString(string: s, attributes: attrs)
}

/// Draws a single line with its baseline at design-space `baselineTop` (y down), left edge at x.
/// Returns the typographic width.
@discardableResult
func drawLine(_ ctx: CGContext, _ s: String, _ st: TextStyle, x: CGFloat, baselineTop: CGFloat,
              align: NSTextAlignment = .left) -> CGFloat {
    let line = CTLineCreateWithAttributedString(attributed(s, st))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    var x0 = x
    if align == .right { x0 = x - width }
    if align == .center { x0 = x - width / 2 }
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x0, y: Y(baselineTop))
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return width
}

func lineWidth(_ s: String, _ st: TextStyle) -> CGFloat {
    let line = CTLineCreateWithAttributedString(attributed(s, st))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

// MARK: - assets --------------------------------------------------------------

struct Cell { var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat; var color: NSColor }

func loadLogoCells() -> [Cell] {
    guard let svg = try? String(contentsOfFile: base + "/assets/logo.svg", encoding: .utf8) else { return [] }
    let re = try! NSRegularExpression(pattern: ##"<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)" fill="#([0-9A-Fa-f]{6})""##)
    let ns = svg as NSString
    return re.matches(in: svg, range: NSRange(location: 0, length: ns.length)).map { m in
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        return Cell(x: CGFloat(Double(g(1))!), y: CGFloat(Double(g(2))!),
                    w: CGFloat(Double(g(3))!), h: CGFloat(Double(g(4))!),
                    color: rgb(UInt32(g(5), radix: 16)!))
    }
}

/// Draws the pixel-art icon at `size` px with top-left at (x, top), iOS-style rounded corners.
/// Cells are drawn as vector rects (from logo.svg), so edges stay crisp at any size.
func drawLogo(_ ctx: CGContext, x: CGFloat, top: CGFloat, size: CGFloat, cells: [Cell]) {
    let frame = R(x, top, size, size)
    let radius = size * 0.2237  // iOS icon corner ratio (≈229/1024)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.setFillColor(rgb(0x2C2A22).cgColor)
    ctx.addPath(roundedPath(frame, radius).cgPath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedPath(frame, radius).cgPath)
    ctx.clip()
    ctx.setShouldAntialias(false)
    let s = size / 1024
    for c in cells {
        let x0 = (frame.minX + c.x * s).rounded()
        let x1 = (frame.minX + (c.x + c.w) * s).rounded()
        let yTop = top + c.y * s
        let y0 = (Y(yTop + c.h * s)).rounded()
        let y1 = (Y(yTop)).rounded()
        ctx.setFillColor(c.color.cgColor)
        ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }
    ctx.restoreGState()
}

// MARK: - render --------------------------------------------------------------

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap rep")
}
rep.size = NSSize(width: W, height: H)
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
ctx.setAllowsFontSmoothing(true)
ctx.setShouldSmoothFonts(true)

// -- palette
let bgBase   = rgb(0x14100D)
let offWhite = rgb(0xF4EDE4)
let accent   = rgb(0xF2CFB3)   // note colour from the icon: the one accent
let muted    = offWhite.withAlphaComponent(0.72)

// -- layout constants (design space, y down)
let colX: CGFloat = 150            // left column
let logoSize: CGFloat = 160        // 10 px per pixel-art cell
let logoTop: CGFloat = 320


// -- background: deep warm black with a subtle vignette
ctx.setFillColor(bgBase.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
do {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [rgb(0x2A2119).cgColor, rgb(0x1B1612).cgColor, rgb(0x0E0B09).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
    let c = CGPoint(x: W * 0.62, y: H * 0.5)
    ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: 1250, options: [.drawsAfterEndLocation])
}

// -- big logo on the right, with a warm glow behind it
let bigSize: CGFloat = 576                      // 36 px per pixel-art cell
let bigX: CGFloat = 1180
let bigTop: CGFloat = (H - bigSize) / 2
let bigCenter = CGPoint(x: bigX + bigSize / 2, y: Y(bigTop + bigSize / 2))
do {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [rgb(0x8E6349, 0.38).cgColor, rgb(0x6D442A, 0.14).cgColor, rgb(0x6D442A, 0).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(grad, startCenter: bigCenter, startRadius: 0, endCenter: bigCenter, endRadius: 760, options: [])
}
do {
    // soft drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 70, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.setFillColor(rgb(0x36342A).cgColor)
    ctx.addPath(roundedPath(R(bigX, bigTop, bigSize, bigSize), bigSize * 0.2237).cgPath)
    ctx.fillPath()
    ctx.restoreGState()
}
let cells = loadLogoCells()
drawLogo(ctx, x: bigX, top: bigTop, size: bigSize, cells: cells)

// -- lockup on the left: name + tagline, vertically centred against the logo
let nameStyle = TextStyle(font: NSFont.systemFont(ofSize: 150, weight: .bold), color: offWhite, kern: -4.5)
let tagStyle = TextStyle(font: NSFont.systemFont(ofSize: 66, weight: .medium), color: offWhite.withAlphaComponent(0.90), kern: -0.6)
let nameBaseline: CGFloat = 486
drawLine(ctx, "NowLyrics", nameStyle, x: colX, baselineTop: nameBaseline)
drawLine(ctx, "Synced lyrics in place", tagStyle, x: colX + 6, baselineTop: 600)
drawLine(ctx, "of the track title.", tagStyle, x: colX + 6, baselineTop: 680)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(rep.pixelsWide)x\(rep.pixelsHigh); name ends x=\(colX + lineWidth("NowLyrics", nameStyle)); logo x=\(bigX)-\(bigX + bigSize)")
