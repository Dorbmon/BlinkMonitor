import Cocoa
import FlutterMacOS
import AVFoundation

/// Native camera lifecycle, Vision detection, and menu bar integration. Only
/// numeric measurements cross the platform channel; images never leave Swift.
@MainActor
final class BlinkBridge: NSObject, FlutterStreamHandler {
    private let camera = CameraService()
    private let control: FlutterMethodChannel
    private let events: FlutterEventChannel
    private var sink: FlutterEventSink?
    private var runID: String?
    private weak var window: NSWindow?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observers: [NSObjectProtocol] = []
    private var running = false
    var permitsTermination = false

    init(messenger: FlutterBinaryMessenger, window: NSWindow) {
        self.window = window
        control = FlutterMethodChannel(name: "com.dorbmon.blinkmonitor/control", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "com.dorbmon.blinkmonitor/events", binaryMessenger: messenger)
        super.init()
        control.setMethodCallHandler { [weak self] call, reply in self?.handle(call, reply: reply) }
        events.setStreamHandler(self)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "BlinkMonitor")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = " Paused"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runID = nil
                self?.camera.stop()
                self?.emit(["type": "action", "action": "sleep"])
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit(["type": "action", "action": "wake"]) }
        })
    }

    nonisolated func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        // Flutter dispatches platform channel handlers on the macOS main thread.
        MainActor.assumeIsolated {
            sink = events
            return nil
        }
    }

    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        MainActor.assumeIsolated {
            sink = nil; runID = nil; camera.stop()
            return nil
        }
    }

    private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "storageDirectory": reply(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)
        case "cameras": reply(CameraService.cameras().map { ["id": $0.id, "name": $0.name] })
        case "start":
            guard let id = args["runId"] as? String, !id.isEmpty,
                  let cameraID = args["cameraId"] as? String,
                  let sensitivity = args["sensitivity"] as? Double, sensitivity.isFinite, (0.4...0.8).contains(sensitivity) else {
                reply(FlutterError(code: "arguments", message: "Invalid camera start parameters.", details: nil)); return
            }
            runID = id
            Task {
                let authorization = AVCaptureDevice.authorizationStatus(for: .video)
                let allowed = authorization == .notDetermined
                    ? await AVCaptureDevice.requestAccess(for: .video) : authorization == .authorized
                guard runID == id else { reply(nil); return }
                guard allowed else {
                    runID = nil
                    reply(FlutterError(code: "permission_denied", message: "Camera permission denied. Enable BlinkMonitor in System Settings → Privacy & Security → Camera, then try again.", details: nil)); return
                }
                camera.start(deviceID: cameraID, sensitivity: sensitivity, onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == id else { return }
                        let state: String
                        switch frame.result.state {
                        case .noFace: state = "noFace"
                        case .calibrating: state = "calibrating"
                        case .tracking: state = "tracking"
                        }
                        self.emit(["type": "frame", "runId": id, "timestamp": frame.date.timeIntervalSince1970,
                                   "state": state, "didBlink": frame.result.didBlink,
                                   "trackedDuration": frame.result.trackedDuration,
                                   "calibrationProgress": frame.result.calibrationProgress,
                                   "openness": frame.result.openness, "hint": frame.hint ?? ""])
                    }
                }, onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == id else { return }
                        self.emit(["type": "error", "runId": id, "message": message])
                        self.camera.stop(); self.runID = nil
                    }
                })
                reply(nil)
            }
        case "stop": runID = nil; camera.stop(); reply(nil)
        case "recalibrate":
            guard let sensitivity = args["sensitivity"] as? Double, sensitivity.isFinite, (0.4...0.8).contains(sensitivity) else {
                reply(FlutterError(code: "arguments", message: "Sensitivity must be between 0.4 and 0.8.", details: nil)); return
            }
            camera.recalibrate(sensitivity: sensitivity); reply(nil)
        case "updateStatus":
            let title = args["title"] as? String ?? "Paused"
            let status = args["status"] as? String ?? ""
            running = args["running"] as? Bool ?? false
            statusItem.button?.title = " \(title)"
            statusItem.button?.toolTip = "BlinkMonitor · \(status)\nClick for dashboard. Right-click for controls."
            statusItem.button?.setAccessibilityLabel("BlinkMonitor, \(title), \(status)")
            reply(nil)
        case "showDashboard": showDashboard(); reply(nil)
        case "openCameraSettings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
            reply(nil)
        case "terminate":
            permitsTermination = true
            camera.stop()
            reply(nil)
            NSApp.reply(toApplicationShouldTerminate: true)
            NSApp.terminate(nil)
        default: reply(FlutterMethodNotImplemented)
        }
    }

    func requestQuit() -> Bool {
        guard sink != nil else { return false }
        emit(["type": "action", "action": "quit"])
        // The Dart side flushes its archive before acknowledging termination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.permitsTermination else { return }
            self.permitsTermination = true
            self.camera.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return true
    }

    func shutdown() {
        camera.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func emit(_ event: [String: Any]) { sink?(event) }
    @objc private func toggle() { emit(["type": "action", "action": "toggle"]) }
    @objc private func settings() { showDashboard(); emit(["type": "action", "action": "settings"]) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func statusClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { showDashboard(); return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard", action: #selector(showDashboard), keyEquivalent: "")
        menu.addItem(withTitle: running ? "Pause Monitoring" : "Start Monitoring", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit BlinkMonitor", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
