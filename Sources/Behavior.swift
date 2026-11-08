import Foundation
import CoreGraphics

enum Pose {
    case stand, walk, run, jump, sniff, lie, sleep

    var strideLength: CGFloat {
        switch self {
        case .walk: return 42
        case .run: return 52
        default: return 0
        }
    }
}

enum Activity {
    case stand(until: TimeInterval)
    case walk(to: CGPoint, folder: CGPoint?)
    case sniff(until: TimeInterval)
    case chase(until: TimeInterval, forced: Bool)
    case jump(Jump)
    case lie(until: TimeInterval)
    case sleep
}

struct Jump {
    let start: CGPoint
    let landing: CGPoint
    let startedAt: TimeInterval
    let duration: TimeInterval
    let height: CGFloat
    let chaseUntil: TimeInterval
    let forced: Bool
}

struct Dog {
    var position: CGPoint
    private(set) var heading: CGFloat = -.pi / 2 + 0.62
    var activity: Activity
    private(set) var pose: Pose = .stand
    private(set) var animationTime: TimeInterval = 0
    private(set) var gaitPhase: CGFloat = 0
    private(set) var gaitStrength: CGFloat = 0
    private(set) var joy: CGFloat = 0
    private(set) var jumpProgress: CGFloat = 0
    private(set) var jumpLift: CGFloat = 0
    private var movementSpeed: CGFloat = 0
    private var nextChase: TimeInterval
    private var lastFolder: CGPoint?
    private var manualRest = false
    private var joyUntil: TimeInterval
    private var chasePoint: CGPoint?
    private var caughtCursor = false
    private var resumeSince: TimeInterval?
    private var viewerSide: CGFloat = 1
    private var turnSettle: TimeInterval = 0

    static let restThreshold: TimeInterval = 120
    static let walkSpeed: CGFloat = 63
    static let runSpeed: CGFloat = 185
    static let pointsPerUnit: CGFloat = 53
    static let cameraDepth: CGFloat = 0.52
    static let cameraRise = sqrt(1 - cameraDepth * cameraDepth)

    var isChasing: Bool {
        switch activity {
        case .chase, .jump: return true
        default: return false
        }
    }

    init(position: CGPoint, now: TimeInterval) {
        self.position = position
        activity = .stand(until: now + 1.2)
        nextChase = now + Double.random(in: 40...75)
        joyUntil = now + 2.2
    }

    func sniffTarget(for icon: CGPoint, bounds: CGRect, scale: CGFloat) -> CGPoint? {
        let offset = 49 * scale
        let left = CGPoint(x: icon.x - offset, y: icon.y - 6 * scale)
        let right = CGPoint(x: icon.x + offset, y: left.y)
        let closest = position.x <= icon.x ? [left, right] : [right, left]
        return closest.first { bounds.insetBy(dx: -1, dy: -1).contains($0) }
    }

    @discardableResult
    mutating func visitFolder(_ folders: [CGPoint], in bounds: CGRect, scale: CGFloat) -> Bool {
        let choices = folders.filter { $0 != lastFolder }.shuffled() + folders
        for icon in choices {
            guard let target = sniffTarget(for: icon, bounds: bounds, scale: scale) else { continue }
            manualRest = false
            lastFolder = icon
            activity = .walk(to: target, folder: icon)
            return true
        }
        return false
    }

    mutating func stroll(in bounds: CGRect) {
        manualRest = false
        var point = position
        for _ in 0..<12 {
            let angle = CGFloat(Int.random(in: 0..<8)) * .pi / 4
            let distance = CGFloat.random(in: 145...440)
            point = bounds.clamp(CGPoint(x: position.x + cos(angle) * distance,
                y: position.y + sin(angle) * distance * Self.cameraDepth))
            if Self.groundDistance(dx: point.x - position.x, dy: point.y - position.y) > 105 { break }
        }
        activity = .walk(to: point, folder: nil)
    }

    mutating func rest(now: TimeInterval) {
        manualRest = true
        activity = .lie(until: now + 4)
    }

    mutating func wake(now: TimeInterval) {
        manualRest = false
        activity = .stand(until: now + 1.3)
        nextChase = max(nextChase, now + 18)
        joyUntil = now + 2.2
    }

    mutating func chase(now: TimeInterval, forced: Bool) {
        manualRest = false
        activity = .chase(until: now + (forced ? 9 : Double.random(in: 3.8...6.0)), forced: forced)
        nextChase = now + Double.random(in: 80...155)
        joyUntil = now + 2.8
        chasePoint = nil
        caughtCursor = false
        resumeSince = nil
    }

    mutating func pet(now: TimeInterval) {
        wake(now: now)
        activity = .stand(until: now + 3.4)
        joyUntil = now + 3.4
    }

    mutating func step(now: TimeInterval, dt: TimeInterval, idle: TimeInterval, pointer: CGPoint,
                       pointerOnScreen: Bool, pointerMoving: Bool, allowChase: Bool,
                       bounds: CGRect, folders: [CGPoint], scale: CGFloat) {
        position = bounds.clamp(position)
        let startPosition = position
        animationTime += dt
        jumpLift = 0
        jumpProgress = 0
        let shouldSleep = manualRest || idle >= Self.restThreshold
        switch activity {
        case .lie, .sleep:
            if !shouldSleep { wake(now: now) }
        case .jump:
            break
        default:
            if shouldSleep { activity = .lie(until: now + 8) }
        }

        let nextPose: Pose
        switch activity {
        case let .stand(until):
            nextPose = .stand
            let side = cos(heading)
            if abs(side) > 0.35 { viewerSide = side > 0 ? 1 : -1 }
            _ = turn(toward: -.pi / 2 + viewerSide * 0.62, maxChange: 2.6 * dt)
            if now >= until {
                let pointerDistance = hypot(pointer.x - position.x, pointer.y - position.y)
                if allowChase && pointerMoving && pointerOnScreen && pointerDistance > 75 && now >= nextChase {
                    chase(now: now, forced: false)
                } else if Double.random(in: 0..<1) >= 0.36 || !visitFolder(folders, in: bounds, scale: scale) {
                    stroll(in: bounds)
                }
            }
        case let .walk(target, folder):
            nextPose = .walk
            if move(toward: bounds.clamp(target), speed: Self.walkSpeed * scale,
                    acceleration: 230 * scale, steering: false, bounds: bounds, dt: dt) {
                if let folder {
                    face(folder)
                    activity = .sniff(until: now + Double.random(in: 2.7...4.7))
                } else {
                    activity = .stand(until: now + Double.random(in: 1.6...5.2))
                }
            }
        case let .sniff(until):
            nextPose = .sniff
            if now >= until { activity = .stand(until: now + 1.5) }
        case let .chase(until, forced):
            if now >= until || (!forced && !allowChase) || !pointerOnScreen {
                nextPose = .stand
                activity = .stand(until: now + 2.4)
                break
            }
            let cursor = CGPoint(x: pointer.x, y: pointer.y - 42 * scale)
            let previous = chasePoint ?? cursor
            let smoothing = 1 - exp(-dt / 0.085)
            let tracked = CGPoint(x: previous.x + (cursor.x - previous.x) * smoothing,
                                  y: previous.y + (cursor.y - previous.y) * smoothing)
            chasePoint = tracked
            let dx = tracked.x - position.x, dy = tracked.y - position.y
            let distance = Self.groundDistance(dx: dx, dy: dy)
            let reach = max(0, 1 - 61 * scale / max(1, distance))
            let aim = bounds.clamp(CGPoint(x: position.x + dx * reach, y: position.y + dy * reach))
            let remaining = Self.groundDistance(dx: aim.x - position.x, dy: aim.y - position.y)
            if caughtCursor {
                if remaining > 31 * scale {
                    let since = resumeSince ?? now
                    resumeSince = since
                    if now - since >= 0.10 { caughtCursor = false }
                } else {
                    resumeSince = nil
                }
            } else if remaining < 5 * scale && movementSpeed < 38 * scale {
                caughtCursor = true
                resumeSince = nil
            }
            if caughtCursor {
                nextPose = .stand
                joyUntil = max(joyUntil, now + 0.7)
            } else if remaining > 1,
                      abs(headingError(toward: aim)) < 0.16,
                      let jump = jumpToward(aim, over: folders, in: bounds, scale: scale,
                                            now: now, chaseUntil: until, forced: forced) {
                face(jump.landing)
                activity = .jump(jump)
                nextPose = .jump
            } else {
                _ = move(toward: aim, speed: Self.runSpeed * scale, acceleration: 490 * scale,
                         steering: true, bounds: bounds, dt: dt)
                nextPose = .run
            }
        case let .jump(jump):
            nextPose = .jump
            jumpProgress = min(1, (now - jump.startedAt) / jump.duration)
            position = bounds.clamp(CGPoint(
                x: jump.start.x + (jump.landing.x - jump.start.x) * jumpProgress,
                y: jump.start.y + (jump.landing.y - jump.start.y) * jumpProgress
            ))
            // Hold the paws on the ground during the gather and landing frames.
            let air = max(0, min(1, (jumpProgress - 0.13) / 0.74))
            jumpLift = 4 * jump.height * air * (1 - air)
            if jumpProgress == 1 {
                activity = .chase(until: jump.chaseUntil, forced: jump.forced)
            }
        case let .lie(until):
            nextPose = .lie
            if now >= until { activity = .sleep }
        case .sleep:
            nextPose = .sleep
        }
        pose = nextPose
        let happy = now < joyUntil && pose != .lie && pose != .sleep
        joy += ((happy ? 1 : 0) - joy) * min(1, dt * 6)
        if pose.strideLength > 0 {
            // Advance the cycle only as the body travels. This also slows the
            // paws on takeoff and braking, and keeps stride length at any size.
            let travel = Self.groundDistance(dx: position.x - startPosition.x,
                                             dy: position.y - startPosition.y)
            gaitPhase = (gaitPhase + travel / (pose.strideLength * scale))
                .truncatingRemainder(dividingBy: 1)
            let speed = (pose == .run ? Self.runSpeed : Self.walkSpeed) * scale
            gaitStrength = min(1, movementSpeed / (0.55 * speed))
        } else if pose != .jump {
            movementSpeed = 0
            gaitStrength = 0
        }
    }

    private func jumpToward(_ target: CGPoint, over folders: [CGPoint], in bounds: CGRect,
                            scale: CGFloat, now: TimeInterval, chaseUntil: TimeInterval,
                            forced: Bool) -> Jump? {
        // Avoid jumping from a standstill and leave room to land beyond the icon.
        guard movementSpeed >= 140 * scale, !folders.isEmpty else { return nil }
        let dx = target.x - position.x, dy = target.y - position.y
        let distance = hypot(dx, dy)
        let ux = dx / distance, uy = dy / distance
        let height = 91 * scale
        let takeoff = 100 * scale, landingClearance = 91 * scale
        var nearest = CGFloat.infinity
        for folder in folders {
            let x = folder.x - position.x
            let y = folder.y - (position.y + 16 * scale)
            let ahead = x * ux + y * uy
            let across = abs(x * uy - y * ux)
            if across <= 29 * scale, ahead > 36 * scale, ahead <= takeoff,
               ahead + landingClearance <= distance {
                nearest = min(nearest, ahead)
            }
        }
        guard nearest.isFinite else { return nil }
        let travel = nearest + landingClearance
        let landing = CGPoint(x: position.x + ux * travel, y: position.y + uy * travel)
        guard max(position.y, landing.y) + height <= bounds.maxY else { return nil }
        let duration = max(0.46, Self.groundDistance(dx: ux * travel, dy: uy * travel) / (Self.runSpeed * scale))
        return Jump(start: position, landing: landing, startedAt: now, duration: duration,
                    height: height, chaseUntil: chaseUntil, forced: forced)
    }

    private mutating func move(toward target: CGPoint, speed: CGFloat, acceleration: CGFloat,
                               steering: Bool, bounds: CGRect, dt: TimeInterval) -> Bool {
        let dx = target.x - position.x, dy = target.y - position.y
        let distance = Self.groundDistance(dx: dx, dy: dy)
        if distance < 0.5 {
            position = target
            movementSpeed = 0
            return true
        }
        let bearing = atan2(dy / Self.cameraDepth, dx)
        let error = turn(toward: bearing, maxChange: (steering ? 8 : 2.7) * dt)
        // A walk starts with a turn in place. At a run the dog follows a
        // curve, slowing into tight turns instead of running sideways.
        if !steering && abs(error) > 0.10 {
            turnSettle = 0.24
            movementSpeed = 0
            return false
        }
        if !steering && turnSettle > 0 {
            turnSettle = max(0, turnSettle - dt)
            return false
        }
        let brakingSpeed = sqrt(2 * acceleration * distance)
        let alignment = max(0, cos(error))
        let desiredSpeed = min(speed, brakingSpeed) * alignment * alignment
        movementSpeed += max(-acceleration * dt, min(acceleration * dt, desiredSpeed - movementSpeed))
        let stride = movementSpeed * dt
        if distance <= stride && abs(error) < 0.12 {
            position = target
            movementSpeed = 0
            return true
        }
        let travel = min(stride, distance)
        position = bounds.clamp(CGPoint(x: position.x + cos(heading) * travel,
            y: position.y + sin(heading) * travel * Self.cameraDepth))
        return false
    }

    @discardableResult
    private mutating func turn(toward bearing: CGFloat, maxChange: CGFloat) -> CGFloat {
        let delta = bearing - heading
        let error = atan2(sin(delta), cos(delta))
        let change = max(-maxChange, min(maxChange, error))
        let turned = heading + change
        heading = atan2(sin(turned), cos(turned))
        return error - change
    }

    private func headingError(toward target: CGPoint) -> CGFloat {
        let bearing = atan2((target.y - position.y) / Self.cameraDepth, target.x - position.x)
        let delta = bearing - heading
        return atan2(sin(delta), cos(delta))
    }

    private mutating func face(_ target: CGPoint) {
        let dx = target.x - position.x, dy = target.y - position.y
        if hypot(dx, dy) > 1 { heading = atan2(dy / Self.cameraDepth, dx) }
    }

    private static func groundDistance(dx: CGFloat, dy: CGFloat) -> CGFloat {
        hypot(dx, dy / cameraDepth)
    }
}

extension CGRect {
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(minX, min(maxX, p.x)), y: max(minY, min(maxY, p.y)))
    }
}
