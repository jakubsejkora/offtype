import AppKit
import OfftypeCore

// Menu-bar (LSUIElement) entry point. Top-level code in `main.swift` runs on the
// main actor, so it can construct the @MainActor delegate + app state directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        item.button?.toolTip = "Offtype — every correction becomes a rule"
        item.menu = buildMenu()
        statusItem = item

        appState.start()
        Log.app.info("Offtype launched")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Hold Right-Command to talk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        addItem(to: menu, "Toggle Big-Screen Mirror", #selector(toggleMirror), key: "m")
        addItem(to: menu, "Run HUD Demo", #selector(runDemo))
        addItem(to: menu, "Stop HUD Demo", #selector(stopDemo))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Offtype",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleMirror() { appState.toggleMirror() }
    @objc private func runDemo() { appState.startHUDDemo() }
    @objc private func stopDemo() { appState.stopHUDDemo() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only; pairs with LSUIElement
app.run()
