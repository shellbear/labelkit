#!/usr/bin/env swift
// make-sample-dataset.swift <count> <out-dir> [--bases N]
//
// Generates a realistic labelkit test dataset for profiling and scale testing,
// with no network and no dependencies beyond system frameworks.
//
//   swift scripts/make-sample-dataset.swift 10000 /tmp/labelkit-sample
//   swift scripts/make-sample-dataset.swift 10000 /tmp/labelkit-sample --bases 32
//   labelkit /tmp/labelkit-sample
//
// How it works: it draws a small set of DISTINCT base JPEGs at camera
// resolutions (gradient + dense random-rect texture so they compress to a
// realistic ~1-3 MB, i.e. real decode cost) into a hidden `.bases/` subdir,
// then creates `count` symlinks (img-000000.jpg ...) cycling over them. Each
// symlink is a unique filename -> a unique URL -> a real cache-miss decode in
// the app, so navigation cost is representative — but disk stays tiny (one
// physical file per base). A few larger colored rectangles per base double as
// ground-truth annotation targets, written to annotations.json.
import CoreGraphics
import Foundation
import ImageIO

// Deterministic RNG so the same args reproduce the same dataset (handy for
// before/after profiling). Seeded per-base.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Args
let argv = CommandLine.arguments
guard argv.count >= 3, let count = Int(argv[1]), count > 0 else {
    FileHandle.standardError.write(Data(
        "usage: make-sample-dataset.swift <count> <out-dir> [--bases N]\n".utf8))
    exit(2)
}
let outDir = (argv[2] as NSString).expandingTildeInPath
var baseCount = 24
if let i = argv.firstIndex(of: "--bases"), i + 1 < argv.count, let n = Int(argv[i + 1]), n > 0 {
    baseCount = min(n, count)
}
let labels = ["person", "car", "dog", "sign", "tree", "bike"]
let resolutions = [(4000, 3000), (3000, 4000), (4032, 3024), (3024, 4032), (3840, 2160), (4608, 3456)]

let fm = FileManager.default
let basesDir = (outDir as NSString).appendingPathComponent(".bases")
try? fm.createDirectory(atPath: basesDir, withIntermediateDirectories: true)

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

// MARK: - Base image generation
// Returns the annotation boxes (Create ML: center x/y + w/h, top-left origin).
func makeBase(index: Int) -> [[String: Any]] {
    var rng = SplitMix64(seed: UInt64(index) &* 0x1234_5 &+ 1)
    let (w, h) = resolutions[index % resolutions.count]
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }

    func rand01() -> Double { Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    func setFill(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
    }

    // Gradient wash.
    let colors = [CGColor(red: rand01(), green: rand01(), blue: rand01(), alpha: 1),
                  CGColor(red: rand01(), green: rand01(), blue: rand01(), alpha: 1)] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
    }

    // Dense fine texture — this is what gives the JPEG realistic size (and real
    // decode cost). Native CG fills, so it stays fast even in script mode.
    let texRects = 55_000
    for _ in 0..<texRects {
        setFill(rand01(), rand01(), rand01(), 0.5)
        let s = 2 + Int(rand01() * 6)
        ctx.fill(CGRect(x: Int(rand01() * Double(w)), y: Int(rand01() * Double(h)),
                        width: s, height: s))
    }

    // A few big rectangles = annotation targets. Record them top-left-origin.
    var boxes: [[String: Any]] = []
    let n = 1 + Int(rand01() * 6)
    let dw = Double(w), dh = Double(h)
    for _ in 0..<n {
        let bw = (0.08 + rand01() * 0.30) * dw
        let bh = (0.08 + rand01() * 0.30) * dh
        let cx = (0.02 * dw + bw / 2) + rand01() * (0.96 * dw - bw)
        let cy = (0.02 * dh + bh / 2) + rand01() * (0.96 * dh - bh)
        setFill(rand01(), rand01(), rand01(), 1)
        // CG origin is bottom-left; flip y so the drawn box matches the
        // top-left-origin annotation coordinates.
        ctx.fill(CGRect(x: cx - bw / 2, y: dh - cy - bh / 2, width: bw, height: bh))
        boxes.append([
            "label": labels[Int(rand01() * Double(labels.count))],
            "coordinates": ["x": round2(cx), "y": round2(cy),
                            "width": round2(bw), "height": round2(bh)],
        ])
    }

    guard let image = ctx.makeImage() else { return boxes }
    let url = URL(fileURLWithPath: (basesDir as NSString)
        .appendingPathComponent(String(format: "base-%03d.jpg", index)))
    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
    return boxes
}

// MARK: - Generate bases
print("generating \(baseCount) base images...")
var baseBoxes: [[[String: Any]]] = []
for b in 0..<baseCount {
    baseBoxes.append(makeBase(index: b))
    if (b + 1) % 8 == 0 { print("  \(b + 1)/\(baseCount)") }
}

// MARK: - Fan out to `count` symlinks + annotations.json
print("linking \(count) images + writing annotations.json...")
var entries: [[String: Any]] = []
entries.reserveCapacity(count)
for i in 0..<count {
    let base = i % baseCount
    let name = String(format: "img-%06d.jpg", i)
    let link = (outDir as NSString).appendingPathComponent(name)
    try? fm.removeItem(atPath: link)
    try? fm.createSymbolicLink(atPath: link,
                               withDestinationPath: ".bases/" + String(format: "base-%03d.jpg", base))
    entries.append(["image": name, "annotations": baseBoxes[base]])
}
let json = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
try json.write(to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent("annotations.json")))

let totalBoxes = entries.reduce(0) { $0 + (($1["annotations"] as? [Any])?.count ?? 0) }
print("done: \(count) images (\(baseCount) distinct) + \(totalBoxes) boxes -> \(outDir)")
print("open with:  labelkit \(outDir)")
