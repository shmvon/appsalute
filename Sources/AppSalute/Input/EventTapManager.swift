import Cocoa
import Carbon.HIToolbox

/// Manages event taps and Carbon hotkeys to intercept the custom trigger shortcut (default Ctrl+Option+Tab),
/// navigation arrows, close/quit commands (Cmd/Opt/Ctrl+Opt + W/Q), and modifier release.
public final class EventTapManager: @unchecked Sendable {
    public static let shared = EventTapManager()

    private var eventTap: CFMachPort?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var runLoopSource: CFRunLoopSource?
    public var isSwitcherActive: Bool = false
    /// Set to true once the user navigates with arrows or closes/quits a window,
    /// so releasing Ctrl/Opt to press Cmd+W or Cmd+Q does not dismiss the panel prematurely.
    public var isPinnedByNavigation: Bool = false

    private init() {}

    public var isRunning: Bool { eventTap != nil }

    /// Registers a Carbon global hotkey for the active trigger shortcut.
    /// Works even when CGEventTap / Accessibility permission is not yet active.
    public func registerHotKey() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()

        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                guard let event = event else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let backward = (hkID.id == 2)
                DebugLog.write("Carbon hotkey fired (id \(hkID.id))")
                DispatchQueue.main.async {
                    EventTapManager.shared.isSwitcherActive = true
                    SwitcherState.shared.triggerSwitcher(backward: backward)
                    SwitcherPanel.shared.showInteractive()
                }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }

        let shortcut = Preferences.shared.shortcut
        var fwdRef: EventHotKeyRef?
        let fwdID = EventHotKeyID(signature: OSType(0x43415431), id: 1)
        let fwdStatus = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, fwdID, GetApplicationEventTarget(), 0, &fwdRef)
        DebugLog.write("RegisterEventHotKey(\(shortcut.displayString)) status = \(fwdStatus)")
        if fwdStatus == noErr, let r = fwdRef {
            hotKeyRefs.append(r)
        }

        if (shortcut.carbonModifiers & UInt32(shiftKey)) == 0 {
            var bwdRef: EventHotKeyRef?
            let bwdID = EventHotKeyID(signature: OSType(0x43415431), id: 2)
            if RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers | UInt32(shiftKey), bwdID, GetApplicationEventTarget(), 0, &bwdRef) == noErr, let r = bwdRef {
                hotKeyRefs.append(r)
            }
        }
    }

    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: observer
        ) else {
            DebugLog.write("CGEventTap creation FAILED (Accessibility missing)")
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.write("CGEventTap created OK")
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
        }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let isAltPressed = flags.contains(.maskAlternate)
        let isCmdPressed = flags.contains(.maskCommand)
        let isCtrlPressed = flags.contains(.maskControl)
        let isShiftPressed = flags.contains(.maskShift)
        let shortcut = Preferences.shared.shortcut

        if type == .flagsChanged {
            // Only auto-commit on modifier release if confirmWithReturn is off and the user hasn't entered arrow/W/Q navigation mode
            if isSwitcherActive && !isPinnedByNavigation && !Preferences.shared.confirmWithReturn && shortcut.areAllModifiersReleased(flags: flags) {
                isSwitcherActive = false
                DispatchQueue.main.async {
                    SwitcherState.shared.commit()
                    SwitcherPanel.shared.hide()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

            // Trigger shortcut check (Default: Ctrl + Option + Tab)
            if shortcut.matches(keyCode: keyCode, flags: flags) {
                isSwitcherActive = true
                isPinnedByNavigation = false
                DispatchQueue.main.async {
                    SwitcherState.shared.triggerSwitcher(backward: isShiftPressed)
                    SwitcherPanel.shared.showInteractive()
                }
                return nil // swallow trigger key event
            }

            // In-switcher controls when active
            if isSwitcherActive {
                let hasActionModifier = isCmdPressed || isAltPressed || isCtrlPressed
                let char = ShortcutConfig.keyName(for: UInt16(keyCode)).lowercased()

                // Cmd+W, Opt+W, or Ctrl+Opt+W: Close selected window (live keyboard layout aware)
                if hasActionModifier && char == "w" {
                    isPinnedByNavigation = true
                    DispatchQueue.main.async {
                        SwitcherState.shared.closeSelectedWindow()
                    }
                    return nil
                }

                // Cmd+Q, Opt+Q, or Ctrl+Opt+Q: Quit selected app (live keyboard layout aware)
                if hasActionModifier && char == "q" {
                    isPinnedByNavigation = true
                    DispatchQueue.main.async {
                        SwitcherState.shared.quitSelectedApp()
                    }
                    return nil
                }

                // Escape: Dismiss
                if keyCode == kVK_Escape {
                    isSwitcherActive = false
                    isPinnedByNavigation = false
                    DispatchQueue.main.async {
                        SwitcherState.shared.dismiss()
                        SwitcherPanel.shared.hide()
                    }
                    return nil
                }

                // Space, arrow keys navigation & Return
                switch keyCode {
                case kVK_Space:
                    isPinnedByNavigation = true
                    DispatchQueue.main.async { SwitcherState.shared.bringToFrontWithoutLeaving() }
                    return nil
                case kVK_LeftArrow:
                    isPinnedByNavigation = true
                    DispatchQueue.main.async { SwitcherState.shared.moveSelectionLeft() }
                    return nil
                case kVK_RightArrow:
                    isPinnedByNavigation = true
                    DispatchQueue.main.async { SwitcherState.shared.moveSelectionRight() }
                    return nil
                case kVK_DownArrow:
                    isPinnedByNavigation = true
                    DispatchQueue.main.async { SwitcherState.shared.moveSelectionDown() }
                    return nil
                case kVK_UpArrow:
                    isPinnedByNavigation = true
                    DispatchQueue.main.async { SwitcherState.shared.moveSelectionUp() }
                    return nil
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    DispatchQueue.main.async {
                        SwitcherPanel.shared.commitSelection()
                    }
                    return nil
                default:
                    break
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
