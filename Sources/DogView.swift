import AppKit

final class DogWindow: NSWindow {
    static let size = CGSize(width: 198, height: 276)
    static let groundMargin: CGFloat = 43

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        setAccessibilityLabel("Собака на рабочем столе")
    }

    static func origin(at point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x - size.width / 2 * scale, y: point.y - groundMargin * scale)
    }
}

final class DogView: NSView {
    private let photoView: PhotoSurface?
    private let groundShadow = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.22), NSColor.black.withAlphaComponent(0)
    ])
    private var bathroomEffect: BathroomEffect?
    private var wasSleeping = false
    private var sleepPhase = 0.0
    private var jumpHeight: CGFloat = 0
    private var lastRenderedPose: Pose?
    private var renderElapsed: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        let frame = CGRect(origin: .zero, size: frameRect.size)
        let assets = Bundle.main.resourceURL?.appendingPathComponent("Photo", isDirectory: true)
        photoView = assets.flatMap { PhotoSurface.make(frame: frame, assets: $0) }
        super.init(frame: frameRect)
        if let photoView {
            photoView.autoresizingMask = [.width, .height]
            addSubview(photoView)
        } else {
            NSLog("The desktop dog photo assets could not be loaded.")
        }
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    func prepareRoaming() { photoView?.prepareRoaming() }

    func display(_ dog: Dog, dt: TimeInterval, bedFrame: BedLife.Sample? = nil) {
        if let bedFrame {
            if wasSleeping || jumpHeight != 0 || bathroomEffect != nil {
                bathroomEffect = nil
                wasSleeping = false
                sleepPhase = 0
                jumpHeight = 0
                needsDisplay = true
            }
            lastRenderedPose = nil
            renderElapsed = 0
            photoView?.updateBed(bedFrame)
            return
        }
        renderElapsed += dt
        // Keep the walk and chase responsive. Breathing and a settled tail
        // need fewer updates when the dog is resting.
        let resting = dog.pose == .sleep || dog.pose == .lie || (dog.pose == .stand && dog.joy < 0.02)
        if dog.pose == lastRenderedPose, resting, renderElapsed < 1.0 / 26.0 { return }
        lastRenderedPose = dog.pose
        let animationStep = renderElapsed
        renderElapsed = 0
        let scale = bounds.width / DogWindow.size.width
        photoView?.update(dog, dt: animationStep, scale: scale)

        let effect = BathroomEffect(dog)
        if bathroomEffect != effect {
            bathroomEffect = effect
            needsDisplay = true
        }
        let sleeping = dog.pose == .sleep
        let newPhase = sleeping ? dog.animationTime.truncatingRemainder(dividingBy: 4.2) : 0
        let newHeight = dog.jumpLift / scale
        if sleeping != wasSleeping || abs(jumpHeight - newHeight) > 0.1 ||
            abs(sleepPhase - newPhase) > 0.03 {
            wasSleeping = sleeping
            sleepPhase = newPhase
            jumpHeight = newHeight
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = bounds.width / DogWindow.size.width
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: DogWindow.size.width / 2, y: DogWindow.groundMargin)
        let shadowScale = 1 - min(jumpHeight / 280, 0.32)
        ctx.saveGState()
        ctx.scaleBy(x: shadowScale, y: 0.28 * shadowScale)
        groundShadow?.draw(fromCenter: .zero, radius: 3, toCenter: .zero,
                           radius: 66, options: [.drawsBeforeStartingLocation])
        ctx.restoreGState()
        bathroomEffect?.draw(in: ctx)
        ctx.restoreGState()

        if wasSleeping {
            let p = sleepPhase / 4.2
            let alpha = max(0, sin(p * .pi)) * 0.9
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: (11 + p * 4) * s, weight: .semibold),
                .foregroundColor: NSColor(white: 0.98, alpha: alpha),
                .strokeColor: NSColor(white: 0.22, alpha: alpha * 0.55), .strokeWidth: -2
            ]
            ("z" as NSString).draw(at: CGPoint(x: (139 + 7 * p) * s, y: (100 + 26 * p) * s),
                                    withAttributes: attrs)
        }
    }

}

/// Draw on the ground layer, so the coat and the supporting legs occlude the effect.
struct BathroomEffect: Equatable {
    let kind: BathroomBreak
    let elapsed: TimeInterval
    let mirror: CGFloat

    init?(_ dog: Dog) {
        guard case let .bathroom(kind) = dog.pose else { return nil }
        let elapsed = dog.bathroomTime - BathroomBreak.enter
        guard elapsed > 0, elapsed < kind.hold + 1.1 else { return nil }
        let release = kind.hold * 0.55
        if kind == .defecate && elapsed <= release { return nil }
        self.kind = kind
        let still = kind == .defecate ? release + 0.27 : kind.hold
        self.elapsed = (still...kind.hold+0.55).contains(elapsed) ? still : elapsed
        mirror = cos(dog.heading) < 0 ? -1 : 1
    }

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: mirror, y: 1)
        let fade = min(1, (kind.hold + 1.1 - elapsed) / 0.55)
        ctx.setAlpha(fade)
        switch kind {
        case .urinate:
            // The stream starts under the belly and follows an arc to the ground.
            // At the end the last segment falls clear of the dog.
            let flight = 0.21
            let head = min(1, elapsed / flight)
            let tail = max(0, min(1, (elapsed - kind.hold + flight) / flight))
            if head > tail {
                ctx.setStrokeColor(red: 0.80, green: 0.69, blue: 0.39, alpha: 0.72)
                ctx.setLineWidth(1.15)
                ctx.setLineCap(.round)
                ctx.beginPath()
                for i in 0...10 {
                    let t = tail + (head - tail) * Double(i) / 10
                    let point = CGPoint(x: -37 + 9*t, y: 54 - 18*t - 40*t*t)
                    if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
                }
                ctx.strokePath()
            }
            let spread = min(1, max(0, (elapsed - flight) / (kind.hold - flight)))
            if spread > 0 {
                ctx.setFillColor(red: 0.53, green: 0.45, blue: 0.25, alpha: 0.32)
                ctx.fillEllipse(in: CGRect(x: -28 - 6*spread, y: -4 - 2*spread,
                                           width: 12*spread, height: 4*spread))
            }
        case .defecate:
            // It drops once the squat has settled, then stays at its landing point.
            let release = kind.hold * 0.55
            guard elapsed > release else { return }
            let t = min(1, (elapsed - release) / 0.27)
            ctx.translateBy(x: -72 - 3*t, y: 46 - 48*t*t)
            ctx.setFillColor(red: 0.31, green: 0.20, blue: 0.12, alpha: 0.96)
            ctx.fillEllipse(in: CGRect(x: -4.2, y: 0, width: 7, height: 3.9))
            ctx.fillEllipse(in: CGRect(x: -1.9, y: 0.9, width: 5, height: 4.5))
        }
    }
}
