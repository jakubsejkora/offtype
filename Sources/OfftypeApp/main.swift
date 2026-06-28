import AppKit
import OfftypeCore

// Menu-bar (LSUIElement) entry point. The composition root that wires modules
// together lives here; for now it stands up the status item so the signed .app
// can hold TCC grants. Real wiring (hotkey → capture → STT → rewrite → inject →
// HUD) is added at M1.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        item.button?.toolTip = "Offtype — every correction becomes a rule"

        let menu = NSMenu()
        menu.addItem(withTitle: "Offtype — ready", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Offtype",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        self.statusItem = item

        Log.app.info("Offtype launched")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only; pairs with LSUIElement
app.run()
