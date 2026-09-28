// NowLyrics Havoc banner, "Apple-clean" direction, refined after judging.
// Renders a 1920x1080 PNG with AppKit only.  Run: swift final.swift [cross|dot] [outPath]
import AppKit
import CoreText

let base = "/private/tmp/claude-501/-Users-chxhua2k7-Projects-NowLyrics/05025344-54ea-4711-a5a1-65ab60d6fec6/scratchpad/banner"
let args = CommandLine.arguments
let leaderMode = args.count > 1 ? args[1] : "cross"     // "cross": leader runs to the highlight box; "dot": stops at the card edge
let outPath = args.count > 2 ? args[2] : base + "/out/final-clean.png"

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

// -- phone geometry.  The phone bleeds off the bottom edge (cut just below the
//    flashlight/camera row, above the personal caption) and fades out at the top
//    in the empty band between the widgets and the now-playing card.
let shotScale: CGFloat = 0.76
let shotW: CGFloat = 923 * shotScale, shotH: CGFloat = 2000 * shotScale
let lyricSrcY: CGFloat = 1335       // centre of the lyric line in the 923x2000 screenshot
let lyricRowTop: CGFloat = 659      // where that line lands on the canvas (also the caption row)
let screenTop = lyricRowTop - lyricSrcY * shotScale
let bezel: CGFloat = 12
let rightMargin: CGFloat = 150
let screenX = W - rightMargin - bezel - shotW
let screenRect = R(screenX, screenTop, shotW, shotH)
let phoneRect = screenRect.insetBy(dx: -bezel, dy: -bezel)
let screenRadius = shotW * 0.145
let phoneRadius = screenRadius + bezel
func srcX(_ x: CGFloat) -> CGFloat { screenX + x * shotScale }
func srcY(_ y: CGFloat) -> CGFloat { screenTop + y * shotScale }   // design space (y down)

// -- background: deep warm black with a subtle vignette
ctx.setFillColor(bgBase.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
do {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [rgb(0x2A2119).cgColor, rgb(0x1B1612).cgColor, rgb(0x0E0B09).cgColor] as CFArray
    let locs: [CGFloat] = [0, 0.55, 1]
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: locs)!
    let c = CGPoint(x: W * 0.55, y: H * 0.5)
    ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: 1250,
                           options: [.drawsAfterEndLocation])
}
// -- a faint warm glow behind the card, tying the brown palette to the photo
do {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [rgb(0x8E6349, 0.30).cgColor, rgb(0x6D442A, 0.12).cgColor, rgb(0x6D442A, 0).cgColor] as CFArray
    let locs: [CGFloat] = [0, 0.45, 1]
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: locs)!
    let c = CGPoint(x: srcX(461), y: Y(srcY(1490)))
    ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: 720, options: [])
}

// -- top fade mask: fully transparent above `fadeFrom`, fully opaque below `fadeTo`,
//    eased in between (smoothstep), so the clock/widget zone is gone entirely.
func topFadeMask(fadeFrom: CGFloat, fadeTo: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceGray()
    let m = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: Int(W),
                      space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    m.setFillColor(CGColor(colorSpace: cs, components: [1, 1])!)
    m.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let steps = 12
    var colors: [CGColor] = []
    var locs: [CGFloat] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let v = t * t * (3 - 2 * t)
        colors.append(CGColor(colorSpace: cs, components: [v, 1])!)
        locs.append(t)
    }
    let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    m.drawLinearGradient(grad, start: CGPoint(x: 0, y: Y(fadeFrom)), end: CGPoint(x: 0, y: Y(fadeTo)),
                         options: [.drawsBeforeStartLocation])
    return m.makeImage()!
}
let widgetsBottom = srcY(840)        // bottom of the purple widget circles
let cardTop = srcY(1258)
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H),
         mask: topFadeMask(fadeFrom: widgetsBottom + 20, fadeTo: cardTop - 30))

// -- phone: shadow + bezel
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: NSColor.black.withAlphaComponent(0.70).cgColor)
ctx.setFillColor(rgb(0x0A0908).cgColor)
ctx.addPath(roundedPath(phoneRect, phoneRadius).cgPath)
ctx.fillPath()
ctx.restoreGState()

// -- screenshot, clipped to the screen
if let shot = NSImage(contentsOfFile: base + "/assets/lockscreen.webp") {
    NSGraphicsContext.saveGraphicsState()
    roundedPath(screenRect, screenRadius).addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    shot.draw(in: screenRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
} else {
    fatalError("lockscreen.webp not readable")
}
// bezel rim highlight
ctx.saveGState()
ctx.addPath(roundedPath(phoneRect.insetBy(dx: 0.75, dy: 0.75), phoneRadius - 0.75).cgPath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
ctx.setLineWidth(1.5)
ctx.strokePath()
ctx.restoreGState()
ctx.restoreGState()   // end of top-fade mask clip

// -- logo + name lockup
let cells = loadLogoCells()
drawLogo(ctx, x: colX, top: logoTop, size: logoSize, cells: cells)

let nameStyle = TextStyle(font: NSFont.systemFont(ofSize: 132, weight: .bold), color: offWhite, kern: -4)
let nameX = colX + logoSize + 40
let nameCap = nameStyle.font.capHeight
let nameBaseline = logoTop + logoSize / 2 + nameCap / 2
drawLine(ctx, "NowLyrics", nameStyle, x: nameX, baselineTop: nameBaseline)

// -- tagline (two lines)
let tagStyle = TextStyle(font: NSFont.systemFont(ofSize: 64, weight: .medium), color: offWhite.withAlphaComponent(0.90), kern: -0.6)
drawLine(ctx, "Synced lyrics in place", tagStyle, x: colX, baselineTop: 600)
drawLine(ctx, "of the track title.", tagStyle, x: colX, baselineTop: 676)

// -- highlight box around the lyric row on the card (no text: Havoc 1.10.7.1)
let boxRect = R(srcX(216), srcY(1309), (772 - 216) * shotScale, (1358 - 1309) * shotScale)
let boxRadius: CGFloat = 12
do {
    ctx.saveGState()
    ctx.setFillColor(accent.withAlphaComponent(0.10).cgColor)
    ctx.addPath(roundedPath(boxRect, boxRadius).cgPath)
    ctx.fillPath()
    ctx.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
    ctx.setLineWidth(2.5)
    ctx.addPath(roundedPath(boxRect, boxRadius).cgPath)
    ctx.strokePath()
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

// -- write PNG
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(rep.pixelsWide)x\(rep.pixelsHigh) mode=\(leaderMode)")
