// Build with the same Sources files as the app, replacing main.swift with this file.
// Pass the built bundle's Resources/Photo directory. Pipe stdout to ffmpeg with
// -f rawvideo -pix_fmt bgra -s 720x360 -r 30 -i - to capture the fixed desktop camera.
import AppKit
import MetalKit

@main
struct MotionPreview {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Expected the Photo resource directory", code: 1)
        }
        let assets = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = DogWindow.size
        let retina = 2
        let width = Int(size.width) * retina, height = Int(size.height) * retina
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let surface = PhotoSurface.make(frame: CGRect(origin: .zero, size: size), assets: assets),
              let device = surface.device, let queue = device.makeCommandQueue(),
              let texture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "Could not create the app's Metal renderer", code: 2)
        }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColorMake(0, 0, 0, 0)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let format = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let canvasWidth = 720, canvasHeight = 360
        let ctx = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                            bytesPerRow: canvasWidth * 4, space: space, bitmapInfo: format)!
        ctx.setFillColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        ctx.setFillColor(red: 0.77, green: 0.78, blue: 0.75, alpha: 1)
        for x in stride(from: 7, to: canvasWidth, by: 24) {
            for y in stride(from: 4, to: canvasHeight, by: 24) {
                ctx.fillEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1.6, height: 1.6))
            }
        }
        let background = ctx.makeImage()!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let fixedBounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let start = CGPoint(x: 400, y: 300)
        var dog = Dog(position: start, now: 0)
        let dt = 1.0 / 60
        let zoom = 1.5
        for tick in 0..<840 {
            // Right and left profiles, a diagonal, then a change of target mid-turn.
            switch tick {
            case 24: dog.activity = .walk(to: CGPoint(x: 590, y: 300), folder: nil)
            case 198: dog.activity = .walk(to: CGPoint(x: 360, y: 300), folder: nil)
            case 485: dog.activity = .walk(to: CGPoint(x: 558, y: 381), folder: nil)
            case 696: dog.activity = .walk(to: CGPoint(x: 342, y: 260), folder: nil)
            case 725: dog.activity = .walk(to: CGPoint(x: 603, y: 301), folder: nil)
            case 805: dog.activity = .stand(until: 30)
            default: break
            }
            dog.step(now: Double(tick)*dt, dt: dt, idle: 0, pointer: .zero,
                     pointerOnScreen: false, pointerMoving: false, allowChase: false,
                     bounds: fixedBounds, folders: [], scale: 1)
            let desired = DogWindow.origin(at: dog.position, scale: 1)
            let origin = CGPoint(x: desired.x.rounded(), y: desired.y.rounded())
            let remainder = CGPoint(x: desired.x-origin.x, y: desired.y-origin.y)
            surface.update(dog, dt: dt, scale: 1, offset: remainder)
            guard tick.isMultiple(of: 2) else { continue }
            try autoreleasepool {
                let command = queue.makeCommandBuffer()!
                guard surface.encode(pass, into: command) else {
                    throw NSError(domain: "Missing photograph at tick \(tick)", code: 3)
                }
                command.commit()
                command.waitUntilCompleted()
                if let error = command.error { throw error }
                var pixels = Data(count: width*height*4)
                pixels.withUnsafeMutableBytes { raw in
                    texture.getBytes(raw.baseAddress!, bytesPerRow: width*4,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
                let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width*4, space: space, bitmapInfo: CGBitmapInfo(rawValue: format),
                    provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
                    shouldInterpolate: true, intent: .defaultIntent)!
                ctx.draw(background, in: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
                ctx.saveGState()
                ctx.translateBy(x: 220+(dog.position.x-start.x)*zoom, y: 70+(dog.position.y-start.y)*zoom)
                ctx.scaleBy(x: zoom, y: zoom)
                DogView.drawGroundShadow(in: ctx, height: dog.jumpLift)
                ctx.restoreGState()
                ctx.draw(image, in: CGRect(x: 220+(origin.x-start.x)*zoom, y: 70+(origin.y-start.y)*zoom,
                                         width: size.width*zoom, height: size.height*zoom))
                try FileHandle.standardOutput.write(contentsOf: Data(bytesNoCopy: ctx.data!,
                    count: ctx.bytesPerRow*canvasHeight, deallocator: .none))
            }
        }
    }
}
