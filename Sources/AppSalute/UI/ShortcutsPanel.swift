import Cocoa
import SwiftUI
import Combine

/// State model for shortcuts view.
@MainActor
final class ShortcutsViewModel: ObservableObject {
    @Published var currentShortcut: String = Preferences.shared.shortcut.displayString

    func update() {
        currentShortcut = Preferences.shared.shortcut.displayString
    }
}

/// Menu bar dialog showing all available shortcuts and allowing customization of the launcher shortcut.
@MainActor
public final class ShortcutsPanel: NSPanel {
    public static let shared = ShortcutsPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Shortcuts"
        isFloatingPanel = true
        level = .floating
        center()
    }

    public func present(onUpdated: (() -> Void)? = nil) {
        contentView = NSHostingView(rootView: ShortcutsView(onShortcutUpdated: {
            onUpdated?()
        }))
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

private struct ShortcutRow: Identifiable {
    let id = UUID()
    let action: String
    let keys: String
}

private struct ShortcutsView: View {
    @StateObject private var model = ShortcutsViewModel()
    var onShortcutUpdated: () -> Void

    private let shortcutsList: [ShortcutRow] = [
        ShortcutRow(action: "Cycle apps forward", keys: "Tab / Launcher"),
        ShortcutRow(action: "Cycle apps backward", keys: "⇧Tab / ⇧Launcher"),
        ShortcutRow(action: "Navigate apps", keys: "← / →"),
        ShortcutRow(action: "Select close all inactive apps", keys: "↑ (from app bar)"),
        ShortcutRow(action: "Navigate to active windows", keys: "↓ (from app bar)"),
        ShortcutRow(action: "Navigate windows", keys: "↑ / ↓"),
        ShortcutRow(action: "Bring app to front (stay in app)", keys: "Space"),
        ShortcutRow(action: "Close selected window", keys: "⌘W / ⌥W / ⌃⌥W"),
        ShortcutRow(action: "Quit selected app", keys: "⌘Q / ⌥Q / ⌃⌥Q"),
        ShortcutRow(action: "Activate selection and exit", keys: "Return"),
        ShortcutRow(action: "Dismiss switcher", keys: "Esc")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Launcher Shortcut Config Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Launcher shortcut")
                    .font(.system(size: 13, weight: .semibold))

                HStack {
                    Text(model.currentShortcut)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))

                    Spacer()

                    Button("Record new…") {
                        ShortcutRecorderPanel.shared.present { newConfig in
                            model.currentShortcut = newConfig.displayString
                            EventTapManager.shared.registerHotKey()
                            onShortcutUpdated()
                        }
                    }

                    Button("Reset to default") {
                        Preferences.shared.resetToDefault()
                        model.currentShortcut = Preferences.shared.shortcut.displayString
                        EventTapManager.shared.registerHotKey()
                        onShortcutUpdated()
                    }
                    .disabled(Preferences.shared.shortcut == .defaultShortcut)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            Divider()

            // Reference list of all shortcuts
            Text("Interface navigation & actions")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(shortcutsList) { row in
                        HStack {
                            Text(row.action)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(row.keys)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 250)

            HStack {
                Spacer()
                Button("Done") {
                    ShortcutsPanel.shared.orderOut(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500, height: 480)
    }
}
