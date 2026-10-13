#!/usr/bin/env bash
set -Eeuo pipefail
umask 022   # секреты защищаются явными chmod 600 / umask 077 в подоболочках
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
validate_settings() {
  [[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $TARGET_USER != root ]] || fail 'Недопустимый TARGET_USER'
  [[ $WEB_PORT =~ ^[0-9]{4,5}$ ]] || fail 'WEB_PORT должен быть числом 1024–65535'
  (( 10#$WEB_PORT >= 1024 && 10#$WEB_PORT <= 65535 )) || fail 'WEB_PORT вне диапазона'
  for flag in INSTALL_DOCKER INSTALL_WEBIDE INSTALL_HARNESS CONFIGURE_KEYS; do
    [[ ${!flag} == 0 || ${!flag} == 1 ]] || fail "$flag должен быть 0 или 1"
  done
}
TARGET_USER=${TARGET_USER:-devuser}
WEB_PORT=${WEB_PORT:-8443}
INSTALL_DOCKER=${INSTALL_DOCKER:-0}
INSTALL_WEBIDE=${INSTALL_WEBIDE:-1}
INSTALL_HARNESS=${INSTALL_HARNESS:-0}
CONFIGURE_KEYS=${CONFIGURE_KEYS:-1}
validate_settings
if [[ ${1:-} == --check ]]; then
  printf 'Конфигурация корректна. Пользователь=%s, порт=%s\n' "$TARGET_USER" "$WEB_PORT"
  exit 0
fi
[[ $# == 0 ]] || fail 'Поддерживается только --check'
# При запуске через `curl ... | sudo bash` stdin занят скриптом — вопросы задаём через /dev/tty.
HAVE_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
ask() { # ask <приглашение> [-s]; ответ в $REPLY
  local silent=()
  [[ ${2:-} == -s ]] && silent=(-s)
  IFS= read -r "${silent[@]}" -p "$1" REPLY </dev/tty || REPLY=''
  [[ ${2:-} != -s ]] || printf '\n' >/dev/tty
}
[[ $EUID == 0 ]] || fail 'Запустите sudo bash install.sh'
trap 'printf "Ошибка на строке %s. Установка частичная; устраните причину и повторите запуск.\n" "$LINENO" >&2' ERR
[[ -f /etc/os-release ]] || fail 'Нет /etc/os-release'
# shellcheck disable=SC1091
source /etc/os-release
case $ID in
  ubuntu) dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04 || fail 'Нужна Ubuntu 24.04 или новее' ;;
  debian) dpkg --compare-versions "${VERSION_ID:-0}" ge 12 || fail 'Нужен Debian 12 или новее (testing/sid без VERSION_ID не поддерживаются)' ;;
  *) fail 'Поддерживаются Ubuntu 24.04+ и Debian 12+ (apt-системы)' ;;
esac
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
provider=${1:-}; mode=''
case ${2:-} in
  native|api|aider|claude) mode=$2; shift 2 ;;
  *) if (( $# > 0 )); then shift; fi ;;
esac
if [[ -z $mode ]]; then
  case $provider in deepseek|openrouter) mode=aider ;; *) mode=native ;; esac
fi
need() { [[ -n ${!1:-} ]] || { printf 'Не задан %s — выполните ai-keys\n' "$1" >&2; exit 1; }; }
args=()
case "$provider:$mode" in
  claude:native) exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude "$@" ;;
  codex:native) exec env -u OPENAI_API_KEY codex "$@" ;;
  gemini:native) exec env -u GEMINI_API_KEY -u GOOGLE_API_KEY gemini "$@" ;;
  claude:api)
    need ANTHROPIC_API_KEY
    [[ -z ${CLAUDE_MODEL:-} ]] || args=(--model "$CLAUDE_MODEL")
    exec claude "${args[@]}" "$@" ;;
  codex:api)
    need OPENAI_API_KEY
    # Отдельный CODEX_HOME: вход по ключу не должен затирать подписочную авторизацию.
    export CODEX_HOME="$HOME/.codex-api"; mkdir -p -m 700 "$CODEX_HOME"
    printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
    [[ -z ${CODEX_MODEL:-} ]] || args=(-m "$CODEX_MODEL")
    exec codex "${args[@]}" "$@" ;;
  gemini:api)
    need GEMINI_API_KEY
    [[ -z ${GEMINI_MODEL:-} ]] || args=(-m "$GEMINI_MODEL")
    exec gemini "${args[@]}" "$@" ;;
  deepseek:aider|deepseek:api|deepseek:native)
    need DEEPSEEK_API_KEY
    id=${DEEPSEEK_MODEL:-deepseek-flash}; id=${id#deepseek/}
    exec aider --model "deepseek/$id" "$@" ;;
  deepseek:claude)
    # DeepSeek как модель внутри харнесса Claude Code (официальный Anthropic-совместимый эндпоинт).
    need DEEPSEEK_API_KEY
    id=${DEEPSEEK_MODEL:-deepseek-flash}; id=${id#deepseek/}
    export CLAUDE_CONFIG_DIR="$HOME/.claude-deepseek"   # не смешиваем с подписочным входом Claude
    exec env -u ANTHROPIC_API_KEY \
      ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic \
      ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY" \
      ANTHROPIC_MODEL="$id" ANTHROPIC_DEFAULT_OPUS_MODEL="$id" \
      ANTHROPIC_DEFAULT_SONNET_MODEL="$id" ANTHROPIC_DEFAULT_HAIKU_MODEL="$id" \
      CLAUDE_CODE_SUBAGENT_MODEL="$id" claude "$@" ;;
  openrouter:aider|openrouter:api|openrouter:native)
    need OPENROUTER_API_KEY
    id=${OPENROUTER_MODEL:-deepseek/deepseek-chat}; id=${id#openrouter/}
    exec aider --model "openrouter/$id" "$@" ;;
  *) printf 'Использование: ai {claude|codex|gemini} [native|api] [аргументы]\n             ai deepseek [aider|claude] [аргументы]   (aider — по умолчанию, claude — харнесс Claude Code на DeepSeek)\n             ai openrouter [аргументы]\n' >&2; exit 2 ;;
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
cat > "$ROOT_DIR/bin/ai-models" <<'AI_STACK_EMBED_bin_ai_models'
#!/usr/bin/env bash
# Выбор моделей по спискам, которые отдают официальные API провайдеров (запрос идёт с вашим ключом).
set -Eeuo pipefail
ENV_FILE=$HOME/.env.ai
[[ -t 0 ]] || { printf 'Нужен интерактивный терминал.\n' >&2; exit 1; }
[[ -f $ENV_FILE && ! -L $ENV_FILE ]] || { printf 'Сначала выполните ai-keys.\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
read -r -d '' PARSE <<'PYEOF' || true
import json, sys
d = json.load(sys.stdin); kind = sys.argv[1]
if kind == 'gemini':
    ids = [m['name'].split('/', 1)[-1] for m in d.get('models', []) if 'generateContent' in m.get('supportedGenerationMethods', [])]
else:
    ids = [m['id'] for m in d.get('data', [])]
if kind == 'openai':
    ids = [i for i in ids if i.startswith(('gpt', 'o1', 'o3', 'o4', 'codex', 'chatgpt'))]
print('\n'.join(sorted(set(ids))))
PYEOF
set_var() {
  local tmp; tmp=$(mktemp "$ENV_FILE.XXXXXX")
  { grep -v "^export $1=" "$ENV_FILE" || true; printf 'export %s=%q\n' "$1" "$2"; } > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$ENV_FILE"
}
fetch() { # fetch <вид>: печатает ID моделей из официального API
  local url; local -a hdr=()
  case $1 in
    anthropic) url='https://api.anthropic.com/v1/models?limit=1000'; hdr=("x-api-key: $ANTHROPIC_API_KEY" 'anthropic-version: 2023-06-01') ;;
    openai) url='https://api.openai.com/v1/models'; hdr=("Authorization: Bearer $OPENAI_API_KEY") ;;
    gemini) url='https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000'; hdr=("x-goog-api-key: $GEMINI_API_KEY") ;;
    deepseek) url='https://api.deepseek.com/models'; hdr=("Authorization: Bearer $DEEPSEEK_API_KEY") ;;
    openrouter) url='https://openrouter.ai/api/v1/models'; hdr=("Authorization: Bearer $OPENROUTER_API_KEY") ;;
  esac
  # Ключ передаётся через stdin (-K -), а не в аргументах: не виден в ps.
  { printf 'url = "%s"\n' "$url"; for h in "${hdr[@]}"; do printf 'header = "%s"\n' "$h"; done; } \
    | curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 45 -K - | python3 -c "$PARSE" "$1" | tr -d '\r'
}
choose() { # choose <ПЕРЕМЕННАЯ_МОДЕЛИ> <вид> <ключ> <название>
  local var=$1 kind=$2 keyvar=$3 title=$4 current=${!1:-} filter='' ans i
  local -a all=() shown=()
  [[ -n ${!keyvar:-} ]] || { printf '\n%s: ключ не задан — пропуск (ai-keys)\n' "$title"; return 0; }
  printf '\n== %s ==  сейчас: %s\n' "$title" "${current:-по умолчанию клиента}"
  if mapfile -t all < <(fetch "$kind" 2>/dev/null) && (( ${#all[@]} > 0 )); then :; else
    all=(); printf 'Не удалось получить список (ключ/сеть). Можно ввести ID вручную.\n'
  fi
  while true; do
    shown=()
    for i in "${all[@]}"; do [[ -z $filter || $i == *"$filter"* ]] && shown+=("$i"); done
    for i in "${!shown[@]}"; do (( i < 40 )) && printf '  %2d) %s\n' "$((i+1))" "${shown[$i]}"; done
    (( ${#shown[@]} > 40 )) && printf '  … ещё %d (сузьте фильтром)\n' "$(( ${#shown[@]} - 40 ))"
    IFS= read -r -p 'номер | ID | /фильтр | Enter — оставить: ' ans || return 0
    ans=${ans//[[:space:]]/}
    if [[ -z $ans ]]; then return 0
    elif [[ $ans == /* ]]; then filter=${ans#/}
    elif [[ $ans =~ ^[0-9]+$ && $ans -ge 1 && $ans -le ${#shown[@]} && $ans -le 40 ]]; then set_var "$var" "${shown[$((ans-1))]}"; printf 'сохранено: %s\n' "${shown[$((ans-1))]}"; return 0
    elif [[ $ans =~ ^[A-Za-z0-9._:/@+-]+$ && ! $ans =~ ^[0-9]+$ ]] && { (( ${#all[@]} == 0 )) || printf '%s\n' "${all[@]}" | grep -Fxq -- "$ans"; }; then set_var "$var" "$ans"; printf 'сохранено: %s\n' "$ans"; return 0
    else printf 'Нет такой модели в списке API.\n'; fi
  done
}
choose CLAUDE_MODEL anthropic ANTHROPIC_API_KEY 'Claude (Anthropic API)'
choose CODEX_MODEL openai OPENAI_API_KEY 'Codex (OpenAI API)'
choose GEMINI_MODEL gemini GEMINI_API_KEY 'Gemini (Google AI API)'
choose DEEPSEEK_MODEL deepseek DEEPSEEK_API_KEY 'DeepSeek (aider / харнесс Claude Code / SWE-bench)'
choose OPENROUTER_MODEL openrouter OPENROUTER_API_KEY 'OpenRouter'
printf '\nМодели применяются в режиме API: ai claude api, ai codex api, ai gemini api, ai deepseek [aider|claude], ai openrouter.\n'
AI_STACK_EMBED_bin_ai_models
chmod 0644 "$ROOT_DIR/bin/ai-models"
cat > "$ROOT_DIR/bin/ai-bench" <<'AI_STACK_EMBED_bin_ai_bench'
#!/usr/bin/env bash
# SWE-bench: агент mini-swe-agent на модели DeepSeek. Пример: ai-bench --subset lite --split dev --slice 0:5 -o ~/projects/harness/out
# Оценка результатов (нужен Docker): см. README, раздел «Харнесс».
set -Eeuo pipefail
[[ ! -f $HOME/.env.ai ]] || source "$HOME/.env.ai"
BIN=$HOME/projects/harness/venv/bin/mini-extra
[[ -x $BIN ]] || { printf 'Харнесс не установлен (INSTALL_HARNESS=1).\n' >&2; exit 1; }
[[ -n ${DEEPSEEK_API_KEY:-} ]] || { printf 'Не задан DEEPSEEK_API_KEY — выполните ai-keys\n' >&2; exit 1; }
id=${DEEPSEEK_MODEL:-deepseek-flash}; id=${id#deepseek/}
exec "$BIN" swebench --model "deepseek/$id" "$@"
AI_STACK_EMBED_bin_ai_bench
chmod 0644 "$ROOT_DIR/bin/ai-bench"
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
  tmux split-window -t "$SESSION:agents" -v -c "$WORKDIR" "ai deepseek ${DEEPSEEK_PANE:-aider}; exec bash"
  tmux select-layout -t "$SESSION:agents" tiled
  tmux set-option -t "$SESSION" mouse on
fi
if [[ -n ${TMUX:-} ]]; then
  exec tmux switch-client -t "$SESSION"
else
  exec tmux attach-session -t "$SESSION"
fi
AI_STACK_EMBED_bin_ai_quad
chmod 0644 "$ROOT_DIR/bin/ai-quad"
cat > "$ROOT_DIR/bin/ai-keys" <<'AI_STACK_EMBED_bin_ai_keys'
#!/usr/bin/env bash
# Интерактивный ввод API-ключей: ввод скрыт, значения безопасно пишутся в ~/.env.ai (права 600).
set -Eeuo pipefail
ENV_FILE=$HOME/.env.ai
[[ -t 0 ]] || { printf 'Нужен интерактивный терминал.\n' >&2; exit 1; }
[[ ! -L $ENV_FILE ]] || { printf '%s — символическая ссылка, отказ.\n' "$ENV_FILE" >&2; exit 1; }
[[ -e $ENV_FILE ]] || install -m 600 /dev/null "$ENV_FILE"
chmod 600 "$ENV_FILE"
declare -A LINK=(
  [ANTHROPIC_API_KEY]='https://console.anthropic.com/settings/keys'
  [OPENAI_API_KEY]='https://platform.openai.com/api-keys'
  [GEMINI_API_KEY]='https://aistudio.google.com/apikey'
  [DEEPSEEK_API_KEY]='https://platform.deepseek.com/api_keys'
  [OPENROUTER_API_KEY]='https://openrouter.ai/keys'
)
set_var() {
  local tmp; tmp=$(mktemp "$ENV_FILE.XXXXXX")
  { grep -v "^export $1=" "$ENV_FILE" || true; printf 'export %s=%q\n' "$1" "$2"; } > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$ENV_FILE"
}
printf 'Вставьте ключ и нажмите Enter (ввод скрыт). Пустая строка — оставить как есть.\n'
for name in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY; do
  state='не задан'; grep -q "^export $name=[^\"'[:space:]]" "$ENV_FILE" && state='задан'
  printf '\n%s [%s]\n  получить: %s\n' "$name" "$state" "${LINK[$name]}"
  IFS= read -r -s -p '  ключ: ' value || value=''; printf '\n'
  value=${value//[[:space:]]/}
  [[ -z $value ]] || { set_var "$name" "$value"; printf '  сохранён\n'; }
done
printf '\nПодписочный вход (без ключей): ai-login. Запуск: ai-quad\n'
read -r -p 'Выбрать модели по спискам из официальных API сейчас? [Y/n] ' answer || answer=n
[[ ${answer,,} == n* ]] || exec ai-models
AI_STACK_EMBED_bin_ai_keys
chmod 0644 "$ROOT_DIR/bin/ai-keys"
cat > "$ROOT_DIR/.env.ai.example" <<'AI_STACK_EMBED__env_ai_example'
# Исполняемый Bash-файл. Только ваши ключи, права 600. Не добавляйте в Git.
export ANTHROPIC_API_KEY=""
export OPENAI_API_KEY=""
export GEMINI_API_KEY=""
export DEEPSEEK_API_KEY=""
export OPENROUTER_API_KEY=""
# Модели (пусто = по умолчанию клиента). Удобнее выбирать командой ai-models.
export CLAUDE_MODEL=""
export CODEX_MODEL=""
export GEMINI_MODEL=""
export DEEPSEEK_MODEL="deepseek-flash"
export OPENROUTER_MODEL=""
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
# uv сам подтягивает Python 3.12: aider и SWE-bench не зависят от версии python3 в свежих дистрибутивах.
as_user pipx install uv
as_user uv tool install --python 3.12 "aider-chat${AIDER_VERSION:+==$AIDER_VERSION}"
for script in ai ai-login ai-quad ai-keys ai-models ai-bench; do
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
  [[ $INSTALL_DOCKER == 1 ]] || printf 'Предупреждение: SWE-bench для запуска требует Docker (INSTALL_DOCKER=1).\n'
  as_user mkdir -p "$USER_HOME/projects/harness"
  as_user uv venv --python 3.12 "$USER_HOME/projects/harness/venv"
  as_user uv pip install --python "$USER_HOME/projects/harness/venv/bin/python" \
    "swebench${SWEBENCH_VERSION:+==$SWEBENCH_VERSION}" "mini-swe-agent${MINISWE_VERSION:+==$MINISWE_VERSION}"
fi
if [[ $INSTALL_WEBIDE == 1 ]]; then
  if ! command -v code-server >/dev/null; then
    download https://code-server.dev/install.sh "$TMP_DIR/code-server-install.sh"
    sh "$TMP_DIR/code-server-install.sh" --method=standalone --prefix=/usr/local
  fi
  as_user mkdir -p "$USER_HOME/.config/code-server"
  WEB_CONFIG="$USER_HOME/.config/code-server/config.yaml"
  [[ ! -L $WEB_CONFIG ]] || fail 'Web IDE config не должен быть ссылкой'
  GENERATED_PASSWORD=0
  if [[ ! -e $WEB_CONFIG ]]; then
    WEB_PASSWORD=''
    if [[ $HAVE_TTY == 1 && $CONFIGURE_KEYS == 1 ]]; then
      ask 'Пароль для веб-IDE (от 12 символов; Enter — сгенерировать): ' -s
      WEB_PASSWORD=$REPLY
      [[ -z $WEB_PASSWORD || ${#WEB_PASSWORD} -ge 12 ]] || fail 'Пароль веб-IDE короче 12 символов'
    fi
    if [[ -z $WEB_PASSWORD ]]; then WEB_PASSWORD=$(openssl rand -hex 24); GENERATED_PASSWORD=1; fi
    # YAML: одинарные кавычки, внутренние ' удваиваются
    YAML_PASSWORD=${WEB_PASSWORD//\'/\'\'}
    ( umask 077; printf "bind-addr: 127.0.0.1:%s\nauth: password\npassword: '%s'\ncert: false\n" "$WEB_PORT" "$YAML_PASSWORD" | as_user tee "$WEB_CONFIG" >/dev/null )
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
as_user bash -c 'node --version; npm list -g --prefix "$HOME/.local" --depth=0 || true; pipx list || true; uv tool list || true' > "$TMP_DIR/versions.txt"
as_user tee "$USER_HOME/.config/ai-stack/installed-versions.txt" < "$TMP_DIR/versions.txt" >/dev/null
if [[ $HAVE_TTY == 1 && $CONFIGURE_KEYS == 1 ]]; then
  ask $'\nВвести API-ключи сейчас (Claude/OpenAI/Gemini/DeepSeek/OpenRouter)? [Y/n] '
  if [[ ${REPLY,,} != n* ]]; then
    runuser -u "$TARGET_USER" -- env HOME="$USER_HOME" PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" ai-keys </dev/tty || printf 'Ключи не сохранены; повторите позже: ai-keys\n'
  fi
fi
printf '\n=== Готово ===\n'
printf 'Консоль:   войдите как %s, затем:\n' "$TARGET_USER"
printf '             ai-login   — вход по подписке (покажет ссылку для авторизации в браузере)\n'
printf '             ai-keys    — ввод/смена API-ключей\n'
printf '             ai-models  — выбор моделей из списков официальных API\n'
printf '             ai-quad    — 4 агента в одном окне (tmux)\n'
printf '             ai deepseek claude — харнесс Claude Code на DeepSeek; ai deepseek — aider\n'
if [[ $INSTALL_WEBIDE == 1 ]]; then
  printf 'Веб-IDE:   ssh -L %s:127.0.0.1:%s %s@IP_СЕРВЕРА  →  http://127.0.0.1:%s\n' "$WEB_PORT" "$WEB_PORT" "$TARGET_USER" "$WEB_PORT"
  if [[ $GENERATED_PASSWORD == 1 ]]; then
    printf '           пароль (сгенерирован, показан один раз): %s\n' "$WEB_PASSWORD"
  fi
  printf '           пароль хранится в %s/.config/code-server/config.yaml\n' "$USER_HOME"
  printf '           в терминале веб-IDE запустите ai-quad — тот же разделённый экран\n'
fi
printf 'SSH-ключ добавьте вручную (README.md).\n'
