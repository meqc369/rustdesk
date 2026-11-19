import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      dummy_method_to_enforce_bundling()
    // https://github.com/leanflutter/window_manager/issues/214
    return false
  }
    
    // Qianchen Desk: clicking the Dock icon brings the device list forward even while a
    // file transfer or remote window is open (otherwise it stays hidden behind them).
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag, let main = mainFlutterWindow {
            main.makeKeyAndOrderFront(nil)
        }
        return true
    }

    override func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if (launched) {
            handle_applicationShouldOpenUntitledFile();
        }
        return true
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        launched = true;
        NSApplication.shared.activate(ignoringOtherApps: true);
    }
}
