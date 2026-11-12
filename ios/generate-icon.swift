// Run with: swift ios/generate-icon.swift ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(red: 0.16, green: 0.38, blue: 0.88, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
NSColor.white.setStroke(); NSColor.white.setFill()
let frame = NSBezierPath(); frame.lineWidth = 46; frame.lineCapStyle = .round; frame.lineJoinStyle = .round
frame.move(to: NSPoint(x: 326, y: 800)); frame.line(to: NSPoint(x: 698, y: 800))
frame.move(to: NSPoint(x: 326, y: 224)); frame.line(to: NSPoint(x: 698, y: 224))
frame.move(to: NSPoint(x: 360, y: 790)); frame.curve(to: NSPoint(x: 470, y: 545), controlPoint1: NSPoint(x: 355, y: 670), controlPoint2: NSPoint(x: 380, y: 610))
frame.curve(to: NSPoint(x: 470, y: 480), controlPoint1: NSPoint(x: 510, y: 520), controlPoint2: NSPoint(x: 510, y: 505))
frame.curve(to: NSPoint(x: 360, y: 234), controlPoint1: NSPoint(x: 380, y: 415), controlPoint2: NSPoint(x: 355, y: 350))
frame.move(to: NSPoint(x: 664, y: 790)); frame.curve(to: NSPoint(x: 554, y: 545), controlPoint1: NSPoint(x: 669, y: 670), controlPoint2: NSPoint(x: 644, y: 610))
frame.curve(to: NSPoint(x: 554, y: 480), controlPoint1: NSPoint(x: 514, y: 520), controlPoint2: NSPoint(x: 514, y: 505))
frame.curve(to: NSPoint(x: 664, y: 234), controlPoint1: NSPoint(x: 644, y: 415), controlPoint2: NSPoint(x: 669, y: 350)); frame.stroke()
let sand = NSBezierPath(); sand.move(to: NSPoint(x: 412, y: 324)); sand.line(to: NSPoint(x: 512, y: 426)); sand.line(to: NSPoint(x: 612, y: 324)); sand.close(); sand.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
