#if os(macOS)
import AppKit

@main
@MainActor
enum KumquatApp {
    /// Kept alive for the app's lifetime; NSApplication holds its delegate weakly.
    private static var delegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
#else
@main
enum KumquatApp {
    static func main() {
        print("The Kumquat app requires macOS. Use kumquat-cli on other platforms.")
    }
}
#endif
