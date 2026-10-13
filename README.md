# servAI

Установщик «AI-сервера» для Ubuntu 24.04+ и Debian 12+: одним скриптом ставит официальные консольные ИИ-клиенты, рабочего пользователя, tmux-раскладку из четырёх агентов и (по желанию) веб-IDE.

## Что устанавливается

| Компонент | Описание |
|---|---|
| Node.js 24 LTS | из подписанного apt-репозитория NodeSource |
| Claude Code, Codex CLI, Gemini CLI | глобально в `~/.local` рабочего пользователя, не от root |
| Aider (через uv, Python 3.12) | DeepSeek и OpenRouter по официальному API |
| Команды `ai`, `ai-login`, `ai-keys`, `ai-models`, `ai-quad`, `ai-bench` | вспомогательные скрипты в `~/.local/bin` |
| `~/.env.ai` | шаблон для API-ключей (права `600`) |
| code-server (опционально) | веб-IDE, слушает только `127.0.0.1`, служба systemd |
| Docker и harness/SWE-bench (опционально) | отключены по умолчанию |

## Требования

Модели работают в облаке провайдеров, поэтому GPU не нужен — серверу нужны только процессор, память и диск под клиенты, tmux и (опционально) веб-IDE.

| Сценарий | CPU | RAM | Диск | 
|---|---|---|---|
| Минимум: только консольные клиенты + tmux (`INSTALL_WEBIDE=0`) | 1 vCPU | 2 ГиБ | 8 ГиБ свободно |
| **Рекомендуется**: клиенты + веб-IDE (по умолчанию) | 2 vCPU | 4 ГиБ | 20 ГиБ |
| С Docker и SWE-bench harness (`INSTALL_DOCKER=1 INSTALL_HARNESS=1`) | 4–8 vCPU | 16 ГиБ | 120 ГиБ |

Общее: **Ubuntu 24.04 и новее** (24.04, 25.10, 26.04…) или **Debian 12 и новее** (amd64 или arm64), работающий systemd, root (`sudo`), исходящий интернет (HTTPS) до npm, PyPI, GitHub, NodeSource и API провайдеров. Для Debian минимальный образ может не содержать `sudo` и `curl` — поставьте их (`apt install sudo curl`) или запускайте от root без `sudo`. Fedora/RHEL/Arch (не apt) пока не поддерживаются. Python для aider и SWE-bench ставит `uv` (3.12), поэтому слишком новый системный `python3` не мешает. Установщик отказывается работать при < 8 ГиБ свободного места и предупреждает при RAM < 4 ГиБ.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/Chistovik92/servAI/main/install.sh | sudo bash
```

Скрипт сам задаст вопросы (пароль веб-IDE, API-ключи) через `/dev/tty`, поэтому интерактивность работает и при запуске через конвейер. С параметрами:

```bash
curl -fsSL https://raw.githubusercontent.com/Chistovik92/servAI/main/install.sh | sudo TARGET_USER=alice WEB_PORT=9000 INSTALL_DOCKER=1 bash
```

Без вопросов (CI, cloud-init): добавьте `CONFIGURE_KEYS=0` — пароль веб-IDE сгенерируется, ключи вводятся позже командой `ai-keys`.

Осторожнее с `curl | sudo bash`: скрипт исполняется с правами root. Если хотите сначала посмотреть код:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/Chistovik92/servAI/main/install.sh
less install.sh
bash install.sh --check     # только проверка настроек
sudo bash install.sh
```

## Что происходит после установки

1. Установщик спрашивает пароль веб-IDE (Enter — сгенерировать) и предлагает ввести API-ключи (`ai-keys`; ввод скрыт, рядом показана ссылка, где ключ получить).
2. Подписочный вход (без ключей): `ai-login` — клиент напечатает ссылку авторизации, откройте её в браузере на своём компьютере.
3. `ai-models` — выбор моделей из списков, которые отдают официальные API (см. ниже).
4. `ai-quad` — Claude, Codex, Gemini и DeepSeek в одном окне tmux (2×2, мышь включена).
5. Веб-IDE: SSH-туннель на `127.0.0.1`, в её терминале тоже работает `ai-quad`.

## Настройка через переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TARGET_USER` | `devuser` | рабочий пользователь (не `root`) |
| `WEB_PORT` | `8443` | порт веб-IDE на loopback (1024–65535) |
| `INSTALL_WEBIDE` | `1` | ставить code-server |
| `INSTALL_DOCKER` | `0` | ставить Docker (`docker.io`) |
| `INSTALL_HARNESS` | `0` | ставить SWE-bench в venv (нужен Docker) |
| `CONFIGURE_KEYS` | `1` | задавать вопросы (пароль веб-IDE, ключи); `0` — без вопросов |
| `CLAUDE_VERSION`, `CODEX_VERSION`, `GEMINI_VERSION` | `latest` | версии npm-пакетов |
| `AIDER_VERSION`, `SWEBENCH_VERSION`, `MINISWE_VERSION` | не заданы | закрепить версии pip-пакетов |

Пример:

```bash
sudo TARGET_USER=alice WEB_PORT=9000 INSTALL_DOCKER=1 bash install.sh
```

## Модели и официальные API

`ai-models` по вашим ключам запрашивает списки моделей напрямую у провайдеров и сохраняет выбор в `~/.env.ai`:

| Провайдер | Эндпоинт списка | Переменная |
|---|---|---|
| Anthropic | `api.anthropic.com/v1/models` | `CLAUDE_MODEL` |
| OpenAI | `api.openai.com/v1/models` | `CODEX_MODEL` |
| Google Gemini | `generativelanguage.googleapis.com/v1beta/models` | `GEMINI_MODEL` |
| DeepSeek | `api.deepseek.com/models` | `DEEPSEEK_MODEL` |
| OpenRouter | `openrouter.ai/api/v1/models` | `OPENROUTER_MODEL` |

В списке можно выбрать номер, ввести ID или `/текст` для фильтра. Ключ передаётся curl через stdin и не виден в `ps`. Выбранные модели применяются в режиме `api`; в режиме `native` (подписка) клиент использует свою модель по умолчанию.

## DeepSeek: модель и харнесс

DeepSeek работает тремя способами, все через официальный API и один ключ `DEEPSEEK_API_KEY`:

- `ai deepseek` — харнесс Aider с моделью DeepSeek.
- `ai deepseek claude` — харнесс **Claude Code** с DeepSeek вместо Claude (официальный Anthropic-совместимый эндпоинт `api.deepseek.com/anthropic`; настройки хранятся отдельно в `~/.claude-deepseek`, подписочный вход не затрагивается).
- `ai-bench` — оценка на **SWE-bench** агентом mini-swe-agent с моделью DeepSeek (`INSTALL_HARNESS=1`, для оценки нужен Docker):

```bash
ai-bench --subset lite --split dev --slice 0:5 -o ~/projects/harness/out
# оценка: проверьте формат preds (preds.json / jsonl) и запустите
~/projects/harness/venv/bin/python -m swebench.harness.run_evaluation \
  --dataset_name princeton-nlp/SWE-bench_Lite --predictions_path <файл> --max_workers 4 --run_id test1
```

В панели ai-quad четвёртым агентом можно запустить харнесс Claude Code: `DEEPSEEK_PANE=claude ai-quad`. Имена моделей DeepSeek меняются — берите актуальные через `ai-models`.

## Команды

- `ai {claude|codex|gemini} [native|api] [аргументы]` — запуск клиента. `native` — вход по подписке (API-ключи из окружения скрываются), `api` — по ключу из `~/.env.ai`. Режим можно опустить: `ai claude --resume`.
- `ai deepseek [aider|claude] [аргументы]`, `ai openrouter [аргументы]` — DeepSeek и OpenRouter.
- `ai-models` — выбор моделей по спискам официальных API.
- `ai-bench` — SWE-bench на DeepSeek.
- `ai-keys` — интерактивный ввод API-ключей в `~/.env.ai`.
- `ai-login [claude|codex|gemini]` — интерактивный вход.
- `ai-quad [каталог]` — tmux-сессия `ai-quad` (по умолчанию `~/projects`).

## API-ключи

Проще всего командой `ai-keys` (ввод скрыт, значения экранируются). Либо вручную в `~/.env.ai` (Bash-файл с `export ...`). Файл создаётся с правами `600`, **не добавляйте его в Git**.

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
- Режим `ai codex api` использует отдельный `CODEX_HOME` (`~/.codex-api`), чтобы не затирать подписочный вход.

## Устранение неполадок

- **«Установка частичная»** — устраните причину и запустите скрипт повторно: он идемпотентен.
- **«Установка уже выполняется»** — другой экземпляр держит блокировку `/run/lock/ai-server-stack.lock`.
- Проверьте, что `~/.local/bin` в `PATH` (скрипт добавляет строку в `.profile` и `.bashrc`); перезайдите в сессию.
- Список установленных версий: `~/.config/ai-stack/installed-versions.txt`.

## Версии

См. [CHANGELOG.md](CHANGELOG.md). Лицензия — [MIT](LICENSE).
