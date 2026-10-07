# Mode Runner user guide

Mode Runner is a macOS 14+ menu bar app for starting local commands, switching between groups of commands, and reading their output. Click its terminal icon in the menu bar to open the app.

## Configure your workspace

Create `~/.config/mode-runner/config.yaml`. Each top-level tab represents a project; each button with `scripts` defines a mode. Replace the example working directory and commands with your own:

```yaml
tabs:
  - id: my-app
    title: My app
    buttons:
      - id: development
        title: Development
        scripts:
          - id: frontend
            title: Frontend :3000
            command: yarn dev --port 3000
            cwd: ~/projects/my-app
      - id: tests
        title: Tests
        scripts:
          - id: unit-tests
            title: Unit tests
            command: yarn test
            cwd: ~/projects/my-app
```

- IDs must be unique within their containing list. A mode can contain several scripts; they run in parallel with separate log tabs.
- `cwd` is the working directory. Relative paths resolve from the YAML file's directory, and `~` expands to your home directory.
- `command` runs through an interactive login zsh by default, loading your shell's tool setup. Install the tools and project dependencies before running commands.
- For direct execution, use `executable: /absolute/path/to/program` and `arguments: [arg1, arg2]` instead of `command`. Direct executables inherit the app environment; configure `PATH` when needed.
- Add `environment` to a script to provide environment variables, for example `environment: {NODE_ENV: development}`.
- Existing `~/.config/script-mode-runner/config.yaml` files are used when the new default file is absent. To choose another file when launching from Terminal, set `MODE_RUNNER_CONFIG=/path/to/config.yaml`.

After saving the file, choose **Reload configuration** in the top-right menu. Hover over that item to see the active configuration path. Reload updates the interface and command catalogs while keeping running processes and logs.

## Run modes

- Select a project tab, then select a mode. Selecting a mode shows its logs; use the play control beside the mode selector to start it.
- Use the restart control beside the mode selector to restart the selected mode. Use stop to stop the running mode.
- Starting a different mode stops the previous mode in that project first. Different projects can run at the same time; switching project tabs keeps their processes running.
- Drag project tabs onto one another to reorder them. The order is saved locally for each configuration.
- A spinner indicates work in progress. Check the process status and logs for errors; a running indicator reports a running process, rather than server readiness.

## Read and control logs

- Select a command's log tab to see its output and status. Titles stay fully visible while the tabs fit; longer titles shorten with an ellipsis when space is limited. The tooltip shows the full title with its port and the launch command. Scroll horizontally when there are too many tabs to fit comfortably.
- **Stop** stops the selected command. **Reload** restarts only that command with fresh output. **Start** runs a stopped or completed command again when compatible with the current mode.
- **Clear** clears the selected output. Configured mode command tabs stay available even after stopping or completing. Only completed command-menu and seed log tabs have a close control.
- Click HTTP or HTTPS links in output to open them in your default browser. A running process's latest detected URL also appears below its status.
- Output is kept in memory and bounded: up to 5 MB per process and 100 MB shared across logs. Older output may be discarded; logs are not restored after quitting.

## Command menus

A button with `source` opens a command menu. These commands run alongside the current mode. For example, add this button to a project's `buttons` list to expose its package.json scripts:

```yaml
- id: scripts
  title: Scripts
  cwd: ~/projects/my-app
  runner: [yarn, run]
  source:
    type: package_scripts
    path: package.json
```

Use `runner: [npm, run]` or `[pnpm, run]` for another package manager. Select a menu item to run it and open its log tab. Menus refresh when opened with the mouse; **Refresh** reloads a catalog manually. Repeated script selections create separate runs.

Seed catalogs use `json_file`, `command`, or `seed_module` sources. A seed item may ask for an additional argument before starting. Seed commands cannot overlap in the same working directory. The project's [README](https://github.com/domyshev-labs/script-mode-runner#command-menus-and-logs) includes the catalog format and configuration examples.

## Quit, restart, and existing processes

The top-right menu contains **About...**, **Documentation**, **Quit&Start "Mode Runner"**, and **Quit "Mode Runner"**. About shows the author, version, and project link; Documentation opens this guide offline.

Quit and Quit&Start ask for confirmation. **Terminate processes** is unchecked by default, so commands keep running. Check it to stop managed processes before the app exits. Quit&Start opens a replacement app instance.

At startup and configuration reload, Mode Runner detects matching mode processes owned by your user, using their exact commands and explicit working directories. It can manage processes left by an earlier instance or started in Terminal. Ambiguous matches are left unmanaged. Keep server commands in the foreground so the app can track them.

Existing processes display a detection message instead of captured output: their previous logs and eventual exit codes are unavailable. A configured port in the title, `--port` argument, or `PORT` environment variable can provide a localhost shortcut.

## Troubleshooting and installation

- **No configuration:** check the path shown by Reload configuration, create a valid YAML file, and reload it. Errors are shown in the app.
- **Command not found:** verify your shell setup, the working directory, and installed dependencies. For direct executables, use absolute paths or an explicit `PATH`.
- **A process is not detected:** provide `cwd` and an exact command. A listening port alone is insufficient to identify a process.
- **No output for a detected process:** this is expected; restart it through Mode Runner to capture new output.

For building, installing, and updating the app, see the project's [installation guide](https://github.com/domyshev-labs/script-mode-runner/blob/master/INSTALL.md). Source code and configuration examples are on [GitHub](https://github.com/domyshev-labs/script-mode-runner).
