// VLM media-decode OOM probe — faithful to the provider's real decode path.
//
// decodeImage (provider-swift/Sources/ProviderCore/Inference/VLMRequestInference.swift):
//     let data = try dataFromDataURI(uri)        // base64-decode, no size cap
//     guard let image = CIImage(data: data) ...  // <-- exact call replicated below
//
// MediaProcessing (libs/mlx-swift-lm/Libraries/MLXVLM/MediaProcessing.swift):
//     private let context = CIContext()
//     resampleBicubic(image, to: config.size)    // lazy CIBicubicScaleTransform
//     asMLXArray: Data(count: w*h*4); context.render(image, toBitmap:..., bounds: image.extent)
//
// Modes:
//   decode   — just CIImage(data:) + read .extent (proves laziness; no raster)
//   naive    — render at full extent (a direct CIImage consumer)
//   mlxpath  — resampleBicubic(to: target²) then render at the SMALL extent
//              (the real provider path — decisive: does CoreImage decode the
//               full-res PNG source before downscaling?)
//
// Run under `/usr/bin/time -l` and read "maximum resident set size".

import Foundation
import CoreImage
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: oom_probe <png> <decode|naive|mlxpath> [target=448]\n".utf8))
    exit(2)
}
let path = args[1]
let mode = args[2]
let target = args.count >= 4 ? (Double(args[3]) ?? 448) : 448

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    log("read fail: \(path)"); exit(2)
}
log("input PNG on-wire bytes: \(data.count)")

// FIX-MECHANISM probe: read pixel dimensions from the format header only,
// WITHOUT constructing a CIImage / decoding the raster. This is the guard the
// fix will use to reject a bomb before decodeImage's CIImage(data:) ever runs.
if mode == "header" {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { log("header read failed"); exit(3) }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? -1
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? -1
    log(String(format: "HEADER dims (no CIImage decode): %d x %d  (%.1f Mpx)",
               w, h, Double(w) * Double(h) / 1e6))
    log("done"); exit(0)
}

// EXACT decode call from decodeImage:
guard let ci = CIImage(data: data) else {
    log("CIImage(data:) returned nil (decode failed/refused)"); exit(3)
}
let ext = ci.extent
log(String(format: "decoded extent: %.0f x %.0f  (%.1f Mpx)",
           ext.width, ext.height, ext.width * ext.height / 1e6))

let context = CIContext()  // mirrors MediaProcessing's shared `private let context = CIContext()`

func renderToData(_ image: CIImage, bounds: CGRect) {
    let w = Int(bounds.width), h = Int(bounds.height)
    let bytesPerRow = w * 4
    var buf = Data(count: w * h * 4)
    buf.withUnsafeMutableBytes { ptr in
        context.render(image, toBitmap: ptr.baseAddress!, rowBytes: bytesPerRow,
                       bounds: bounds, format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    log("rendered \(w)x\(h) -> output Data \(w * h * 4) bytes")
}

switch mode {
case "decode":
    log("decode-only (no raster)")
case "naive":
    renderToData(ci, bounds: ext)                 // full-resolution raster
case "mlxpath":
    // faithful to MediaProcessing.resampleBicubic(_:to:) + asMLXArray render
    let yScale = target / Double(ext.height)
    let xScale = target / Double(ext.width)
    let filter = CIFilter(name: "CIBicubicScaleTransform")!
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(yScale, forKey: "inputScale")
    filter.setValue(xScale / yScale, forKey: "inputAspectRatio")
    guard let scaled = filter.outputImage else { log("scale filter nil"); exit(4) }
    renderToData(scaled, bounds: CGRect(x: 0, y: 0, width: target, height: target))
default:
    log("unknown mode \(mode)"); exit(2)
}
log("done")
