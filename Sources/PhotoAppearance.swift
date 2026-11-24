import Foundation
import simd

struct PhotoFrame: Equatable {
    let atlas: String
    let bounds: SIMD4<Float>
    let pivot: SIMD2<Float>
    let scale: Float
    var mirror: Float = 1
    var lift: Float = 0
    var targetBounds = SIMD4<Float>.zero
    var targetPivot = SIMD2<Float>.zero
    var tile = 0
    var reversed = false
    var fraction: Float = 0
}

/// Key poses use the original photographs. Intermediate poses use motion measured
/// between adjacent photographs taken from the same direction.
struct PhotoAppearance {
    private struct Clip: Decodable {
        let atlas: String
        let scale: Float
        let frames: [[Float]]

        func frame(_ index: Int, mirror: Float = 1, lift: Float = 0) -> PhotoFrame {
            let f = frames[index]
            return PhotoFrame(atlas: atlas, bounds: [f[0], f[1], f[2], f[3]],
                              pivot: [f[4], f[5]], scale: scale, mirror: mirror, lift: lift)
        }
    }

    // Counterclockwise from screen right. Negative Y points toward the viewer.
    private enum Direction: Int, CaseIterable {
        case right, awayRight, away, awayLeft, left, towardLeft, toward, towardRight

        var clip: String {
            switch self {
            case .right, .left: return "side"
            case .awayRight, .awayLeft: return "far"
            case .towardLeft, .towardRight: return "near"
            case .away: return "back"
            case .toward: return "front"
            }
        }

        var mirror: Float {
            switch self {
            case .left, .awayRight, .towardLeft: return -1
            default: return 1
            }
        }

        var sideOn: Bool { self == .right || self == .left }

        func distance(from heading: CGFloat) -> CGFloat {
            let delta = heading - CGFloat(rawValue) * .pi / 4
            return abs(atan2(sin(delta), cos(delta)))
        }
    }

    private let flowIndex: [String: Int]
    private let clips: [String: Clip]
    private var direction: Direction?
    private var pose: Pose?
    private var timeInPose = 0.0
    private var turnPhase: CGFloat?
    private var previousHeading: CGFloat?
    private var lastMovingFrame: PhotoFrame?
    private var wagClock = 0.0

    var motionAtlases: Set<String> { Set(clips.values.map(\.atlas)) }

    init?(assets: URL) {
        let manifest = assets.appendingPathComponent("Motion/Atlas.json")
        let required = ["side", "near", "far", "front", "back", "trot", "jump", "wag", "bed"]
        guard let data = try? Data(contentsOf: manifest),
              let clips = try? JSONDecoder().decode([String: Clip].self, from: data),
              required.allSatisfy({ name in
                  guard let clip = clips[name], clip.scale > 0,
                        clip.frames.count == (name == "bed" ? 16 : 8) else { return false }
                  return clip.frames.allSatisfy { f in f.count == 6 && f[0] < f[2] && f[1] < f[3] }
              }) else { return nil }
        guard let indexData = try? Data(contentsOf: assets.appendingPathComponent("Motion/Flow.json")),
              let index = try? JSONDecoder().decode([String: Int].self, from: indexData) else { return nil }
        flowIndex = index
        self.clips = clips
    }

    private func transition(_ name: String, _ a: Int, _ b: Int, _ t: Float,
                            mirror: Float = 1, lift: Float = 0) -> PhotoFrame {
        let clip = clips[name]!
        var frame = clip.frame(a, mirror: mirror, lift: lift)
        if a == b || t <= 0 { return frame }
        let target = clip.frame(b, mirror: mirror, lift: lift)
        if t >= 1 { return target }
        let forward = flowIndex["\(name)/\(a)/\(b)"]
        guard let tile = forward ?? flowIndex["\(name)/\(b)/\(a)"] else { return t < 0.5 ? frame : target }
        frame.tile = tile
        frame.reversed = forward == nil
        frame.fraction = t
        frame.targetBounds = target.bounds
        frame.targetPivot = target.pivot
        return frame
    }

    func bedFrame(_ sample: BedLife.Sample) -> PhotoFrame {
        transition("bed", sample.from, sample.to, Float(sample.phase) / 4)
    }

    mutating func frame(for dog: Dog, dt: TimeInterval, windowScale: CGFloat) -> PhotoFrame {
        if pose == dog.pose { timeInPose += dt } else { pose = dog.pose; timeInPose = 0 }
        let heading = dog.heading
        let yaw = heading - (previousHeading ?? heading)
        previousHeading = heading
        // Prevent tiny steering changes from flapping between two angles.
        if direction == nil || direction!.distance(from: heading) > .pi / 8 + 0.09 {
            direction = Direction.allCases.min { $0.distance(from: heading) < $1.distance(from: heading) }
        }
        let view = direction ?? .towardRight
        let facesLeft = cos(heading) < -0.12 || view == .towardLeft
        switch dog.pose {
        case .walk, .run:
            if dog.gaitStrength < 0.025 && abs(atan2(sin(yaw), cos(yaw))) > 0.003 {
                turnPhase = (turnPhase ?? dog.gaitPhase) + dt * 1.8
            } else if dog.gaitStrength >= 0.025 {
                turnPhase = nil
            }
            let phase = (turnPhase ?? dog.gaitPhase) + (view.mirror == -1 ? 0.5 : 0)
            let position = phase.truncatingRemainder(dividingBy: 1) * 8
            let index = Int(position)
            let clip = dog.pose == .run && view.sideOn ? "trot" : view.clip
            let frame = transition(clip, index, (index + 1) % 8, Float(position - CGFloat(index)), mirror: view.mirror)
            lastMovingFrame = frame
            return frame
        case .jump:
            turnPhase = nil
            let position = min(7, dog.jumpProgress * 8)
            let index = Int(position)
            return transition("jump", index, min(7, index + 1), Float(position - CGFloat(index)), mirror: facesLeft ? -1 : 1,
                                        lift: Float(dog.jumpLift / windowScale))
        case .lie:
            return PhotoFrame(atlas: "Portraits", bounds: [966, 549, 1488, 995],
                              pivot: [1214, 917], scale: 0.265)
        case .sleep:
            return PhotoFrame(atlas: "Rest", bounds: [26, 208, 878, 766],
                              pivot: [443, 719], scale: 0.145)
        case .sniff:
            return PhotoFrame(atlas: "Rest", bounds: [893, 110, 1749, 732],
                              pivot: [1310, 681], scale: 0.166, mirror: facesLeft ? -1 : 1)
        case .stand:
            turnPhase = nil
            // Give the chase a stable finish before turning to look at you.
            if dog.isChasing, timeInPose < 0.20, let lastMovingFrame { return lastMovingFrame }
            wagClock += dt * 15 * Double(dog.joy)
            wagClock.formTruncatingRemainder(dividingBy: 14)
            let position = dog.joy > 0.12 ? min(wagClock, 14 - wagClock) : 3
            let index = Int(position)
            return transition("wag", index, min(7, index + 1), Float(position - Double(index)), mirror: facesLeft ? -1 : 1)
        }
    }
}
