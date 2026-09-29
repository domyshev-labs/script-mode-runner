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

codesign --force --deep --sign - "${APP_BUNDLE}"

print "Installed: ${APP_BUNDLE}"
print "Configuration: ${HOME}/.config/script-mode-runner/config.yaml"
print "Open the app from Finder or run:"
print "  open '${APP_BUNDLE}'"
