import Cocoa
import SwiftUI
import Combine

/// State model for excluded apps view.
@MainActor
final class ExcludedAppsViewModel: ObservableObject {
    @Published var excludedList: [String] = Preferences.shared.excludedApps
    @Published var runningApps: [NSRunningApplication] = []

    func refresh() {
        excludedList = Preferences.shared.excludedApps
        let myPID = ProcessInfo.processInfo.processIdentifier
        runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            !$0.isTerminated &&
            $0.processIdentifier != myPID
        }
    }

    func addExcluded(_ identifier: String) {
        Preferences.shared.addExcludedApp(identifier: identifier)
        excludedList = Preferences.shared.excludedApps
        SwitcherState.shared.loadRunningApps()
    }

    func removeExcluded(_ identifier: String) {
        Preferences.shared.removeExcludedApp(identifier: identifier)
        excludedList = Preferences.shared.excludedApps
        SwitcherState.shared.loadRunningApps()
    }
}

/// Window dialog managing applications excluded from the switcher and from closing.
@MainActor
public final class ExcludedAppsPanel: NSPanel {
    public static let shared = ExcludedAppsPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Excluded apps"
        isFloatingPanel = true
        level = .floating
        center()
    }

    public func present() {
        contentView = NSHostingView(rootView: ExcludedAppsView())
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

private struct ExcludedAppsView: View {
    @StateObject private var model = ExcludedAppsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apps in this list will not appear in the switcher and will never close when instructing to close all inactive apps.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            // Current Excluded Apps List
            List {
                if model.excludedList.isEmpty {
                    Text("No excluded apps.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.excludedList, id: \.self) { item in
                        HStack {
                            Text(displayName(for: item))
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(item)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Button {
                                model.removeExcluded(item)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 220)

            // Add actions
            HStack(spacing: 10) {
                Menu("Running apps") {
                    ForEach(model.runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "Unknown") {
                            if let bid = app.bundleIdentifier {
                                model.addExcluded(bid)
                            } else if let name = app.localizedName {
                                model.addExcluded(name)
                            }
                        }
                    }
                }

                Button("Add app") {
                    chooseAppFromDisk()
                }

                Spacer()

                Button("Done") {
                    ExcludedAppsPanel.shared.orderOut(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 420)
        .onAppear {
            model.refresh()
        }
    }

    private func displayName(for identifier: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == identifier }) {
            return app.localizedName ?? identifier
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return url.deletingPathExtension().lastPathComponent
        }
        return identifier
    }

    private func chooseAppFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                model.addExcluded(bid)
            } else {
                let name = url.deletingPathExtension().lastPathComponent
                model.addExcluded(name)
            }
        }
    }
}
