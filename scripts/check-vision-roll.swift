import Foundation
import CoreImage
import Vision

/// Optional integration check using a local, consented portrait fixture.
/// Compile with BlinkDetector.swift and CameraService.swift. No camera is opened.
@main
struct VisionRollCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
            fatalError("Provide a local portrait image path")
        }
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(ciImage: image).perform([request])
        guard let original = request.results?.first else { fatalError("Fixture has no face") }
        let pivot = CGPoint(x: original.boundingBox.midX * image.extent.width,
                            y: original.boundingBox.midY * image.extent.height)
        func eyes(_ face: VNFaceObservation) -> [Double] {
            [face.landmarks?.leftEye, face.landmarks?.rightEye].map { region in
                guard let region else { return 0 }
                return EyeGeometry.aspectRatio(region.normalizedPoints.map {
                    LandmarkPoint(x: Double($0.x) * face.boundingBox.width * image.extent.width,
                                  y: Double($0.y) * face.boundingBox.height * image.extent.height)
                }) ?? 0
            }
        }
        let baseline = eyes(original)
        var failures = 0
        for degrees in [-45.0, -30, -15, 0, 15, 30, 45] {
            let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .rotated(by: degrees * .pi / 180).translatedBy(x: -pivot.x, y: -pivot.y)
            let tilted = image.transformed(by: transform).cropped(to: image.extent)
            let tracker = UprightFaceLandmarks()
            var faces: [VNFaceObservation] = []
            for _ in 0..<6 { faces = try tracker.detect(tilted) }
            guard faces.count == 1, let face = faces.first else {
                print("\(degrees)°: face lost"); failures += 1; continue
            }
            let values = eyes(face)
            let relative = zip(values, baseline).map { $0 / $1 }
            let stable = !tracker.isSettling && relative.allSatisfy { (0.75...1.25).contains($0) }
            print("\(degrees)°: normalized eye geometry \(relative), stable=\(stable)")
            if !stable { failures += 1 }
        }
        guard failures == 0 else { fatalError("Roll stabilization failed for \(failures) angles") }
    }
}
