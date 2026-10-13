# servAI

Установщик «AI-сервера» для Ubuntu: одним скриптом ставит официальные консольные ИИ-клиенты, рабочего пользователя, tmux-раскладку из четырёх агентов и (по желанию) веб-IDE.

## Что устанавливается

| Компонент | Описание |
|---|---|
| Node.js 24 LTS | из подписанного apt-репозитория NodeSource |
| Claude Code, Codex CLI, Gemini CLI | глобально в `~/.local` рабочего пользователя, не от root |
| Aider (через pipx) | используется для DeepSeek по API |
| Команды `ai`, `ai-login`, `ai-quad` | вспомогательные скрипты в `~/.local/bin` |
| `~/.env.ai` | шаблон для API-ключей (права `600`) |
| code-server (опционально) | веб-IDE, слушает только `127.0.0.1`, служба systemd |
| Docker и harness/SWE-bench (опционально) | отключены по умолчанию |

## Требования

- Ubuntu 22.04 или 24.04, архитектура amd64 или arm64
- работающий systemd, права root (`sudo`)
- не менее 8 ГиБ свободного места (с Docker/harness — 30+ ГиБ), RAM от 4 ГиБ рекомендуется
- доступ в интернет

## Быстрый старт

```bash
git clone https://github.com/Chistovik92/servAI.git
cd servAI
bash install.sh --check      # проверить настройки, ничего не устанавливая
sudo bash install.sh         # установка
```

После установки войдите под рабочим пользователем (по умолчанию `devuser`):

```bash
ai-login      # вход в официальный клиент (Claude / Codex / Gemini)
ai-quad       # tmux-сессия с четырьмя агентами
```

## Настройка через переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TARGET_USER` | `devuser` | рабочий пользователь (не `root`) |
| `WEB_PORT` | `8443` | порт веб-IDE на loopback (1024–65535) |
| `INSTALL_WEBIDE` | `1` | ставить code-server |
| `INSTALL_DOCKER` | `0` | ставить Docker (`docker.io`) |
| `INSTALL_HARNESS` | `0` | ставить SWE-bench в venv |
| `CLAUDE_VERSION`, `CODEX_VERSION`, `GEMINI_VERSION` | `latest` | версии npm-пакетов |
| `AIDER_VERSION`, `SWEBENCH_VERSION` | не заданы | закрепить версии pip-пакетов |

Пример:

```bash
sudo TARGET_USER=alice WEB_PORT=9000 INSTALL_DOCKER=1 bash install.sh
```

## Команды

- `ai {claude|codex|gemini} {native|api} [аргументы]` — запуск клиента. `native` — вход по подписке (API-ключи из окружения скрываются), `api` — по ключу из `~/.env.ai`. Режим можно опустить: `ai claude --resume`.
- `ai deepseek api [аргументы]` — DeepSeek через Aider.
- `ai-login [claude|codex|gemini]` — интерактивный вход.
- `ai-quad [каталог]` — tmux-сессия `ai-quad` (по умолчанию `~/projects`).

## API-ключи

Заполните `~/.env.ai` (это Bash-файл с `export ...`). Файл создаётся с правами `600`, **не добавляйте его в Git**.

## Веб-IDE

code-server доступен только на `127.0.0.1`. Подключайтесь через SSH-туннель:

```bash
ssh -L 8443:127.0.0.1:8443 devuser@ВАШ_СЕРВЕР
```

Затем откройте `http://127.0.0.1:8443`. Пароль: `~/.config/code-server/config.yaml`.

## SSH-доступ

Пользователь создаётся без пароля. Добавьте свой публичный ключ вручную (под root):

```bash
install -d -m 700 -o devuser -g devuser /home/devuser/.ssh
echo 'ssh-ed25519 AAAA... вы@хост' >> /home/devuser/.ssh/authorized_keys
chown devuser:devuser /home/devuser/.ssh/authorized_keys
chmod 600 /home/devuser/.ssh/authorized_keys
```

## Безопасность

- Установка клиентов выполняется от рабочего пользователя, не от root.
- Веб-IDE не открыт наружу и защищён паролем; существующий конфиг с иными настройками отвергается.
- Скрипт отказывается работать с символическими ссылками в домашнем каталоге.
- Установщик code-server загружается с `code-server.dev` по HTTPS и запускается от root — при необходимости проверьте его заранее или отключите `INSTALL_WEBIDE=0`.
- Группа `docker` пользователю не назначается.

## Устранение неполадок

- **«Установка частичная»** — устраните причину и запустите скрипт повторно: он идемпотентен.
- **«Установка уже выполняется»** — другой экземпляр держит блокировку `/run/lock/ai-server-stack.lock`.
- Проверьте, что `~/.local/bin` в `PATH` (скрипт добавляет строку в `.profile` и `.bashrc`); перезайдите в сессию.
- Список установленных версий: `~/.config/ai-stack/installed-versions.txt`.

## Версии

См. [CHANGELOG.md](CHANGELOG.md). Лицензия — [MIT](LICENSE).
