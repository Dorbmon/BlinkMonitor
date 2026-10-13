import Foundation

public struct EyeMeasurement: Sendable {
    public let left: Double
    public let right: Double
    public let yaw: Double
    public let pitch: Double

    public init(left: Double, right: Double, yaw: Double = 0, pitch: Double = 0) {
        self.left = left
        self.right = right
        self.yaw = yaw
        self.pitch = pitch
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
    private var previousEye: EyeMeasurement?
    private var previousPose: (yaw: Double, pitch: Double)?
    private var quickDip: (time: TimeInterval, left: Double, right: Double)?

    public init(closedFraction: Double = 0.58) {
        self.closedFraction = min(0.8, max(0.4, closedFraction))
    }

    public mutating func reset() {
        self = BlinkDetector(closedFraction: closedFraction)
    }

    public mutating func process(_ measurement: EyeMeasurement?, at timestamp: TimeInterval) -> DetectionResult {
        guard let raw = measurement,
              let eye = EyeGeometry.compensated(raw),
              eye.left.isFinite, eye.right.isFinite,
              eye.left >= 0, eye.right >= 0,
              eye.left < 1, eye.right < 1 else {
            closedAt = nil
            armed = false
            quickDip = nil
            previousEye = nil
            previousPose = nil
            previousTimestamp = nil
            if baseline == nil { samples = []; calibrationStart = nil }
            return result(.noFace)
        }

        // A person returning after a long absence may have moved relative to the camera.
        if let last = lastValidTimestamp, timestamp - last > 3 { reset() }
        lastValidTimestamp = timestamp
        let poseChanged = previousPose.map { abs(raw.yaw - $0.yaw) > 0.2 || abs(raw.pitch - $0.pitch) > 0.2 } ?? false
        previousPose = (raw.yaw, raw.pitch)

        guard let reference = baseline else {
            // A fully closed lid can have zero height. It is a valid closed
            // sample after calibration, but cannot define the open-eye baseline.
            guard eye.left > 0, eye.right > 0 else { return result(.calibrating) }
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
        if !continuous || poseChanged {
            closedAt = nil; armed = false; quickDip = nil; previousEye = nil
        }

        let left = eye.left / reference.left
        let right = eye.right / reference.right
        let threshold = min(0.8, max(0.4, closedFraction))
        let reopen = min(0.96, threshold + 0.16)
        let isClosed = left < threshold && right < threshold
        let isOpen = left > reopen && right > reopen
        var blink = false
        let previous = previousEye
        previousEye = EyeMeasurement(left: left, right: right)

        // A camera can sample only the shoulder of a fast blink, missing its
        // fully closed peak. Require a sharp bilateral dip AND prompt recovery.
        if let dip = quickDip {
            if timestamp - dip.time > 0.25 {
                quickDip = nil
                armed = false
            } else if left >= dip.left * 0.9 && right >= dip.right * 0.9 {
                blink = timestamp - dip.time >= 0.008 && timestamp - lastBlink >= 0.12
                if blink { lastBlink = timestamp }
                quickDip = nil
                armed = true
            } else if isClosed {
                closedAt = dip.time
                quickDip = nil
                armed = false
            }
        } else if isClosed && armed && closedAt == nil {
            closedAt = timestamp
            armed = false
        } else if armed, closedAt == nil, continuous, delta <= 0.1,
                  let previous,
                  left <= previous.left * 0.8, right <= previous.right * 0.8,
                  left < min(0.9, threshold + 0.2), right < min(0.9, threshold + 0.2) {
            quickDip = (timestamp, previous.left, previous.right)
            armed = false
        } else if isOpen {
            if let start = closedAt {
                let duration = timestamp - start
                blink = duration >= 0.008 && duration <= 0.8 && timestamp - lastBlink >= 0.12
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
    /// Approximate perspective correction for moderate head yaw and pitch.
    /// Retain a limit where the far eye becomes occluded and geometry is unstable.
    public static func compensated(_ eye: EyeMeasurement) -> EyeMeasurement? {
        guard eye.yaw.isFinite, eye.pitch.isFinite,
              abs(eye.yaw) <= 0.85, abs(eye.pitch) <= 0.65 else { return nil }
        let factor = cos(eye.yaw) / cos(eye.pitch)
        return EyeMeasurement(left: eye.left * factor, right: eye.right * factor)
    }

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
