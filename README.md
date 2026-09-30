# Script Mode Runner

A native macOS 14+ menu bar app that runs configured groups of commands and displays their output.

For setup and installation on another Mac, see [INSTALL.md](INSTALL.md).

## Quick start

1. Create `~/.config/script-mode-runner/config.yaml` using `Examples/config.yaml` as a template.
2. Build and run the app with `swift run ScriptModeRunner`.
3. Open the terminal icon in the menu bar.

A command can use an `executable`/`arguments` pair or a `command` string executed through a shell. Yarn, npm, Python, local binaries, and other programs are handled the same way.

A complete `.app` build with signing and notarization requires Xcode. The current Swift Package build is intended for development and testing the runner.

## Test applications

`TestApplications` contains three small Yarn projects. The ready-to-use `Examples/test-apps.yaml` configuration creates a tab for each project with two modes:

- `Lab` runs `yarn dev:lab`;
- `Mock pair` runs `yarn dev:mock` and `yarn mock` in parallel with separate output tabs.

Working directories in YAML are resolved relative to the YAML file. This lets you keep portable configurations alongside the project.

Run the app with the test configuration:

```bash
SCRIPT_MODE_RUNNER_CONFIG="$PWD/Examples/test-apps.yaml" swift run ScriptModeRunner
```

## MVP behavior

- Modes within the same top-level tab are mutually exclusive.
- Switching top-level tabs does not deactivate a mode.
- Reloading preserves running processes while updating the configuration shown in the UI.
- On normal exit, the app stops managed process groups.
- The app keeps at most 5 MB of output per process in memory.
