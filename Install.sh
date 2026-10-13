#!/usr/bin/env bash
# ==============================================================================
# AI Server Stack 2026: Claude Code, OpenAI Codex, DeepSeek Harness, Gemini & Web IDE
# Улучшенная версия с pre-flight проверками ресурсов, безопасностью и Nginx WS.
# Модели: Claude Opus 5.5 / Fable 5.1, GPT-6.1 Sol, DeepSeek V4.
# ==============================================================================

set -euo pipefail

# ----------------- НАСТРОЙКИ ПО УМОЛЧАНИЮ -----------------
TARGET_USER="${TARGET_USER:-devuser}"
WEB_PORT="${WEB_PORT:-8443}"
WEB_ADMIN_USER="${WEB_ADMIN_USER:-admin}"
WEB_ADMIN_PASS="${WEB_ADMIN_PASS:-SecurePass_$(openssl rand -hex 4)}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-8}"

# Перехват ошибок для безопасного выхода
trap 'echo "[ОШИБКА] Скрипт прервался на строке $LINENO. Проверьте логи."' ERR

if [[ $EUID -ne 0 ]]; then
   echo "[ОШИБКА] Запустите скрипт с правами root!" >&2
   exit 1
fi

echo "=================================================================="
echo ">> Старт инициализации AI-сервера 2026"
echo ">> Пользователь: ${TARGET_USER}"
echo ">> Web IDE Port: ${WEB_PORT} (Basic Auth: ${WEB_ADMIN_USER})"
echo "=================================================================="

# ----------------- 0. PRE-FLIGHT ПРОВЕРКИ -----------------
echo "[0/10] Проверка системных требований..."

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 3500 ]; then
    echo "[ВНИМАНИЕ] Рекомендуется минимум 4ГБ RAM для SWE-bench/Docker. Найдено: ${TOTAL_RAM}МБ."
    read -p "Продолжить установку? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
fi

FREE_DISK=$(df -m / | awk 'NR==2 {print $4}')
if [ "$FREE_DISK" -lt 30000 ]; then
    echo "[ОШИБКА] Недостаточно места. Требуется 30ГБ+, доступно: $((FREE_DISK/1024))ГБ."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ----------------- 1. SWAP И ТЮНИНГ ЯДРА -----------------
echo "[1/10] Настройка Swap и ядра..."
if [ ! -f /swapfile ]; then
    if [ "$FREE_DISK" -gt $(((SWAP_SIZE_GB + 5) * 1024)) ]; then
        fallocate -l "${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024)) status=none
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        echo "[ВНИМАНИЕ] Пропускаем создание Swap — мало места на диске."
    fi
fi

cat << 'EOF' > /etc/sysctl.d/99-ai-optimizations.conf
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.file-max=2097152
fs.inotify.max_user_watches=524288
EOF
sysctl --system > /dev/null

# ----------------- 2. ПАКЕТЫ И ПОЛЬЗОВАТЕЛЬ -----------------
echo "[2/10] Установка системных утилит и создание пользователя..."
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget git jq build-essential tmux htop rsync \
    ca-certificates gnupg apache2-utils nginx ufw fail2ban \
    python3 python3-pip python3-venv python3-dev pipx libffi-dev libssl-dev

if ! id "${TARGET_USER}" &>/dev/null; then
    adduser --disabled-password --gecos "" "${TARGET_USER}"
    usermod -aG sudo "${TARGET_USER}"
    echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-${TARGET_USER}"
    chmod 0440 "/etc/sudoers.d/99-${TARGET_USER}"
fi

USER_HOME="/home/${TARGET_USER}"
mkdir -p "${USER_HOME}/.ssh"
for KEY_SOURCE in /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys; do
    if [[ -f "$KEY_SOURCE" ]]; then
        cp "$KEY_SOURCE" "${USER_HOME}/.ssh/authorized_keys"
        break
    fi
done
chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null || true

# ----------------- 3. ЗАЩИТА (UFW + Fail2Ban) -----------------
echo "[3/10] Настройка файрвола..."
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow "${WEB_PORT}/tcp" comment "Web Code Server"
ufw --force enable
systemctl enable --now fail2ban

# ----------------- 4. DOCKER ENGINE -----------------
echo "[4/10] Установка Docker..."
if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "${TARGET_USER}"

# ----------------- 5. NODE.JS И CLAUDE CODE -----------------
echo "[5/10] Установка Node.js и Claude Code CLI..."
if ! command -v node &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update -y && apt-get install -y nodejs
fi
npm install -g @anthropic-ai/claude-code

# ----------------- 6. PYTHON, AIDER & GEMINI CHAT -----------------
echo "[6/10] Установка Aider, SWE-bench и консольного клиента Gemini..."
sudo -H -u "${TARGET_USER}" bash -c '
    pipx ensurepath
    pipx install aider-chat
    
    # Настройка SWE-bench / Harness
    mkdir -p ~/projects/harness ~/projects/swe-bench
    python3 -m venv ~/projects/harness/venv
    ~/projects/harness/venv/bin/pip install --upgrade pip setuptools wheel
    ~/projects/harness/venv/bin/pip install swebench datasets litellm openai requests google-genai

    # Простой клиент для общения с Gemini в терминале
    mkdir -p ~/.local/bin
    cat << "EOF_GEMINI" > ~/.local/bin/gemini-chat
#!/usr/bin/env python3
import os
import sys
try:
    from google import genai
except ImportError:
    print("Устанавливаю библиотеку google-genai...")
    os.system("pip install google-genai --break-system-packages >/dev/null 2>&1")
    from google import genai

api_key = os.getenv("GEMINI_API_KEY")
if not api_key:
    print("Ошибка: GEMINI_API_KEY не установлен. Добавьте его в ~/.env.ai")
    sys.exit(1)

client = genai.Client(api_key=api_key)
chat = client.chats.create(model="gemini-2.5-pro")

print("\n=== Терминал Gemini 2.5 Pro ===")
print("Введите exit или quit для выхода\n")

while True:
    try:
        user_msg = input("\033[92mВы:\033[0m ")
        if user_msg.strip().lower() in ["exit", "quit"]: break
        if not user_msg.strip(): continue
        
        print("\033[96mGemini:\033[0m", end=" ", flush=True)
        response = chat.send_message_stream(user_msg)
        for chunk in response:
            print(chunk.text, end="", flush=True)
        print("\n")
    except KeyboardInterrupt:
        break
    except Exception as e:
        print(f"\nОшибка: {e}")
EOF_GEMINI
    chmod +x ~/.local/bin/gemini-chat
'

# ----------------- 7. ШЛЮЗ API КЛЮЧЕЙ -----------------
echo "[7/10] Настройка конфигурации API-ключей (~/.env.ai)..."
cat << 'EOF' > "${USER_HOME}/.env.ai"
export ANTHROPIC_API_KEY=""
export OPENAI_API_KEY=""
export DEEPSEEK_API_KEY=""
export GEMINI_API_KEY=""
export OPENROUTER_API_KEY=""
EOF
chown "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.env.ai"
chmod 600 "${USER_HOME}/.env.ai"

sudo -H -u "${TARGET_USER}" bash -c '
    sed -i "/source ~\/.env.ai/d" ~/.bashrc
    echo "source ~/.env.ai" >> ~/.bashrc
    
    sed -i "/export PATH=.*\.local\/bin/d" ~/.bashrc
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
'

# ----------------- 8. TMUX: АГЕНТЫ В 4 ОКНА (QUAD) -----------------
echo "[8/10] Настройка мульти-воркспейса (ai-quad) с актуальными моделями..."
sudo -H -u "${TARGET_USER}" bash -c '
cat << "EOF_TMUX" > ~/.tmux.conf
set -g mouse on
set -g default-terminal "screen-256color"
set -g prefix C-b
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D
set -g status-bg black
set -g status-fg cyan
set -g status-left "#[fg=green][AI-QUAD] "
EOF_TMUX

cat << "EOF_QUAD" > ~/.local/bin/ai-quad
#!/usr/bin/env bash
WORKDIR="${1:-$HOME/projects}"
SESSION="ai-quad"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach-session -t "$SESSION"
    exit 0
fi

tmux new-session -d -s "$SESSION" -c "$WORKDIR"
tmux split-window -h -c "$WORKDIR"
tmux select-pane -t 0
tmux split-window -v -c "$WORKDIR"
tmux select-pane -t 2
tmux split-window -v -c "$WORKDIR"

# 0: Верх-лево - Claude Opus 5.5
tmux send-keys -t "$SESSION:0.0" "echo 'Для нативного клиента используйте команду claude'; aider --model claude-opus-5-5" C-m

# 1: Низ-лево - Gemini Chat
tmux send-keys -t "$SESSION:0.1" "gemini-chat" C-m

# 2: Верх-право - OpenAI GPT-6.1 Sol
tmux send-keys -t "$SESSION:0.2" "aider --model gpt-6.1-sol" C-m

# 3: Низ-право - DeepSeek V4
tmux send-keys -t "$SESSION:0.3" "aider --model deepseek/deepseek-v4" C-m

tmux select-pane -t "$SESSION:0.0"
tmux attach-session -t "$SESSION"
EOF_QUAD
chmod +x ~/.local/bin/ai-quad
'

# ----------------- 9. ВЕБ-ПАНЕЛЬ CODE-SERVER И NGINX -----------------
echo "[9/10] Развертывание Web IDE (VS Code) и Nginx (с поддержкой WebSockets)..."
if ! command -v code-server &>/dev/null; then
    curl -fsSL https://code-server.dev/install.sh | sh
fi

sudo -H -u "${TARGET_USER}" bash -c '
    mkdir -p ~/.config/code-server
    cat << EOF > ~/.config/code-server/config.yaml
bind-addr: 127.0.0.1:8080
auth: none
cert: false
EOF
'
systemctl enable --now code-server@${TARGET_USER}

mkdir -p /etc/nginx/auth
htpasswd -b -c /etc/nginx/auth/.htpasswd "${WEB_ADMIN_USER}" "${WEB_ADMIN_PASS}"

cat << EOF > /etc/nginx/sites-available/ai-webide
server {
    listen ${WEB_PORT};
    server_name _;
    auth_basic "AI Environment Restricted Area";
    auth_basic_user_file /etc/nginx/auth/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available/ai-webide /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# ----------------- 10. ФИНАЛ -----------------
SERVER_IP=$(curl -s ifconfig.me || echo "IP_СЕРВЕРА")
echo ""
echo "=================================================================="
echo "                   УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА"
echo "=================================================================="
echo "1. Web-панель (редактор кода): http://${SERVER_IP}:${WEB_PORT}"
echo "   Логин: ${WEB_ADMIN_USER} | Пароль: ${WEB_ADMIN_PASS}"
echo ""
echo "2. Подключение по SSH (Termius):"
echo "   ssh ${TARGET_USER}@${SERVER_IP}"
echo ""
echo "3. Ваши API ключи лежат в файле (нужно заполнить):"
echo "   ~/.env.ai"
echo ""
echo "4. Запуск 4-х нейросетей одновременно в терминале:"
echo "   ai-quad"
echo "==================================================================”
