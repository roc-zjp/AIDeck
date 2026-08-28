import AppKit
let W = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let c = CGPoint(x: 512, y: 512)
let cyan  = NSColor(srgbRed: 0.20, green: 0.83, blue: 0.75, alpha: 1)
let amber = NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)

// 背景 squircle（现代 macOS 图标自带圆角、四周留少量透明）
let inset: CGFloat = 84, cr: CGFloat = 230
let rect = CGRect(x: inset, y: inset, width: CGFloat(W) - 2*inset, height: CGFloat(W) - 2*inset)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cr, cornerHeight: cr, transform: nil))
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.06, green: 0.10, blue: 0.16, alpha: 1).cgColor,
    NSColor(srgbRed: 0.02, green: 0.04, blue: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: W), end: CGPoint(x: W, y: 0), options: [])

func ring(_ radius: CGFloat, _ width: CGFloat, _ color: NSColor, glow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glow, color: color.withAlphaComponent(0.9).cgColor)
    ctx.setStrokeColor(color.withAlphaComponent(0.92).cgColor); ctx.setLineWidth(width)
    ctx.addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi*2, clockwise: false); ctx.strokePath()
    ctx.restoreGState()
}
func dot(_ angle: CGFloat, _ radius: CGFloat, _ size: CGFloat, _ color: NSColor) {
    let p = CGPoint(x: c.x + cos(angle)*radius, y: c.y + sin(angle)*radius)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: color.cgColor)
    ctx.setFillColor(color.cgColor)
    ctx.addArc(center: p, radius: size, startAngle: 0, endAngle: .pi*2, clockwise: false); ctx.fillPath()
    ctx.restoreGState()
}
// 两圈能量环 + 环上的会话卫星点（橙 = 等你、青 = 在跑），是产品的缩影
ring(300, 15, cyan, glow: 42)
ring(206, 10, amber, glow: 30)
dot(.pi * 0.30, 300, 24, amber)
dot(.pi * 1.15, 300, 17, cyan)
dot(.pi * 1.72, 300, 17, cyan)
// 中心核：白→青径向发光
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 90, color: cyan.cgColor)
let core = CGGradient(colorsSpace: cs, colors: [
    NSColor.white.cgColor, cyan.cgColor, cyan.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.42, 1])!
ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: 150, options: [])
ctx.restoreGState()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon1024.png"))
print("icon1024.png done")
