import AppKit
import ImageIO
import MetalKit
import simd

private struct PhotoTexture {
    let texture: MTLTexture
    let size: SIMD2<Float>

    init?(device: MTLDevice, queue: MTLCommandQueue, url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height, stride = image.width * 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: true)
        guard let texture = device.makeTexture(descriptor: descriptor),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let loaded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let data = bytes.baseAddress,
                  let context = CGContext(data: data, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: stride, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt32.self)
            for i in rgba.indices where rgba[i] >> 24 <= 10 { rgba[i] = 0 }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: data, bytesPerRow: stride)
            return true
        }
        guard loaded, let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        command.commit()
        self.texture = texture
        self.size = SIMD2(Float(width), Float(height))
    }
}

/// One rigid photograph per draw. Heading changes and the chase never clear
/// the old drawable until a complete replacement has been encoded.
final class PhotoSurface: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let atlasURLs: [String: URL]
    private var atlases: [String: PhotoTexture] = [:]
    private let turnPipeline: MTLRenderPipelineState
    private var currentTurn: PhotoAppearance.Turn?
    private let flow: MTLTexture
    private var animation: PhotoAppearance
    private var current: PhotoFrame?

    static func make(frame: CGRect, assets: URL) -> PhotoSurface? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let appearance = PhotoAppearance(assets: assets) else { return nil }
        let motionAtlases = appearance.motionAtlases
        let atlasURLs = Dictionary(uniqueKeysWithValues: motionAtlases.union(["Portraits", "Rest"]).map { name in
            let folder = motionAtlases.contains(name) ? assets.appendingPathComponent("Motion") : assets
            return (name, folder.appendingPathComponent(name).appendingPathExtension("png"))
        })
        guard let flow = loadFlow(assets.appendingPathComponent("Motion/Flow.rgba"), device: device) else { return nil }
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "photo_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "photo_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "turn_fragment")
            let turns = try device.makeRenderPipelineState(descriptor: descriptor)
            return PhotoSurface(frame: frame, device: device, queue: queue,
                                pipeline: pipeline, atlasURLs: atlasURLs, appearance: appearance, flow: flow,
                                turns: turns)
        } catch {
            NSLog("Could not initialize dog rendering: %@", error.localizedDescription)
            return nil
        }
    }

    private static func loadFlow(_ url: URL, device: MTLDevice, width: Int = 864, blockHeight: Int = 100) -> MTLTexture? {
        let rowBytes = width * 4
        guard let bytes = try? Data(contentsOf: url),
              !bytes.isEmpty, bytes.count % (rowBytes * blockHeight) == 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: bytes.count / rowBytes, mipmapped: false)
        guard let flow = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { raw in
            flow.replace(region: MTLRegionMake2D(0, 0, flow.width, flow.height), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: rowBytes)
        }
        return flow
    }

    private init(frame: CGRect, device: MTLDevice, queue: MTLCommandQueue,
                 pipeline: MTLRenderPipelineState, atlasURLs: [String: URL],
                 appearance: PhotoAppearance, flow: MTLTexture, turns: MTLRenderPipelineState) {
        self.turnPipeline = turns
        self.flow = flow
        self.queue = queue
        self.pipeline = pipeline
        self.atlasURLs = atlasURLs
        animation = appearance
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("PhotoSurface is created from its asset bundle") }
    override var isOpaque: Bool { false }

    func update(_ dog: Dog, dt: TimeInterval, scale: CGFloat) {
        let frame = animation.frame(for: dog, dt: dt, windowScale: scale)
        display(frame, turn: animation.turn)
    }

    func updateBed(_ sample: BedLife.Sample) {
        display(animation.bedFrame(sample))
    }

    func prepareRoaming() {
        // Keep the walking textures out of memory at a normal launch, and
        // load them before the first walk so the animation doesn't stall.
        let bedAtlas = animation.bedFrame(.init(from: 0, to: 0, phase: 4)).atlas
        for name in atlasURLs.keys where name != bedAtlas {
            _ = loadAtlas(name)
        }
    }

    @discardableResult
    private func loadAtlas(_ name: String) -> Bool {
        if atlases[name] != nil { return true }
        guard let device, let url = atlasURLs[name],
              let texture = PhotoTexture(device: device, queue: queue, url: url) else { return false }
        atlases[name] = texture
        return true
    }

    private func display(_ next: PhotoFrame, turn: PhotoAppearance.Turn? = nil) {
        if next != current || turn != currentTurn {
            guard loadAtlas(next.atlas) else { return }
            if let turn, !loadAtlas(turn.target.atlas) { return }
            currentTurn = turn
            current = next
            needsDisplay = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if current != nil { needsDisplay = true }
    }

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = queue.makeCommandBuffer(), encode(pass, into: command) else { return }
        command.present(drawable)
        command.commit()
    }

    @discardableResult
    func encode(_ pass: MTLRenderPassDescriptor, into command: MTLCommandBuffer) -> Bool {
        guard let frame = current, let atlas = atlases[frame.atlas],
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        func bounds(_ pose: PhotoFrame, interpolated: Bool = false) -> SIMD4<Float> {
            func rect(_ pixels: SIMD4<Float>, _ pivot: SIMD2<Float>) -> SIMD4<Float> {
                let r = (pixels - SIMD4(pivot.x,pivot.y,pivot.x,pivot.y)) * pose.scale
                return pose.mirror > 0 ? r : SIMD4(-r.z,r.y,-r.x,r.w)
            }
            var r = rect(pose.bounds,pose.pivot)
            if pose.fraction > 0 {
                let other = rect(pose.targetBounds, pose.targetPivot)
                r = interpolated ? r + (other-r)*pose.fraction : union(r,other)
            }
            return r
        }
        func union(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4(min(a.x,b.x),min(a.y,b.y),max(a.z,b.z),max(a.w,b.w))
        }
        func parameters(_ pose: PhotoFrame) -> [SIMD4<Float>] {
            [SIMD4(pose.pivot.x, pose.pivot.y, pose.targetPivot.x, pose.targetPivot.y),
             SIMD4(pose.scale,pose.fraction,Float(pose.tile),pose.reversed ? 1 : 0),
             pose.bounds,pose.targetBounds]
        }
        var b = bounds(frame)
        var uniforms = parameters(frame)
        if let turn = currentTurn, let second = atlases[turn.target.atlas] {
            let firstBounds = bounds(frame, interpolated: true)
            let secondBounds = bounds(turn.target, interpolated: true)
            b = union(b, bounds(turn.target))
            uniforms += parameters(turn.target)
            uniforms += [SIMD4(0,0,0,turn.amount),
                         SIMD4(frame.mirror,turn.target.mirror,0,0), firstBounds, secondBounds,
                         SIMD4(frame.nose.x*frame.mirror,frame.nose.y,turn.target.nose.x*turn.target.mirror,turn.target.nose.y)]
            encoder.setRenderPipelineState(turnPipeline)
            encoder.setFragmentTexture(second.texture,index:2)
        } else {
            encoder.setRenderPipelineState(pipeline)
        }
        let half = SIMD2(Float(DogWindow.size.width / 2), Float(DogWindow.size.height / 2))
        let floor = Float(DogWindow.groundMargin) - half.y + frame.lift
        let corners = [SIMD2(b.x-2,b.y-2), SIMD2(b.z+2,b.y-2), SIMD2(b.x-2,b.w+2), SIMD2(b.z+2,b.w+2)]
        let samplingMirror = currentTurn != nil ? Float(1) : frame.mirror
        let vertices = corners.map { p in
            SIMD4(p.x/half.x, (floor-p.y)/half.y, p.x*samplingMirror, p.y)
        }
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentTexture(flow, index: 1)
        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        vertices.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct PhotoPixel { float4 position [[position]]; float2 uv; };
    vertex PhotoPixel photo_vertex(uint id [[vertex_id]], constant float4 *corners [[buffer(0)]]) {
        float4 corner = corners[id];
        return {float4(corner.xy, 0, 1), corner.zw};
    }
    // Optical flow is measured on registered poses at one pixel per desktop point.
    float2 displacement(texture2d<float> flow, float2 local, int tile, bool reverse) {
        constexpr sampler linear(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 cell = clamp((local + float2(108,172))*0.5, float2(0.5), float2(107.5,99.5));
        float4 field = flow.sample(linear, float2((tile%8)*108,(tile/8)*100) + cell);
        return ((reverse ? field.zw : field.xy)*255.0 - 128.0)*0.5;
    }
    float4 photo(texture2d<float> atlas, float2 pixel, float4 bounds, float lod) {
        constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        if (any(pixel < bounds.xy) || any(pixel >= bounds.zw)) return 0;
        return atlas.sample(linear, pixel/float2(atlas.get_width(),atlas.get_height()), level(lod));
    }
    float4 gait(float2 pos, float pixelWidth, texture2d<float> atlas,
                texture2d<float> flow, constant float4 *u) {
        float scale = u[1].x, t = u[1].y;
        float lod = log2(pixelWidth/scale);
        if (t == 0) return photo(atlas,pos/scale+u[0].xy,u[2],lod);
        int tile = int(u[1].z);
        bool reverse = u[1].w > 0;
        float2 a = pos, b = pos;
        for (int i=0; i<3; ++i) {
            a = pos - t*displacement(flow,a,tile,reverse);
            b = pos - (1-t)*displacement(flow,b,tile,!reverse);
        }
        float4 first = photo(atlas,a/scale+u[0].xy,u[2],lod);
        float4 second = photo(atlas,b/scale+u[0].zw,u[3],lod);
        // Prefer the closer exposure where limbs uncover a different background.
        float2 forward = displacement(flow,a,tile,reverse);
        float2 backward = displacement(flow,b,tile,!reverse);
        float errorA = length(forward + displacement(flow,a+forward,tile,!reverse));
        float errorB = length(backward + displacement(flow,b+backward,tile,reverse));
        float weight = mix(t, smoothstep(0.2,0.8,t),abs(first.a-second.a));
        float wa = (1-weight)/(1+t*errorA);
        float wb = weight/(1+(1-t)*errorB);
        return (wa*first+wb*second)/(wa+wb);
    }
    fragment float4 photo_fragment(PhotoPixel p [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                   texture2d<float> flow [[texture(1)]], constant float4 *u [[buffer(0)]]) {
        return gait(p.uv,max(length(dfdx(p.uv)),length(dfdy(p.uv))),atlas,flow,u);
    }
    float mapInterval(float v,float lo,float hi,float a,float b) {
        return a+(v-lo)*(b-a)/max(hi-lo,0.4);
    }
    float remap(float v,float3 mid,float3 dest) {
        return v < mid.y ? mapInterval(v,mid.x,mid.y,dest.x,dest.y)
                         : mapInterval(v,mid.y,mid.z,dest.y,dest.z);
    }
    fragment float4 turn_fragment(PhotoPixel p [[stage_in]], texture2d<float> first [[texture(0)]],
            texture2d<float> stride [[texture(1)]], texture2d<float> second [[texture(2)]],
            constant float4 *u [[buffer(0)]]) {
        float t = u[8].w, width = max(length(dfdx(p.uv)),length(dfdy(p.uv)));
        float4 h=u[10], k=u[11], n=u[12];
        float3 ax=float3(h.x,clamp(n.x,h.x+3,h.z-3),h.z);
        float3 bx=float3(k.x,clamp(n.z,k.x+3,k.z-3),k.z);
        float3 ay=float3(h.y,clamp(n.y,h.y+3,h.w-3),h.w);
        float3 by=float3(k.y,clamp(n.w,k.y+3,k.w-3),k.w);
        float3 mx=mix(ax,bx,t), my=mix(ay,by,t);
        float2 a=float2(remap(p.uv.x,mx,ax),remap(p.uv.y,my,ay));
        float2 b=float2(remap(p.uv.x,mx,bx),remap(p.uv.y,my,by));
        float4 A = gait(a*float2(u[9].x,1),width,first,stride,u);
        float4 B = gait(b*float2(u[9].y,1),width,second,stride,u+4);
        return mix(A,B,smoothstep(0.12,0.88,t));
    }
    """
}
