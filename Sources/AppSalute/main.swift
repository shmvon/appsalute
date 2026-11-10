import Cocoa
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var tapRetryTimer: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Agent app: no dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.reset()
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ControlAltTab.log"))
        _ = SwitcherState.shared // Start tracking app activation order right away
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "AppSalute")
        }

        statusMenu.delegate = self
        statusItem?.menu = statusMenu

        // Silent check on launch: never show startup popups or alerts.
        let trusted = AXWindowService.isProcessTrusted(prompt: false)
        DebugLog.write("Launch. Accessibility trusted (silent) = \(trusted)")

        EventTapManager.shared.registerHotKey()
        if !trusted || !EventTapManager.shared.start() {
            startTapRetryTimer()
        }
        rebuildMenu()
    }

    /// Background check so if the user enables Accessibility in System Settings, the event tap starts automatically.
    private func startTapRetryTimer() {
        tapRetryTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] t in
            guard AXWindowService.isProcessTrusted(prompt: false) else { return }
            if EventTapManager.shared.start() {
                t.invalidate()
                self?.tapRetryTimer = nil
                Task { @MainActor in
                    SwitcherState.shared.refreshWindowsForCurrentApps()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tapRetryTimer = timer
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if AXWindowService.isProcessTrusted(prompt: false) && !EventTapManager.shared.isRunning {
            _ = EventTapManager.shared.start()
        }
        rebuildMenu()
    }

    /// Set to true during development to reveal extra TCC diagnostic items in the menu bar.
    private let showDeveloperMenuOptions = false

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        let trusted = AXWindowService.isProcessTrusted(prompt: false)
        let tapActive = EventTapManager.shared.isRunning

        let statusTitle: String
        if trusted && tapActive {
            statusTitle = "Accessibility status: active ✓"
        } else if trusted {
            statusTitle = "Accessibility status: granted (standby)"
        } else {
            statusTitle = "Accessibility status: not granted ✗"
        }

        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusMenu.addItem(statusLine)

        let openSettingsItem = NSMenuItem(title: "Open Accessibility settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openSettingsItem.target = self
        statusMenu.addItem(openSettingsItem)

        if showDeveloperMenuOptions {
            let checkItem = NSMenuItem(title: "Check permission status", action: #selector(checkPermissionStatus), keyEquivalent: "")
            checkItem.target = self
            statusMenu.addItem(checkItem)

            let registerItem = NSMenuItem(title: "Register app in Accessibility settings", action: #selector(registerInAccessibility), keyEquivalent: "")
            registerItem.target = self
            statusMenu.addItem(registerItem)

            let revealItem = NSMenuItem(title: "Reveal AppSalute.app in Finder", action: #selector(revealAppInFinder), keyEquivalent: "")
            revealItem.target = self
            statusMenu.addItem(revealItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open AppSalute", action: #selector(openSwitcher), keyEquivalent: "")
        openItem.target = self
        statusMenu.addItem(openItem)

        let confirmReturnItem = NSMenuItem(
            title: "Confirm selection with return",
            action: #selector(toggleConfirmWithReturn),
            keyEquivalent: ""
        )
        confirmReturnItem.target = self
        confirmReturnItem.state = Preferences.shared.confirmWithReturn ? .on : .off
        statusMenu.addItem(confirmReturnItem)

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusMenu.addItem(launchAtLoginItem)

        statusMenu.addItem(NSMenuItem.separator())

        let shortcutsItem = NSMenuItem(
            title: "Shortcuts",
            action: #selector(openShortcutsDialog),
            keyEquivalent: ""
        )
        shortcutsItem.target = self
        statusMenu.addItem(shortcutsItem)

        let excludedAppsItem = NSMenuItem(
            title: "Excluded apps",
            action: #selector(openExcludedAppsDialog),
            keyEquivalent: ""
        )
        excludedAppsItem.target = self
        statusMenu.addItem(excludedAppsItem)

        statusMenu.addItem(NSMenuItem.separator())

        // No keyEquivalent "q" so pressing Cmd+Q inside the switcher quits the selected app, not AppSalute.
        let quitItem = NSMenuItem(title: "Quit AppSalute", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    @objc private func checkPermissionStatus() {
        let trusted = AXWindowService.isProcessTrusted(prompt: false)
        if trusted {
            _ = EventTapManager.shared.start()
            Task { @MainActor in
                SwitcherState.shared.refreshWindowsForCurrentApps()
            }
        } else {
            startTapRetryTimer()
        }
        rebuildMenu()
    }

    @objc private func registerInAccessibility() {
        _ = AXWindowService.isProcessTrusted(prompt: true)
        startTapRetryTimer()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTapRetryTimer()
    }

    @objc private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func toggleConfirmWithReturn() {
        Preferences.shared.confirmWithReturn.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            DebugLog.write("Launch at login toggle failed: \(error)")
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        DebugLog.write("Launch at login status = \(service.status.rawValue)")
        rebuildMenu()
    }

    @objc private func openShortcutsDialog() {
        DispatchQueue.main.async { [weak self] in
            ShortcutsPanel.shared.present {
                self?.rebuildMenu()
            }
        }
    }

    @objc private func openExcludedAppsDialog() {
        DispatchQueue.main.async {
            ExcludedAppsPanel.shared.present()
        }
    }

    @objc private func openSwitcher() {
        DispatchQueue.main.async { SwitcherPanel.shared.showInteractive() }
    }

    @objc private func quitApp() {
        EventTapManager.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}
