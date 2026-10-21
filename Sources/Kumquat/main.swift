#if os(macOS)
import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
#else
print("The Kumquat app requires macOS. Use kumquat-cli on other platforms.")
#endif
