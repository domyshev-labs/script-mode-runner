#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
INSTALL_DIRECTORY="${1:-${HOME}/Applications}"
APP_BUNDLE="${INSTALL_DIRECTORY}/Mode Runner.app"
LEGACY_APP_BUNDLE="${INSTALL_DIRECTORY}/Script Mode Runner.app"
STAGING_BUNDLE=""
CONTENTS_DIRECTORY=""
DEVELOPER_DIRECTORY="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if (( MACOS_MAJOR < 14 )); then
    print -u2 "Mode Runner requires macOS 14 or newer."
    exit 1
fi

if [[ ! -d "${DEVELOPER_DIRECTORY}" ]]; then
    print -u2 "Full Xcode was not found at ${DEVELOPER_DIRECTORY}."
    print -u2 "Install Xcode or set DEVELOPER_DIR before running this installer."
    exit 1
fi

print "Building Mode Runner in release mode..."
(
    cd "${PROJECT_DIRECTORY}"
    DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" xcrun swift build -c release --product ModeRunner
)

BIN_DIRECTORY="$(
    cd "${PROJECT_DIRECTORY}"
    DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" xcrun swift build -c release --show-bin-path
)"

# Build the entire replacement before touching either installed app bundle.
mkdir -p "${INSTALL_DIRECTORY}"
STAGING_BUNDLE="$(mktemp -d "${INSTALL_DIRECTORY}/.ModeRunner.XXXXXX")/Mode Runner.app"
trap 'rm -rf "${STAGING_BUNDLE:h}"' EXIT
CONTENTS_DIRECTORY="${STAGING_BUNDLE}/Contents"
mkdir -p "${CONTENTS_DIRECTORY}/MacOS" "${CONTENTS_DIRECTORY}/Resources"
install -m 755 "${BIN_DIRECTORY}/ModeRunner" "${CONTENTS_DIRECTORY}/MacOS/ModeRunner"
install -m 644 "${PROJECT_DIRECTORY}/Packaging/Info.plist" "${CONTENTS_DIRECTORY}/Info.plist"
cp -R "${BIN_DIRECTORY}/ModeRunner_ModeRunnerApp.bundle" "${CONTENTS_DIRECTORY}/Resources/"

ICONSET_DIRECTORY="${BIN_DIRECTORY}/AppIcon.iconset"
DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" xcrun swift "${PROJECT_DIRECTORY}/Scripts/generate-icon.swift" "${ICONSET_DIRECTORY}"
iconutil -c icns "${ICONSET_DIRECTORY}" -o "${CONTENTS_DIRECTORY}/Resources/AppIcon.icns"

codesign --force --deep --sign - "${STAGING_BUNDLE}"
codesign --verify --deep --strict "${STAGING_BUNDLE}"

# Only replace a bundle owned by this project.
for EXISTING_BUNDLE in "${APP_BUNDLE}" "${LEGACY_APP_BUNDLE}"; do
    if [[ -e "${EXISTING_BUNDLE}" ]]; then
        EXISTING_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${EXISTING_BUNDLE}/Contents/Info.plist")"
        if [[ "${EXISTING_IDENTIFIER}" != "dev.domyshev.mode-runner" && "${EXISTING_IDENTIFIER}" != "dev.domyshev.script-mode-runner" ]]; then
            print -u2 "Refusing to replace an unrelated app: ${EXISTING_BUNDLE}"
            exit 1
        fi
    fi
done

if [[ -e "${APP_BUNDLE}" ]]; then
    rm -rf "${APP_BUNDLE}"
fi
mv "${STAGING_BUNDLE}" "${APP_BUNDLE}"
if [[ -e "${LEGACY_APP_BUNDLE}" ]]; then
    if [[ -x "${LAUNCH_SERVICES_REGISTER}" ]]; then
        "${LAUNCH_SERVICES_REGISTER}" -u "${LEGACY_APP_BUNDLE}" || print -u2 "Could not unregister the former app."
    fi
    rm -rf "${LEGACY_APP_BUNDLE}"
fi

# In-place bundle updates otherwise leave Finder/Spotlight using cached metadata.
touch "${APP_BUNDLE}"
if [[ -x "${LAUNCH_SERVICES_REGISTER}" ]]; then
    "${LAUNCH_SERVICES_REGISTER}" -f "${APP_BUNDLE}" || print -u2 "Could not refresh Launch Services registration."
fi
mdimport "${APP_BUNDLE}" || print -u2 "Could not refresh Spotlight metadata."

print "Installed: ${APP_BUNDLE}"
CONFIGURATION_PATH="${HOME}/.config/mode-runner/config.yaml"
if [[ ! -f "${CONFIGURATION_PATH}" && -f "${HOME}/.config/script-mode-runner/config.yaml" ]]; then
    CONFIGURATION_PATH="${HOME}/.config/script-mode-runner/config.yaml"
fi
print "Configuration: ${CONFIGURATION_PATH}"
print "Open the app from Finder or run:"
print "  open '${APP_BUNDLE}'"
