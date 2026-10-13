#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
validate_settings() {
  [[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $TARGET_USER != root ]] || fail 'Недопустимый TARGET_USER'
  [[ $WEB_PORT =~ ^[0-9]{4,5}$ ]] || fail 'WEB_PORT должен быть числом 1024–65535'
  (( 10#$WEB_PORT >= 1024 && 10#$WEB_PORT <= 65535 )) || fail 'WEB_PORT вне диапазона'
  for flag in INSTALL_DOCKER INSTALL_WEBIDE INSTALL_HARNESS; do
    [[ ${!flag} == 0 || ${!flag} == 1 ]] || fail "$flag должен быть 0 или 1"
  done
}
TARGET_USER=${TARGET_USER:-devuser}
WEB_PORT=${WEB_PORT:-8443}
INSTALL_DOCKER=${INSTALL_DOCKER:-0}
INSTALL_WEBIDE=${INSTALL_WEBIDE:-1}
INSTALL_HARNESS=${INSTALL_HARNESS:-0}
validate_settings
if [[ ${1:-} == --check ]]; then
  printf 'Конфигурация корректна. Пользователь=%s, порт=%s\n' "$TARGET_USER" "$WEB_PORT"
  exit 0
fi
[[ $# == 0 ]] || fail 'Поддерживается только --check'
[[ $EUID == 0 ]] || fail 'Запустите sudo bash install.sh'
trap 'printf "Ошибка на строке %s. Установка частичная; устраните причину и повторите запуск.\n" "$LINENO" >&2' ERR
[[ -f /etc/os-release ]] || fail 'Нет /etc/os-release'
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && ( $VERSION_ID == 22.04 || $VERSION_ID == 24.04 ) ]] || fail 'Поддерживаются только Ubuntu 22.04/24.04'
[[ -d /run/systemd/system ]] || fail 'Нужна система с работающим systemd'
case $(dpkg --print-architecture) in amd64|arm64) ;; *) fail 'Нужен amd64 или arm64';; esac
exec 9>/run/lock/ai-server-stack.lock
flock -n 9 || fail 'Установка уже выполняется'
FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')
(( FREE_MB >= 8192 )) || fail 'Нужно не менее 8 ГиБ свободного места (для Docker/harness — 30+ ГиБ)'
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
(( RAM_MB >= 3500 )) || printf 'Предупреждение: RAM < 4 ГиБ; harness может не работать.\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git build-essential tmux python3 python3-venv pipx openssl
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos '' "$TARGET_USER"
fi
USER_UID=$(id -u "$TARGET_USER")
(( USER_UID >= 1000 )) || fail 'Нельзя использовать системного пользователя'
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
USER_GROUP=$(id -gn "$TARGET_USER")
[[ $USER_HOME == /* && $USER_HOME != / && -d $USER_HOME && ! -L $USER_HOME ]] || fail 'Небезопасный домашний каталог'
[[ $USER_HOME =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail 'Домашний каталог содержит неподдерживаемые символы'
as_user() { runuser -u "$TARGET_USER" -- env HOME="$USER_HOME" PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
download() { curl --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 300 --proto '=https' --tlsv1.2 "$1" -o "$2"; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

# Встроенные вспомогательные файлы; дополнительных загрузок проекта не нужно.
ROOT_DIR="$TMP_DIR/bundle"
mkdir -p "$ROOT_DIR/bin"
chmod 0755 "$TMP_DIR" "$ROOT_DIR" "$ROOT_DIR/bin"
cat > "$ROOT_DIR/bin/ai" <<'AI_STACK_EMBED_bin_ai'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ! -f $HOME/.env.ai ]] || source "$HOME/.env.ai"
provider=${1:-}; mode=native
if [[ ${2:-} == native || ${2:-} == api ]]; then
  mode=$2; shift 2
elif (( $# > 0 )); then
  shift
fi
case "$provider:$mode" in
  claude:native) exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude "$@" ;;
  codex:native) exec env -u OPENAI_API_KEY codex "$@" ;;
  gemini:native) exec env -u GEMINI_API_KEY -u GOOGLE_API_KEY gemini "$@" ;;
  claude:api) : "${ANTHROPIC_API_KEY:?Заполните ~/.env.ai}"; exec claude "$@" ;;
  codex:api) : "${OPENAI_API_KEY:?Заполните ~/.env.ai}"; printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key; exec codex "$@" ;;
  gemini:api) : "${GEMINI_API_KEY:?Заполните ~/.env.ai}"; exec gemini "$@" ;;
  deepseek:api) : "${DEEPSEEK_API_KEY:?Заполните ~/.env.ai}"; exec aider --model "${DEEPSEEK_MODEL:-deepseek/deepseek-chat}" "$@" ;;
  *) printf 'Использование: ai {claude|codex|gemini} {native|api} [аргументы]\n             ai deepseek api [аргументы]\n' >&2; exit 2 ;;
esac
AI_STACK_EMBED_bin_ai
chmod 0644 "$ROOT_DIR/bin/ai"
cat > "$ROOT_DIR/bin/ai-login" <<'AI_STACK_EMBED_bin_ai_login'
#!/usr/bin/env bash
set -Eeuo pipefail
provider=${1:-}
if [[ -z $provider ]]; then
  printf '1) Claude  2) Codex  3) Gemini\n'
  read -r -p 'Выберите официальный клиент: ' answer
  case $answer in 1) provider=claude;; 2) provider=codex;; 3) provider=gemini;; *) exit 2;; esac
fi
case $provider in
  claude) exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude auth login ;;
  codex) exec env -u OPENAI_API_KEY codex login --device-auth ;;
  gemini) printf 'В клиенте выберите Login with Google. Если выбран API, используйте /auth.\n'; exec env -u GEMINI_API_KEY -u GOOGLE_API_KEY gemini ;;
  *) printf 'Поддерживаются claude, codex, gemini. DeepSeek — через API.\n' >&2; exit 2 ;;
esac
AI_STACK_EMBED_bin_ai_login
chmod 0644 "$ROOT_DIR/bin/ai-login"
cat > "$ROOT_DIR/bin/ai-quad" <<'AI_STACK_EMBED_bin_ai_quad'
#!/usr/bin/env bash
set -Eeuo pipefail
WORKDIR=${1:-$HOME/projects}
SESSION=ai-quad
mkdir -p -- "$WORKDIR"
WORKDIR=$(cd -- "$WORKDIR" && pwd)
if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -n agents -c "$WORKDIR" 'ai claude native; exec bash'
  tmux split-window -t "$SESSION:agents" -h -c "$WORKDIR" 'ai codex native; exec bash'
  tmux split-window -t "$SESSION:agents" -v -c "$WORKDIR" 'ai gemini native; exec bash'
  tmux split-window -t "$SESSION:agents" -v -c "$WORKDIR" 'ai deepseek api; exec bash'
  tmux select-layout -t "$SESSION:agents" tiled
fi
if [[ -n ${TMUX:-} ]]; then
  exec tmux switch-client -t "$SESSION"
else
  exec tmux attach-session -t "$SESSION"
fi
AI_STACK_EMBED_bin_ai_quad
chmod 0644 "$ROOT_DIR/bin/ai-quad"
cat > "$ROOT_DIR/.env.ai.example" <<'AI_STACK_EMBED__env_ai_example'
# Исполняемый Bash-файл. Только ваши ключи, права 600. Не добавляйте в Git.
export ANTHROPIC_API_KEY=""
export OPENAI_API_KEY=""
export GEMINI_API_KEY=""
export DEEPSEEK_API_KEY=""
export OPENROUTER_API_KEY=""
# Выберите доступную в вашем аккаунте модель DeepSeek.
export DEEPSEEK_MODEL="deepseek/deepseek-chat"
AI_STACK_EMBED__env_ai_example
chmod 0644 "$ROOT_DIR/.env.ai.example"

# Node.js 24 LTS, подписанный apt-репозиторий NodeSource.
if ! command -v node >/dev/null || (( $(node -p 'process.versions.node.split(".")[0]') < 24 )); then
  install -d -m 0755 /etc/apt/keyrings
  download https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key "$TMP_DIR/node.key"
  gpg --batch --yes --dearmor -o "$TMP_DIR/nodesource.gpg" "$TMP_DIR/node.key"
  install -m 0644 "$TMP_DIR/nodesource.gpg" /etc/apt/keyrings/ai-nodesource.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/ai-nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main\n' > /etc/apt/sources.list.d/ai-nodesource.list
  apt-get update
  apt-get install -y nodejs
fi
for entry in .local .local/bin .config .config/ai-stack .config/code-server .env.ai .profile .bashrc; do
  [[ ! -L $USER_HOME/$entry ]] || fail "Символическая ссылка в домашнем каталоге: $entry"
done
as_user mkdir -p "$USER_HOME/.local/bin" "$USER_HOME/projects" "$USER_HOME/.config/ai-stack"
# Npm и pip выполняются от рабочего пользователя, не от root.
as_user npm install --global --prefix "$USER_HOME/.local" \
  "@anthropic-ai/claude-code@${CLAUDE_VERSION:-latest}" \
  "@openai/codex@${CODEX_VERSION:-latest}" \
  "@google/gemini-cli@${GEMINI_VERSION:-latest}"
if ! as_user pipx list 2>/dev/null | grep -Eq '(^|[[:space:]])aider-chat([[:space:]]|$)'; then
  as_user pipx install "aider-chat${AIDER_VERSION:+==$AIDER_VERSION}"
fi
for script in ai ai-login ai-quad; do
  as_user cp "$ROOT_DIR/bin/$script" "$USER_HOME/.local/bin/$script"
  as_user chmod 0755 "$USER_HOME/.local/bin/$script"
done
if [[ ! -e $USER_HOME/.env.ai ]]; then
  as_user cp "$ROOT_DIR/.env.ai.example" "$USER_HOME/.env.ai"
fi
as_user chmod 0600 "$USER_HOME/.env.ai"
PROFILE_LINE='export PATH="$HOME/.local/bin:$PATH"'
for profile in .profile .bashrc; do
  as_user touch "$USER_HOME/$profile"
  if ! grep -Fqx "$PROFILE_LINE" "$USER_HOME/$profile"; then
    printf '%s\n' "$PROFILE_LINE" | as_user tee -a "$USER_HOME/$profile" >/dev/null
  fi
done
if [[ $INSTALL_DOCKER == 1 ]]; then
  apt-get install -y docker.io
  systemctl enable --now docker
  printf 'Docker установлен; доступ через sudo у администратора. Группа docker не назначается.\n'
fi
if [[ $INSTALL_HARNESS == 1 ]]; then
  as_user python3 -m venv "$USER_HOME/projects/harness/venv"
  as_user "$USER_HOME/projects/harness/venv/bin/pip" install "swebench${SWEBENCH_VERSION:+==$SWEBENCH_VERSION}"
fi
if [[ $INSTALL_WEBIDE == 1 ]]; then
  if ! command -v code-server >/dev/null; then
    download https://code-server.dev/install.sh "$TMP_DIR/code-server-install.sh"
    sh "$TMP_DIR/code-server-install.sh" --method=standalone --prefix=/usr/local
  fi
  as_user mkdir -p "$USER_HOME/.config/code-server"
  WEB_CONFIG="$USER_HOME/.config/code-server/config.yaml"
  [[ ! -L $WEB_CONFIG ]] || fail 'Web IDE config не должен быть ссылкой'
  if [[ ! -e $WEB_CONFIG ]]; then
    WEB_PASSWORD=$(openssl rand -hex 24)
    printf 'bind-addr: 127.0.0.1:%s\nauth: password\npassword: %s\ncert: false\n' "$WEB_PORT" "$WEB_PASSWORD" | as_user tee "$WEB_CONFIG" >/dev/null
  else
    grep -Eq '^bind-addr: 127\.0\.0\.1:[0-9]+$' "$WEB_CONFIG" || fail 'Существующий Web IDE должен слушать только loopback'
    grep -qx 'auth: password' "$WEB_CONFIG" || fail 'Существующий Web IDE должен использовать пароль'
  fi
  as_user chmod 0600 "$WEB_CONFIG"
  UNIT="/etc/systemd/system/ai-code-server.service"
  if [[ -e $UNIT ]] && ! grep -qx '# Managed by ai-server-stack' "$UNIT"; then
    fail 'Конфликт systemd unit ai-code-server.service'
  fi
  cat > "$UNIT" <<UNIT_EOF
# Managed by ai-server-stack
[Unit]
Description=AI Stack code-server (loopback only)
After=network.target
[Service]
Type=simple
User=$TARGET_USER
Group=$USER_GROUP
Environment=HOME=$USER_HOME
Environment=PATH=$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/code-server --config "$WEB_CONFIG" "$USER_HOME/projects"
Restart=on-failure
RestartSec=5
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT_EOF
  # Используем реальный путь, если code-server уже установлен другим способом.
  CODE_SERVER_BIN=$(command -v code-server)
  sed -i "s|ExecStart=/usr/local/bin/code-server |ExecStart=$CODE_SERVER_BIN |" "$UNIT"
  systemctl daemon-reload
  systemctl enable ai-code-server.service
  systemctl restart ai-code-server.service
  systemctl is-active --quiet ai-code-server.service
fi
printf '\nГотово. Войдите как %s и выполните: ai-login; ai-quad\n' "$TARGET_USER"
printf 'SSH-ключ добавьте вручную, инструкция — README.md репозитория. Web IDE: SSH-туннель; пароль в ~/.config/code-server/config.yaml.\n'
as_user bash -c 'node --version; npm list -g --prefix "$HOME/.local" --depth=0 || true; pipx list || true' > "$TMP_DIR/versions.txt"
as_user tee "$USER_HOME/.config/ai-stack/installed-versions.txt" < "$TMP_DIR/versions.txt" >/dev/null
