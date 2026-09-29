# Test applications

Три независимых Yarn-проекта для ручной и автоматической проверки Script Mode Runner. Сторонних npm-зависимостей нет: сервер использует встроенный модуль Node.js `http`.

Порты:

| Project | `yarn dev:lab` | `yarn dev:mock` | `yarn mock` |
|---|---:|---:|---:|
| Application #1 | 3010 | 3010 | 3015 |
| Application #2 | 3020 | 3020 | 3025 |
| Application #3 | 3030 | 3030 | 3035 |

`dev:lab` и `dev:mock` используют один порт намеренно: соответствующие режимы взаимоисключающие, поэтому переключение проверяет корректную остановку предыдущей process group.

Чтобы использовать fixtures в приложении, запустите его с тестовой конфигурацией:

```bash
SCRIPT_MODE_RUNNER_CONFIG="$PWD/Examples/test-apps.yaml" swift run ScriptModeRunner
```
