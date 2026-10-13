import AVFoundation
import Foundation
import Vision

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
    private var lastFrameTime: TimeInterval = 0
    private var visionFailures = 0

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
                if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    try device.lockForConfiguration()
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    device.unlockForConfiguration()
                }
                visionQueue.sync {
                    detector = BlinkDetector(closedFraction: sensitivity)
                    frameHandler = onFrame; errorHandler = onError
                    lastFrameTime = 0; visionFailures = 0
                }
                for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
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
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard timestamp - lastFrameTime >= 1.0 / 35 else { return }
        lastFrameTime = timestamp
        let date = Date()
        autoreleasepool {
            do {
                let request = VNDetectFaceLandmarksRequest()
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                visionFailures = 0
                let faces = (request.results ?? []).filter { $0.confidence >= 0.7 && $0.boundingBox.width > 0.12 }
                var measurement: EyeMeasurement?
                var hint: String?
                if faces.count > 1 {
                    hint = "More than one face detected. Keep only your face in view."
                } else if let face = faces.first {
                    let yaw = abs(face.yaw?.doubleValue ?? 0)
                    let pitch = abs(face.pitch?.doubleValue ?? 0)
                    if yaw > 0.45 || pitch > 0.4 {
                        hint = "Look toward the camera for reliable tracking."
                    } else if let landmarks = face.landmarks,
                              let left = landmarks.leftEye, let right = landmarks.rightEye {
                        let width = Double(CVPixelBufferGetWidth(buffer)) * face.boundingBox.width
                        let height = Double(CVPixelBufferGetHeight(buffer)) * face.boundingBox.height
                        func ratio(_ region: VNFaceLandmarkRegion2D) -> Double? {
                            EyeGeometry.aspectRatio(region.normalizedPoints.map {
                                LandmarkPoint(x: $0.x * width, y: $0.y * height)
                            })
                        }
                        if let l = ratio(left), let r = ratio(right) { measurement = EyeMeasurement(left: l, right: r) }
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
