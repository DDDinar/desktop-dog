import Foundation
import simd

/// Toe landmarks in the floor coordinates of the registered photographs. Order is
/// right fore, left fore, right hind, left hind. An occluded toe retains its
/// expected ground position (for the other view), with 128 subtracted from y.
enum PivotRegistration {
    private static let toes: [String:[[Int]]] = [
        "side": [
            [57,-1,7,-5,-31,-1,-73,-13], [46,-1,6,-5,-47,-2,-32,-20],
            [43,-1,5,-6,-43,-2,-23,-14], [19,-1,46,-15,-36,-2,-32,-141],
            [5,0,52,-9,-54,1,-26,-8], [12,0,46,-13,-45,-4,-31,-15],
            [38,-1,12,-2,-24,-1,-56,-5], [50,-5,22,-2,-17,-1,-60,-7]],
        "rearSide": [
            [54,-5,-7,-8,-58,0,-34,-15], [4,-7,30,-13,-37,0,-43,-139],
            [51,-9,-2,-9,-49,0,-33,-16], [9,-9,38,-19,-46,0,-42,-140]],
        "far": [
            [3,-35,-28,-33,41,-14,27,0], [10,-158,-23,-33,35,-16,26,0],
            [4,-155,-21,-25,35,-17,23,0], [13,-156,-19,-21,45,0,22,-1],
            [-15,-23,-22,-21,38,-6,10,0], [-4,-32,-37,-43,40,-3,16,1],
            [-1,-30,-37,-42,44,-11,22,-1], [4,-157,-26,-36,35,-143,23,0]],
        "backTilt": [
            [13,-37,-16,-160,-6,0,-18,-25], [12,-36,-12,-160,-6,-1,-20,-21],
            [15,-40,-11,-161,-11,-1,-24,-14], [9,-30,-13,-158,-10,-1,-22,-24]],
        "back": [
            [9,-157,-11,-157,7,-1,-12,-14], [9,-157,-11,-157,8,0,-9,-9],
            [9,-157,-11,-157,7,0,-11,-3], [9,-157,-11,-157,6,-1,-13,-9],
            [9,-157,-11,-157,10,-12,-12,-1], [9,-157,-11,-157,9,-9,-10,0],
            [9,-157,-11,-157,9,-1,-12,-1], [9,-157,-11,-157,9,-6,-9,0]],
        "frontTilt": [
            [-3,-10,15,0,-21,-22,-5,-151], [-6,0,12,-5,-21,-19,-4,-151],
            [-8,-9,9,-1,-21,-20,-4,-151], [-6,-12,14,0,-17,-150,-3,-151]],
        "near": [
            [4,0,45,-5,-48,-29,-17,-30], [-2,-7,46,0,-47,-30,-20,-31],
            [0,-1,23,-8,-33,-19,-21,-32], [0,-11,35,0,-29,-15,-13,-155],
            [25,-1,4,-16,-31,-22,-42,-35], [26,0,14,-11,-42,-23,-36,-34],
            [20,-1,9,-144,-43,-33,-16,-38], [25,-1,11,-144,-47,-35,-17,-34]],
        "nearSide": [
            [42,0,13,-16,-56,-23,-17,-26], [37,0,-6,-13,-37,-20,-47,-21],
            [34,-1,24,-141,-41,-16,-35,-26], [16,0,39,-5,-41,-4,-32,-24]],
        "front": [
            [-13,0,9,-11,-12,-149,9,-149], [-9,0,9,-12,-12,-149,9,-149],
            [-11,-1,9,0,-12,-149,9,-149], [-8,-10,9,-1,-12,-149,9,-149],
            [-8,-15,9,-1,-12,-149,9,-149], [-9,-9,9,-1,-12,-149,9,-149],
            [-13,-3,7,-1,-12,-149,9,-149], [-11,-1,6,-14,-12,-149,9,-149]],
        "wag": Array(repeating:[8,0,33,-6,-48,-16,-15,-22],count:8),
        "trot": [
            [23,0,55,-11,-16,-1,-44,-9], [19,0,57,-8,-20,0,-50,-12],
            [55,-11,14,-11,-45,0,-30,-143], [55,0,11,-12,-51,0,-17,-13],
            [51,-1,23,-16,-55,-5,-19,-13], [26,0,50,-20,-30,-9,-47,-19],
            [10,0,54,-7,-24,0,-52,-11], [24,-8,56,-15,-32,0,-51,-18]]
    ]

    static func points(_ clip: String, _ index: Int, mirror: Float) -> [SIMD3<Float>] {
        guard let row = toes[clip]?[index] else { return [] }
        return (0..<4).map { leg in
            let i = 2 * (mirror > 0 ? leg : leg ^ 1)
            let y = row[i+1]
            return SIMD3(Float(row[i]) * mirror, Float(y < -100 ? y+128 : y), y < -100 ? 0 : 1)
        }
    }
}

/// Contacts live in desktop coordinates (including window translation and size).
/// Each swing has a fixed takeoff and landing; a planted paw is never integrated
/// along with the torso. Only a diagonally opposite paw can swing concurrently.
struct PivotSteps {
    typealias Point = SIMD2<Float>
    private struct Foot {
        var at: Point
        var from: Point
        var landing: Point
        var elapsed: Float = 0
        var duration: Float = 0
    }
    private var feet: [Foot] = []
    private var nextPair = 0
    private(set) var settled = false

    mutating func reset() { feet.removeAll(keepingCapacity: true); settled = false }

    mutating func place(initial: [Point], neutral: [Point], ahead: [Point],
                        origin: CGPoint, scale: CGFloat, dt: TimeInterval, settling: Bool) -> [Point] {
        let s = Float(scale)
        let center = Point(Float(origin.x), -Float(origin.y))
        func world(_ local: Point) -> Point { center + local*s }
        if feet.isEmpty { feet = initial.map { let p = world($0); return Foot(at:p,from:p,landing:p) } }
        var result = Array(repeating:Point.zero,count:4)
        for i in feet.indices {
            var f = feet[i]
            if f.duration > 0 {
                f.elapsed += Float(dt)
                let t = min(1, f.elapsed/f.duration)
                let smooth = t*t*(3-2*t)
                f.at = f.from + (f.landing-f.from)*smooth
                // Both the height and the vertical velocity vanish at contact.
                let arc = 16*t*t*(1-t)*(1-t)
                f.at.y -= min(6*s, simd_distance(f.from,f.landing)*0.30)*arc
                if t >= 1 { f.duration = 0 }
                feet[i] = f
            }
            result[i] = (f.at-center)/s
        }
        // Transfer a diagonal pair together. Do not let the less-loaded leg
        // repeatedly take off and starve the other diagonal during a reversal.
        let errors = (0..<4).map { simd_distance(result[$0],neutral[$0]) }
        settled = !feet.contains { $0.duration > 0 } && (errors.max() ?? 0) < 0.7
        if !feet.contains(where: { $0.duration > 0 }) {
            for candidate in [nextPair,1-nextPair] {
                let pair = [candidate,candidate ^ 3]
                guard pair.contains(where: { errors[$0] > (settling ? 0.65 : 3.5) }) else { continue }
                let reach = pair.map { simd_distance(ahead[$0],result[$0]) }.max()!
                let duration = max(0.10,min(0.15,0.08+reach*0.0025))
                for i in pair where simd_distance(ahead[i],result[i]) > 0.5 {
                    feet[i].from = feet[i].at
                    feet[i].landing = world(ahead[i])
                    feet[i].elapsed = 0
                    feet[i].duration = duration
                }
                nextPair = 1-candidate
                break
            }
        }
        return result
    }
}
