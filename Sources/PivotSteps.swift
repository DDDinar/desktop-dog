import Foundation
import simd

/// A quiet pivot always has three supporting feet. Positions below are in
/// desktop coordinates so a planted toe stays still as the window moves.
struct PivotSteps {
    typealias Point = SIMD2<Float>
    private var anchors: [Point] = []
    private var moving: Int?
    private var takeoff = Point.zero
    private var landing = Point.zero
    private var elapsed: Float = 0
    private var duration: Float = 0
    private var previousFoot = 0
    private(set) var settled = false

    mutating func reset() {
        anchors.removeAll(keepingCapacity:true)
        moving = nil
        settled = false
    }

    mutating func place(initial: [Point], neutral: [Point], ahead: [Point],
                        origin: CGPoint, scale: CGFloat, dt: TimeInterval) -> [Point] {
        let s = Float(scale)
        let center = Point(Float(origin.x), -Float(origin.y))
        if anchors.isEmpty { anchors = initial.map { center+$0*s } }
        if let leg = moving {
            elapsed = min(duration,elapsed+Float(dt))
            let t = elapsed/duration
            let smooth = t*t*t*(10+t*(-15+6*t))
            anchors[leg] = takeoff+(landing-takeoff)*smooth
            let reach = simd_length(landing-takeoff)/s
            anchors[leg].y -= min(5.2,reach*0.34)*s*16*t*t*(1-t)*(1-t)
            if elapsed >= duration { moving = nil }
        }
        let local = anchors.map { ($0-center)/s }
        guard moving == nil else { return local }
        // Give the unloaded limb a clear landing before the next lifts. Ties
        // favour the next foot around the body, not a simultaneous diagonal.
        let order = [0,3,1,2]
        let next = (order.firstIndex(of:previousFoot)!+1)%4
        var candidate: Int?
        var largest: Float = 1.4
        for offset in 0..<4 {
            let leg = order[(next+offset)%4]
            let halfway = neutral[leg]+(ahead[leg]-neutral[leg])*0.45
            let miss = simd_distance(local[leg],halfway)
            let score = leg == previousFoot ? miss*0.72 : miss
            if score > largest { candidate = leg; largest = score }
        }
        settled = candidate == nil
        if let leg = candidate {
            takeoff = anchors[leg]
            landing = center+ahead[leg]*s
            duration = min(0.115,max(0.08,0.068+simd_distance(takeoff,landing)/s*0.0023))
            elapsed = 0
            moving = leg
            previousFoot = leg
        }
        return local
    }
}
