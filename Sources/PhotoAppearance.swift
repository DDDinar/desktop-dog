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
        let toes: [[Float]]?

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

        var pivotIndex: Int { [4,5,6,7,8,7,6,5,4,3,2,1,0,1,2,3][rawValue] }
        var pivotMirror: Float { (5...11).contains(rawValue) ? -1 : 1 }
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
    private(set) var isSettledStanding = true
    private var facing: CGFloat?
    private var yawSpeed: CGFloat = 0
    private var restSide: CGFloat = 1
    private var wasStanding = true
    private var strideStrength: Float = 0
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
        let frameCounts = ["pivot":9, "bed":16, "urinate":6, "defecate":6,
                           "trot":8, "jump":8, "wag":8]
        guard let data = try? Data(contentsOf: manifest),
              let clips = try? JSONDecoder().decode([String: Clip].self, from: data),
              frameCounts.allSatisfy({ name,count in
                  guard let clip = clips[name], clip.scale > 0, clip.frames.count == count else { return false }
                  if name == "pivot" {
                      guard let toes = clip.toes, toes.count == 9, toes.allSatisfy({ $0.count == 12 }) else { return false }
                  }
                  return clip.frames.allSatisfy { f in f.count == 6 && f[0] < f[2] && f[1] < f[3] }
              }) else { return nil }
        guard let indexData = try? Data(contentsOf: assets.appendingPathComponent("Motion/Flow.json")),
              let index = try? JSONDecoder().decode([String: Int].self, from: indexData) else { return nil }
        guard let walkData = try? Data(contentsOf: assets.appendingPathComponent("Motion/Walk.json")),
              let walks = try? JSONDecoder().decode([String: Clip].self, from: walkData),
              (0..<9).allSatisfy({ view in
                  guard let clip = walks["walk\(view)"], clip.atlas == "Walk\(view)", clip.scale > 0,
                        clip.frames.count == 84, let toes = clip.toes, toes.count == 84 else { return false }
                  return toes.allSatisfy { $0.count == 8 } &&
                      clip.frames.allSatisfy { $0.count == 6 && $0[2] > $0[0] && $0[3] > $0[1] }
              }) else { return nil }
        flowIndex = index
        self.clips = clips.merging(walks) { original, _ in original }
    }

    private func transition(_ name: String, _ a: Int, _ b: Int, _ t: Float,
                            mirror: Float = 1, lift: Float = 0) -> PhotoFrame {
        let clip = clips[name]!
        var frame = clip.frame(a, mirror: mirror, lift: lift)
        if name == "wag" { frame.nose = [42,-89] }
        if name == "trot" { frame.nose = [62,-88] }
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

    /// Each photograph has three baked stride amplitudes. Match the nearest
    /// exposure and use its registered toes for the small subframe correction.
    private func gait(_ view: Direction, _ phase: CGFloat, strength: Float) -> PhotoFrame {
        if running && view.sideOn {
            let t = ((Float(phase) + (view.pivotMirror < 0 ? 0.5 : 0)) * 8)
                .truncatingRemainder(dividingBy: 8)
            let i = Int(t)
            return markedFrame("trot", i, (i+1)%8, t-Float(i), mirror: view.pivotMirror)
        }
        let mirror = view.pivotMirror
        let cycle = (Float(phase) + (mirror < 0 ? 0.5 : 0)).truncatingRemainder(dividingBy: 1)
        let clip = clips["walk\(view.pivotIndex)"]!
        let toes = clip.toes!
        let band: (start: Int, count: Int)
        switch strength {
        case ..<0.485: band = (0, 12)
        case ..<0.825: band = (12, 24)
        default: band = (36, 48)
        }
        let sample = band.start + Int((cycle*Float(band.count)).rounded()) % band.count
        let full = cycle*48
        let i = Int(full), t = full-Float(i)
        let neutral = pivotToes(view)
        let useNeutral = strength < 0.16
        var frame = useNeutral ? pivotFrame(view) : clip.frame(sample, mirror: mirror)
        if useNeutral { frame.pawPins.removeAll(keepingCapacity: true) }
        frame.nose = pivotNose(view)
        for leg in 0..<4 {
            let j = 2*(mirror < 0 ? leg ^ 1 : leg)
            func toe(_ sample: Int) -> SIMD2<Float> {
                SIMD2(toes[sample][j]*mirror, toes[sample][j+1])
            }
            let rest = SIMD2(neutral[leg].x,neutral[leg].y)
            let current = useNeutral ? rest : toe(sample)
            let a = toe(36+i), b = toe(36+(i+1)%48)
            let target = rest + (a + (b-a)*t-rest)*strength
            frame.pawPins.append(SIMD4(current.x,current.y,target.x,target.y))
            // Even far paws can appear from behind the body on a stride.
            frame.pawVisibility[leg] = strength > 0.35 ? 1 : neutral[leg].z
        }
        return frame
    }

    private func pivotToes(_ view: Direction) -> [SIMD3<Float>] {
        let row = clips["pivot"]!.toes![view.pivotIndex]
        let mirror = view.pivotMirror
        return (0..<4).map { leg in
            let i = 3 * (mirror < 0 ? leg ^ 1 : leg)
            return SIMD3(row[i]*mirror,row[i+1],row[i+2])
        }
    }

    private func pivotNose(_ view: Direction) -> SIMD2<Float> {
        let noses: [SIMD2<Float>] = [[6,-79],[24,-79],[47,-78],[60,-85],[78,-88],
                                      [64,-89],[51,-101],[41,-102],[-2,-125]]
        return noses[view.pivotIndex]
    }

    private func pivotFrame(_ view: Direction) -> PhotoFrame {
        var frame = clips["pivot"]!.frame(view.pivotIndex, mirror:view.pivotMirror)
        frame.nose = pivotNose(view)
        for (i,p) in pivotToes(view).enumerated() {
            frame.pawPins.append(SIMD4(p.x,p.y,p.x,p.y))
            frame.pawVisibility[i] = p.z
        }
        return frame
    }

    private func views(at angle: CGFloat) -> (Direction,Direction,Float) {
        let sector = (angle / (.pi/8) + 32).truncatingRemainder(dividingBy:16)
        let i = Int(sector)
        return (Direction(rawValue:i)!, Direction(rawValue:(i+1)%16)!, Float(sector-CGFloat(i)))
    }

    func walkAtlas(for heading: CGFloat) -> String {
        let (first, second, fraction) = views(at: heading)
        return "Walk\(fraction < 0.5 ? first.pivotIndex : second.pivotIndex)"
    }

    private func footprint(_ angle: CGFloat) -> [SIMD2<Float>] {
        let (a,b,t) = views(at:angle)
        let wag = PivotRegistration.points("wag",3,mirror:Float(restSide))
        return zip(zip(pivotToes(a), pivotToes(b)),wag).map { pair,w in
            let p = pair.0 + (pair.1-pair.0)*t
            return SIMD2(p.x+(w.x-p.x)*Float(stance),p.y+(w.y-p.y)*Float(stance))
        }
    }

    private mutating func contacts(_ first: PhotoFrame, second: PhotoFrame? = nil, fraction: Float = 0,
                                   tile: Int? = nil, outlines: (Int,Int)? = nil, dog: Dog, angle: CGFloat,
                                   dt: TimeInterval, scale: CGFloat) -> PhotoFrame {
        var a = first, b = second
        if planting > 0 && a.pawPins.count == 4 && (b == nil || b!.pawPins.count == 4) {
            let initial = a.pawPins.indices.map { leg in
                let p = a.pawPins[leg], q = b?.pawPins[leg] ?? p
                return SIMD2(p.x+(q.x-p.x)*fraction,p.y+(q.y-p.y)*fraction)
            }
            let placed = steps.place(initial:initial, neutral:footprint(angle),
                                     ahead:footprint(angle+yawSpeed*0.24), origin:dog.position,
                                     scale:scale,dt:dt)
            func attach(_ frame: inout PhotoFrame) {
                for i in 0..<4 {
                    let p = frame.pawPins[i]
                    frame.pawPins[i].z = p.z + (placed[i].x-p.z)*planting
                    frame.pawPins[i].w = p.w + (placed[i].y-p.w)*planting
                }
            }
            attach(&a)
            if b != nil { attach(&b!) }
            if b == nil && a.pawPins.allSatisfy({ p in abs(p.x-p.z)+abs(p.y-p.w)<0.04 }) {
                a.pawPins = []
                a.pawVisibility = .zero
            }
        }
        if let b {
            func component(_ view: Int) -> Int {
                guard let base = flowIndex["pivot/outline/\(view/4)"] else { return -1 }
                return base*4+view%4
            }
            let fields = outlines.map { SIMD2(component($0.0),component($0.1)) } ?? SIMD2(repeating:-1)
            turn = Turn(target:b, amount:fraction, angularTile:tile, angularWeight:planting,
                        outlines:fields)
        }
        return a
    }

    private mutating func facingFrame(_ dog: Dog, dt: TimeInterval, scale: CGFloat) -> PhotoFrame {
        let standing = dog.pose == .stand
        if facing == nil || (standing && !wasStanding) {
            if abs(cos(dog.heading)) > 0.08 { restSide = cos(dog.heading) < 0 ? -1 : 1 }
            else if let facing { restSide = cos(facing) < 0 ? -1 : 1 }
        }
        let restAngle: CGFloat = restSide < 0 ? -.pi*3/4 : -.pi/4
        if facing == nil && !standing { stance = 0 }
        let start = facing ?? (standing ? restAngle : dog.heading)
        wasStanding = standing
        let headingChange = dog.heading - (previousHeading ?? dog.heading)
        previousHeading = dog.heading
        let steady = abs(atan2(sin(headingChange),cos(headingChange))) < 0.1*dt
        straightTime = steady && dog.gaitStrength > 0.18 ? straightTime + dt : 0
        var target = standing || stance > 0 ? restAngle : dog.heading
        if straightTime > 0.12 && stance == 0 && !standing {
            let sector = target/(.pi/8)
            let old = cruisingView ?? Int(sector.rounded())
            if cruisingView == nil || abs((sector-CGFloat(old)).remainder(dividingBy:16))>0.59 {
                cruisingView = Int(sector.rounded())
            }
            target = CGFloat(cruisingView!)*(.pi/8)
        }
        let delta = atan2(sin(target-start), cos(target-start))
        // A new target can arrive mid-step. Decelerate the turn while the
        // current paw finishes its swing, then accelerate in the new direction.
        let acceleration: CGFloat = dog.pose == .run ? 48 : 18
        let maxRate: CGFloat = dog.pose == .run ? 7.0 : 2.45
        let goalRate = copysign(min(maxRate, sqrt(2*acceleration*abs(delta))),delta)
        yawSpeed += max(-acceleration*dt,min(acceleration*dt,goalRate-yawSpeed))
        var change = yawSpeed*dt
        if change*delta >= 0 && abs(change)>=abs(delta) {
            change = delta
            yawSpeed = dt > 0 ? change/dt : 0
        }
        let angle = atan2(sin(start+change),cos(start+change))
        facing = angle
        if !standing { stance = max(0,stance-dt/0.25) }
        if standing && abs(delta-change)<0.008 { stance = min(1,stance+dt/0.29) }
        running = dog.pose == .run
        let desiredStrength: Float = standing || stance>0 ? 0 : Float(dog.gaitStrength)
        strideStrength += min(Float(dt/0.30),max(-Float(dt/0.20),desiredStrength-strideStrength))
        planting = 1-strideStrength
        if planting == 0 { steps.reset() }
        isSettledStanding = standing && stance == 1 && steps.settled && abs(yawSpeed)<0.01
        if stance > 0 {
            if stance == 1 {
                wagClock = (wagClock+dt*15*Double(dog.joy)).truncatingRemainder(dividingBy:14)
            }
            let wag = dog.joy>0.12 ? min(wagClock,14-wagClock) : 3
            let frame = markedFrame("wag",Int(wag),min(7,Int(wag)+1),Float(wag-Double(Int(wag))),mirror:Float(restSide))
            if stance == 1 {
                return contacts(frame,dog:dog,angle:restAngle,dt:dt,scale:scale)
            }
            let view: Direction = restSide<0 ? .towardLeft : .towardRight
            return contacts(pivotFrame(view),second:frame,fraction:Float(stance),
                            tile:flowIndex["pivot/\(view.rawValue)/wag"],
                            outlines:(view.rawValue,restSide<0 ? 17 : 16),dog:dog,angle:restAngle,dt:dt,scale:scale)
        }
        let (a,b,t) = views(at:angle)
        func pose(_ view: Direction) -> PhotoFrame {
            strideStrength>0 ? gait(view,dog.gaitPhase,strength:strideStrength) : pivotFrame(view)
        }
        if t < 0.0001 { return contacts(pose(a),dog:dog,angle:angle,dt:dt,scale:scale) }
        if t > 0.9999 { return contacts(pose(b),dog:dog,angle:angle,dt:dt,scale:scale) }
        return contacts(pose(a),second:pose(b),fraction:t,tile:flowIndex["pivot/\(a.rawValue)/\(b.rawValue)"],
                        outlines:(a.rawValue,b.rawValue),dog:dog,angle:angle,dt:dt,scale:scale)
    }

    mutating func resetContacts() {
        planting = 0
        strideStrength = 0
        yawSpeed = 0
        straightTime = 0
        cruisingView = nil
        previousHeading = nil
        wasStanding = false
        isSettledStanding = false
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
            restSide = facesLeft ? -1 : 1
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
