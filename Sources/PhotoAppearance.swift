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
    // Registered toe, destination toe (both in mirrored floor coordinates).
    var pawPins: [SIMD4<Float>] = []
    var pawVisibility = SIMD4<Float>.zero
}

/// Key poses use the original photographs. Intermediate poses use motion measured
/// between adjacent photographs taken from the same direction.
struct PhotoAppearance {
    private struct Clip: Decodable {
        let atlas: String
        let scale: Float
        let frames: [[Float]]
        let pivotFrame: Int?

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
        var angularTile: Int? = nil
        var angularWeight: Float = 0
        var outlines = SIMD2<Int>(repeating:-1)
    }

    private let flowIndex: [String: Int]
    private let clips: [String: Clip]
    private(set) var turn: Turn?
    private var facing: CGFloat?
    private var previousHeading: CGFloat?
    private var straightTime: TimeInterval = 0
    private var cruisingView: Int?
    private var steps = PivotSteps()
    private var planting: Float = 0
    private var stance: CGFloat = 1
    private var wagClock = 3.0
    private var running = false

    var motionAtlases: Set<String> { Set(clips.values.map(\.atlas)) }

    init?(assets: URL) {
        let manifest = assets.appendingPathComponent("Motion/Atlas.json")
        let turns = ["frontTilt", "nearSide", "rearSide", "backTilt"]
        let breaks = ["urinate", "defecate"]
        let required = turns + breaks + ["side", "near", "far", "front", "back", "trot", "jump", "wag", "bed"]
        guard let data = try? Data(contentsOf: manifest),
              let clips = try? JSONDecoder().decode([String: Clip].self, from: data),
              required.allSatisfy({ name in
                  let count = name == "bed" ? 16 : breaks.contains(name) ? 6 : turns.contains(name) ? 4 : 8
                  guard let clip = clips[name], clip.scale > 0, clip.frames.count == count else { return false }
                  if !breaks.contains(name) && name != "bed" && name != "jump" {
                      guard let i = clip.pivotFrame, clip.frames.indices.contains(i) else { return false }
                  }
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

    private func markedFrame(_ clip: String, _ a: Int, _ b: Int, _ fraction: Float,
                             mirror: Float) -> PhotoFrame {
        var frame = transition(clip, a, b, fraction, mirror:mirror)
        guard planting > 0 else { return frame }
        let from = PivotRegistration.points(clip, a, mirror:mirror)
        let to = PivotRegistration.points(clip, b, mirror:mirror)
        for (leg, pair) in zip(from,to).enumerated() {
            let p = pair.0 + (pair.1-pair.0)*fraction
            frame.pawPins.append(SIMD4(p.x,p.y,p.x,p.y))
            frame.pawVisibility[leg] = p.z
        }
        return frame
    }

    private func gait(_ view: Direction, _ phase: CGFloat) -> PhotoFrame {
        let clip = running && view.sideOn ? "trot" : view.clip
        let count = Float(clips[clip]!.frames.count)
        var position = Float(phase + (view.mirror < 0 ? 0.5 : 0))*count
        if planting > 0, let neutral = clips[clip]?.pivotFrame {
            // Ease along the shorter part of the original photographic cycle to
            // a balanced stance. Toe-off during a pivot belongs to the contact solver.
            let delta = (Float(neutral)-position).remainder(dividingBy:count)
            position += delta*planting
        }
        position = (position+2*count).truncatingRemainder(dividingBy:count)
        let i = Int(position)
        return markedFrame(clip,i,(i+1)%Int(count),position-Float(i),mirror:view.mirror)
    }

    private func footprint(_ angle: CGFloat) -> [SIMD2<Float>] {
        let sector = (angle/(.pi/8)+32).truncatingRemainder(dividingBy:16)
        let i = Int(sector), t = Float(sector-CGFloat(i))
        func toes(_ i: Int) -> [SIMD3<Float>] {
            let view = Direction(rawValue:i%16)!
            return PivotRegistration.points(view.clip,clips[view.clip]!.pivotFrame!,mirror:view.mirror)
        }
        return zip(toes(i),toes(i+1)).map { a,b in
            let p = a+(b-a)*t
            return SIMD2(p.x,p.y)
        }
    }

    private mutating func contacts(_ first: PhotoFrame, second: PhotoFrame? = nil, fraction: Float = 0,
                                   tile: Int? = nil, views: (Int,Int)? = nil, dog: Dog, angle: CGFloat, advance: CGFloat,
                                   dt: TimeInterval, scale: CGFloat) -> PhotoFrame {
        var a = first, b = second
        if planting > 0 {
            let left = cos(angle) < 0
            let wag = PivotRegistration.points("wag",3,mirror:left ? -1 : 1)
            func target(_ angle: CGFloat) -> [SIMD2<Float>] {
                zip(footprint(angle),wag).map { toe, w in
                    toe + (SIMD2(w.x,w.y)-toe)*Float(stance)
                }
            }
            let rest = target(angle), ahead = target(angle+advance)
            let initial = a.pawPins.indices.map { leg in
                let p = a.pawPins[leg], q = b?.pawPins[leg] ?? p
                return SIMD2(p.x+(q.x-p.x)*fraction, p.y+(q.y-p.y)*fraction)
            }
            let planted = steps.place(initial:initial,neutral:rest,ahead:ahead,origin:dog.position,
                                      scale:scale,dt:dt,settling:dog.pose == .stand)
            func apply(_ frame: inout PhotoFrame) {
                for i in frame.pawPins.indices {
                    frame.pawPins[i].z = planted[i].x
                    frame.pawPins[i].w = planted[i].y
                }
                frame.pawVisibility *= planting
            }
            apply(&a)
            if b != nil { apply(&b!) }
        }
        if let b {
            let weight = max(0,min(1,(planting-0.3)/0.7))
            func outline(_ i: Int) -> Int {
                guard let base = flowIndex["pivot/outline/\(i/4)"] else { return -1 }
                return base*4+i%4
            }
            let fields = views.map { SIMD2(outline($0.0),outline($0.1)) } ?? SIMD2(repeating:-1)
            turn = Turn(target:b,amount:fraction,angularTile:tile,angularWeight:weight*weight*(3-2*weight),
                        outlines:fields)
        }
        return a
    }

    /// Resolve each visible angle into two neighbouring views of the same step.
    /// Both views sample the same stride before their silhouettes are aligned.
    private mutating func facingFrame(_ dog: Dog, dt: TimeInterval, scale: CGFloat) -> PhotoFrame {
        let standing = dog.pose == .stand
        let initialRest: CGFloat = cos(dog.heading) >= 0 ? -.pi/4 : -.pi*3/4
        let start = facing ?? (standing ? initialRest : dog.heading)
        if facing == nil && !standing { stance = 0 }
        let left = cos(start) < 0
        let restAngle: CGFloat = left ? -.pi*3/4 : -.pi/4
        let headingChange = dog.heading-(previousHeading ?? dog.heading)
        let stable = abs(atan2(sin(headingChange),cos(headingChange))) < 0.09*dt
        previousHeading = dog.heading
        straightTime = stable && dog.gaitStrength > 0.15 ? straightTime+dt : 0
        var target = standing || stance > 0 ? restAngle : dog.heading
        if straightTime >= 0.12 && !standing && stance == 0 {
            // At a steady course show one complete photographic view. Hysteresis
            // avoids oscillating between neighbouring cameras at their boundary.
            let sector = target/(.pi/8)
            let old = CGFloat(cruisingView ?? Int(sector.rounded()))
            let distance = (sector-old).remainder(dividingBy:16)
            if cruisingView == nil || abs(distance)>0.60 { cruisingView = Int(sector.rounded()) }
            target = CGFloat(cruisingView!)*(.pi/8)
        }
        let delta = atan2(sin(target-start), cos(target-start))
        let limit = CGFloat(dt) * (dog.gaitStrength < 0.04 ? 2.7 : 5.8)
        let eased = abs(delta) < 0.003 ? delta : delta * (1 - exp(-dt/0.05))
        let change = max(-limit, min(limit, eased))
        let angle = start + change
        facing = atan2(sin(angle), cos(angle))
        let pivoting = dog.gaitStrength < 0.04 && (abs(change) > 0.001 ||
            (!standing && stance > 0) || (planting > 0 && (!standing || stance < 1 || !steps.settled)))
        let rate = Float(dt) / 0.17
        planting = pivoting ? min(1,planting+rate) : max(0,planting-rate)
        if planting == 0 { steps.reset() }
        let advance = max(-0.26,min(0.26,change/max(dt,0.001)*0.09))
        if !standing { running = dog.pose == .run }
        let phase = dog.gaitPhase
        if standing && abs(delta-change) < 0.0001 { stance = min(1, stance + dt/0.22) }
        if !standing { stance = max(0, stance - dt/0.22) }
        if stance > 0 {
            let mirror: Float = left ? -1 : 1
            if stance == 1 {
                wagClock = (wagClock + dt * 15 * Double(dog.joy)).truncatingRemainder(dividingBy: 14)
            }
            let wag = dog.joy > 0.12 ? min(wagClock, 14-wagClock) : 3
            let wagFrame = markedFrame("wag",Int(wag),min(7,Int(wag)+1),Float(wag-Double(Int(wag))),mirror:mirror)
            if stance == 1 {
                return contacts(wagFrame,dog:dog,angle:angle,advance:0,dt:dt,scale:scale)
            }
            return contacts(gait(left ? .towardLeft : .towardRight,phase),second:wagFrame,
                            fraction:Float(stance),tile:flowIndex["pivot/\(left ? 10 : 14)/wag"],views:(left ? 10 : 14,left ? 17 : 16),dog:dog,angle:angle,advance:advance,dt:dt,scale:scale)
        }
        let sector = (angle/(.pi/8) + 32).truncatingRemainder(dividingBy: 16)
        let i = Int(sector)
        let a = Direction(rawValue:i)!, b = Direction(rawValue:(i+1)%16)!
        let fraction = Float(sector-CGFloat(i))
        let first = gait(a,phase)
        if fraction < 0.0001 {
            return contacts(first,dog:dog,angle:angle,advance:advance,dt:dt,scale:scale)
        }
        let second = gait(b,phase)
        if fraction > 0.9999 {
            return contacts(second,dog:dog,angle:angle,advance:advance,dt:dt,scale:scale)
        }
        return contacts(first,second:second,fraction:fraction,tile:flowIndex["pivot/\(i)/\((i+1)%16)"],views:(i,(i+1)%16),dog:dog,angle:angle,advance:advance,dt:dt,scale:scale)
    }

    mutating func resetContacts() {
        planting = 0
        steps.reset()
    }

    mutating func frame(for dog: Dog, dt: TimeInterval, windowScale: CGFloat) -> PhotoFrame {
        turn = nil
        if dog.pose != .walk && dog.pose != .run && dog.pose != .stand { resetContacts() }
        let facesLeft = cos(dog.heading) < 0
        switch dog.pose {
        case .walk, .run, .stand:
            return facingFrame(dog, dt: dt, scale: windowScale)
        case let .bathroom(kind):
            facing = facesLeft ? -.pi*3/4 : -.pi/4
            stance = 1
            let position = min(5, kind.keyframe(at: dog.bathroomTime))
            let i = Int(position)
            return transition(kind == .urinate ? "urinate" : "defecate", i, min(5, i+1),
                              Float(position - Double(i)), mirror: facesLeft ? -1 : 1)
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
