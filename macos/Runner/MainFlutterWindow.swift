import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
    var blinkBridge: BlinkBridge?

    override func awakeFromNib() {
        let controller = FlutterViewController()
        contentViewController = controller
        setContentSize(NSSize(width: 1160, height: 830))
        minSize = NSSize(width: 840, height: 650)
        title = "BlinkMonitor"
        titlebarAppearsTransparent = true
        backgroundColor = NSColor(red: 0.965, green: 0.973, blue: 0.961, alpha: 1)
        isReleasedWhenClosed = false
        setFrameAutosaveName("BlinkMonitorDashboard")
        if !setFrameUsingName("BlinkMonitorDashboard") { center() }
        RegisterGeneratedPlugins(registry: controller)
        blinkBridge = BlinkBridge(messenger: controller.engine.binaryMessenger, window: self)
        delegate = self
        super.awakeFromNib()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        orderOut(nil)
        return false
    }
}
