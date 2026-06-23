// Retint the app icon so the fork is visually distinct in Finder/Launchpad.
// Usage: swift tint_icon.swift <input.png> <output.png> [hueRadians]
import Foundation
import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: tint_icon.swift <in.png> <out.png> [hueRadians]\n".data(using: .utf8)!)
    exit(1)
}
let inPath = args[1], outPath = args[2]
let hue = args.count >= 4 ? (Double(args[3]) ?? Double.pi) : Double.pi   // default ~180° shift (orange→blue)

guard let img = CIImage(contentsOf: URL(fileURLWithPath: inPath)) else {
    FileHandle.standardError.write("cannot load \(inPath)\n".data(using: .utf8)!); exit(1)
}

let hueFilter = CIFilter(name: "CIHueAdjust")!
hueFilter.setValue(img, forKey: kCIInputImageKey)
hueFilter.setValue(hue, forKey: kCIInputAngleKey)
var out = hueFilter.outputImage!

// Small saturation/brightness nudge so the tint reads as deliberate, not muddy.
if let vib = CIFilter(name: "CIVibrance") {
    vib.setValue(out, forKey: kCIInputImageKey)
    vib.setValue(0.25, forKey: "inputAmount")
    out = vib.outputImage ?? out
}

let ctx = CIContext()
guard let cg = ctx.createCGImage(out, from: out.extent) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!); exit(1)
}
let rep = NSBitmapImageRep(cgImage: cg)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("✅ wrote \(outPath)")
