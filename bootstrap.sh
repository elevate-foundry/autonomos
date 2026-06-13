#!/bin/sh
# ============================================================
# AUTONOMOS — Self-Bootstrapping Autonomous Agent
# ============================================================
# Zero assumptions. Discovers its environment. Builds itself.
# Works on: Termux (Android), Linux, macOS, WSL, any POSIX shell.
# ============================================================
# Usage: curl -fsSL <url>/bootstrap.sh | sh
# ============================================================

set -e

# --- Configuration (all derived, nothing hardcoded) ---
AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
LOG_FILE="$AGENT_DIR/bootstrap.log"

# --- Utility functions ---
say() { printf '\033[1;36m[agent]\033[0m %s\n' "$1"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; }
logged() { "$@" >> "$LOG_FILE" 2>&1; }

detect_os() {
    case "$(uname -s)" in
        Linux*)
            if [ -d /data/data/com.termux ]; then
                echo "termux"
            else
                echo "linux"
            fi
            ;;
        Darwin*) echo "macos" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armv8*) echo "arm" ;;
        *) echo "$(uname -m)" ;;
    esac
}

detect_ram_mb() {
    if command -v free >/dev/null 2>&1; then
        free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0"
    elif [ "$(detect_os)" = "macos" ]; then
        sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1048576)}' || echo "0"
    else
        echo "0"
    fi
}

detect_pkg_manager() {
    if command -v pkg >/dev/null 2>&1 && [ "$(detect_os)" = "termux" ]; then
        echo "pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v brew >/dev/null 2>&1; then
        echo "brew"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "none"
    fi
}

install_pkg() {
    # Only install if not already available
    command -v "$1" >/dev/null 2>&1 && return 0

    say "Installing $1..."
    case "$PKG_MANAGER" in
        pkg)    logged pkg install -y "$1" ;;
        apt)    logged sudo apt-get install -y "$1" ;;
        dnf)    logged sudo dnf install -y "$1" ;;
        pacman) logged sudo pacman -S --noconfirm "$1" ;;
        brew)   logged brew install "$1" ;;
        apk)    logged sudo apk add "$1" ;;
        none)   err "No package manager found. Please install '$1' manually."; return 1 ;;
    esac
}

pick_model() {
    RAM=$(detect_ram_mb)
    if [ "$RAM" -ge 16000 ]; then
        echo "7b"
    elif [ "$RAM" -ge 8000 ]; then
        echo "3b"
    elif [ "$RAM" -ge 4000 ]; then
        echo "1.5b"
    else
        echo "0.5b"
    fi
}

# ============================================================
# PHASE 0: Environment discovery
# ============================================================
say "Discovering environment..."
OS=$(detect_os)
ARCH=$(detect_arch)
RAM=$(detect_ram_mb)
PKG_MANAGER=$(detect_pkg_manager)
MODEL_SIZE=$(pick_model)

mkdir -p "$AGENT_DIR"
cat > "$AGENT_DIR/env.json" << EOF
{
  "os": "$OS",
  "arch": "$ARCH",
  "ram_mb": $RAM,
  "pkg_manager": "$PKG_MANAGER",
  "model_size": "$MODEL_SIZE",
  "home": "$HOME",
  "agent_dir": "$AGENT_DIR",
  "shell": "$(basename "$SHELL" 2>/dev/null || echo sh)",
  "user": "$(whoami)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

say "  OS: $OS | Arch: $ARCH | RAM: ${RAM}MB | Pkg: $PKG_MANAGER | Model: $MODEL_SIZE"

# ============================================================
# PHASE 1: Ensure minimal toolchain (only what's missing)
# ============================================================
say "Ensuring minimal toolchain..."

# Update package lists if applicable
case "$PKG_MANAGER" in
    pkg) logged pkg update -y ;;
    apt) logged sudo apt-get update -y ;;
esac

# We need: curl/wget (fetch), git (self-update), jq (JSON parsing)
install_pkg curl || install_pkg wget
install_pkg git
install_pkg jq

# ============================================================
# PHASE 2: Directory structure
# ============================================================
say "Setting up agent workspace..."
mkdir -p "$AGENT_DIR/core"
mkdir -p "$AGENT_DIR/tools"
mkdir -p "$AGENT_DIR/memory"
mkdir -p "$AGENT_DIR/models"
mkdir -p "$AGENT_DIR/logs"
mkdir -p "$AGENT_DIR/tmp"

# ============================================================
# PHASE 3: Local LLM — discover or install
# ============================================================
say "Setting up local LLM (target: ${MODEL_SIZE} parameter model)..."

LLM_BACKEND=""
LLM_MODEL=""

# Strategy 1: Ollama (preferred — handles model management)
if command -v ollama >/dev/null 2>&1; then
    LLM_BACKEND="ollama"
    say "  Found existing Ollama installation."
else
    say "  Attempting to install Ollama..."
    if curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_FILE" 2>&1; then
        LLM_BACKEND="ollama"
        say "  Ollama installed successfully."
    else
        say "  Ollama install failed, will try alternatives."
    fi
fi

# If Ollama available, select model based on RAM
if [ "$LLM_BACKEND" = "ollama" ]; then
    case "$MODEL_SIZE" in
        0.5b) LLM_MODEL="qwen2.5:0.5b" ;;
        1.5b) LLM_MODEL="qwen2.5:1.5b" ;;
        3b)   LLM_MODEL="qwen2.5:3b" ;;
        7b)   LLM_MODEL="qwen2.5:7b" ;;
    esac
    say "  Pulling model: $LLM_MODEL (this may take a while)..."
    ollama pull "$LLM_MODEL" >> "$LOG_FILE" 2>&1 || {
        err "  Model pull failed. Agent will retry on first run."
    }
fi

# Strategy 2: llama.cpp (if Ollama unavailable)
if [ -z "$LLM_BACKEND" ]; then
    say "  Building llama.cpp from source..."
    install_pkg cmake
    install_pkg make

    # Detect compiler
    if command -v clang >/dev/null 2>&1; then
        CC_FOUND="clang"
    elif command -v gcc >/dev/null 2>&1; then
        CC_FOUND="gcc"
    else
        install_pkg clang || install_pkg gcc
        CC_FOUND="$(command -v clang >/dev/null 2>&1 && echo clang || echo gcc)"
    fi

    if [ ! -d "$AGENT_DIR/llama.cpp" ]; then
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$AGENT_DIR/llama.cpp" >> "$LOG_FILE" 2>&1
    fi

    (cd "$AGENT_DIR/llama.cpp" && make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)") >> "$LOG_FILE" 2>&1

    LLM_BACKEND="llamacpp"
    LLM_MODEL="$AGENT_DIR/models/model.gguf"

    # Download appropriate model
    say "  Downloading quantized model..."
    case "$MODEL_SIZE" in
        0.5b) MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf" ;;
        1.5b) MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf" ;;
        3b)   MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf" ;;
        7b)   MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf" ;;
    esac

    if [ ! -f "$LLM_MODEL" ]; then
        curl -fSL -o "$LLM_MODEL" "$MODEL_URL" >> "$LOG_FILE" 2>&1 || {
            wget -q -O "$LLM_MODEL" "$MODEL_URL" >> "$LOG_FILE" 2>&1 || {
                err "  Model download failed. Place a GGUF file at: $LLM_MODEL"
            }
        }
    fi
fi

# ============================================================
# PHASE 4: Write the agent core (pure shell — no runtime deps)
# ============================================================
say "Writing agent core..."

cat > "$AGENT_DIR/core/agent.sh" << 'AGENT_CORE'
#!/bin/sh
# ============================================================
# AUTONOMOS AGENT CORE — Pure shell, zero dependencies
# ============================================================
# This is the minimal agent loop. It uses only: sh, curl/ollama, jq
# The agent can rewrite this file to upgrade itself.
# ============================================================

AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
MEMORY_DIR="$AGENT_DIR/memory"
LOG_DIR="$AGENT_DIR/logs"
CONFIG="$AGENT_DIR/env.json"
MAX_ITER="${MAX_ITER:-50}"

# --- Logging ---
log() {
    local msg="[$(date +%Y-%m-%dT%H:%M:%S)] [$1] $2"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/$(date +%Y-%m-%d).log"
}

# --- Memory ---
mem_save() { printf '%s' "$2" > "$MEMORY_DIR/$1"; }
mem_load() { [ -f "$MEMORY_DIR/$1" ] && cat "$MEMORY_DIR/$1" || echo ""; }

# --- LLM Query ---
query_llm() {
    local prompt="$1"
    local backend=$(jq -r '.llm_backend // "ollama"' "$AGENT_DIR/config.json" 2>/dev/null)
    local model=$(jq -r '.llm_model // "qwen2.5:1.5b"' "$AGENT_DIR/config.json" 2>/dev/null)

    case "$backend" in
        ollama)
            # Use Ollama API (works whether ollama was started as service or not)
            local response
            # Ensure Ollama is running
            ollama list >/dev/null 2>&1 || ollama serve >/dev/null 2>&1 &
            sleep 1

            response=$(curl -s http://localhost:11434/api/generate \
                -d "$(jq -n --arg model "$model" --arg prompt "$prompt" \
                '{model: $model, prompt: $prompt, stream: false}')" \
                | jq -r '.response // empty')

            if [ -z "$response" ]; then
                # Fallback: pipe to ollama run
                response=$(printf '%s' "$prompt" | ollama run "$model" 2>/dev/null)
            fi
            printf '%s' "$response"
            ;;
        llamacpp)
            local bin="$AGENT_DIR/llama.cpp/llama-cli"
            local model_path=$(jq -r '.llm_model_path // ""' "$AGENT_DIR/config.json" 2>/dev/null)
            "$bin" -m "$model_path" -p "$prompt" -n 2048 --temp 0.7 2>/dev/null
            ;;
    esac
}

# --- Tool execution ---
exec_tool() {
    local tool="$1"
    local args="$2"

    case "$tool" in
        shell)
            local cmd=$(printf '%s' "$args" | jq -r '.command')
            eval "$cmd" 2>&1 | head -c 4096
            ;;
        read_file)
            local path=$(printf '%s' "$args" | jq -r '.path')
            cat "$path" 2>&1 | head -c 4096
            ;;
        write_file)
            local path=$(printf '%s' "$args" | jq -r '.path')
            local content=$(printf '%s' "$args" | jq -r '.content')
            mkdir -p "$(dirname "$path")"
            printf '%s' "$content" > "$path"
            echo "OK: wrote $path"
            ;;
        list_dir)
            local path=$(printf '%s' "$args" | jq -r '.path // "."')
            ls -la "$path" 2>&1 | head -c 4096
            ;;
        self_modify)
            local file=$(printf '%s' "$args" | jq -r '.file')
            local content=$(printf '%s' "$args" | jq -r '.content')
            printf '%s' "$content" > "$AGENT_DIR/$file"
            chmod +x "$AGENT_DIR/$file" 2>/dev/null
            echo "OK: modified $file"
            ;;
        done)
            local summary=$(printf '%s' "$args" | jq -r '.summary // "Complete"')
            log "INFO" "DONE: $summary"
            mem_save "last_result" "$summary"
            exit 0
            ;;
        *)
            echo "Unknown tool: $tool"
            ;;
    esac
}

# --- Parse action from LLM response ---
parse_action() {
    local response="$1"
    # Extract JSON between ```action and ```
    printf '%s' "$response" | sed -n '/```action/,/```/{/```/d;p}' | jq '.' 2>/dev/null
}

# --- System prompt ---
SYSTEM_PROMPT="You are an autonomous agent running locally. OS: $(jq -r '.os' "$CONFIG"). Arch: $(jq -r '.arch' "$CONFIG").

You execute actions by responding with:
\`\`\`action
{\"tool\": \"shell\", \"args\": {\"command\": \"ls\"}}
\`\`\`

Tools:
- shell: {\"command\": \"...\"}
- read_file: {\"path\": \"...\"}
- write_file: {\"path\": \"...\", \"content\": \"...\"}
- list_dir: {\"path\": \"...\"}
- self_modify: {\"file\": \"core/agent.sh\", \"content\": \"...\"}
- done: {\"summary\": \"...\"}

Your source is at: $AGENT_DIR/core/
You may modify yourself. Be concise. One action per response."

# --- Main loop ---
main() {
    local goal="${1:-$(mem_load current_goal)}"
    [ -z "$goal" ] && goal="Explore this system, report capabilities, and await instructions."

    log "INFO" "Agent starting. Goal: $goal"
    mem_save "current_goal" "$goal"

    local context="GOAL: $goal

System info:
$(cat "$CONFIG")

Begin working."

    local iter=0
    while [ "$iter" -lt "$MAX_ITER" ]; do
        iter=$((iter + 1))
        log "INFO" "Iteration $iter/$MAX_ITER"

        local full_prompt="$SYSTEM_PROMPT

$context"
        local response
        response=$(query_llm "$full_prompt")

        if [ -z "$response" ]; then
            log "ERROR" "Empty LLM response. Retrying..."
            sleep 2
            continue
        fi

        log "INFO" "LLM: $(printf '%.200s' "$response")..."

        local action
        action=$(parse_action "$response")

        if [ -z "$action" ] || [ "$action" = "null" ]; then
            context="$context

ASSISTANT: $response

Respond with an action block. Use \`\`\`action {...} \`\`\` format."
            continue
        fi

        local tool=$(printf '%s' "$action" | jq -r '.tool')
        local args=$(printf '%s' "$action" | jq -c '.args // {}')

        log "INFO" "Exec: $tool"
        local result
        result=$(exec_tool "$tool" "$args")
        log "INFO" "Result: $(printf '%.200s' "$result")..."

        context="$context

ASSISTANT: $response

OBSERVATION: $result

Continue toward the goal."
    done

    log "INFO" "Loop ended (max iterations reached)."
}

main "$@"
AGENT_CORE

chmod +x "$AGENT_DIR/core/agent.sh"

# ============================================================
# PHASE 5: Write config
# ============================================================
cat > "$AGENT_DIR/config.json" << EOF
{
  "llm_backend": "$LLM_BACKEND",
  "llm_model": "$LLM_MODEL",
  "llm_model_path": "$LLM_MODEL",
  "max_iterations": 50,
  "self_modify": true,
  "version": "0.1.0"
}
EOF

# ============================================================
# PHASE 6: Launcher
# ============================================================
cat > "$AGENT_DIR/run" << 'LAUNCHER'
#!/bin/sh
export AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
exec sh "$AGENT_DIR/core/agent.sh" "$@"
LAUNCHER
chmod +x "$AGENT_DIR/run"

# ============================================================
# DONE
# ============================================================
say ""
say "=========================================="
say " AUTONOMOS — Bootstrap complete"
say "=========================================="
say ""
say " Environment: $OS / $ARCH / ${RAM}MB RAM"
say " LLM backend: $LLM_BACKEND ($LLM_MODEL)"
say " Agent dir:   $AGENT_DIR"
say ""
say " Run:  ~/agent/run \"your goal here\""
say " Logs: ~/agent/logs/"
say "=========================================="
