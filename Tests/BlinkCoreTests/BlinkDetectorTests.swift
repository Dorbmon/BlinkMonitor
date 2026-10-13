import XCTest
@testable import BlinkCore

final class BlinkDetectorTests: XCTestCase {
    private let open = EyeMeasurement(left: 0.3, right: 0.3)
    private let closed = EyeMeasurement(left: 0.10, right: 0.11)

    private func calibrated() -> BlinkDetector {
        var detector = BlinkDetector()
        for index in 0...65 { _ = detector.process(open, at: Double(index) / 30) }
        return detector
    }

    func testCalibrationRequiresTimeAndEnoughFrames() {
        var detector = BlinkDetector()
        for index in 0..<30 {
            XCTAssertEqual(detector.process(open, at: Double(index) / 30).state, .calibrating)
        }
        XCTAssertEqual(detector.process(open, at: 2).state, .calibrating)
        XCTAssertLessThan(detector.process(open, at: 2.1).calibrationProgress, 1)
    }

    func testBilateralCloseReopenCountsExactlyOnce() {
        var detector = calibrated()
        XCTAssertFalse(detector.process(closed, at: 2.20).didBlink)
        XCTAssertFalse(detector.process(closed, at: 2.24).didBlink)
        XCTAssertTrue(detector.process(open, at: 2.28).didBlink)
        XCTAssertFalse(detector.process(open, at: 2.32).didBlink)
    }

    func testWinksAreNotBlinks() {
        var detector = calibrated()
        XCTAssertFalse(detector.process(EyeMeasurement(left: 0.1, right: 0.3), at: 2.20).didBlink)
        XCTAssertFalse(detector.process(open, at: 2.25).didBlink)
    }

    func testLongClosureDoesNotCountAsBlink() {
        var detector = calibrated()
        for index in 0...30 { _ = detector.process(closed, at: 2.2 + Double(index) / 30) }
        XCTAssertFalse(detector.process(open, at: 3.24).didBlink)
        _ = detector.process(closed, at: 3.30)
        XCTAssertTrue(detector.process(open, at: 3.37).didBlink)
    }

    func testFaceLossCancelsPendingBlinkAndExposure() {
        var detector = calibrated()
        _ = detector.process(closed, at: 2.20)
        XCTAssertEqual(detector.process(nil, at: 2.24).state, .noFace)
        let result = detector.process(open, at: 2.28)
        XCTAssertFalse(result.didBlink)
        XCTAssertEqual(result.trackedDuration, 0)
    }

    func testFrameGapDoesNotCountBlinkOrUnobservedTime() {
        var detector = calibrated()
        _ = detector.process(closed, at: 2.20)
        let result = detector.process(open, at: 2.8)
        XCTAssertFalse(result.didBlink)
        XCTAssertEqual(result.trackedDuration, 0)
    }

    func testReturningAfterAbsenceRecalibrates() {
        var detector = calibrated()
        _ = detector.process(nil, at: 2.20)
        XCTAssertEqual(detector.process(open, at: 6).state, .calibrating)
    }

    func testNoiseBetweenThresholdsDoesNotDoubleCount() {
        var detector = calibrated()
        _ = detector.process(closed, at: 2.20)
        XCTAssertFalse(detector.process(EyeMeasurement(left: 0.20, right: 0.20), at: 2.24).didBlink)
        XCTAssertTrue(detector.process(open, at: 2.28).didBlink)
        _ = detector.process(closed, at: 2.31)
        XCTAssertFalse(detector.process(open, at: 2.34).didBlink)
    }

    func testInvalidMeasurementsNeverTrack() {
        var detector = calibrated()
        XCTAssertEqual(detector.process(EyeMeasurement(left: .nan, right: 0.3), at: 2.20).state, .noFace)
        XCTAssertEqual(detector.process(EyeMeasurement(left: 0, right: 0.3), at: 2.24).trackedDuration, 0)
    }

    func testEyeAspectRatioIsInvariantToRotationAndScale() throws {
        let eye = [LandmarkPoint(x: -5, y: 0), LandmarkPoint(x: -2, y: 1), LandmarkPoint(x: 2, y: 1),
                   LandmarkPoint(x: 5, y: 0), LandmarkPoint(x: 2, y: -1), LandmarkPoint(x: -2, y: -1)]
        let angle = 0.4
        let rotated = eye.map { LandmarkPoint(x: 3 * ($0.x * cos(angle) - $0.y * sin(angle)) + 100,
                                              y: 3 * ($0.x * sin(angle) + $0.y * cos(angle)) + 50) }
        XCTAssertEqual(try XCTUnwrap(EyeGeometry.aspectRatio(eye)), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(EyeGeometry.aspectRatio(rotated)), 0.2, accuracy: 0.0001)
        XCTAssertNil(EyeGeometry.aspectRatio([]))
    }
}
