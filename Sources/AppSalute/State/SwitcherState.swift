import Cocoa
import Combine

/// Model representing an open application in the switcher.
public struct AppItem: Identifiable, Equatable {
    public var id: pid_t { app.processIdentifier }
    public let app: NSRunningApplication
    public var name: String { app.localizedName ?? "App" }
    public var icon: NSImage { app.icon ?? NSWorkspace.shared.icon(for: .application) }
    public var windows: [WindowInfo] = []

    public static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id && lhs.windows == rhs.windows
    }
}

/// Navigation focus position.
public enum FocusTarget: Equatable {
    case closeAll
    case app(index: Int)
    case window(appIndex: Int, windowIndex: Int)
}

/// Central state controller managing the switcher state and operations.
@MainActor
public final class SwitcherState: ObservableObject {
    public static let shared = SwitcherState()

    @Published public private(set) var isVisible: Bool = false
    @Published public private(set) var isAccessibilityTrusted: Bool = false
    @Published public private(set) var apps: [AppItem] = []
    @Published public private(set) var focus: FocusTarget = .app(index: 0) {
        didSet { if focus != .closeAll { closeAllArmed = false } }
    }
    @Published public private(set) var inactiveAppCount: Int = 0
    @Published public private(set) var inactiveAppNames: [String] = []
    /// True after a first "Close all inactive apps" request; the next request actually quits the apps.
    @Published public private(set) var closeAllArmed: Bool = false

    private var lastAppIndex: Int = 0
    private let windowService = AXWindowService.shared
    /// App PIDs ordered by most recent activation, most recent first.
    private var recentPIDs: [pid_t] = []

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication {
            recentPIDs = [front.processIdentifier]
        }
        setupWorkspaceObservers()
    }

    private func setupWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            let pid = app.processIdentifier
            Task { @MainActor in
                self.recentPIDs.removeAll { $0 == pid }
                self.recentPIDs.insert(pid, at: 0)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let terminatedApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self.recentPIDs.removeAll { $0 == terminatedApp.processIdentifier }
                self.handleAppTerminated(pid: terminatedApp.processIdentifier)
            }
        }
    }

    /// Triggers or cycles the switcher when the shortcut is pressed.
    public func triggerSwitcher(backward: Bool = false) {
        let trustedNow = AXWindowService.isProcessTrusted(prompt: false)
        if trustedNow && !EventTapManager.shared.isRunning {
            _ = EventTapManager.shared.start()
        }
        let permissionJustGranted = (trustedNow && !isAccessibilityTrusted)
        isAccessibilityTrusted = trustedNow

        if !isVisible {
            loadRunningApps()
            if apps.isEmpty { return }
            isVisible = true
            let initialIndex = apps.count > 1 ? 1 : 0
            lastAppIndex = initialIndex
            focus = .app(index: initialIndex)
        } else {
            if permissionJustGranted {
                refreshWindowsForCurrentApps()
            }
            cycleApp(backward: backward)
        }
    }

    public func refreshWindowsForCurrentApps() {
        isAccessibilityTrusted = AXWindowService.isProcessTrusted(prompt: false)
        for i in apps.indices {
            apps[i].windows = windowService.windows(for: apps[i].id)
        }
        updateInactiveCount()
    }

    /// Refreshes running regular applications in MRU order, excluding user-excluded apps.
    public func loadRunningApps() {
        isAccessibilityTrusted = AXWindowService.isProcessTrusted(prompt: false)
        DebugLog.write("Loading apps. Accessibility trusted = \(isAccessibilityTrusted)")
        let myPID = ProcessInfo.processInfo.processIdentifier
        let prefs = Preferences.shared

        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                !app.isTerminated &&
                app.processIdentifier != myPID &&
                !prefs.isAppExcluded(bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "")
            }
            .enumerated()
            .sorted { lhs, rhs in
                // Most recently used first; apps never activated since launch keep the system order after them.
                let lRank = recentPIDs.firstIndex(of: lhs.element.processIdentifier) ?? Int.max
                let rRank = recentPIDs.firstIndex(of: rhs.element.processIdentifier) ?? Int.max
                return lRank != rRank ? lRank < rRank : lhs.offset < rhs.offset
            }
            .map(\.element)

        apps = running.map { app in
            var item = AppItem(app: app)
            item.windows = windowService.windows(for: app.processIdentifier)
            return item
        }

        updateInactiveCount()
    }

    private func updateInactiveCount() {
        let inactive = apps.filter { isAppInactive($0) }
        inactiveAppCount = inactive.count
        inactiveAppNames = inactive.map(\.name)
        DebugLog.write("Inactive apps: \(inactive.map(\.name))")
    }

    /// Evaluates if an app is truly inactive. Running apps that are not minimized or hidden are never inactive.
    public func isAppInactive(_ item: AppItem) -> Bool {
        let app = item.app
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return false }
        if app.bundleIdentifier == "com.apple.finder" { return false }
        if Preferences.shared.isAppExcluded(bundleIdentifier: app.bundleIdentifier, appName: item.name) { return false }
        if app.isActive { return false }

        // A visible app with any unminimized window (empty ones included) must NEVER close
        if !app.isHidden {
            let hasUnminimizedWindow = item.windows.contains { !$0.isMinimized }
            return !hasUnminimizedWindow && !windowService.hasRealWindows(for: app.processIdentifier)
        }

        // A hidden app is inactive unless it has an unminimized window with real content;
        // open dialogs, empty tabs and untitled documents don't count.
        return !item.windows.contains { !$0.isMinimized && !$0.isPlaceholder }
    }

    /// Activates an app. Without a usable window it asks the app to reopen one, like a Dock click does
    /// (e.g. PowerPoint shows its start screen); plain activation would show nothing.
    private func activateApp(_ item: AppItem) {
        item.app.unhide()
        guard !item.windows.contains(where: { !$0.isMinimized }), let bundleURL = item.app.bundleURL else {
            item.app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    /// First request arms the action and shows which apps will quit; the second request quits them.
    public func requestCloseAll() {
        guard isVisible else { return }
        focus = .closeAll
        if closeAllArmed {
            closeAllInactiveApps()
        } else if inactiveAppCount > 0 {
            closeAllArmed = true
        }
    }

    /// Quits the inactive apps without the confirmation step, e.g. on a double click.
    public func confirmCloseAll() {
        guard isVisible, inactiveAppCount > 0 else { return }
        closeAllInactiveApps()
    }

    /// Returns true when committing should instead keep the switcher open to confirm "Close all inactive apps".
    public func needsCloseAllConfirmation() -> Bool {
        guard isVisible, focus == .closeAll, !closeAllArmed, inactiveAppCount > 0 else { return false }
        closeAllArmed = true
        return true
    }

    /// Closes all applications in the switcher that are truly inactive.
    public func closeAllInactiveApps() {
        closeAllArmed = false
        let inactive = apps.filter { isAppInactive($0) }
        DebugLog.write("Closing inactive apps: \(inactive.map(\.name))")
        for item in inactive {
            _ = item.app.terminate()
        }
        loadRunningApps()
        if apps.isEmpty {
            dismiss()
            SwitcherPanel.shared.hide()
        } else {
            focus = .app(index: 0)
        }
    }

    public func cycleApp(backward: Bool) {
        guard !apps.isEmpty else { return }
        let currentIndex: Int
        switch focus {
        case .closeAll:
            currentIndex = lastAppIndex
        case .app(let idx):
            currentIndex = idx
        case .window(let appIdx, _):
            currentIndex = appIdx
        }

        let nextIndex: Int
        if backward {
            nextIndex = (currentIndex - 1 + apps.count) % apps.count
        } else {
            nextIndex = (currentIndex + 1) % apps.count
        }

        lastAppIndex = nextIndex
        focus = .app(index: nextIndex)
    }

    /// Selects an app or window directly, e.g. from a mouse click.
    public func select(_ target: FocusTarget) {
        guard isVisible else { return }
        switch target {
        case .closeAll:
            break
        case .app(let idx):
            guard idx < apps.count else { return }
            lastAppIndex = idx
        case .window(let appIdx, let winIdx):
            guard appIdx < apps.count, winIdx < apps[appIdx].windows.count else { return }
            lastAppIndex = appIdx
        }
        focus = target
    }

    public func moveSelectionLeft() {
        cycleApp(backward: true)
    }

    public func moveSelectionRight() {
        cycleApp(backward: false)
    }

    public func moveSelectionDown() {
        guard !apps.isEmpty else { return }
        switch focus {
        case .closeAll:
            let targetIdx = min(lastAppIndex, max(0, apps.count - 1))
            focus = .app(index: targetIdx)
        case .app(let appIdx):
            let currentApp = apps[appIdx]
            if !currentApp.windows.isEmpty {
                focus = .window(appIndex: appIdx, windowIndex: 0)
            }
        case .window(let appIdx, let winIdx):
            let windowCount = apps[appIdx].windows.count
            if winIdx + 1 < windowCount {
                focus = .window(appIndex: appIdx, windowIndex: winIdx + 1)
            }
        }
    }

    public func moveSelectionUp() {
        guard !apps.isEmpty else { return }
        switch focus {
        case .closeAll:
            break
        case .app(let appIdx):
            lastAppIndex = appIdx
            focus = .closeAll
        case .window(let appIdx, let winIdx):
            if winIdx > 0 {
                focus = .window(appIndex: appIdx, windowIndex: winIdx - 1)
            } else {
                focus = .app(index: appIdx)
            }
        }
    }

    /// Brings the currently focused app or window to the front without leaving or dismissing the switcher.
    public func bringToFrontWithoutLeaving() {
        guard isVisible else { return }

        switch focus {
        case .closeAll:
            requestCloseAll()
            SwitcherPanel.shared.assertFrontmostPanel()
        case .app(let appIdx):
            guard appIdx < apps.count else { return }
            let target = apps[appIdx]
            activateApp(target)
            let appElement = AXUIElementCreateApplication(target.app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXFrontmost" as CFString, kCFBooleanTrue)

            if let firstWindow = target.windows.first {
                _ = windowService.raiseWindow(firstWindow, in: target.app)
            } else {
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success ||
                   AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &winRef) == .success,
                   let win = winRef {
                    AXUIElementPerformAction(win as! AXUIElement, kAXRaiseAction as CFString)
                }
            }
            SwitcherPanel.shared.assertFrontmostPanel()
        case .window(let appIdx, let winIdx):
            guard appIdx < apps.count, winIdx < apps[appIdx].windows.count else { return }
            let target = apps[appIdx]
            let window = target.windows[winIdx]
            _ = windowService.raiseWindow(window, in: target.app)
            SwitcherPanel.shared.assertFrontmostPanel()
        }
    }

    /// Closes the currently selected window via Cmd+W, Opt+W, or Ctrl+Opt+W.
    public func closeSelectedWindow() {
        guard isVisible else { return }

        switch focus {
        case .closeAll:
            requestCloseAll()
            SwitcherPanel.shared.refocusPanel()
        case .window(let appIdx, let winIdx):
            guard appIdx < apps.count, winIdx < apps[appIdx].windows.count else { return }
            let targetWindow = apps[appIdx].windows[winIdx]
            let closed = windowService.closeWindow(targetWindow)

            if closed {
                apps[appIdx].windows.remove(at: winIdx)
                if apps[appIdx].windows.isEmpty {
                    focus = .app(index: appIdx)
                } else {
                    let newWinIdx = min(winIdx, apps[appIdx].windows.count - 1)
                    focus = .window(appIndex: appIdx, windowIndex: newWinIdx)
                }
                updateInactiveCount()
            }
            SwitcherPanel.shared.refocusPanel()

        case .app(let appIdx):
            guard appIdx < apps.count, let firstWindow = apps[appIdx].windows.first else { return }
            let closed = windowService.closeWindow(firstWindow)
            if closed {
                apps[appIdx].windows.removeFirst()
                updateInactiveCount()
            }
            SwitcherPanel.shared.refocusPanel()
        }
    }

    /// Quits the currently selected application via Cmd+Q, Opt+Q, or Ctrl+Opt+Q.
    public func quitSelectedApp() {
        guard isVisible else { return }

        let targetAppIdx: Int
        switch focus {
        case .closeAll:
            requestCloseAll()
            SwitcherPanel.shared.refocusPanel()
            return
        case .app(let idx): targetAppIdx = idx
        case .window(let idx, _): targetAppIdx = idx
        }

        guard targetAppIdx < apps.count else { return }
        let appItem = apps[targetAppIdx]
        var ok = appItem.app.terminate()
        if !ok {
            ok = appItem.app.forceTerminate()
        }
        handleAppTerminated(pid: appItem.id)
        SwitcherPanel.shared.refocusPanel()
    }

    private func handleAppTerminated(pid: pid_t) {
        guard let idx = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps.remove(at: idx)
        updateInactiveCount()

        if apps.isEmpty {
            dismiss()
            SwitcherPanel.shared.hide()
        } else {
            let nextIndex = min(idx, apps.count - 1)
            lastAppIndex = nextIndex
            focus = .app(index: nextIndex)
            SwitcherPanel.shared.refocusPanel()
        }
    }

    /// Commits the active selection and raises the window or activates the app, then dismisses the switcher.
    public func commit() {
        guard isVisible else { return }
        defer { dismiss() }

        switch focus {
        case .closeAll:
            closeAllInactiveApps()
        case .app(let appIdx):
            guard appIdx < apps.count else { return }
            activateApp(apps[appIdx])
        case .window(let appIdx, let winIdx):
            guard appIdx < apps.count, winIdx < apps[appIdx].windows.count else { return }
            let app = apps[appIdx].app
            let window = apps[appIdx].windows[winIdx]
            _ = windowService.raiseWindow(window, in: app)
        }
    }

    public func dismiss() {
        closeAllArmed = false
        isVisible = false
        apps.removeAll()
        focus = .app(index: 0)
        lastAppIndex = 0
    }
}
