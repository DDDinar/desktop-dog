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
    private let atlases: [String: PhotoTexture]
    private var animation: PhotoAppearance
    private var current: PhotoFrame?

    static func make(frame: CGRect, assets: URL) -> PhotoSurface? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let appearance = PhotoAppearance(assets: assets) else { return nil }
        var atlases: [String: PhotoTexture] = [:]
        let motionAtlases = appearance.motionAtlases
        for name in motionAtlases.union(["Portraits", "Rest"]) {
            let folder = motionAtlases.contains(name) ? assets.appendingPathComponent("Motion") : assets
            guard let texture = PhotoTexture(device: device, queue: queue,
                    url: folder.appendingPathComponent(name).appendingPathExtension("png")) else { return nil }
            atlases[name] = texture
        }
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "photo_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "photo_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return PhotoSurface(frame: frame, device: device, queue: queue,
                                pipeline: pipeline, atlases: atlases, appearance: appearance)
        } catch {
            NSLog("Could not initialize dog rendering: %@", error.localizedDescription)
            return nil
        }
    }

    private init(frame: CGRect, device: MTLDevice, queue: MTLCommandQueue,
                 pipeline: MTLRenderPipelineState, atlases: [String: PhotoTexture],
                 appearance: PhotoAppearance) {
        self.queue = queue
        self.pipeline = pipeline
        self.atlases = atlases
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
        display(animation.frame(for: dog, dt: dt, windowScale: scale))
    }

    func updateBed(_ index: Int) {
        display(animation.bedFrame(index))
    }

    private func display(_ next: PhotoFrame) {
        if next != current {
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
        let b = frame.bounds
        let half = SIMD2(Float(DogWindow.size.width / 2), Float(DogWindow.size.height / 2))
        let floor = Float(DogWindow.groundMargin) - half.y + frame.lift
        let corners = [SIMD2(b.x, b.y), SIMD2(b.z, b.y), SIMD2(b.x, b.w), SIMD2(b.z, b.w)]
        let vertices = corners.map { source -> SIMD4<Float> in
            let uv = source / atlas.size
            let local = (source - frame.pivot) * frame.scale
            return SIMD4(local.x * frame.mirror / half.x, (floor - local.y) / half.y, uv.x, uv.y)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(atlas.texture, index: 0)
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
    fragment float4 photo_fragment(PhotoPixel p [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler linear(coord::normalized, address::clamp_to_edge,
                                 filter::linear, mip_filter::linear);
        return atlas.sample(linear, p.uv);
    }
    """
}
