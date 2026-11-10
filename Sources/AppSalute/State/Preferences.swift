import Cocoa
import Carbon.HIToolbox

/// Represents any user-definable trigger shortcut (default: Ctrl + Option + Tab).
public struct ShortcutConfig: Equatable, Sendable {
    public var keyCode: UInt16
    /// Carbon modifier flags (`controlKey`, `optionKey`, `cmdKey`, `shiftKey`).
    public var carbonModifiers: UInt32

    public static let defaultShortcut = ShortcutConfig(
        keyCode: UInt16(kVK_Tab),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    public init(keyCode: UInt16, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public init?(event: NSEvent) {
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        // Require at least one modifier (Control, Option, or Command)
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        let code = event.keyCode
        // Ignore bare modifier key presses
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(code) { return nil }
        self.keyCode = code
        self.carbonModifiers = mods
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Matches the CGEventFlags and keyCode for the trigger combination.
    public func matches(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard keyCode == Int(self.keyCode) else { return false }
        let needCtrl = (carbonModifiers & UInt32(controlKey)) != 0
        let needOpt = (carbonModifiers & UInt32(optionKey)) != 0
        let needCmd = (carbonModifiers & UInt32(cmdKey)) != 0
        let needShift = (carbonModifiers & UInt32(shiftKey)) != 0

        let hasCtrl = flags.contains(.maskControl)
        let hasOpt = flags.contains(.maskAlternate)
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)

        if needCtrl != hasCtrl { return false }
        if needOpt != hasOpt { return false }
        if needCmd != hasCmd { return false }
        if needShift && !hasShift { return false }
        return true
    }

    /// Returns true when all required modifiers of the trigger have been released.
    public func areAllModifiersReleased(flags: CGEventFlags) -> Bool {
        let needCtrl = (carbonModifiers & UInt32(controlKey)) != 0
        let needOpt = (carbonModifiers & UInt32(optionKey)) != 0
        let needCmd = (carbonModifiers & UInt32(cmdKey)) != 0

        let hasCtrl = needCtrl && flags.contains(.maskControl)
        let hasOpt = needOpt && flags.contains(.maskAlternate)
        let hasCmd = needCmd && flags.contains(.maskCommand)

        return !hasCtrl && !hasOpt && !hasCmd
    }

    public var displayString: String {
        var s = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { s += "⌃" }
        if (carbonModifiers & UInt32(optionKey)) != 0 { s += "⌥" }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { s += "⇧" }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    public static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_ANSI_Grave: return "`"
        default:
            if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
               let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length: Int = 0
                data.withUnsafeBytes { rawBuffer in
                    guard let layoutPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                    UCKeyTranslate(
                        layoutPtr,
                        keyCode,
                        UInt16(kUCKeyActionDisplay),
                        0,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        4,
                        &length,
                        &chars
                    )
                }
                if length > 0 {
                    return String(utf16CodeUnits: chars, count: length).uppercased()
                }
            }
            return "Key(\(keyCode))"
        }
    }
}

/// Stores user preferences for trigger shortcut, settings, and excluded applications.
public final class Preferences: @unchecked Sendable {
    public static let shared = Preferences()

    private let keyCodePref = "AppSalute_ShortcutKeyCode"
    private let modifiersPref = "AppSalute_ShortcutModifiers"
    private let confirmWithReturnPref = "AppSalute_ConfirmWithReturn"
    private let excludedAppsPref = "AppSalute_ExcludedApps"

    // Legacy keys for migration
    private let legacyKeyCodePref = "ControlAltTab_ShortcutKeyCode"
    private let legacyModifiersPref = "ControlAltTab_ShortcutModifiers"
    private let legacyConfirmWithReturnPref = "ControlAltTab_ConfirmWithReturn"

    private init() {
        migrateLegacyKeysIfNeeded()
    }

    private func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: keyCodePref) == nil && defaults.object(forKey: legacyKeyCodePref) != nil {
            defaults.set(defaults.integer(forKey: legacyKeyCodePref), forKey: keyCodePref)
        }
        if defaults.object(forKey: modifiersPref) == nil && defaults.object(forKey: legacyModifiersPref) != nil {
            defaults.set(defaults.integer(forKey: legacyModifiersPref), forKey: modifiersPref)
        }
        if defaults.object(forKey: confirmWithReturnPref) == nil && defaults.object(forKey: legacyConfirmWithReturnPref) != nil {
            defaults.set(defaults.bool(forKey: legacyConfirmWithReturnPref), forKey: confirmWithReturnPref)
        }
    }

    public var confirmWithReturn: Bool {
        get { UserDefaults.standard.bool(forKey: confirmWithReturnPref) }
        set { UserDefaults.standard.set(newValue, forKey: confirmWithReturnPref) }
    }

    public var shortcut: ShortcutConfig {
        get {
            guard UserDefaults.standard.object(forKey: keyCodePref) != nil else {
                return .defaultShortcut
            }
            let code = UInt16(UserDefaults.standard.integer(forKey: keyCodePref))
            let mods = UInt32(UserDefaults.standard.integer(forKey: modifiersPref))
            return ShortcutConfig(keyCode: code, carbonModifiers: mods)
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: keyCodePref)
            UserDefaults.standard.set(Int(newValue.carbonModifiers), forKey: modifiersPref)
        }
    }

    public var excludedApps: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: excludedAppsPref) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: excludedAppsPref)
        }
    }

    public func isAppExcluded(bundleIdentifier: String?, appName: String) -> Bool {
        let list = excludedApps
        if let bid = bundleIdentifier, list.contains(bid) {
            return true
        }
        return list.contains(appName)
    }

    public func addExcludedApp(identifier: String) {
        var list = excludedApps
        if !list.contains(identifier) {
            list.append(identifier)
            excludedApps = list
        }
    }

    public func removeExcludedApp(identifier: String) {
        var list = excludedApps
        list.removeAll { $0 == identifier }
        excludedApps = list
    }

    public func resetToDefault() {
        shortcut = .defaultShortcut
    }
}
