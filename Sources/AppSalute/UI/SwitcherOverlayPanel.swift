import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

/// Fixed layout metrics shared by the SwiftUI overlay and the panel that hosts it.
enum SwitcherLayout {
    static let panelWidth: CGFloat = 1245
    static let outerPadding: CGFloat = 42
    static let windowRowHeight: CGFloat = 36
    static let windowRowSpacing: CGFloat = 5
    /// Rows beyond this scroll inside the window list.
    static let maxVisibleWindowRows = 7
}

/// Main visual overlay showing the running applications and selected app's window titles.
public struct SwitcherOverlayView: View {
    @ObservedObject var state = SwitcherState.shared
    /// When true the content sticks to the top of the panel, so a height change between redraw and
    /// panel resize only moves the bottom edge. The measuring copy keeps its natural height.
    var pinnedToTop = false

    public var body: some View {
        if pinnedToTop {
            // GeometryReader places its child at the top-left and never grows with it, so content that is
            // momentarily taller than the panel overflows downward instead of being re-centered.
            GeometryReader { _ in content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 21) {
            // Top option: "Close all inactive apps"
            closeAllInactiveOptionView()

            // App row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 21) {
                        ForEach(Array(state.apps.enumerated()), id: \.element.id) { index, item in
                            appItemView(item: item, index: index)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 21)
                }
                .onChange(of: currentAppIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            // Window titles list for selected application
            if let selectedApp = currentSelectedApp {
                windowListView(for: selectedApp)
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(width: SwitcherLayout.panelWidth - 2 * SwitcherLayout.outerPadding)
        .padding(SwitcherLayout.outerPadding)
    }

    private var currentAppIndex: Int {
        switch state.focus {
        case .closeAll: return 0
        case .app(let idx): return idx
        case .window(let appIdx, _): return appIdx
        }
    }

    private var currentSelectedApp: AppItem? {
        if state.focus == .closeAll { return nil }
        let idx = currentAppIndex
        guard idx < state.apps.count else { return nil }
        return state.apps[idx]
    }

    @ViewBuilder
    private func closeAllInactiveOptionView() -> some View {
        let isFocused = (state.focus == .closeAll)
        let isArmed = state.closeAllArmed
        let count = state.inactiveAppCount
        let label: String = {
            if isArmed {
                return "Quit \(state.inactiveAppNames.joined(separator: ", "))? Press again to confirm"
            }
            if count > 0 { return "Close all inactive apps (\(count))" }
            return isFocused ? "No inactive apps to close" : "Close all inactive apps"
        }()

        HStack(spacing: 11) {
            Image(systemName: isArmed ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isFocused ? Color.white : .secondary)

            Text(label)
                .font(.system(size: 15, weight: isFocused ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isFocused ? Color.white : .primary)

            Spacer()
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isArmed ? Color.red.opacity(0.85) : (isFocused ? Color.accentColor : Color.primary.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isFocused && !isArmed ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture {
            EventTapManager.shared.isPinnedByNavigation = true
            state.requestCloseAll()
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            EventTapManager.shared.isPinnedByNavigation = true
            state.confirmCloseAll()
        })
    }

    @ViewBuilder
    private func appItemView(item: AppItem, index: Int) -> some View {
        let isAppSelected: Bool = {
            switch state.focus {
            case .closeAll: return false
            case .app(let idx): return idx == index
            case .window(let appIdx, _): return appIdx == index
            }
        }()

        VStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 78, height: 78)

            Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .frame(width: 96, height: 19)
                .foregroundStyle(isAppSelected ? .primary : .secondary)

            // Fixed-height row for window count indicator
            ZStack {
                if !item.windows.isEmpty {
                    Text("\(item.windows.count)")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.18)))
                }
            }
            .frame(height: 22)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isAppSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isAppSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            EventTapManager.shared.isPinnedByNavigation = true
            state.select(.app(index: index))
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            state.select(.app(index: index))
            SwitcherPanel.shared.commitSelection()
        })
    }

    @ViewBuilder
    private func windowListView(for appItem: AppItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(appItem.name) — Active Windows (\(appItem.windows.count))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 11)

            if !state.isAccessibilityTrusted {
                Label("Window titles and window actions need Accessibility permission for AppSalute", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 11)
            }

            if appItem.windows.isEmpty {
                Text("No open windows (App running in background)")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.06)))
            } else {
                let rowCount = min(appItem.windows.count, SwitcherLayout.maxVisibleWindowRows)
                let listHeight = CGFloat(rowCount) * SwitcherLayout.windowRowHeight
                    + CGFloat(max(rowCount - 1, 0)) * SwitcherLayout.windowRowSpacing
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: appItem.windows.count > SwitcherLayout.maxVisibleWindowRows) {
                        VStack(spacing: SwitcherLayout.windowRowSpacing) {
                            ForEach(Array(appItem.windows.enumerated()), id: \.element.id) { winIdx, window in
                                windowRowView(window: window, appIdx: currentAppIndex, winIdx: winIdx)
                                    .id(winIdx)
                            }
                        }
                    }
                    .frame(height: listHeight)
                    .onChange(of: state.focus) { _, newFocus in
                        if case .window(_, let winIdx) = newFocus {
                            withAnimation { proxy.scrollTo(winIdx) }
                        }
                    }
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func windowRowView(window: WindowInfo, appIdx: Int, winIdx: Int) -> some View {
        let isFocused: Bool = {
            if case .window(_, let targetWinIdx) = state.focus {
                return targetWinIdx == winIdx
            }
            return false
        }()

        HStack {
            Image(systemName: window.isMinimized ? "macwindow.badge.minus" : "macwindow")
                .font(.system(size: 17))
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)

            Text(window.title)
                .font(.system(size: 16, weight: isFocused ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer()

            if window.isPlaceholder {
                Text("Empty")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .foregroundStyle(.secondary)
            }

            if window.isMinimized {
                Text("Minimized")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: SwitcherLayout.windowRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture {
            EventTapManager.shared.isPinnedByNavigation = true
            state.select(.window(appIndex: appIdx, windowIndex: winIdx))
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            state.select(.window(appIndex: appIdx, windowIndex: winIdx))
            SwitcherPanel.shared.commitSelection()
        })
    }
}

/// Floating Non-Activating NSPanel to display the switcher on the active display.
public final class SwitcherPanel: NSPanel {
    public static let shared = SwitcherPanel()
    private var localKeyMonitor: Any?
    private var flagsMonitor: Any?
    private var clickMonitor: Any?
    private var stateObserver: AnyCancellable?
    /// Off-screen copy of the overlay used only to measure the height the content needs.
    private let measuringController = NSHostingController(rootView: SwitcherOverlayView())
    /// Top edge kept fixed while the panel resizes, so the app row doesn't jump between apps.
    private var anchoredTop: CGFloat?

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        let hostingView = NSHostingView(rootView: SwitcherOverlayView(pinnedToTop: true))
        hostingView.sizingOptions = []
        contentView = hostingView

        stateObserver = SwitcherState.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeToFitContent() }
        }
    }

    private func contentHeight(maxHeight: CGFloat) -> CGFloat {
        let fitting = measuringController.sizeThatFits(in: NSSize(width: SwitcherLayout.panelWidth, height: maxHeight))
        return min(ceil(fitting.height), maxHeight)
    }

    private func resizeToFitContent() {
        guard isVisible, let top = anchoredTop, let screen = screen ?? NSScreen.main else { return }
        let height = contentHeight(maxHeight: screen.visibleFrame.height)
        guard abs(height - frame.height) > 0.5 else { return }
        setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
    }

    private var isInteractive = false

    override public var canBecomeKey: Bool { isInteractive }

    /// Shows the switcher and monitors keyboard navigation.
    public func showInteractive() {
        if !SwitcherState.shared.isVisible {
            SwitcherState.shared.triggerSwitcher()
        }
        isInteractive = true
        show()
        refocusPanel()
        installLocalKeyMonitor()
        installClickMonitor()
    }

    /// Re-asserts key focus on the switcher panel so background actions never steal focus.
    public func refocusPanel() {
        guard isInteractive else { return }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Asserts that SwitcherPanel is ordered front and receives key events without activating NSApp as the main application.
    public func assertFrontmostPanel() {
        guard isInteractive else { return }
        orderFrontRegardless()
        makeKey()
    }

    /// Commits the current selection and closes the switcher, e.g. after a double click.
    public func commitSelection() {
        if SwitcherState.shared.needsCloseAllConfirmation() {
            EventTapManager.shared.isPinnedByNavigation = true
            return
        }
        finishInteractive(commit: true)
    }

    private func finishInteractive(commit: Bool) {
        isInteractive = false
        EventTapManager.shared.isSwitcherActive = false
        EventTapManager.shared.isPinnedByNavigation = false
        removeLocalKeyMonitor()
        removeClickMonitor()
        if commit { SwitcherState.shared.commit() } else { SwitcherState.shared.dismiss() }
        hide()
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.isInteractive else { return }
            let mouseLoc = NSEvent.mouseLocation
            if !self.frame.contains(mouseLoc) {
                DispatchQueue.main.async {
                    self.finishInteractive(commit: false)
                }
            }
        }
    }

    private func removeClickMonitor() {
        if let cm = clickMonitor {
            NSEvent.removeMonitor(cm)
            clickMonitor = nil
        }
    }

    private func installLocalKeyMonitor() {
        removeLocalKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isInteractive else { return event }
            return self.handleInteractiveKey(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self, self.isInteractive else { return event }
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            if !EventTapManager.shared.isPinnedByNavigation &&
               !Preferences.shared.confirmWithReturn &&
               Preferences.shared.shortcut.areAllModifiersReleased(flags: cgFlags) {
                self.commitSelection()
            }
            return event
        }
    }

    private func removeLocalKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
        if let f = flagsMonitor {
            NSEvent.removeMonitor(f)
            flagsMonitor = nil
        }
    }

    private func handleInteractiveKey(_ event: NSEvent) -> Bool {
        let state = SwitcherState.shared
        let flags = event.modifierFlags
        let hasActionModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        let keyCode = Int(event.keyCode)
        let char = ShortcutConfig.keyName(for: event.keyCode).lowercased()

        DebugLog.write("Panel key: keyCode=\(keyCode) char=\(char)")

        // Check if trigger key is pressed again to cycle
        let cgFlags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if Preferences.shared.shortcut.matches(keyCode: keyCode, flags: cgFlags) {
            state.cycleApp(backward: flags.contains(.shift))
            return true
        }

        if hasActionModifier && char == "w" {
            EventTapManager.shared.isPinnedByNavigation = true
            state.closeSelectedWindow()
            return true
        }

        if hasActionModifier && char == "q" {
            EventTapManager.shared.isPinnedByNavigation = true
            state.quitSelectedApp()
            return true
        }

        switch keyCode {
        case kVK_Space:
            EventTapManager.shared.isPinnedByNavigation = true
            state.bringToFrontWithoutLeaving()
            return true
        case kVK_LeftArrow:
            EventTapManager.shared.isPinnedByNavigation = true
            state.moveSelectionLeft()
            return true
        case kVK_RightArrow:
            EventTapManager.shared.isPinnedByNavigation = true
            state.moveSelectionRight()
            return true
        case kVK_DownArrow:
            EventTapManager.shared.isPinnedByNavigation = true
            state.moveSelectionDown()
            return true
        case kVK_UpArrow:
            EventTapManager.shared.isPinnedByNavigation = true
            state.moveSelectionUp()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitSelection()
            return true
        case kVK_Escape:
            finishInteractive(commit: false)
            return true
        case kVK_Tab:
            state.cycleApp(backward: flags.contains(.shift))
            return true
        default:
            return false
        }
    }

    override public func resignKey() {
        super.resignKey()
        if isInteractive && SwitcherState.shared.isVisible {
            DispatchQueue.main.async { [weak self] in
                self?.refocusPanel()
            }
        }
    }

    public func show() {
        // Each shortcut press while cycling calls show() again; re-centering would make the panel jump.
        if isVisible, anchoredTop != nil {
            resizeToFitContent()
            orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame

        // Center on the active screen at the height the content needs; later resizes keep the top edge fixed.
        let panelSize = NSSize(width: SwitcherLayout.panelWidth, height: contentHeight(maxHeight: screenRect.height))
        let origin = NSPoint(
            x: screenRect.midX - (panelSize.width / 2),
            y: screenRect.midY - (panelSize.height / 2)
        )
        anchoredTop = origin.y + panelSize.height
        setFrame(NSRect(origin: origin, size: panelSize), display: true)
        orderFrontRegardless()
    }

    public func hide() {
        isInteractive = false
        anchoredTop = nil
        // Otherwise the event tap keeps swallowing Space, arrows, Return and Escape system-wide.
        EventTapManager.shared.isSwitcherActive = false
        EventTapManager.shared.isPinnedByNavigation = false
        removeLocalKeyMonitor()
        removeClickMonitor()
        orderOut(nil)
    }
}
