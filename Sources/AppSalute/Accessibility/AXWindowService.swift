import Cocoa
import ApplicationServices

/// Represents an active window belonging to an application.
public struct WindowInfo: Identifiable, Hashable {
    public let id: CGWindowID
    public let ownerPID: pid_t
    public let index: Int
    public let title: String
    public let isMinimized: Bool
    public let isHidden: Bool
    public let axElement: AXUIElement?
    /// A window without real content: an open dialog, an empty tab or an unsaved untitled document.
    public var isPlaceholder: Bool = false

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(index)
    }

    public static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.index == rhs.index
    }
}

/// Service providing Accessibility API window querying and targeted window closing.
public final class AXWindowService {
    public static let shared = AXWindowService()

    private init() {}

    /// Checks if accessibility permission is granted. Never prompts unless explicitly requested.
    public static func isProcessTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Fetches all active windows for a given application PID using Accessibility.
    public func windows(for pid: pid_t) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        // A frozen app would otherwise block the switcher for the default ~6 s AX timeout.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        let cgWindows = windowServerWindows(for: pid)
        let cgByID = Dictionary(cgWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visibleSpaces = currentlyVisibleSpaces()
        let appIsHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            DebugLog.write("AX windows query failed for pid \(pid): AXError \(result.rawValue), trusted = \(AXIsProcessTrusted())")
            return cgFallbackWindows(cgWindows, visibleSpaces: visibleSpaces)
        }

        var windowList: [WindowInfo] = []

        for (idx, window) in axWindows.enumerated() {
            // Filter out non-window roles or unknown utility popups
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role != (kAXWindowRole as String) {
                continue
            }

            var subrole = ""
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let value = subroleRef as? String {
                subrole = value
                if subrole == "AXUnknown" || subrole == "AXSystemDialog" { continue }
            }

            // Retrieve Window ID via _AXUIElementGetWindow private C function or fallback hash
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(window, &windowID)

            // Minimized status
            var minRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
            let isMinimized = (minResult == .success && minRef != nil) ? (minRef as! Bool) : false

            // Phantom windows: listed by AX but never drawn (e.g. PowerPoint's hidden "Untitled" window).
            // Windows of hidden apps are all off screen, so this check only applies to visible apps.
            if !appIsHidden, !isMinimized, let cgWindow = cgByID[windowID], !cgWindow.isReal(visibleSpaces: visibleSpaces) {
                continue
            }

            // Resolve window title from multiple attributes
            let resolvedTitle = resolveWindowTitle(window: window, windowID: windowID, cgTitle: cgByID[windowID]?.name ?? "")

            if windowID == 0 {
                windowID = CGWindowID(abs(window.hashValue) ^ (idx + 1))
            }

            var info = WindowInfo(
                id: windowID,
                ownerPID: pid,
                index: idx,
                title: resolvedTitle,
                isMinimized: isMinimized,
                isHidden: false,
                axElement: window
            )
            info.isPlaceholder = isPlaceholderWindow(window, title: resolvedTitle, subrole: subrole, appName: appName)
            windowList.append(info)
        }

        if windowList.isEmpty { return cgFallbackWindows(cgWindows, visibleSpaces: visibleSpaces) }

        // AX often omits windows on other desktops; add those the window server knows about.
        let knownIDs = Set(windowList.map(\.id))
        for cgWindow in cgWindows where cgWindow.isReal(visibleSpaces: visibleSpaces)
            && !knownIDs.contains(cgWindow.id)
            && visibleSpaces.isDisjoint(with: cgWindow.spaces) {
            windowList.append(WindowInfo(
                id: cgWindow.id,
                ownerPID: pid,
                index: windowList.count,
                title: cgWindow.name.isEmpty ? "Window on another desktop" : cgWindow.name,
                isMinimized: false,
                isHidden: false,
                axElement: nil
            ))
        }
        return windowList
    }

    /// Placeholder titles of windows without content, compared case-insensitively after stripping an " - AppName" suffix.
    private static let placeholderTitlePattern = try! NSRegularExpression(
        pattern: "^(untitled|new tab|new window|start page|speed dial|open|open file|choose a file)( \\d+)?$|^(presentation|document|book|workbook)\\d+$",
        options: [.caseInsensitive]
    )

    /// Detects windows without real content: open dialogs, empty browser tabs and unsaved untitled documents.
    private func isPlaceholderWindow(_ window: AXUIElement, title: String, subrole: String, appName: String) -> Bool {
        if subrole == "AXDialog" || subrole == "AXFloatingWindow" { return true }

        // A window backed by a file is never a placeholder.
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
           let doc = docRef as? String, !doc.isEmpty {
            return false
        }

        var bareTitle = title
        for separator in [" - ", " — ", " – "] where !appName.isEmpty {
            if bareTitle.hasSuffix(separator + appName) {
                bareTitle = String(bareTitle.dropLast((separator + appName).count))
            }
        }
        let range = NSRange(bareTitle.startIndex..., in: bareTitle)
        return Self.placeholderTitlePattern.firstMatch(in: bareTitle, range: range) != nil
    }

    /// Resolves the human-readable title of an AXWindow using kAXTitleAttribute, kAXDocumentAttribute, kAXDescriptionAttribute, and CGWindowList.
    private func resolveWindowTitle(window: AXUIElement, windowID: CGWindowID, cgTitle: String) -> String {
        // 1. Standard AXTitle
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 2. Document URL (e.g., open text document or file path)
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
           let docString = docRef as? String, !docString.isEmpty {
            if let url = URL(string: docString) {
                let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                if !last.isEmpty { return last }
            } else {
                return (docString as NSString).lastPathComponent
            }
        }

        // 3. AXProxy / AXFilename if present
        var filenameRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFilename" as CFString, &filenameRef) == .success,
           let filename = filenameRef as? String, !filename.isEmpty {
            return filename
        }

        // 4. AXDescription
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let desc = descRef as? String {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 5. CGWindowList title by matching CGWindowID
        if !cgTitle.isEmpty {
            return cgTitle
        }

        return "Untitled Window"
    }

    /// A layer-0 window as the window server sees it.
    private struct CGWindowState {
        let id: CGWindowID
        let ownerPID: pid_t
        let name: String
        let ownerName: String
        /// Spaces the window belongs to; empty for ordered-out helper windows, minimized windows and windows of hidden apps.
        let spaces: Set<Int>
        let isOnscreen: Bool
        /// Visible alpha and a usable size.
        let hasUsableShape: Bool

        /// Real windows belong to a Space. On a Space currently shown they must also be drawn on screen;
        /// otherwise they're phantoms, like PowerPoint's hidden "Untitled" window.
        func isReal(visibleSpaces: Set<Int>) -> Bool {
            guard hasUsableShape, !spaces.isEmpty else { return false }
            return isOnscreen || visibleSpaces.isDisjoint(with: spaces)
        }
    }

    /// All layer-0 windows of an app on any Space. Names require Screen Recording permission, so `name` is usually empty.
    private func windowServerWindows(for pid: pid_t) -> [CGWindowState] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let connection = CGSMainConnectionID()
        var out: [CGWindowState] = []
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let wid = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? CGFloat) ?? 1
            let bounds = (entry[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            let spaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, [wid] as CFArray)?
                .takeRetainedValue() as? [Int] ?? []
            out.append(CGWindowState(
                id: wid,
                ownerPID: ownerPID,
                name: (entry[kCGWindowName as String] as? String) ?? "",
                ownerName: (entry[kCGWindowOwnerName as String] as? String) ?? "Window",
                spaces: Set(spaces),
                isOnscreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                hasUsableShape: alpha > 0 && (bounds["Width"] ?? 0) >= 50 && (bounds["Height"] ?? 0) >= 30
            ))
        }
        return out
    }

    /// The Space currently shown on each display.
    private func currentlyVisibleSpaces() -> Set<Int> {
        let connection = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        let current = displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int }
        return current.isEmpty ? [CGSGetActiveSpace(connection)] : Set(current)
    }

    /// Fallback window list from the window server, used when Accessibility returns nothing.
    private func cgFallbackWindows(_ cgWindows: [CGWindowState], visibleSpaces: Set<Int>) -> [WindowInfo] {
        cgWindows.filter { $0.isReal(visibleSpaces: visibleSpaces) }.enumerated().map { idx, cgWindow in
            WindowInfo(
                id: cgWindow.id,
                ownerPID: cgWindow.ownerPID,
                index: idx,
                title: cgWindow.name.isEmpty ? "\(cgWindow.ownerName) — Window \(idx + 1)" : cgWindow.name,
                isMinimized: false,
                isHidden: false,
                axElement: nil
            )
        }
    }

    /// Verifies if an application process has any real window on any Space.
    public func hasRealWindows(for pid: pid_t) -> Bool {
        let visibleSpaces = currentlyVisibleSpaces()
        return windowServerWindows(for: pid).contains { $0.isReal(visibleSpaces: visibleSpaces) }
    }

    /// Closes a specific window using its AXCloseButton, or re-queries AX on the fly if needed.
    @discardableResult
    public func closeWindow(_ window: WindowInfo) -> Bool {
        if let ax = window.axElement, pressCloseButton(on: ax) {
            return true
        }

        // Fallback: dynamically re-query AXUIElementCreateApplication for the owner PID
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement], !axWindows.isEmpty else {
            return false
        }

        // Try matching by CGWindowID first
        for axWin in axWindows {
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWin, &wid)
            if wid != 0 && wid == window.id {
                if pressCloseButton(on: axWin) { return true }
            }
        }

        // Index match only for windows that came from AX; window-server entries have no AX index,
        // and guessing would close the wrong window.
        if window.axElement != nil, window.index < axWindows.count {
            return pressCloseButton(on: axWindows[window.index])
        }
        return false
    }

    /// Finds the live AX element for a window ID, e.g. for a window listed from the window server.
    private func axElement(forWindowID wid: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard wid != 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }
        return axWindows.first { axWin in
            var candidate: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWin, &candidate)
            return candidate == wid
        }
    }

    private func pressCloseButton(on axWindow: AXUIElement) -> Bool {
        var closeButtonRef: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        guard copyResult == .success, let closeButton = closeButtonRef else {
            return false
        }
        let actionResult = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        return actionResult == .success
    }

    /// Raises and focuses a specific window.
    @discardableResult
    public func raiseWindow(_ window: WindowInfo, in app: NSRunningApplication) -> Bool {
        app.unhide()
        app.activate()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXFrontmost" as CFString, kCFBooleanTrue)

        guard let ax = window.axElement ?? axElement(forWindowID: window.id, pid: window.ownerPID) else { return true }
        if window.isMinimized {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let actionResult = AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        return actionResult == .success
    }
}

// Private Accessibility API for window ID resolution
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// Private CoreGraphics Services API for resolving which Spaces a window belongs to
private let kCGSAllSpacesMask: Int32 = 0x7

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> Int

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?
