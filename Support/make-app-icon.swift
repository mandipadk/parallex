// Renders Parallex's app icon (the parallel mark) into an .icns.
//
//   swift Support/make-app-icon.swift Sources/ParallexApp/Resources/AppIcon.icns
//
// Drawn on Apple's macOS icon grid — an 824 pt squircle with continuous
// corners centered on a 1024 pt canvas — so macOS 26 shows it as-is rather
// than on a grey backing plate. Flat colors only.

import AppKit
import SwiftUI

struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Color(red: 0.118, green: 0.122, blue: 0.133)) // graphite #1E1F22
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
            // The original: a quiet outline, up and to the left.
            RoundedRectangle(cornerRadius: 104, style: .continuous)
                .strokeBorder(Color(red: 0.40, green: 0.41, blue: 0.45), lineWidth: 30)
                .frame(width: 392, height: 392)
                .offset(x: -80, y: -80)
            // The copy: vermilion, in front.
            RoundedRectangle(cornerRadius: 104, style: .continuous)
                .fill(Color(red: 0.95, green: 0.36, blue: 0.17)) // #F25C2B
                .frame(width: 392, height: 392)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
                .offset(x: 80, y: 80)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render(to output: URL) throws {
    let renderer = ImageRenderer(content: AppIconArt())
    renderer.scale = 1
    guard let master = renderer.cgImage else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed"])
    }
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    let sizes = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                 ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
    for (name, pixels) in sizes {
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
    }
}

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "AppIcon.icns")
try MainActor.assumeIsolated { try render(to: output) }
print("Wrote \(output.path)")
