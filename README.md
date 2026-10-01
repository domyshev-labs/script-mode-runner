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

## Command menus and logs

Buttons with a `source` show a menu instead of switching modes. Selecting an
item opens an independent log tab and leaves the current mode running. Repeat
script selections create new runs; seed selections cannot overlap in the same
working directory. Completed logs remain available until closed. Use **Stop**
to stop a running command, **Close** on a completed tab, and **Clear** to clear
its output. Log tabs show the launch command, truncate long titles, and expose
the full command in a tooltip.

HTTP and HTTPS links in logs open with a normal left click in the default
browser. The browser controls whether to use a tab or window. ANSI color and
terminal hyperlink control sequences are removed from the displayed text.

Mode buttons are green while all their processes are running, orange while
starting/stopping or when only some processes remain, and red after an
unexpected failure. A user stop returns the button to its normal color. This
tracks foreground processes launched by the app, not HTTP readiness, external
processes, or detached daemons. Commands that launch a server should keep it in
the foreground. Existing mode buttons remain mutually exclusive within a
project tab; menu commands run independently.

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
Rows scroll horizontally when buttons do not fit.

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
SCRIPT_MODE_RUNNER_CONFIG="$PWD/Examples/dropdowns.yaml" swift run ScriptModeRunner
```

The demo seed runner only prints arguments; it does not modify data. Completed
history is limited to 20 unselected runs per project tab (plus a selected log).
Each log retains at most 5 MB, and a 100 MB shared budget trims older output when
necessary. Reload keeps running processes and their logs, including removed
project tabs that still own logs when the configuration is reloaded.
