import Foundation

public struct EyeMeasurement: Sendable {
    public let left: Double
    public let right: Double

    public init(left: Double, right: Double) {
        self.left = left
        self.right = right
    }
}

public struct DetectionResult: Sendable {
    public enum State: Sendable { case noFace, calibrating, tracking }
    public let state: State
    public let calibrationProgress: Double
    public let openness: Double
    public let didBlink: Bool
    public let trackedDuration: TimeInterval
}

/// A bilateral close/reopen state machine, independent of Vision and camera hardware.
public struct BlinkDetector {
    public var closedFraction: Double
    private var samples: [EyeMeasurement] = []
    private var calibrationStart: TimeInterval?
    private var baseline: EyeMeasurement?
    private var previousTimestamp: TimeInterval?
    private var lastValidTimestamp: TimeInterval?
    private var closedAt: TimeInterval?
    private var lastBlink: TimeInterval = -.infinity
    private var armed = false

    public init(closedFraction: Double = 0.58) {
        self.closedFraction = min(0.8, max(0.4, closedFraction))
    }

    public mutating func reset() {
        self = BlinkDetector(closedFraction: closedFraction)
    }

    public mutating func process(_ measurement: EyeMeasurement?, at timestamp: TimeInterval) -> DetectionResult {
        guard let eye = measurement,
              eye.left.isFinite, eye.right.isFinite,
              eye.left > 0, eye.right > 0,
              eye.left < 1, eye.right < 1 else {
            closedAt = nil
            armed = false
            previousTimestamp = nil
            if baseline == nil { samples = []; calibrationStart = nil }
            return result(.noFace)
        }

        // A person returning after a long absence may have moved relative to the camera.
        if let last = lastValidTimestamp, timestamp - last > 3 { reset() }
        lastValidTimestamp = timestamp

        guard let reference = baseline else {
            if calibrationStart == nil { calibrationStart = timestamp }
            samples.append(eye)
            let elapsed = timestamp - (calibrationStart ?? timestamp)
            let progress = min(1, min(elapsed / 2, Double(samples.count) / 40))
            if progress >= 1 {
                let left = samples.map(\.left).sorted()
                let right = samples.map(\.right).sorted()
                // Upper quantile tolerates natural blinks during calibration.
                let index = Int(Double(samples.count - 1) * 0.8)
                baseline = EyeMeasurement(left: left[index], right: right[index])
                samples.removeAll()
                previousTimestamp = timestamp
            }
            return result(.calibrating, progress: progress)
        }

        let delta = previousTimestamp.map { timestamp - $0 } ?? 0
        previousTimestamp = timestamp
        let continuous = delta > 0 && delta <= 0.25
        if !continuous { closedAt = nil; armed = false }

        let left = eye.left / reference.left
        let right = eye.right / reference.right
        let threshold = min(0.8, max(0.4, closedFraction))
        let reopen = min(0.96, threshold + 0.16)
        let isClosed = left < threshold && right < threshold
        let isOpen = left > reopen && right > reopen
        var blink = false

        if isOpen {
            if let start = closedAt {
                let duration = timestamp - start
                blink = duration >= 0.025 && duration <= 0.8 && timestamp - lastBlink >= 0.18
                if blink { lastBlink = timestamp }
            }
            closedAt = nil
            armed = true
            // Slow adaptation only while confidently open; never learn a closed eye.
            if left > 0.85 && right > 0.85 && left < 1.3 && right < 1.3 {
                baseline = EyeMeasurement(
                    left: reference.left * 0.995 + eye.left * 0.005,
                    right: reference.right * 0.995 + eye.right * 0.005
                )
            }
        } else if isClosed && armed && closedAt == nil {
            closedAt = timestamp
            armed = false
        }

        return DetectionResult(state: .tracking, calibrationProgress: 1,
                               openness: min(1.2, max(0, (left + right) / 2)),
                               didBlink: blink, trackedDuration: continuous ? delta : 0)
    }

    private func result(_ state: DetectionResult.State, progress: Double = 0) -> DetectionResult {
        DetectionResult(state: state, calibrationProgress: progress, openness: 0,
                        didBlink: false, trackedDuration: 0)
    }
}

public struct LandmarkPoint: Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum EyeGeometry {
    /// Measures height perpendicular to the eye's longest chord. Input is in image
    /// pixels, so face-box aspect ratio and head roll do not distort the result.
    public static func aspectRatio(_ points: [LandmarkPoint]) -> Double? {
        guard points.count >= 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var width = 0.0
        var axis = (x: 0.0, y: 0.0)
        for i in points.indices {
            for j in points.indices where j > i {
                let dx = points[j].x - points[i].x
                let dy = points[j].y - points[i].y
                let length = hypot(dx, dy)
                if length > width { width = length; axis = (dx, dy) }
            }
        }
        guard width > 0.001 else { return nil }
        let heights = points.map { (-axis.y * $0.x + axis.x * $0.y) / width }
        return ((heights.max() ?? 0) - (heights.min() ?? 0)) / width
    }
}
