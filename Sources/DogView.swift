import AppKit

final class DogWindow: NSWindow {
    static let size = CGSize(width: 198, height: 276)
    static let groundMargin: CGFloat = 43

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: .borderless, backing: .buffered, defer: false)
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

    func display(_ dog: Dog, dt: TimeInterval, bedFrame: Int? = nil) {
        if let bedFrame {
            if wasSleeping || jumpHeight != 0 {
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
        ctx.scaleBy(x: shadowScale, y: 0.28 * shadowScale)
        groundShadow?.draw(fromCenter: .zero, radius: 3, toCenter: .zero,
                           radius: 66, options: [.drawsBeforeStartingLocation])
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
