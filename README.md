# Mode Runner

**Your frontend projects and mock servers, together in your Mac's menu bar.**

Working on several frontend projects shouldn't mean juggling terminals,
remembering ports, and wondering what happens to your dev servers when you close
your IDE.

Sound familiar?

- Should you run your apps in a terminal or through your IDE?
- A separate terminal window, or another tab inside the IDE?
- Will closing the IDE also stop your dev servers?
- Which project is running on which localhost port?
- Does every app need a mock server—and another terminal to keep track of?

We built Mode Runner because we were tired of keeping all of this in our heads.

Give each project a tab, configure its development modes, and launch the app and
its mock server together. See what's running, read each command's logs, and open
local URLs from one place.

## Less juggling. More building.

- **Keep several projects running.** Switch project tabs without stopping their
  processes.
- **Start your app and mocks together.** A mode can launch multiple commands, each
  with its own log tab.
- **Switch development modes.** Starting another mode stops the previous mode
  within that project.
- **Open your local app without remembering its port.** Click URLs detected in
  logs or configured localhost shortcuts.
- **Keep your workflow independent of your IDE.** Manage processes from the menu
  bar, and choose whether they keep running when you quit Mode Runner.
- **Use your existing commands.** Run npm, Yarn, pnpm, or other tools with a YAML
  configuration.

A native macOS app. Requires macOS 14 or later.

## Installation and documentation

For setup and installation on another Mac, see [INSTALL.md](INSTALL.md).

For daily use, see the [user guide](Sources/ModeRunnerApp/Resources/Usage.md), also
available offline through **Documentation** in the app's top-right menu. This
portable Markdown file is the single source for the bundled guide and can be
published on the project website later.

## Quick start

1. Create `~/.config/mode-runner/config.yaml` using `Examples/config.yaml` as a template.
2. Build and run the app with `swift run ModeRunner`.
3. Open the terminal icon in the menu bar.

Existing configurations at `~/.config/script-mode-runner/config.yaml` remain
supported when the new default path is absent. `MODE_RUNNER_CONFIG` selects a
custom configuration; `SCRIPT_MODE_RUNNER_CONFIG` remains a compatible alias.
The renamed app also imports locally saved project tab order.

A command can use an `executable`/`arguments` pair or a `command` string executed through a shell. Yarn, npm, Python, local binaries, and other programs are handled the same way.

Build with Xcode 26 or newer (Xcode 27 is recommended for macOS 27). Navigation and controls use native Liquid Glass on macOS 26 and later, including the system's current rendering on macOS 27. macOS 14–15 use standard materials. Light/dark appearance, Reduce Transparency, and Increase Contrast are respected. Logs keep a solid background for readability.

Run `./Scripts/install.sh` to build a locally signed `.app` with a custom Finder and Spotlight icon. The colored menu bar icon matches the app icon and gently grows and shrinks three times on startup. Reduce Motion disables the animation.

The menu bar image is generated from the same vector artwork as the app icon. After changing `Scripts/generate-icon.swift`, refresh the checked-in resource before building:

```bash
swift Scripts/generate-icon.swift .build/menu-icon.iconset
cp .build/menu-icon.iconset/icon_128x128.png Sources/ModeRunnerApp/Resources/MenuBarIcon.png
```

## Test applications

`TestApplications` contains three small Yarn projects. The ready-to-use `Examples/test-apps.yaml` configuration creates a tab for each project with two modes:

- `Lab` runs `yarn dev:lab`;
- `Mock pair` runs `yarn dev:mock` and `yarn mock` in parallel with separate output tabs.

Working directories in YAML are resolved relative to the YAML file. This lets you keep portable configurations alongside the project.

Run the app with the test configuration:

```bash
MODE_RUNNER_CONFIG="$PWD/Examples/test-apps.yaml" swift run ModeRunner
```

## MVP behavior

- Modes within the same top-level tab are mutually exclusive.
- Selecting a mode changes the displayed logs without starting or stopping processes.
- Use the controls beside the mode selector to start the selected mode, restart it,
  or stop the running mode. Starting a different mode stops the previous one first.
- Switching top-level tabs does not deactivate a mode.
- Drag project tabs onto one another to change their order. The order is saved
  locally for each configuration file and restored when the app starts again.
- Reloading preserves running processes while updating the configuration shown in the UI.
- The top-right hamburger menu offers **Reload configuration**, **Settings...**, **About...**,
  **Documentation**, **Quit&Start "Mode Runner"**, and **Quit "Mode Runner"**.
  About includes the app icon, author, version/build when available, and project
  link. Documentation opens the bundled Markdown user guide in a separate window.
  Hover over Reload configuration to see the file path. Right-clicking the app icon
  in the menu bar opens the same menu.
- Quit&Start and Quit require confirmation. **Terminate processes** is unchecked by
  default; enable it to stop managed process groups before closing the app.
  Confirm with **Remember choice** to skip future confirmations for both actions
  and reuse the selected process behavior. **Settings...** lets you restore
  confirmation or change the saved process choice.
  If exit hangs for six seconds, an independent watchdog forces the app to quit;
  Quit&Start then launches a replacement instance.
- At startup and configuration reload, the app discovers existing mode processes
  owned by the current user using their exact command and working directory. This
  includes processes left by a previous app instance and matching terminal commands.
  The detected mode is selected, its project tab gains a running indicator, and
  Stop/Restart become available without launching duplicate processes.
- Detection requires an explicit `cwd`. Ambiguous matches are left unmanaged;
  a listening port alone does not establish which configured mode owns a process.
  Common Yarn commands also match Node-based Yarn wrappers. Complex shell commands
  match only while their exact shell invocation remains visible.
- Stop checks PID and process start time before signalling an adopted process and
  its descendants. It does not signal the terminal's entire process group.
- Processes left running continue independently. Their output is drained after exit.
  An adopted process shows an explanation instead of restored logs: existing stdout
  and stderr are not captured, and its eventual exit code is unavailable.
- The app keeps at most 5 MB of output per process in memory.

## Command menus and logs

Buttons with a `source` show a menu instead of switching modes. Selecting an
item opens a log tab in the current mode context and leaves the mode running. Repeat
script selections create new runs; seed selections cannot overlap in the same
working directory. Completed menu logs remain available in that context until closed. Mode logs show only the selected mode, with one tab per configured script; restarting shows its newest run. Stopping or finishing a mode keeps its last logs visible. Use **Stop**
to stop a running command, **Reload** immediately to its left to restart only that
command with fresh output, **Start** to run a stopped or completed command again,
**Close** on a completed menu-command or seed tab, and **Clear** to clear
its output. Log tabs keep their natural title widths while the row fits, then
truncate longer titles to fit the container. Crowded rows remain horizontally
scrollable. Titles display ports as `command • 3015`. Tooltips show aligned
`command:` and `port:` rows without visible borders.
Configured mode command tabs cannot be closed, including when their processes
are stopped or completed.

HTTP and HTTPS links in logs show a pointing-hand cursor and open with a normal
left click in the default browser. While the selected process is running, its
latest detected URL also appears as a shortcut below the status line. For adopted
processes without captured output, a localhost shortcut is derived from an explicit
port in the script title (such as `Dev · :3010`), a `--port` argument, or the `PORT`
environment setting. URLs found in output take precedence. The shortcut disappears
when the process stops; clearing output preserves a configured port shortcut.
Adoption messages use a bold heading and separate lines for the absolute working
directory, matching configured command, port, and detection date and local time,
including its UTC offset. The browser controls whether to use a tab or window. ANSI color and
terminal hyperlink control sequences are removed from the displayed text.

Mode and menu buttons use the same compact height and a neutral border. Menu
buttons size to their label; longer command titles appear only in the open menu.
Play is green and Stop is red. A spinner indicates starting or stopping; process
status and failures remain visible in the selected log. This tracks foreground
processes launched by the app and discovered foreground mode processes, rather
than HTTP readiness or detached daemons. Commands that launch a server should keep it in the foreground. Existing
mode buttons remain mutually exclusive within a project tab; menu commands run
independently.

### package.json scripts

```yaml
buttons:
  - id: scripts
    title: Scripts
    cwd: ~/projects/my-app
    runner: [yarn, run]
    margin_left: 0
    margin_right: 16
    source:
      type: package_scripts
      path: package.json
```

`runner` is an argument array, defaulting to `[yarn, run]`; use `[npm, run]` or
`[pnpm, run]` as needed. The selected script name is passed as an argument,
with shell quoting to prevent interpolation. The app does not install packages
when loading menus. Menus load at startup/Reload, offer **Refresh**, and refresh
when opened by mouse. `path` is relative to the button's `cwd`, which is relative
to the configuration file; omitted `cwd` defaults to that file's directory.
Button `environment` applies to catalog commands and selected runs.

`margin_left` and `margin_right` are finite nonnegative numbers in macOS points,
defaulting to zero. These are external margins and add to the row's 8-point gap.
Set `align: right` to place a button at the right edge; omitted `align` defaults to `left`. Order is preserved within each alignment group. Rows scroll horizontally when buttons do not fit.

### Seed catalogs

Use `json_file` for a catalog file or `command` for a read-only command whose
stdout contains only a JSON array. Each item has a unique `id`, `title`, and
`arguments`; optional `parameter` requests one additional argument before launch:

```json
[
  {"id":"coverage","title":"Coverage","arguments":["coverage"]},
  {"id":"component","title":"Component…","arguments":["component"],
   "parameter":{"prompt":"Component name","default":"ADB"}}
]
```

```yaml
buttons:
  - id: seeds
    title: Seeds
    align: right
    cwd: ~/projects/my-app
    runner: [yarn, mock:seed]
    source:
      type: command
      command: node mock/list-seeds.cjs
```

For a file, replace the source with `{type: json_file, path: seeds.json}`.
Catalog commands use the configured working directory and environment, time out
after 10 seconds, and are limited to 1 MB of stdout/stderr. Their startup shell
files must not print non-JSON content to stdout. Errors remain visible in the
menu without disabling other buttons.

UI2 already exports `seedSetNames` from `mock/data/seed-sets.cjs`; the
`seed_module` adapter reads that export through Node without running the seed
CLI or opening its database:

```yaml
buttons:
  - id: seeds
    title: Seeds
    align: right
    cwd: /path/to/ui2
    runner: [yarn, mock:seed]
    source:
      type: seed_module
      path: mock/data/seed-sets.cjs
      parameters:
        component: {prompt: Component name, default: ADB}
        source: {prompt: Producer source, default: zabbix}
```

Only import modules whose top-level code is read-only. To target another
UI2 database, configure `environment.MOCK_DB_PATH` explicitly. The local Event
Search checkout currently has fixed in-memory fixtures; connect a catalog using
the same JSON contract once its seed list and launch command are available.

Try the bundled menus with:

```bash
MODE_RUNNER_CONFIG="$PWD/Examples/dropdowns.yaml" swift run ModeRunner
```

The demo seed runner only prints arguments; it does not modify data. Completed
history is limited to 20 unselected runs per project tab (plus a selected log).
Each log retains at most 5 MB, and a 100 MB shared budget trims older output when
necessary. Reload keeps running processes and their logs, including removed
project tabs that still own logs when the configuration is reloaded.
