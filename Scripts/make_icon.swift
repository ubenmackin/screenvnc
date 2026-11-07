// Scripts — Generate the ScreenVNC app icon into Assets.xcassets.
// Run once: swift Scripts/make_icon.swift.

import CoreGraphics
import Foundation
import ImageIO

let size = 1024

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Could not create sRGB color space")
}

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

// Vertical navy -> black gradient; CG is y-up, so the top edge is y = size.
let navy = CGColor(srgbRed: 13.0 / 255.0, green: 27.0 / 255.0, blue: 82.0 / 255.0, alpha: 1)
let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

guard let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [navy, black] as CFArray,
    locations: [0, 1]
) else {
    fatalError("Could not create CGGradient")
}

context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Centered monitor mark; bezel plus screen plus stand read as remote desktop.
let displayWidth: CGFloat = 624
let displayHeight: CGFloat = 400
let originX = (CGFloat(size) - displayWidth) / 2
let originY = (CGFloat(size) - displayHeight) / 2 - 60
let radius: CGFloat = 36

let bezel = CGRect(x: originX, y: originY, width: displayWidth, height: displayHeight)

context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.addPath(
    CGPath(roundedRect: bezel, cornerWidth: radius, cornerHeight: radius, transform: nil)
)
context.fillPath()

// Inset screen keeps the framebuffer distinct from the bezel.
let inset: CGFloat = 28
let screen = bezel.insetBy(dx: inset, dy: inset)
context.setFillColor(CGColor(srgbRed: 10.0 / 255.0, green: 20.0 / 255.0, blue: 60.0 / 255.0, alpha: 1))
context.addPath(
    CGPath(roundedRect: screen, cornerWidth: radius / 2, cornerHeight: radius / 2, transform: nil)
)
context.fillPath()

// Stand plus base anchor the monitor without extra chrome.
let standWidth: CGFloat = 96
let standHeight: CGFloat = 120
let stand = CGRect(
    x: CGFloat(size) / 2 - standWidth / 2,
    y: originY - standHeight + 20,
    width: standWidth,
    height: standHeight
)
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.fill(stand)

let baseWidth: CGFloat = 360
let baseHeight: CGFloat = 32
let base = CGRect(
    x: CGFloat(size) / 2 - baseWidth / 2,
    y: stand.minY - baseHeight,
    width: baseWidth,
    height: baseHeight
)
context.addPath(
    CGPath(roundedRect: base, cornerWidth: baseHeight / 2, cornerHeight: baseHeight / 2, transform: nil)
)
context.fillPath()

let outputURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    .standardized

guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        "public.png" as CFString,
        1,
        nil
    )
else {
    fatalError("Could not create PNG destination at \(outputURL.path)")
}

CGImageDestinationAddImage(destination, image, nil)

guard CGImageDestinationFinalize(destination) else {
    fatalError("Failed writing PNG to \(outputURL.path)")
}

print("Wrote \(outputURL.path)")

let contentsURL = outputURL.deletingLastPathComponent().appendingPathComponent("Contents.json")
let contentsJSON = """
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""

do {
    try contentsJSON.write(to: contentsURL, atomically: true, encoding: .utf8)
    print("Wrote \(contentsURL.path)")
} catch {
    fatalError("Failed writing Contents.json to \(contentsURL.path): \(error)")
}
