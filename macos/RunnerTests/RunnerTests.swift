import XCTest
@testable import BlinkMonitor

final class RunnerTests: XCTestCase {
    func testRunnerLinksTheNativeBlinkDetector() {
        var detector = BlinkDetector()
        let open = EyeMeasurement(left: 0.3, right: 0.3)
        for index in 0...65 { _ = detector.process(open, at: Double(index) / 30) }
        _ = detector.process(EyeMeasurement(left: 0.1, right: 0.1), at: 2.20)
        XCTAssertTrue(detector.process(open, at: 2.28).didBlink)
    }
}
