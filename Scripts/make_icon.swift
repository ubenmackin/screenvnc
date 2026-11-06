//
//  make_icon.swift
//  OuterView
//
//  Generates the 1024x1024 app icon into Assets.xcassets/AppIcon.appiconset.
//  Run once: swift Scripts/make_icon.swift
//

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

// Folded-display silhouette: two rounded rects in the outer display's portrait
// proportions (466 x 678 scaled to 384 x 560). The left panel is two thirds of
// the display width; the right panel — the remaining third — is offset further
// right to suggest the hinge opening. Corner radius mirrors the Duo's 59 pt
// display radius.
let displayWidth: CGFloat = 384
let displayHeight: CGFloat = 560
let originX = (CGFloat(size) - displayWidth) / 2
let originY = (CGFloat(size) - displayHeight) / 2
let seam: CGFloat = 18
let rightOffset: CGFloat = 46
let radius: CGFloat = 59

let leftWidth = ((displayWidth - seam) * 2 / 3).rounded()
let rightWidth = displayWidth - seam - leftWidth

let panels = [
    CGRect(x: originX, y: originY, width: leftWidth, height: displayHeight),
    CGRect(
        x: originX + leftWidth + seam + rightOffset,
        y: originY,
        width: rightWidth,
        height: displayHeight
    )
]

context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
for rect in panels {
    context.addPath(
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    )
    context.fillPath()
}

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
