import Foundation

/// A quiet, stationary routine. The bed shares one anchor in every photograph.
struct BedLife {
    enum Action { case wake, sleep, wag, sniff }

    private struct Beat {
        let frame: Int
        let seconds: TimeInterval
    }

    private static let parent = [0, 0, 0, 2, 0, 4, 5, 6, 7, 7, 7, 10]
    private(set) var frame = 0
    private(set) var sleeping = false
    private var manualSleep = false
    private var nextActivity: TimeInterval
    private var nextBlink: TimeInterval
    private var beatEnds: TimeInterval = 0
    private var remaining: [Beat] = []

    init(now: TimeInterval) {
        nextActivity = now + 18
        nextBlink = now + 5
    }

    mutating func step(now: TimeInterval, idle: TimeInterval) {
        if !manualSleep && idle >= Dog.restThreshold && !sleeping {
            perform(.sleep, now: now, manual: false)
        } else if sleeping && !manualSleep && idle < Dog.restThreshold {
            perform(.wake, now: now)
        }
        while !remaining.isEmpty && now >= beatEnds { advance(at: beatEnds) }
        guard !sleeping, now >= beatEnds else { return }
        if now >= nextActivity {
            perform(Bool.random() ? .wag : .sniff, now: now)
        } else if now >= nextBlink {
            begin([Beat(frame: 1, seconds: 0.18), Beat(frame: 0, seconds: 0)], now: now)
            nextBlink = now + Double.random(in: 5...13)
        }
    }

    mutating func perform(_ action: Action, now: TimeInterval, manual: Bool = true) {
        sleeping = action == .sleep
        manualSleep = sleeping && manual
        var beats: [Beat] = []
        func appendRoute(from start: Int, to end: Int, seconds: TimeInterval) {
            beats += Self.route(from: start, to: end).map { Beat(frame: $0, seconds: seconds) }
        }
        switch action {
        case .wake:
            appendRoute(from: frame, to: 0, seconds: 0.20)
        case .sleep:
            appendRoute(from: frame, to: 3, seconds: 0.32)
        case .wag, .sniff:
            appendRoute(from: frame, to: 7, seconds: 0.16)
            beats.append(Beat(frame: 7, seconds: 0.38))
            if action == .wag {
                for _ in 0..<4 {
                    beats += [8, 7, 9, 7].map { Beat(frame: $0, seconds: 0.115) }
                }
            } else {
                beats += [Beat(frame: 10, seconds: 0.25), Beat(frame: 11, seconds: 1.10),
                          Beat(frame: 10, seconds: 0.22), Beat(frame: 7, seconds: 0.35)]
            }
            appendRoute(from: 7, to: 0, seconds: 0.21)
        }
        begin(beats, now: now)
        let end = now + beats.reduce(0) { $0 + $1.seconds }
        nextActivity = end + Double.random(in: 23...48)
        nextBlink = end + Double.random(in: 5...13)
    }

    private mutating func begin(_ beats: [Beat], now: TimeInterval) {
        remaining = beats
        beatEnds = now
        advance(at: now)
    }

    private mutating func advance(at time: TimeInterval) {
        guard !remaining.isEmpty else { return }
        let beat = remaining.removeFirst()
        frame = beat.frame
        beatEnds = time + beat.seconds
    }

    private static func route(from start: Int, to end: Int) -> [Int] {
        func ancestors(_ node: Int) -> [Int] {
            var path = [node]
            while let last = path.last, last != 0 { path.append(parent[last]) }
            return path
        }
        let from = ancestors(start), to = ancestors(end)
        let fork = from.first { to.contains($0) } ?? 0
        let upward = start == fork ? [] : Array(from.dropFirst().prefix { $0 != fork }) + [fork]
        return upward + Array(to.prefix { $0 != fork }.reversed())
    }
}
