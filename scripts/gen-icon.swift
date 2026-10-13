// 一次性脚本：brand.svg → AppIcon.iconset → AppIcon.icns
// 渲染走 AppKit 原生 SVG 支持（macOS 14），圆角裁切带透明底。
// 用法: swift scripts/gen-icon.swift
import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = repo.appendingPathComponent("DreamanualNAS/Resources/brand.svg")
let iconsetURL = URL(fileURLWithPath: "/tmp/nas-icon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let src = NSImage(contentsOf: svgURL) else {
    fatalError("SVG 读不出来（AppKit 原生支持需要 macOS 11+）")
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!
    // macOS 图标网格：画稿只占画布 0.828、四周留透明边距 —— 与产品线其他
    // app（投资监控 / 密码管理 / 视频下载均 0.828）同尺寸，满幅会明显偏大。
    let content = Int(Double(px) * 0.828)
    let inset = (px - content) / 2
    let r = Double(content) * 0.22
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: content, height: content),
                 xRadius: r, yRadius: r).addClip()
    src.draw(in: NSRect(x: inset, y: inset, width: content, height: content),
             from: NSRect.zero, operation: .sourceOver, fraction: 1.0)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ px: Int, _ name: String) {
    let rep = render(px)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconsetURL.appendingPathComponent(name))
    print("  \(name)")
}

write(16, "icon_16x16.png")
write(32, "icon_16x16@2x.png")
write(32, "icon_32x32.png")
write(64, "icon_32x32@2x.png")
write(128, "icon_128x128.png")
write(256, "icon_128x128@2x.png")
write(256, "icon_256x256.png")
write(512, "icon_256x256@2x.png")
write(512, "icon_512x512.png")
write(1024, "icon_512x512@2x.png")
print("iconset 完成：\(iconsetURL.path)")
