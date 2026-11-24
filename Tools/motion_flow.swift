// Bake bidirectional flow once, in desktop points, for the Metal renderer.
// Run from the repository root: swift Tools/motion_flow.swift /path/to/packed/Bed.png
import AppKit
import Vision
import simd
import ImageIO
import UniformTypeIdentifiers

struct Clip: Decodable { let atlas: String; let scale: Double; let frames: [[Double]] }
let folder = URL(fileURLWithPath: "Assets/Photo/Motion")
let clips = try JSONDecoder().decode([String: Clip].self, from: Data(contentsOf: folder.appendingPathComponent("Atlas.json")))
let width = 216, height = 200, tileW = 108, tileH = 100
let columns = 8
var tile = 0
var pixels: [UInt8] = []
var index: [String: Int] = [:]

func aligned(_ atlas: CGImage, _ f: [Double], _ scale: Double, mirror: Bool = false, transparent: Bool = false) -> CGImage {
    let crop = atlas.cropping(to: CGRect(x: f[0], y: f[1], width: f[2]-f[0], height: f[3]-f[1]))!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if !transparent {
        ctx.setFillColor(gray: 0.49, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    if mirror {
        ctx.translateBy(x: CGFloat(width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
    }
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
// Vision can follow the adjacent ankle instead of the planted toe when the
// front legs overlap. Pin measured toe centres in the four approach photos.
let approachToes: [[SIMD2<Float>]] = [
    [[8.5, 0], [34, -7], [-46, -16], [-14, -21]],
    [[8.5, 0], [32, -3], [-45, -9], [-15, -16]],
    [[8.5, 0], [25, -5], [-53, -7], [-31, -13]],
    [[8.5, 0], [21, -6], [-76, -4], [-50, -9]]
]
func pinToes(_ start: Int, _ end: Int, channel: Int) {
    let offset = (tile/columns * tileH * columns * tileW + tile%columns * tileW) * 4 + channel
    func byte(_ x: Int, _ y: Int) -> Int { offset + (y*columns*tileW + x)*4 }
    let corrections = zip(approachToes[start], approachToes[end]).map { a,b in
        let x = Int(((a.x + 108) * 0.5 - 0.5).rounded())
        let y = Int(((a.y + 172) * 0.5 - 0.5).rounded())
        let p = byte(x,y)
        let measured = (SIMD2(Float(pixels[p]), Float(pixels[p+1])) - 128) * 0.5
        return (at: a, delta: b-a-measured)
    }
    for y in 0..<tileH {
        for x in 0..<tileW {
            let pos = SIMD2<Float>(Float(2*x+1)-108, Float(2*y+1)-172)
            var delta = SIMD2<Float>.zero
            for c in corrections {
                let influence = max(0, 1 - simd_distance_squared(pos, c.at) / 144)
                delta += c.delta * influence * influence
            }
            let p = byte(x,y)
            for axis in 0..<2 {
                pixels[p+axis] = UInt8(clamping: Int(pixels[p+axis]) + Int((2*delta[axis]).rounded()))
            }
        }
    }
}

func bakePair(_ key: String, _ from: CGImage, _ to: CGImage, approach: Int? = nil) throws {
    if tile % columns == 0 {
        pixels += [UInt8](repeating: 128, count: columns * tileW * tileH * 4)
    }
    try autoreleasepool {
        try writeFlow(from: from, to: to, channel: 0)
        try writeFlow(from: to, to: from, channel: 2)
    }
    if let start = approach {
        pinToes(start, start+1, channel: 0)
        pinToes(start+1, start, channel: 2)
    }
    index[key] = tile
    tile += 1
}

for name in clips.keys.sorted() where ["bed","urinate","defecate"].contains(name) {
    let clip = clips[name]!
    let url = name == "bed" ? URL(fileURLWithPath: CommandLine.arguments[1]) : folder.appendingPathComponent(clip.atlas + ".png")
    let atlas = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
    let photos = clip.frames.map { aligned(atlas, $0, clip.scale) }
    let edges: [(Int,Int)]
    if name == "bed" {
        edges = [(0,1),(0,2),(2,3),(0,4),(4,5),(5,6),(6,7),(7,8),(7,9),(7,10),(10,11),(0,12),(12,13),(0,14),(14,15)]
    } else {
        edges = (1..<(photos.count-1)).map { ($0,$0+1) }
    }
    for (a,b) in edges {
        let approach = (name == "urinate" || name == "defecate") && a < 3 ? a : nil
        try bakePair("\(name)/\(a)/\(b)", photos[a], photos[b], approach: approach)
    }
}

// Turn views are compared after projection onto the same screen-space floor,
// including reflection. RG and BA therefore remain screen-space vectors.
let pivotIndices = [4,5,6,7,8,7,6,5,4,3,2,1,0,1,2,3]
let directions = pivotIndices.enumerated().map { (i, index) in
    (name: "pivot", frame: index, mirror: (5...11).contains(i))
}
func pivotPose(_ name: String, _ frame: Int, _ mirror: Bool, transparent: Bool = false) -> CGImage {
    let clip = clips[name]!
    let url = folder.appendingPathComponent(clip.atlas + ".png")
    let atlas = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    return aligned(atlas, clip.frames[frame], clip.scale, mirror: mirror, transparent: transparent)
}
// Vision can match similar curls on different sides of a silhouette. Constrain
// the upper-body flow by the span of opaque fur at each corresponding height.
// The contour remains connected while the interior retains its measured flow.
struct Silhouette {
    let alpha: [Bool]
    let rows: [SIMD2<Float>]
    let top: Int
    let bottom: Int

    init(_ image: CGImage) {
        let data = image.dataProvider!.data! as Data
        alpha = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to:UInt8.self)
            return (0..<width*height).map { bytes[($0/width)*image.bytesPerRow + ($0%width)*4+3] > 116 }
        }
        var spans = Array(repeating:SIMD2<Float>.zero,count:height)
        var first = height-1, last = 0
        for y in 0..<height {
            var left = width, right = -1
            for x in 0..<width where alpha[y*width+x] { left=min(x,left); right=max(x,right) }
            if right > left {
                spans[y] = SIMD2(Float(left),Float(right))
                first=min(first,y); last=max(last,y)
            }
        }
        top = first; bottom = last
        rows = (0..<height).map { y in
            var total = SIMD2<Float>.zero
            for r in -2...2 { total += spans[min(last,max(first,y+r))]*Float(3-abs(r)) }
            return total/9
        }
    }
}

func constrainTurn(_ source: Silhouette, _ target: Silhouette, tile t: Int, channel: Int) {
    func offset(_ x: Int,_ y: Int) -> Int {
        (((t/columns)*tileH+y)*columns*tileW+(t%columns)*tileW+x)*4+channel
    }
    func smooth(_ edge: Float) -> Float {
        let v=min(1,max(0,edge))
        return v*v*(3-2*v)
    }
    var draft = Array(repeating:SIMD2<Float>.zero,count:tileW*tileH)
    for y in 0..<tileH {
        let sy=Float(2*y+1)
        let by=Float(target.top)+(sy-Float(source.top))*Float(target.bottom-target.top)/Float(source.bottom-source.top)
        let a=source.rows[Int(sy)], b=target.rows[max(0,min(height-1,Int(by.rounded())))]
        let ratio=min(2.1,max(0.47,(b.y-b.x)/max(1,a.y-a.x)))
        let amount=smooth((144-sy)/25)
        for x in 0..<tileW {
            let sx=Float(2*x+1), pos=offset(x,y)
            let vision=(SIMD2(Float(pixels[pos]),Float(pixels[pos+1]))-128)*0.5
            let bx=(b.x+b.y)/2+(sx-(a.x+a.y)/2)*ratio
            let contour=SIMD2(bx-sx,by-sy)
            let error=vision-contour
            // Different-height ears and tails can share a scanline. A contour
            // match may refine the measured flow by at most five points.
            let directed=vision-error/max(1,simd_length(error)/5)
            draft[y*tileW+x]=vision+(directed-vision)*amount
        }
    }
    for y in 0..<tileH {
        for x in 0..<tileW {
            var total=SIMD2<Float>.zero
            for j in -2...2 {
                for i in -2...2 {
                    let idx=min(tileH-1,max(0,y+j))*tileW+min(tileW-1,max(0,x+i))
                    total += draft[idx]*Float((3-abs(i))*(3-abs(j)))
                }
            }
            let p=offset(x,y), v=total/81
            pixels[p]=UInt8(clamping:128+Int((v.x*2).rounded()))
            pixels[p+1]=UInt8(clamping:128+Int((v.y*2).rounded()))
        }
    }
}
let silhouettes = directions
let outlines = silhouettes.map { Silhouette(pivotPose($0.name,$0.frame,$0.mirror,transparent:true)) }
let pivots = directions.map { pivotPose($0.name, $0.frame, $0.mirror) }
for i in pivots.indices {
    let next = (i + 1) % pivots.count
    try bakePair("pivot/\(i)/\(next)", pivots[i], pivots[next])
    constrainTurn(outlines[i],outlines[next],tile:tile-1,channel:0)
    constrainTurn(outlines[next],outlines[i],tile:tile-1,channel:2)
}
for i in [10, 14] {
    let next = pivotPose("urinate", 1, directions[i].mirror)
    try bakePair("pivot/\(i)/break", pivots[i], next)
}
// A distance field blends the two outlines geometrically in a turn. Mixing
// alpha values directly leaves a transparent second dog wherever views differ.
for (i,outline) in outlines.enumerated() {
    let channel = i%4
    if channel == 0 {
        if tile%columns == 0 { pixels += Array(repeating:128,count:columns*tileW*tileH*4) }
        index["pivot/outline/\(i/4)"] = tile
    }
    let solid = outline.alpha
    // Two sweeps compute the octile distance to a one-pixel silhouette border.
    var d = Array(repeating:Float(64),count:width*height)
    for y in 1..<height-1 {
        for x in 1..<width-1 {
            let k=y*width+x
            if [k-1,k+1,k-width,k+width].contains(where:{solid[$0] != solid[k]}) { d[k]=0.5 }
        }
    }
    for k in d.indices where k%width>0 && k%width<width-1 && k>=width {
        d[k]=min(d[k],d[k-1]+1,d[k-width]+1,d[k-width-1]+1.414,d[k-width+1]+1.414)
    }
    for k in d.indices.reversed() where k%width>0 && k%width<width-1 && k<d.count-width {
        d[k]=min(d[k],d[k+1]+1,d[k+width]+1,d[k+width-1]+1.414,d[k+width+1]+1.414)
    }
    for y in 0..<tileH {
        for x in 0..<tileW {
            let a = 2*y*width+2*x
            let value = [a,a+1,a+width,a+width+1].reduce(Float(0)) { $0+(solid[$1] ? d[$1] : -d[$1]) }
            let offset = (((tile/columns)*tileH+y)*columns*tileW+(tile%columns)*tileW+x)*4+channel
            pixels[offset] = UInt8(clamping:128+Int(value.rounded()))
        }
    }
    if channel == 3 || i == silhouettes.count-1 { tile += 1 }
}
let rows = (tile+columns-1)/columns
let size = columns*tileW*rows*tileH*4
try Data(pixels.prefix(size)).write(to: folder.appendingPathComponent("Flow.rgba"))
try JSONEncoder().encode(index).write(to: folder.appendingPathComponent("Flow.json"))
print("Baked", tile, "motion and outline tiles")
