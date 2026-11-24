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

/// Decode a single upcoming view while the dog is turning toward its destination.
private final class PendingWalkAtlas {
    let name: String
    let completion = DispatchGroup()
    private(set) var texture: PhotoTexture?

    init(name: String, url: URL, device: MTLDevice, queue: MTLCommandQueue) {
        self.name = name
        DispatchQueue.global(qos: .userInitiated).async(group: completion) { [self] in
            texture = autoreleasepool { PhotoTexture(device: device, queue: queue, url: url) }
        }
    }
}

/// One rigid photograph per draw. Heading changes and the chase never clear
/// the old drawable until a complete replacement has been encoded.
final class PhotoSurface: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let atlasURLs: [String: URL]
    private var atlases: [String: PhotoTexture] = [:]
    private var walkOrder: [String] = []
    private var pendingWalk: PendingWalkAtlas?
    private let turnPipeline: MTLRenderPipelineState
    private var currentTurn: PhotoAppearance.Turn?
    private let flow: MTLTexture
    private let startingAppearance: PhotoAppearance
    private var floorOffset = SIMD2<Float>.zero
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
        startingAppearance = appearance
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

    var isSettledStanding: Bool { animation.isSettledStanding }

    func resumeRoaming() {
        animation = startingAppearance
    }

    func update(_ dog: Dog, dt: TimeInterval, scale: CGFloat, offset: CGPoint = .zero) {
        let nextOffset = SIMD2(Float(offset.x), Float(offset.y))
        if floorOffset != nextOffset {
            floorOffset = nextOffset
            needsDisplay = true
        }
        if let job = pendingWalk, job.completion.wait(timeout: .now()) == .success {
            finishLoading(job)
        }
        if pendingWalk == nil {
            let heading: CGFloat?
            switch dog.activity {
            case let .walk(target, _):
                heading = atan2((target.y-dog.position.y)/Dog.cameraDepth, target.x-dog.position.x)
            case .chase, .jump:
                heading = dog.heading
            default:
                heading = nil
            }
            if let heading {
                let name = animation.walkAtlas(for: heading)
                if atlases[name] == nil, let device, let url = atlasURLs[name] {
                    pendingWalk = PendingWalkAtlas(name:name,url:url,device:device,queue:queue)
                }
            }
        }
        let frame = animation.frame(for: dog, dt: dt, windowScale: scale)
        display(frame, turn: animation.turn)
        // Keep both views of the newly selected frame alive until encoding.
        while walkOrder.count > 3, let i = walkOrder.firstIndex(where: {
            $0 != current?.atlas && $0 != currentTurn?.target.atlas
        }) {
            atlases[walkOrder.remove(at: i)] = nil
        }
    }

    func updateBed(_ sample: BedLife.Sample) {
        floorOffset = .zero
        pendingWalk = nil
        for name in walkOrder { atlases[name] = nil }
        walkOrder.removeAll(keepingCapacity: true)
        animation.resetContacts()
        display(animation.bedFrame(sample))
    }

    func prepareRoaming() {
        // Large directional walk sheets are loaded separately as destinations change.
        let bedAtlas = animation.bedFrame(.init(from: 0, to: 0, phase: 4)).atlas
        for name in atlasURLs.keys where name != bedAtlas && !name.hasPrefix("Walk") {
            _ = loadAtlas(name)
        }
    }

    private func finishLoading(_ job: PendingWalkAtlas) {
        if let texture = job.texture {
            atlases[job.name] = texture
            touchWalk(job.name)
        }
        pendingWalk = nil
    }

    private func touchWalk(_ name: String) {
        guard name.hasPrefix("Walk"), walkOrder.last != name else { return }
        walkOrder.removeAll { $0 == name }
        walkOrder.append(name)
    }

    @discardableResult
    private func loadAtlas(_ name: String) -> Bool {
        if let job = pendingWalk, job.name == name {
            job.completion.wait()
            finishLoading(job)
        }
        if atlases[name] != nil {
            touchWalk(name)
            return true
        }
        guard let device, let url = atlasURLs[name],
              let texture = PhotoTexture(device: device, queue: queue, url: url) else { return false }
        atlases[name] = texture
        touchWalk(name)
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
        func contactParameters(_ pose: PhotoFrame) -> [SIMD4<Float>] {
            [pose.pawVisibility] + pose.pawPins
        }
        var b = bounds(frame)
        var uniforms = parameters(frame)
        if let turn = currentTurn, let second = atlases[turn.target.atlas] {
            let firstBounds = bounds(frame, interpolated: true)
            let secondBounds = bounds(turn.target, interpolated: true)
            b = union(b, bounds(turn.target))
            uniforms += parameters(turn.target)
            uniforms += [SIMD4(Float(turn.angularTile ?? 0),turn.angularTile == nil ? 0 : turn.angularWeight,turn.angularTile == nil ? 0 : 1,turn.amount),
                         SIMD4(frame.mirror,turn.target.mirror,Float(turn.outlines.x),Float(turn.outlines.y)), firstBounds, secondBounds,
                         SIMD4(frame.nose.x*frame.mirror,frame.nose.y,turn.target.nose.x*turn.target.mirror,turn.target.nose.y)]
            var firstContacts = contactParameters(frame)
            // Reserve a fixed slot for the second view even without constraints.
            if firstContacts.count == 1 { firstContacts += Array(repeating:.zero,count:4) }
            uniforms += firstContacts + contactParameters(turn.target)
            encoder.setRenderPipelineState(turnPipeline)
            encoder.setFragmentTexture(second.texture,index:2)
        } else {
            var maxShiftSquared: Float = 0
            for (leg,p) in frame.pawPins.enumerated() where frame.pawVisibility[leg] > 0 {
                let delta = SIMD2(p.z-p.x,p.w-p.y)
                maxShiftSquared = max(maxShiftSquared,simd_length_squared(delta))
            }
            // The tail rotates around its attachment in the same exposure as the torso.
            // Reserve enough space to rasterize it outside the neutral outline.
            if frame.wagAngle != 0 {
                let guide = frame.tailGuide
                let reach = abs(frame.wagAngle)*simd_distance(SIMD2(guide.x,guide.y), SIMD2(guide.z,guide.w))
                b.x -= reach
                b.z += reach
                b.y -= reach
            }
            uniforms += [SIMD4(frame.mirror,maxShiftSquared,frame.wagAngle,0), frame.tailGuide] + contactParameters(frame)
            encoder.setRenderPipelineState(pipeline)
        }
        for pin in frame.pawPins {
            b = union(b,SIMD4(pin.z-9,pin.w-9,pin.z+9,pin.w+9))
        }
        let half = SIMD2(Float(DogWindow.size.width / 2), Float(DogWindow.size.height / 2))
        let floor = Float(DogWindow.groundMargin) - half.y + frame.lift
        let corners = [SIMD2(b.x-2,b.y-2), SIMD2(b.z+2,b.y-2), SIMD2(b.x-2,b.w+2), SIMD2(b.z+2,b.w+2)]
        let vertices = corners.map { p in
            SIMD4((p.x+floorOffset.x)/half.x, (floor+floorOffset.y-p.y)/half.y, p.x, p.y)
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
    float2 plant(float2 p, float4 visible, thread float4 *pins) {
        if (!any(visible > 0.0) || p.y < -80) return p;
        // Keep each toe inside the shin's reach. In a foreshortened view the
        // far paw may project behind the near paw; moving both here would bend
        // the visible shin into a loop. Leave that occluded colour with the
        // near leg. Only the active swing needs the full vertical adjustment.
        for (int i=0; i<4; ++i) {
            if (visible[i] <= 0) continue;
            float clearance=30.0;
            for (int j=0; j<4; ++j) {
                if (j==i || visible[j]<=0) continue;
                float2 separation = pins[i].xy-pins[j].xy;
                clearance=min(clearance,length(separation));
                if (separation.y < -2.0) {
                    float landingLane=pins[i].z-pins[j].z;
                    float gap=separation.x*landingLane>0 ? min(abs(separation.x),abs(landingLane)) : 0.0;
                    float lane=smoothstep(1.5,9.0,gap);
                    float behind=1.0-smoothstep(0.0,21.0,-separation.y);
                    visible[i] *= mix(1.0,lane,behind);
                }
            }
            float2 correction=pins[i].zw-pins[i].xy;
            float reach=clamp(0.44*clearance,3.0,7.5);
            pins[i].zw=pins[i].xy+correction*min(1.0,reach/max(0.01,length(correction)));
        }
        // Integrate small inverse displacements. A single large inverse offset
        // folds a shin over itself when the two photographs have different strides.
        for (int step=0;step<8;step++) {
            float phase = 1.0-float(step)/8.0;
            float2 sum = 0;
            float total = 0, envelope = 0;
            for (int i=0; i<4; ++i) {
                if (visible[i] <= 0) continue;
                float4 pin = pins[i];
                float2 d = p - mix(pin.xy,pin.zw,phase);
                d.y *= d.y < 0 ? 0.68 : 1.05;
                float r2 = dot(d,d);
                float reach = 1-smoothstep(64.0,1444.0,r2);
                float inverse = 1.0/max(2.0,r2);
                float w = visible[i]*reach*inverse*inverse;
                total += w;
                sum += w*(pin.xy-pin.zw);
                envelope = max(envelope,visible[i]*reach);
            }
            p += 0.125*envelope*sum/max(total,1.0e-12);
        }
        return p;
    }
    // Baked walking frames already contain knee and ankle articulation. Between
    // two exposures a subframe registration needs only one inverse translation.
    float2 subframeOffset(float2 p, constant float4 *registration) {
        float2 sum = 0;
        float weightSum = 0, envelope = 0;
        for (int i=0;i<4;i++) {
            float4 pin=registration[i+1];
            float2 d=p-pin.zw;
            d.y*=d.y<0 ? 0.68 : 1.05;
            float r2=dot(d,d);
            float reach=registration[0][i]*(1-smoothstep(64.0,1444.0,r2));
            float w=reach/max(4.0,r2*r2);
            sum+=w*(pin.xy-pin.zw);
            weightSum+=w;
            envelope=max(envelope,reach);
        }
        return p+envelope*sum/max(1.0e-12,weightSum);
    }
    fragment float4 photo_fragment(PhotoPixel p [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                   texture2d<float> flow [[texture(1)]], constant float4 *u [[buffer(0)]]) {
        float2 pos = p.uv;
        if (u[4].y>0.01 && pos.y > -80) {
            if (u[4].y<4.0) {
                pos=subframeOffset(pos,u+6);
            } else {
                float4 pins[4];
                for (int i=0;i<4;i++) pins[i]=u[7+i];
                pos=plant(pos,u[6],pins);
            }
        }
        pos.x *= u[4].x;
        if (u[4].z != 0) {
            float2 root = u[5].zw, stem = u[5].xy-root;
            float lengthSq = max(1.0,dot(stem,stem));
            float2 q = pos-root;
            float along = dot(q,stem)/lengthSq;
            float across = length(q-stem*clamp(along,0.0,1.0));
            float radius = sqrt(lengthSq);
            float influence = smoothstep(0.0,0.65,along)*(1-smoothstep(0.52,1.1,across/radius));
            float angle = -u[4].z*influence;
            float c = cos(angle), s = sin(angle);
            pos = root + float2(c*q.x-s*q.y,s*q.x+c*q.y);
        }
        return gait(pos,max(length(dfdx(p.uv)),length(dfdy(p.uv))),atlas,flow,u);
    }
    float mapInterval(float v,float lo,float hi,float a,float b) {
        return a+(v-lo)*(b-a)/max(hi-lo,0.4);
    }
    float remap(float v,float3 mid,float3 dest) {
        return v < mid.y ? mapInterval(v,mid.x,mid.y,dest.x,dest.y)
                         : mapInterval(v,mid.y,mid.z,dest.y,dest.z);
    }
    float2 turnPosition(float2 p, float3 mx, float3 my, float3 x, float3 y,
                        float t, float opticalWeight, int tile, bool reverse,
                        texture2d<float> flow, constant float4 *registration) {
        float4 visible = registration[0];
        if (any(visible > 0.0) && p.y > -80) {
            float4 pins[4];
            for (int i=0;i<4;i++) {
                pins[i]=registration[i+1];
                float2 raw=pins[i].xy;
                float2 middle=float2(remap(raw.x,x,mx),remap(raw.y,y,my));
                if (opticalWeight > 0) {
                    float2 tracked=raw+t*displacement(flow,raw,tile,reverse);
                    middle=mix(middle,tracked,opticalWeight);
                }
                pins[i].xy=middle;
            }
            p=plant(p,visible,pins);
        }
        float2 geometric=float2(remap(p.x,mx,x),remap(p.y,my,y));
        if (opticalWeight <= 0) return geometric;
        float2 sample=geometric;
        for (int i=0;i<4;i++) sample=mix(sample,p-t*displacement(flow,sample,tile,reverse),0.72);
        return mix(geometric,sample,opticalWeight);
    }
    float outlineDistance(texture2d<float> atlas, float2 pos, int component) {
        constexpr sampler linear(coord::pixel,address::clamp_to_edge,filter::linear);
        int tile=component/4;
        float2 uv=clamp((pos+float2(108,172))*0.5,float2(0.5),float2(107.5,99.5));
        float4 values=atlas.sample(linear,uv+float2((tile%8)*108,(tile/8)*100));
        return (values[component%4]*255.0-128.0)*0.25;
    }
    // Signed distance to the actual fur and paw outlines of a moving exposure.
    // Only boundary pixels shared with transparent space require extra samples.
    float movingEdge(texture2d<float> atlas, float2 local, float mirror, float alpha,
                     float pixelWidth, constant float4 *pose) {
        float scale = pose[1].x;
        float2 p = local*float2(mirror,1)/scale+pose[0].xy;
        float lod = log2(pixelWidth/scale);
        float sign = alpha>=0.5 ? 1.0 : -1.0;
        if (abs(alpha-0.5)<0.45) return (alpha-0.5)*pixelWidth;
        float radius = 12.0;
        const float2 directions[8] = {float2(1,0),float2(-1,0),float2(0,1),float2(0,-1),
            float2(.707,.707),float2(-.707,.707),float2(-.707,-.707),float2(.707,-.707)};
        for (int i=0;i<8;i++) {
            float previous = alpha, last = 0.0;
            for (float r=1.5; r<=12.0 && last<radius; r*=2.0) {
                float next = photo(atlas,p+directions[i]*r/scale,pose[2],lod).a;
                if ((next-0.5)*sign<=0.0) {
                    radius=min(radius,mix(last,r,(0.5-previous)/(next-previous)));
                    break;
                }
                previous=next;
                last=r;
            }
        }
        return sign*radius;
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
        // The muzzle and ears follow the measured flow even during acceleration.
        // The lower body increasingly follows the gait's four registered feet.
        float upper = 1.0-smoothstep(-75.0,-34.0,p.uv.y);
        float opticalWeight = mix(u[8].y,u[8].z,upper);
        float2 a=turnPosition(p.uv,mx,my,ax,ay,t,opticalWeight,int(u[8].x),false,stride,u+13);
        float2 b=turnPosition(p.uv,mx,my,bx,by,1-t,opticalWeight,int(u[8].x),true,stride,u+18);
        float4 A = gait(a*float2(u[9].x,1),width,first,stride,u);
        float4 B = gait(b*float2(u[9].y,1),width,second,stride,u+4);
        float w=smoothstep(0.12,0.88,t);
        float4 color=mix(A,B,w);
        if (u[9].z>=0 && u[9].w>=0 && w>0 && w<1 && color.a>0.001) {
            float edgeA=outlineDistance(stride,a,int(u[9].z));
            float edgeB=outlineDistance(stride,b,int(u[9].w));
            if (opticalWeight<0.999 && abs(A.a-B.a)>0.06) {
                edgeA=mix(movingEdge(first,a,u[9].x,A.a,width,u),edgeA,opticalWeight);
                edgeB=mix(movingEdge(second,b,u[9].y,B.a,width,u+4),edgeB,opticalWeight);
            } else if (opticalWeight<0.999) {
                return color;
            }
            float aa=max(0.58,width*0.72);
            float alpha=smoothstep(-aa,aa,mix(edgeA,edgeB,w));
            float weight=smoothstep(0.0,0.16,min(w,1-w));
            color *= mix(color.a,alpha,weight)/color.a;
        }
        return color;
    }
    """
}
