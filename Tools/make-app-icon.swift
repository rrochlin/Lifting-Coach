#!/usr/bin/env swift
//
// Renders the app icon from the same palette Theme.swift uses, so the icon on
// the home screen and the app behind it can't drift apart. Run it after
// changing a ground or signal colour:
//
//     swift Tools/make-app-icon.swift
//
// Writes a 1024×1024 opaque PNG — App Store Connect rejects an icon with an
// alpha channel, and iOS applies its own corner mask, so this draws neither.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

// Theme.void / Theme.panelRaised / Theme.signal, kept in step by hand.
let void = CGColor(red: 0.039, green: 0.051, blue: 0.067, alpha: 1)
let panelRaised = CGColor(red: 0.094, green: 0.125, blue: 0.169, alpha: 1)
let signal = CGColor(red: 0.275, green: 0.835, blue: 0.878, alpha: 1)

let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    // noneSkipLast: opaque, no alpha channel to strip afterwards.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create the bitmap context") }

// Ground: lit at the top, falling away — the same "panels above a void" reading
// the app's screens have.
let gradient = CGGradient(
    colorsSpace: space,
    colors: [panelRaised, void] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

/// A horizontal bar, rounded, centred vertically.
func plate(x: Double, width: Double, height: Double, radius: Double) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: x, y: (size - height) / 2, width: width, height: height),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

context.setFillColor(signal)

// The bar itself, then two plates a side. A loaded barbell is the one shape
// that reads as this app at 40 points.
for path in [
    plate(x: 120, width: 784, height: 38, radius: 19),      // bar
    plate(x: 190, width: 62, height: 214, radius: 18),       // outer plate, left
    plate(x: 772, width: 62, height: 214, radius: 18),       // outer plate, right
    plate(x: 278, width: 78, height: 330, radius: 22),       // inner plate, left
    plate(x: 668, width: 78, height: 330, radius: 22),       // inner plate, right
] {
    context.addPath(path)
    context.fillPath()
}

let output = URL(fileURLWithPath: "Sources/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not encode the icon") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
print("wrote \(output.path)")
