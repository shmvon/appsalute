import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// Small modal window that records a custom shortcut combination.
@MainActor
public final class ShortcutRecorderPanel: NSPanel {
    public static let shared = ShortcutRecorderPanel()

    private var keyMonitor: Any?
    public var onShortcutRecorded: ((ShortcutConfig) -> Void)?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Set AppSalute Launcher Shortcut"
        isFloatingPanel = true
        level = .floating
        center()
    }

    public func present(onRecorded: @escaping (ShortcutConfig) -> Void) {
        self.onShortcutRecorded = onRecorded
        let current = Preferences.shared.shortcut.displayString
        contentView = NSHostingView(rootView: ShortcutRecorderView(
            currentShortcut: current,
            onReset: { [weak self] in
                Preferences.shared.resetToDefault()
                self?.onShortcutRecorded?(.defaultShortcut)
                self?.closeRecorder()
            },
            onCancel: { [weak self] in
                self?.closeRecorder()
            }
        ))
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        startMonitoring()
    }

    private func startMonitoring() {
        stopMonitoring()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if Int(event.keyCode) == kVK_Escape {
                self.closeRecorder()
                return nil
            }
            if let config = ShortcutConfig(event: event) {
                Preferences.shared.shortcut = config
                self.onShortcutRecorded?(config)
                self.closeRecorder()
                return nil
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    public func closeRecorder() {
        stopMonitoring()
        orderOut(nil)
    }

    override public func close() {
        stopMonitoring()
        super.close()
    }
}

private struct ShortcutRecorderView: View {
    let currentShortcut: String
    let onReset: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Press your desired shortcut combination")
                .font(.system(size: 14, weight: .semibold))

            Text("Hold at least one modifier (⌃, ⌥, or ⌘) and press a key.\nCurrent shortcut: \(currentShortcut)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Reset to Default (⌃⌥Tab)") {
                    onReset()
                }
                Button("Cancel (Esc)") {
                    onCancel()
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380, height: 170)
    }
}

