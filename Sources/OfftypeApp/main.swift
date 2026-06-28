import AppKit
import OfftypeCore

// Menu-bar (LSUIElement) entry point. Top-level code in `main.swift` runs on the
// main actor, so it can construct the @MainActor delegate + app state directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var executeItem: NSMenuItem?
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        item.button?.toolTip = "Offtype — every correction becomes a rule"
        item.menu = buildMenu()
        statusItem = item

        appState.start()
        // OnboardingWindow.presentIfNeeded()  // re-enabled when feat/onboarding merges
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

        let cu = NSMenuItem(title: "Computer Use (Gemini 3.5)", action: nil, keyEquivalent: "")
        cu.submenu = buildComputerUseMenu()
        menu.addItem(cu)

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

    private func buildComputerUseMenu() -> NSMenu {
        let m = NSMenu()
        addItem(to: m, "Set Gemini API Key…", #selector(setGeminiKey))
        addItem(to: m, "Run Command…", #selector(runCUCommand))
        addItem(to: m, "Replay Last Macro (0 Gemini calls)", #selector(replayMacro))
        m.addItem(.separator())
        let exec = NSMenuItem(title: "Execute Actions for Real", action: #selector(toggleCUExecute), keyEquivalent: "")
        exec.target = self
        exec.state = .off
        m.addItem(exec)
        executeItem = exec
        addItem(to: m, "Confirm Pending Action", #selector(confirmCU))
        addItem(to: m, "Stop Computer-Use", #selector(stopCU))
        return m
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Dictation actions

    /// One-tap correction: edit the last result to what it should have been, and
    /// Offtype crystallizes a durable rule from the diff.
    @objc private func correctLast() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = appState.lastFinalText
        field.placeholderString = "Corrected text"
        if runDialog(
            "Correct the last dictation",
            "Edit it to what it should have been. Offtype learns a rule so it never makes that mistake again — applied next time with zero tokens.",
            accessory: field, confirm: "Learn"
        ) {
            appState.learn(correctedText: field.stringValue)
        }
    }

    @objc private func runLearningDemo() { appState.runLearningDemo() }
    @objc private func toggleMirror() { appState.toggleMirror() }
    @objc private func runHUDDemo() { appState.startHUDDemo() }
    @objc private func stopDemos() { appState.stopHUDDemo() }

    // MARK: - Computer-use actions

    @objc private func setGeminiKey() {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "AIza…"
        if runDialog(
            "Set your Gemini API key",
            "Stored only in your macOS Keychain (BYOK). Use a key restricted to the Generative Language API.",
            accessory: field, confirm: "Save"
        ) {
            appState.setGeminiAPIKey(field.stringValue)
        }
    }

    @objc private func runCUCommand() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "e.g. file a task called “Offtype demo”"
        let note = appState.computerUseExecuteForReal
            ? "Gemini 3.5 acts on your Mac; the verified sequence becomes a macro that replays with 0 Gemini calls."
            : "Dry-run: plans + crystallizes a macro without moving your mouse. Enable “Execute Actions for Real” for a live run."
        if runDialog("Computer-use command", note, accessory: field, confirm: "Run") {
            appState.runComputerUseCommand(field.stringValue)
        }
    }

    @objc private func replayMacro() { appState.replayLastMacro() }
    @objc private func confirmCU() { appState.acknowledgeComputerUseConfirmation() }
    @objc private func stopCU() { appState.cancelComputerUse() }

    @objc private func toggleCUExecute() {
        let newState = !appState.computerUseExecuteForReal
        appState.setComputerUseExecuteForReal(newState)
        executeItem?.state = newState ? .on : .off
    }

    // MARK: - Helpers

    /// Show a modal alert with a text accessory; returns true if confirmed.
    private func runDialog(_ title: String, _ info: String, accessory: NSView, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.accessoryView = accessory
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only; pairs with LSUIElement
app.run()
