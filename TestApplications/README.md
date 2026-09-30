# Test applications

Three independent Yarn projects for manual and automated testing of Script Mode Runner. They have no third-party npm dependencies: the servers use Node.js's built-in `http` module.

Ports:

| Project | `yarn dev:lab` | `yarn dev:mock` | `yarn mock` |
|---|---:|---:|---:|
| Application #1 | 3010 | 3010 | 3015 |
| Application #2 | 3020 | 3020 | 3025 |
| Application #3 | 3030 | 3030 | 3035 |

`dev:lab` and `dev:mock` intentionally use the same port. Their modes are mutually exclusive, so switching modes tests that the previous process group stops correctly.

To use these fixtures in the app, run it with the test configuration:

```bash
SCRIPT_MODE_RUNNER_CONFIG="$PWD/Examples/test-apps.yaml" swift run ScriptModeRunner
```
