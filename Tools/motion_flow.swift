// Bake bidirectional flow once, in desktop points, for the Metal renderer.
// Run from the repository root: swift Tools/motion_flow.swift /path/to/packed/Bed.png
import AppKit
import Vision
import ImageIO
import UniformTypeIdentifiers

struct Clip: Decodable { let atlas: String; let scale: Double; let frames: [[Double]] }
let folder = URL(fileURLWithPath: "Assets/Photo/Motion")
let clips = try JSONDecoder().decode([String: Clip].self, from: Data(contentsOf: folder.appendingPathComponent("Atlas.json")))
let width = 216, height = 200, tileW = 108, tileH = 100
let columns = 8
var tile = 0
var pixels = [UInt8](repeating: 128, count: columns * tileW * 12 * tileH * 4)
var index: [String: Int] = [:]

func aligned(_ atlas: CGImage, _ f: [Double], _ scale: Double) -> CGImage {
    let crop = atlas.cropping(to: CGRect(x: f[0], y: f[1], width: f[2]-f[0], height: f[3]-f[1]))!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray: 0.49, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(crop, in: CGRect(x: 108+(f[0]-f[4])*scale, y: 28-(f[3]-f[5])*scale,
                             width: (f[2]-f[0])*scale, height: (f[3]-f[1])*scale))
    return ctx.makeImage()!
}

func writeFlow(from source: CGImage, to target: CGImage, channel: Int) throws {
    let request = VNGenerateOpticalFlowRequest(targetedCGImage: target)
    request.computationAccuracy = .veryHigh
    request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
    try VNImageRequestHandler(cgImage: source).perform([request])
    let buf = request.results![0].pixelBuffer
    precondition(CVPixelBufferGetWidth(buf) == width && CVPixelBufferGetHeight(buf) == height)
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let data = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: Float.self)
    let stride = CVPixelBufferGetBytesPerRow(buf) / MemoryLayout<Float>.stride
    for y in 0..<tileH {
        for x in 0..<tileW {
            let p = y*2*stride + x*4
            let dst = (((tile / columns)*tileH+y)*columns*tileW + (tile % columns)*tileW+x)*4 + channel
            for axis in 0..<2 {
                let i = p+axis
                let v = (data[i]+data[i+2]+data[i+stride]+data[i+stride+2])/4
                pixels[dst+axis] = UInt8(clamping: Int((v*2).rounded()) + 128)
            }
        }
    }
}
for name in clips.keys.sorted() {
    let clip = clips[name]!
    let url = name == "bed" ? URL(fileURLWithPath: CommandLine.arguments[1]) : folder.appendingPathComponent(clip.atlas + ".png")
    let atlas = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
    let photos = clip.frames.map { aligned(atlas, $0, clip.scale) }
    let edges: [(Int,Int)]
    if name == "bed" {
        edges = [(0,1),(0,2),(2,3),(0,4),(4,5),(5,6),(6,7),(7,8),(7,9),(7,10),(10,11),(0,12),(12,13),(0,14),(14,15)]
    } else {
        let count = name == "jump" || name == "wag" ? 7 : 8
        edges = (0..<count).map { ($0, ($0+1)%8) }
    }
    for (a,b) in edges {
        try autoreleasepool {
            try writeFlow(from: photos[a], to: photos[b], channel: 0)
            try writeFlow(from: photos[b], to: photos[a], channel: 2)
        }
        index["\(name)/\(a)/\(b)"] = tile
        tile += 1
    }
}
let rows = (tile+columns-1)/columns
let size = columns*tileW*rows*tileH*4
try Data(pixels.prefix(size)).write(to: folder.appendingPathComponent("Flow.rgba"))
try JSONEncoder().encode(index).write(to: folder.appendingPathComponent("Flow.json"))
print("Baked", tile, "motion pairs")
