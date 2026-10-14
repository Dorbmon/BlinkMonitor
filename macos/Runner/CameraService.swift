import AVFoundation
import Foundation
import Vision
import CoreImage

struct CameraChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Session changes and Vision work run on separate serial queues, never on the UI thread.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Frame {
        let date: Date
        let result: DetectionResult
        let hint: String?
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.blinkmonitor.camera")
    private let visionQueue = DispatchQueue(label: "app.blinkmonitor.vision", qos: .userInitiated)
    private var detector = BlinkDetector()
    private var frameHandler: ((Frame) -> Void)?
    private var errorHandler: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var visionFailures = 0
    private var landmarkTracker = UprightFaceLandmarks()

    static func cameras() -> [CameraChoice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14, *) { types = [.builtInWideAngleCamera, .external, .continuityCamera] }
        else { types = [.builtInWideAngleCamera, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(deviceID: String, sensitivity: Double,
               onFrame: @escaping (Frame) -> Void, onError: @escaping (String) -> Void) {
        sessionQueue.async { [self] in
            stopSession()
            do {
                let device: AVCaptureDevice?
                if deviceID.isEmpty { device = AVCaptureDevice.default(for: .video) }
                else { device = AVCaptureDevice(uniqueID: deviceID) }
                guard let device else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                guard session.canAddInput(input) else {
                    session.commitConfiguration(); throw CameraError.configuration
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration(); throw CameraError.configuration
                }
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: visionQueue)
                session.commitConfiguration()
                let ranges = device.activeFormat.videoSupportedFrameRateRanges
                let frameRate = [60, 30].first { rate in
                    ranges.contains { $0.minFrameRate <= Double(rate) && $0.maxFrameRate >= Double(rate) }
                }
                if let frameRate {
                    try device.lockForConfiguration()
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRate))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRate))
                    device.unlockForConfiguration()
                }
                visionQueue.sync {
                    detector = BlinkDetector(closedFraction: sensitivity)
                    frameHandler = onFrame; errorHandler = onError
                    visionFailures = 0
                    landmarkTracker = UprightFaceLandmarks()
                }
                // Raw notification names also compile against older Xcode SDKs,
                // before these constants moved onto AVCaptureSession in Swift.
                for name in [Notification.Name("AVCaptureSessionRuntimeErrorNotification"),
                             Notification.Name("AVCaptureSessionWasInterruptedNotification")] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { notification in
                        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                        onError(error?.localizedDescription ?? "The camera was interrupted. Check other camera apps, then try again.")
                    })
                }
                session.startRunning()
                if !session.isRunning { onError("The camera could not start. Check its connection and try again.") }
            } catch {
                stopSession()
                onError(error.localizedDescription)
            }
        }
    }

    func stop() { sessionQueue.async { [self] in stopSession() } }

    func recalibrate(sensitivity: Double) {
        visionQueue.async { [self] in detector = BlinkDetector(closedFraction: sensitivity) }
    }

    private func stopSession() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if session.isRunning { session.stopRunning() }
        visionQueue.sync { frameHandler = nil; errorHandler = nil }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frameHandler, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Capture time, not callback arrival time: inference scheduling jitter
        // must not drop the only frame containing a fast blink.
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { return }
        let date = Date()
        autoreleasepool {
            do {
                let observations = try landmarkTracker.detect(CIImage(cvPixelBuffer: buffer))
                visionFailures = 0
                let faces = observations.filter { $0.confidence >= 0.7 && $0.boundingBox.width > 0.12 }
                var measurement: EyeMeasurement?
                var hint: String?
                if faces.count > 1 {
                    hint = "More than one face detected. Keep only your face in view."
                } else if let face = faces.first {
                    let yaw = face.yaw?.doubleValue ?? 0
                    let pitch = face.pitch?.doubleValue ?? 0
                    if landmarkTracker.isSettling {
                        hint = "Adjusting to your head tilt. Hold your natural posture briefly."
                    } else if abs(yaw) > 0.85 || abs(pitch) > 0.65 {
                        hint = "Turn slightly toward the camera so both eyes remain visible."
                    } else if let landmarks = face.landmarks,
                              let left = landmarks.leftEye, let right = landmarks.rightEye {
                        let width = Double(CVPixelBufferGetWidth(buffer)) * face.boundingBox.width
                        let height = Double(CVPixelBufferGetHeight(buffer)) * face.boundingBox.height
                        func ratio(_ region: VNFaceLandmarkRegion2D) -> Double? {
                            EyeGeometry.aspectRatio(region.normalizedPoints.map {
                                LandmarkPoint(x: $0.x * width, y: $0.y * height)
                            })
                        }
                        if let l = ratio(left), let r = ratio(right) {
                            measurement = EyeMeasurement(left: l, right: r, yaw: yaw, pitch: pitch)
                        }
                    }
                }
                if measurement == nil && hint == nil { hint = "Keep your face visible and use even lighting." }
                frameHandler(Frame(date: date, result: detector.process(measurement, at: timestamp), hint: hint))
            } catch {
                visionFailures += 1
                frameHandler(Frame(date: date, result: detector.process(nil, at: timestamp), hint: "Unable to read eye landmarks. Adjust your lighting."))
                if visionFailures == 30 { errorHandler?("Eye tracking failed: \(error.localizedDescription)") }
            }
        }
    }

    private enum CameraError: LocalizedError {
        case unavailable, configuration
        var errorDescription: String? {
            switch self {
            case .unavailable: return "No camera is available. Connect a camera or choose another in Settings."
            case .configuration: return "This camera does not support the required video capture configuration."
            }
        }
    }
}

/// Stabilize the pixels before landmark inference. Merely rotating the measured
/// eye contour cannot correct landmark errors caused by a tilted input face.
final class UprightFaceLandmarks {
    private var correction = 0.0
    private var center: CGPoint?
    private(set) var isSettling = false

    func detect(_ image: CIImage) throws -> [VNFaceObservation] {
        let extent = image.extent
        let pivot = center ?? CGPoint(x: extent.midX, y: extent.midY)
        let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: -correction).translatedBy(x: -pivot.x, y: -pivot.y)
        let aligned = image.transformed(by: transform).cropped(to: extent)
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(ciImage: aligned, orientation: .up).perform([request])
        let faces = request.results ?? []
        guard faces.count == 1, let face = faces.first else {
            correction = 0; center = nil; isSettling = false
            return faces
        }
        center = CGPoint(x: face.boundingBox.midX * extent.width + extent.minX,
                         y: face.boundingBox.midY * extent.height + extent.minY).applying(transform.inverted())
        var residual = face.roll?.doubleValue ?? 0
        // The eye line gives a continuous estimate; Vision's reported roll can
        // be quantized. Averaging each eye also avoids changes during a blink.
        if let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye,
           left.pointCount > 0, right.pointCount > 0 {
            func mean(_ eye: VNFaceLandmarkRegion2D) -> CGPoint {
                let sum = eye.normalizedPoints.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y))
                }
                return CGPoint(x: sum.x / CGFloat(eye.pointCount), y: sum.y / CGFloat(eye.pointCount))
            }
            let l = mean(left), r = mean(right)
            residual = atan2((r.y - l.y) * face.boundingBox.height * extent.height,
                             (r.x - l.x) * face.boundingBox.width * extent.width)
            if residual > .pi / 2 { residual -= .pi }
            if residual < -.pi / 2 { residual += .pi }
        }
        isSettling = abs(residual) > 0.12
        correction = min(.pi / 2, max(-.pi / 2, correction + residual * 0.8))
        return faces
    }
}
