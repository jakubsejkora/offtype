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
        addItem(to: menu, "Correct Last Dictation…", #selector(correctLast), key: "e")
        addItem(to: menu, "Run Learning Demo", #selector(runLearningDemo))
        menu.addItem(.separator())
        addItem(to: menu, "Toggle Big-Screen Mirror", #selector(toggleMirror), key: "m")
        addItem(to: menu, "Run HUD Demo (mock)", #selector(runHUDDemo))
        addItem(to: menu, "Stop Demos", #selector(stopDemos))
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

    // MARK: - Actions

    /// One-tap correction: edit the last result to what it should have been, and
    /// Offtype crystallizes a durable rule from the diff.
    @objc private func correctLast() {
        let alert = NSAlert()
        alert.messageText = "Correct the last dictation"
        alert.informativeText = "Edit it to what it should have been. Offtype learns a rule so it never makes that mistake again — applied next time with zero tokens."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = appState.lastFinalText
        field.placeholderString = "Corrected text"
        alert.accessoryView = field
        alert.addButton(withTitle: "Learn")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.learn(correctedText: field.stringValue)
        }
    }

    @objc private func runLearningDemo() { appState.runLearningDemo() }
    @objc private func toggleMirror() { appState.toggleMirror() }
    @objc private func runHUDDemo() { appState.startHUDDemo() }
    @objc private func stopDemos() { appState.stopHUDDemo() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only; pairs with LSUIElement
app.run()
