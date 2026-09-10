import AppKit

@main
enum ShushApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.finishLaunching()

        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: ApplicationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Shush finished launching")
        NSApp.setActivationPolicy(.accessory)

        let controller = ApplicationController()
        applicationController = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationController?.stop()
    }
}
