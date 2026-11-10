#!/bin/bash
set -e

# Usage:
#   ./build_app.sh                      Show a dialog to choose name suffix and install location
#   ./build_app.sh --suffix computer    Skip dialog: suffix = computer name
#   ./build_app.sh --suffix none        Skip dialog: no suffix
#   ./build_app.sh --suffix NAME        Skip dialog: custom suffix NAME
#   ./build_app.sh --install            Install into /Applications (default: next to this script)
#   ./build_app.sh --clean              Remove the cached build output first

# Run from the script's own directory so relative paths work from anywhere
cd "$(dirname "${BASH_SOURCE[0]}")"
WORKSPACE_DIR="$(pwd)"

BASE_APP_NAME="AppSalute"
BUNDLE_ID="com.sem.AppSalute"
DEPLOYMENT_TARGET="14.0"

# ---- Parse arguments ----
SUFFIX_ARG=""
INSTALL_ARG=""
CLEAN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --suffix) SUFFIX_ARG="$2"; shift 2 ;;
        --suffix=*) SUFFIX_ARG="${1#--suffix=}"; shift ;;
        --install) INSTALL_ARG="true"; shift ;;
        --clean) CLEAN="true"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

sanitize() { echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g'; }
computer_name() { scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo "Mac"; }

# ---- Suffix / install selection ----
if [ -n "$SUFFIX_ARG" ] || [ -n "$INSTALL_ARG" ]; then
    # Non-interactive
    CHOICE="No Suffix"; CUSTOM_VAL=""
    case "$SUFFIX_ARG" in
        "") CHOICE="No Suffix" ;;
        none) CHOICE="No Suffix" ;;
        computer) CHOICE="Computer Name" ;;
        *) CHOICE="Custom Name"; CUSTOM_VAL="$SUFFIX_ARG" ;;
    esac
    INSTALL_TO_APPS="${INSTALL_ARG:-false}"
else
    echo "Prompting for build options..."
    DIALOG_RESULT=$(osascript -e "
use framework \"AppKit\"
use framework \"Foundation\"
use scripting additions

on run
    set computerName to do shell script \"scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo Mac\"

    set mainAlert to current application's NSAlert's alloc()'s init()
    mainAlert's setMessageText:\"Build $BASE_APP_NAME\"
    mainAlert's setInformativeText:\"The app only works on the system it was built on, so adding a suffix to each build is recommended.\"
    mainAlert's addButtonWithTitle:\"Build\"
    mainAlert's addButtonWithTitle:\"Cancel\"

    set containerView to current application's NSView's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, 400, 140))

    set radioComputer to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 110, 390, 22))
    radioComputer's setButtonType:(current application's NSRadioButton)
    radioComputer's setTitle:(\"Computer name (\" & computerName & \")\")
    radioComputer's setState:1
    radioComputer's setTarget:me
    radioComputer's setAction:\"radioClicked:\"
    containerView's addSubview:radioComputer

    set radioCustom to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 80, 115, 22))
    radioCustom's setButtonType:(current application's NSRadioButton)
    radioCustom's setTitle:\"Custom name:\"
    radioCustom's setState:0
    radioCustom's setTarget:me
    radioCustom's setAction:\"radioClicked:\"
    containerView's addSubview:radioCustom

    set customField to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(120, 80, 260, 22))
    customField's setPlaceholderString:\"Enter custom suffix\"
    containerView's addSubview:customField

    set radioNoSuffix to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 50, 390, 22))
    radioNoSuffix's setButtonType:(current application's NSRadioButton)
    radioNoSuffix's setTitle:\"No suffix\"
    radioNoSuffix's setState:0
    radioNoSuffix's setTarget:me
    radioNoSuffix's setAction:\"radioClicked:\"
    containerView's addSubview:radioNoSuffix

    set checkbox to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 10, 390, 22))
    checkbox's setButtonType:(current application's NSSwitchButton)
    checkbox's setTitle:\"Install into Applications folder (/Applications)\"
    checkbox's setState:0
    containerView's addSubview:checkbox

    mainAlert's setAccessoryView:containerView

    -- osascript is a background process: make it a regular app so it can take focus from the terminal
    set theApp to current application's NSApplication's sharedApplication()
    theApp's setActivationPolicy:(current application's NSApplicationActivationPolicyRegular)
    theApp's activateIgnoringOtherApps:true
    set alertWindow to mainAlert's |window|()
    alertWindow's setLevel:(current application's NSFloatingWindowLevel)
    alertWindow's makeKeyAndOrderFront:me
    current application's NSRunningApplication's currentApplication()'s activateWithOptions:3
    set response to mainAlert's runModal()

    if response is 1000 then
        if (radioComputer's state() as integer is 1) then
            set choice to \"Computer Name\"
            set customVal to \"\"
        else if (radioCustom's state() as integer is 1) then
            set choice to \"Custom Name\"
            set customVal to (customField's stringValue() as string)
        else
            set choice to \"No Suffix\"
            set customVal to \"\"
        end if
    else
        set choice to \"Cancel\"
        set customVal to \"\"
    end if

    set installToApps to (checkbox's state() as integer is 1)

    return (choice & \"|\" & (installToApps as string) & \"|\" & customVal)
end run

on radioClicked:sender
end radioClicked:
" 2>/dev/null || echo "Cancel|false|")

    CHOICE=$(echo "$DIALOG_RESULT" | cut -d'|' -f1)
    INSTALL_TO_APPS=$(echo "$DIALOG_RESULT" | cut -d'|' -f2)
    CUSTOM_VAL=$(echo "$DIALOG_RESULT" | cut -d'|' -f3)

    if [ -z "$CHOICE" ] || [ "$CHOICE" = "Cancel" ]; then
        echo "Build cancelled by user."
        exit 0
    fi
fi

SUFFIX=""
if [ "$CHOICE" = "Computer Name" ]; then
    SUFFIX="_$(sanitize "$(computer_name)")"
elif [ "$CHOICE" = "Custom Name" ]; then
    CUSTOM_CLEAN=$(sanitize "$CUSTOM_VAL")
    if [ -z "$CUSTOM_CLEAN" ]; then
        echo "Error: Custom suffix is empty or invalid."
        exit 1
    fi
    SUFFIX="_$CUSTOM_CLEAN"
fi

APP_NAME="${BASE_APP_NAME}${SUFFIX}"
echo "=== Building ${APP_NAME}.app ==="

if [ "$INSTALL_TO_APPS" = "true" ]; then
    FINAL_APP_BUNDLE="/Applications/${APP_NAME}.app"
else
    FINAL_APP_BUNDLE="${WORKSPACE_DIR}/${APP_NAME}.app"
fi

# ---- Compile ----
BUILD_DIR="/private/tmp/${BASE_APP_NAME}_build"
[ -n "$CLEAN" ] && { echo "Cleaning build cache..."; rm -rf "$BUILD_DIR"; }
mkdir -p "$BUILD_DIR" /tmp/clang-module-cache

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

echo "Building binary..."
swiftc -module-cache-path /tmp/clang-module-cache -parse-as-library \
    -target "arm64-apple-macos${DEPLOYMENT_TARGET}" \
    $(find Sources/AppSalute -name '*.swift') \
    -o "${BUILD_DIR}/${BASE_APP_NAME}"

# ---- Package in a staging dir ----
STAGING_DIR=$(mktemp -d "/private/tmp/${BASE_APP_NAME}_staging.XXXXXX")
APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Packaging ${APP_NAME}.app..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "${BUILD_DIR}/${BASE_APP_NAME}" "${MACOS_DIR}/${BASE_APP_NAME}"
chmod 755 "${MACOS_DIR}/${BASE_APP_NAME}"

cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${BASE_APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${DEPLOYMENT_TARGET}</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# ---- Sign ----
echo "Signing..."
# A stable certificate keeps the Accessibility grant valid across rebuilds; ad-hoc signing invalidates it every time.
DEFAULT_IDENTITY="AppSalute Dev"
if [ -z "${SIGN_IDENTITY}" ]; then
    if security find-certificate -c "${DEFAULT_IDENTITY}" >/dev/null 2>&1; then
        SIGN_IDENTITY="${DEFAULT_IDENTITY}"
    else
        SIGN_IDENTITY="-"
        cat <<MSG

Warning: certificate "${DEFAULT_IDENTITY}" not found, signing ad-hoc.
Accessibility must be re-granted after EVERY build until you do this one-time setup:

  1. Open "Keychain Access" (Spotlight: Cmd+Space, type "Keychain Access").
  2. Menu bar: Keychain Access > Certificate Assistant > Create a Certificate...
  3. Fill in:
       Name:             ${DEFAULT_IDENTITY}      (must match exactly)
       Identity Type:    Self Signed Root
       Certificate Type: Code Signing
  4. Click Create, then Done. It is stored in the "login" keychain.
  5. (If signing later fails with a trust error) double-click the certificate,
     expand "Trust", set "Code Signing" to "Always Trust", and close the window.
  6. Verify it is found:
       security find-identity -v -p codesigning
  7. Re-run ./build_app.sh, then clear the old (ad-hoc signed) permission,
     either in System Settings:
       System Settings > Privacy & Security > Device Control and Data Access
       (called "Accessibility" on older macOS versions)
       Remove the old AppSalute entry with "-".
     or from the terminal:
       tccutil reset Accessibility ${BUNDLE_ID}
  8. Launch the app and grant the permission once more. If you can't find the
     pane, search for "Accessibility" or "Device Control" in System Settings,
     or try opening it directly (may not work on every macOS version):
       open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
     After that, rebuilds keep the permission.

MSG
        echo "Continuing with ad-hoc signing..."
    fi
fi
echo "Using signing identity: ${SIGN_IDENTITY}"
codesign --force --deep --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

# ---- Install ----
echo "Installing to ${FINAL_APP_BUNDLE}..."
rm -rf "ControlAltTab.app" "${WORKSPACE_DIR}/${APP_NAME}.app" "$FINAL_APP_BUNDLE"
mv "$APP_BUNDLE" "$FINAL_APP_BUNDLE"
rm -rf "$STAGING_DIR"
touch "$FINAL_APP_BUNDLE"

echo "Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -r "$FINAL_APP_BUNDLE" || \
    echo "Warning: Launch Services registration failed; the app bundle was still built."

echo "=== Done! ${APP_NAME}.app successfully built ==="
echo "Run it with: open '${FINAL_APP_BUNDLE}'"
