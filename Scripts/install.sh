#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
INSTALL_DIRECTORY="${1:-${HOME}/Applications}"
APP_BUNDLE="${INSTALL_DIRECTORY}/Script Mode Runner.app"
CONTENTS_DIRECTORY="${APP_BUNDLE}/Contents"
DEVELOPER_DIRECTORY="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if (( MACOS_MAJOR < 14 )); then
    print -u2 "Script Mode Runner requires macOS 14 or newer."
    exit 1
fi

if [[ ! -d "${DEVELOPER_DIRECTORY}" ]]; then
    print -u2 "Full Xcode was not found at ${DEVELOPER_DIRECTORY}."
    print -u2 "Install Xcode or set DEVELOPER_DIR before running this installer."
    exit 1
fi

print "Building Script Mode Runner in release mode..."
(
    cd "${PROJECT_DIRECTORY}"
    DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" xcrun swift build -c release --product ScriptModeRunner
)

BIN_DIRECTORY="$(
    cd "${PROJECT_DIRECTORY}"
    DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" xcrun swift build -c release --show-bin-path
)"

mkdir -p "${CONTENTS_DIRECTORY}/MacOS" "${CONTENTS_DIRECTORY}/Resources"
install -m 755 "${BIN_DIRECTORY}/ScriptModeRunner" "${CONTENTS_DIRECTORY}/MacOS/ScriptModeRunner"
install -m 644 "${PROJECT_DIRECTORY}/Packaging/Info.plist" "${CONTENTS_DIRECTORY}/Info.plist"

ICONSET_DIRECTORY="${BIN_DIRECTORY}/AppIcon.iconset"
DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" xcrun swift "${PROJECT_DIRECTORY}/Scripts/generate-icon.swift" "${ICONSET_DIRECTORY}"
iconutil -c icns "${ICONSET_DIRECTORY}" -o "${CONTENTS_DIRECTORY}/Resources/AppIcon.icns"

codesign --force --deep --sign - "${APP_BUNDLE}"

# In-place bundle updates otherwise leave Finder/Spotlight using cached metadata.
touch "${APP_BUNDLE}"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LAUNCH_SERVICES_REGISTER}" ]]; then
    "${LAUNCH_SERVICES_REGISTER}" -f "${APP_BUNDLE}" || print -u2 "Could not refresh Launch Services registration."
fi
mdimport "${APP_BUNDLE}" || print -u2 "Could not refresh Spotlight metadata."

print "Installed: ${APP_BUNDLE}"
print "Configuration: ${HOME}/.config/script-mode-runner/config.yaml"
print "Open the app from Finder or run:"
print "  open '${APP_BUNDLE}'"
