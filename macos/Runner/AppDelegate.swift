import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    private var bridge: BlinkBridge? { (mainFlutterWindow as? MainFlutterWindow)?.blinkBridge }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if bridge?.permitsTermination == true { return .terminateNow }
        return bridge?.requestQuit() == true ? .terminateLater : .terminateNow
    }
    override func applicationWillTerminate(_ notification: Notification) { bridge?.shutdown() }
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bridge?.showDashboard()
        return true
    }
}
