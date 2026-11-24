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
    var nose = SIMD2<Float>.zero
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
        case right, rearSideRight, awayRight, backTiltRight, away, backTiltLeft, awayLeft, rearSideLeft
        case left, nearSideLeft, towardLeft, frontTiltLeft, toward, frontTiltRight, towardRight, nearSideRight

        var clip: String {
            switch self {
            case .right, .left: return "side"
            case .awayRight, .awayLeft: return "far"
            case .towardLeft, .towardRight: return "near"
            case .rearSideLeft, .rearSideRight: return "rearSide"
            case .backTiltLeft, .backTiltRight: return "backTilt"
            case .nearSideLeft, .nearSideRight: return "nearSide"
            case .frontTiltLeft, .frontTiltRight: return "frontTilt"
            case .away: return "back"
            case .toward: return "front"
            }
        }

        var mirror: Float {
            switch self {
            case .left, .awayRight, .towardLeft, .rearSideLeft, .backTiltLeft, .nearSideLeft, .frontTiltLeft: return -1
            default: return 1
            }
        }

        var sideOn: Bool { self == .right || self == .left }

    }

    struct Turn: Equatable {
        let target: PhotoFrame
        let amount: Float
    }

    private let flowIndex: [String: Int]
    private let clips: [String: Clip]
    private(set) var turn: Turn?
    private var facing: CGFloat?
    private var pivotPhase: CGFloat = 0
    private var stance: CGFloat = 1
    private var wagClock = 3.0
    private var running = false

    var motionAtlases: Set<String> { Set(clips.values.map(\.atlas)) }

    init?(assets: URL) {
        let manifest = assets.appendingPathComponent("Motion/Atlas.json")
        let turns = ["frontTilt", "nearSide", "rearSide", "backTilt"]
        let required = turns + ["side", "near", "far", "front", "back", "trot", "jump", "wag", "bed"]
        guard let data = try? Data(contentsOf: manifest),
              let clips = try? JSONDecoder().decode([String: Clip].self, from: data),
              required.allSatisfy({ name in
                  guard let clip = clips[name], clip.scale > 0,
                        clip.frames.count == (name == "bed" ? 16 : turns.contains(name) ? 4 : 8) else { return false }
                  return clip.frames.allSatisfy { f in f.count == 6 && f[0] < f[2] && f[1] < f[3] }
              }) else { return nil }
        guard let indexData = try? Data(contentsOf: assets.appendingPathComponent("Motion/Flow.json")),
              let index = try? JSONDecoder().decode([String: Int].self, from: indexData) else { return nil }
        flowIndex = index
        self.clips = clips
    }

    // Nose positions (the crown for the back view), in points relative to the floor pivot.
    private static let noses: [String: SIMD2<Float>] = [
        "side":[54,-76], "far":[-44,-108], "back":[0,-80], "near":[33,-73],
        "front":[0,-52], "trot":[62,-88], "wag":[42,-89], "frontTilt":[19,-70],
        "nearSide":[45,-80], "rearSide":[64,-85], "backTilt":[30,-94]
    ]

    private func transition(_ name: String, _ a: Int, _ b: Int, _ t: Float,
                            mirror: Float = 1, lift: Float = 0) -> PhotoFrame {
        let clip = clips[name]!
        var frame = clip.frame(a, mirror: mirror, lift: lift)
        frame.nose = Self.noses[name] ?? .zero
        if a == b || t <= 0 { return frame }
        var target = clip.frame(b, mirror: mirror, lift: lift)
        target.nose = frame.nose
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

    private func gait(_ view: Direction, _ phase: CGFloat) -> PhotoFrame {
        let clip = running && view.sideOn ? "trot" : view.clip
        let count = clips[clip]!.frames.count
        let position = (phase + (view.mirror < 0 ? 0.5 : 0)).truncatingRemainder(dividingBy: 1) * CGFloat(count)
        let i = Int(position)
        return transition(clip, i, (i+1)%count,
                          Float(position-CGFloat(i)), mirror: view.mirror)
    }

    /// Resolve each visible angle into two neighbouring views of the same step.
    /// Both views sample the same stride before their silhouettes are aligned.
    private mutating func facingFrame(_ dog: Dog, dt: TimeInterval) -> PhotoFrame {
        let standing = dog.pose == .stand
        let initialRest: CGFloat = cos(dog.heading) >= 0 ? -.pi/4 : -.pi*3/4
        let start = facing ?? (standing ? initialRest : dog.heading)
        if facing == nil && !standing { stance = 0 }
        let left = cos(start) < 0
        let restAngle: CGFloat = left ? -.pi*3/4 : -.pi/4
        let target = standing || stance > 0 ? restAngle : dog.heading
        let delta = atan2(sin(target-start), cos(target-start))
        let limit = CGFloat(dt) * (standing ? 3.4 : 5.8)
        let eased = abs(delta) < 0.003 ? delta : delta * (1 - exp(-dt/0.05))
        let change = max(-limit, min(limit, eased))
        let angle = start + change
        facing = atan2(sin(angle), cos(angle))
        if dog.gaitStrength < 0.025 {
            pivotPhase = (pivotPhase + abs(change)*0.56).truncatingRemainder(dividingBy: 1)
        }
        if !standing { running = dog.pose == .run }
        let phase = (dog.gaitPhase + pivotPhase).truncatingRemainder(dividingBy: 1)
        if standing && abs(delta-change) < 0.0001 { stance = min(1, stance + dt/0.22) }
        if !standing { stance = max(0, stance - dt/0.22) }
        if stance > 0 {
            let mirror: Float = left ? -1 : 1
            if stance == 1 {
                wagClock = (wagClock + dt * 15 * Double(dog.joy)).truncatingRemainder(dividingBy: 14)
            }
            let wag = dog.joy > 0.12 ? min(wagClock, 14-wagClock) : 3
            let wagFrame = transition("wag",Int(wag),min(7,Int(wag)+1),Float(wag-Double(Int(wag))),mirror:mirror)
            if stance == 1 { return wagFrame }
            turn = Turn(target: wagFrame, amount: Float(stance))
            return gait(left ? .towardLeft : .towardRight, phase)
        }
        let sector = (angle/(.pi/8) + 32).truncatingRemainder(dividingBy: 16)
        let i = Int(sector)
        let a = Direction(rawValue:i)!, b = Direction(rawValue:(i+1)%16)!
        let fraction = Float(sector-CGFloat(i))
        let first = gait(a,phase)
        if fraction < 0.0001 { return first }
        let second = gait(b,phase)
        if fraction > 0.9999 { return second }
        turn = Turn(target:second, amount:fraction)
        return first
    }

    mutating func frame(for dog: Dog, dt: TimeInterval, windowScale: CGFloat) -> PhotoFrame {
        turn = nil
        let facesLeft = cos(dog.heading) < 0
        switch dog.pose {
        case .walk, .run, .stand:
            return facingFrame(dog, dt: dt)
        case .jump:
            facing = dog.heading
            stance = 0
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
        }
    }
}
