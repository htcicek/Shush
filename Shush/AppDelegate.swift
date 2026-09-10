import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: ApplicationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = ApplicationController()
        applicationController = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationController?.stop()
    }
}
