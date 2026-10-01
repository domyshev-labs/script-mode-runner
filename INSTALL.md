# Installing Script Mode Runner on another Mac

## Requirements

- macOS 14 Sonoma or newer;
- Apple Silicon or Intel Mac;
- full Xcode installation;
- Node.js and Yarn Classic when the configured commands use Yarn.

## 1. Install Xcode

Install Xcode from the Mac App Store, launch it once, and accept the license and component installation prompts.

Verify the bundled Swift toolchain without changing the Mac's global developer-directory setting:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift --version
```

## 2. Install Node.js and Yarn Classic

If Homebrew is already installed:

```bash
brew install node
npm install -g yarn@1.22.22
```

Alternatively, install the current Node.js LTS package from [nodejs.org](https://nodejs.org/), then install Yarn:

```bash
npm install -g yarn@1.22.22
```

Verify both commands:

```bash
node --version
yarn --version
```

The expected Yarn version is `1.22.22`.

## 3. Copy or clone the project

Clone the repository when a remote is available, or copy the entire project directory to the other Mac. Then enter it:

```bash
cd /path/to/script-mode-runner
```

## 4. Build and test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test
```

This downloads the pinned Yams dependency and runs the process, mock-pair, and AppKit log-viewer tests.

## 5. Install the app

Run the local installer:

```bash
./Scripts/install.sh
```

It builds a release executable, creates `Script Mode Runner.app`, applies an ad-hoc local signature, and installs it to:

```text
~/Applications/Script Mode Runner.app
```

To install into a different application directory, pass it as the first argument:

```bash
./Scripts/install.sh /Applications
```

Writing to `/Applications` may require administrator permission. `~/Applications` is recommended for local development builds.

## 6. Configure commands

The installed app reads:

```text
~/.config/script-mode-runner/config.yaml
```

Create the directory and copy the general example:

```bash
mkdir -p ~/.config/script-mode-runner
cp Examples/config.yaml ~/.config/script-mode-runner/config.yaml
```

Edit every `cwd`, executable, command, and environment value for the new Mac. Relative `cwd` values are resolved from the directory containing the YAML file.

Commands use an interactive login zsh (`zsh -ilc`) by default, loading `.zprofile` and `.zshrc` so tools initialized there (such as Node and Yarn through NVM) are available when the app starts from Finder. Startup files also run their other commands and may print output. Custom shells other than zsh use `-lc`. Direct `executable` entries inherit the app's environment; use absolute executable paths and configure `PATH` when needed.

## Running the included test applications

For the repository fixtures, run from Terminal so the example YAML remains next to the fixture directories:

```bash
SCRIPT_MODE_RUNNER_CONFIG="$PWD/Examples/test-apps.yaml" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run ScriptModeRunner
```

The three tabs expose:

- `Lab`: one `yarn dev:lab` process;
- `Mock pair`: a `yarn dev:mock` frontend and a `yarn mock` backend with separate output tabs.

The mock frontend requests `/api/test-data` from its paired backend. The web page and both command logs identify the mock-server number and port.

## Launching the installed app

Open `~/Applications/Script Mode Runner.app` in Finder. Its terminal icon appears in the macOS menu bar; the app does not create a Dock icon.

Because this is a locally built, ad-hoc-signed application, another Mac may ask for confirmation the first time it is opened. A public build should use a Developer ID signature and Apple notarization instead.

## Updating

Pull or copy the newer source tree and rerun:

```bash
./Scripts/install.sh
```

The installer replaces the executable and metadata inside the existing local app bundle. It does not overwrite the user's YAML configuration.
