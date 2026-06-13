#!/bin/sh
# ============================================================
# AUTONOMOS — Self-Bootstrapping Autonomous Agent
# ============================================================
# Zero assumptions. Discovers its environment. Builds itself.
# Works on: Termux (Android), Linux, macOS, WSL, any POSIX shell.
# ============================================================
# Usage: curl -fsSL <url>/bootstrap.sh | sh
# ============================================================

# NOTE: No set -e. This script must NEVER exit early.
# Individual failures are handled gracefully. The agent must live.

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

pick_model_size() {
    # Returns a max parameter size the device can likely run
    RAM=$(detect_ram_mb)
    if [ "$RAM" -ge 16000 ]; then
        echo "7b"
    elif [ "$RAM" -ge 8000 ]; then
        echo "3b"
    elif [ "$RAM" -ge 6000 ]; then
        echo "4b"
    elif [ "$RAM" -ge 4000 ]; then
        echo "2b"
    elif [ "$RAM" -ge 2000 ]; then
        echo "1b"
    else
        echo "0.5b"
    fi
}

discover_multimodal_model() {
    # Query Ollama's library for the best available multimodal model
    # that fits within our size budget. Prefers vision-capable models.
    local max_size="$1"

    # Check if any vision model is already pulled locally
    local existing
    existing=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | head -20)

    # Look for already-downloaded vision models first
    for model in $existing; do
        case "$model" in
            *vl*|*vision*|*vlm*|*gemma*4*|*smolvlm*|*llava*|*moondream*)
                echo "$model"
                return 0
                ;;
        esac
    done

    # Search Ollama for multimodal models that fit our size
    # Try common vision model families in preference order
    local candidates
    candidates=$(ollama search --multimodal 2>/dev/null | awk 'NR>1{print $1}' | head -10)

    # If search doesn't support --multimodal flag, try known patterns
    if [ -z "$candidates" ]; then
        # Query Ollama API for available models, filter by size
        candidates=$(curl -s "https://ollama.com/api/models?capability=vision" 2>/dev/null \
            | jq -r '.[].name' 2>/dev/null | head -20)
    fi

    # If we got candidates, pick the largest that fits
    if [ -n "$candidates" ]; then
        for model in $candidates; do
            echo "$model"
            return 0
        done
    fi

    # Last resort: return empty and let the caller handle it
    echo ""
    return 1
}

# ============================================================
# PHASE 0: Environment discovery
# ============================================================
say "Discovering environment..."
OS=$(detect_os)
ARCH=$(detect_arch)
RAM=$(detect_ram_mb)
PKG_MANAGER=$(detect_pkg_manager)
MODEL_SIZE=$(pick_model_size)

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
# PHASE 3: Local LLM — multimodal, adaptive, discovered
# ============================================================
say "Setting up multimodal LLM (max size: ${MODEL_SIZE})..."

LLM_BACKEND=""
LLM_MODEL=""
LLM_MMPROJ=""
MODALITIES="text"

# Strategy 1: Ollama (preferred — handles multimodal natively)
if command -v ollama >/dev/null 2>&1; then
    LLM_BACKEND="ollama"
    say "  Found existing Ollama installation."
else
    say "  Attempting to install Ollama..."
    if curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_FILE" 2>&1; then
        LLM_BACKEND="ollama"
        say "  Ollama installed successfully."
    else
        say "  Ollama install failed, will try llama.cpp."
    fi
fi

if [ "$LLM_BACKEND" = "ollama" ]; then
    # Ensure Ollama is running
    if ! curl -s "http://localhost:11434/api/tags" >/dev/null 2>&1; then
        say "  Starting Ollama..."
        ollama serve > /dev/null 2>&1 &
        sleep 3
    fi

    # Step 1: Check if we already have ANY model pulled
    say "  Checking for existing models..."
    LLM_MODEL=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | head -1)

    if [ -n "$LLM_MODEL" ]; then
        say "  Found existing model: $LLM_MODEL"
    else
        # Step 2: Pick the right text model for this device's RAM
        # These are guaranteed to exist in Ollama's registry
        case "$MODEL_SIZE" in
            7b)  LLM_MODEL="qwen2.5:7b" ;;
            4b)  LLM_MODEL="qwen2.5:3b" ;;
            3b)  LLM_MODEL="qwen2.5:3b" ;;
            2b)  LLM_MODEL="qwen2.5:1.5b" ;;
            1b)  LLM_MODEL="qwen2.5:0.5b" ;;
            *)   LLM_MODEL="qwen2.5:0.5b" ;;
        esac

        say "  Pulling model: $LLM_MODEL (this may take a while)..."
        ollama pull "$LLM_MODEL" 2>> "$LOG_FILE"
        if [ $? -ne 0 ]; then
            # If that fails, try the smallest possible model
            say "  Pull failed. Trying smallest model..."
            LLM_MODEL="tinyllama"
            ollama pull "$LLM_MODEL" 2>> "$LOG_FILE" || {
                err "  CRITICAL: Cannot pull any model. Check network."
                err "  Once online, run: ollama pull qwen2.5:0.5b"
                # Don't exit — continue with empty model, supervisor will retry
            }
        fi
    fi

    # Detect modalities from model name
    if [ -n "$LLM_MODEL" ]; then
        case "$LLM_MODEL" in
            *vl*|*vision*|*vlm*|*smolvlm*|*llava*|*moondream*|*gemma*4*)
                MODALITIES="vision,text" ;;
            *omni*)
                MODALITIES="vision,audio,text" ;;
            *)
                MODALITIES="text" ;;
        esac
    fi
fi

# Strategy 2: llama.cpp with multimodal server (if Ollama unavailable)
if [ -z "$LLM_BACKEND" ]; then
    say "  Ollama unavailable. Building llama.cpp from source..."
    install_pkg cmake
    install_pkg make

    if command -v clang >/dev/null 2>&1; then
        : # clang available
    elif command -v gcc >/dev/null 2>&1; then
        : # gcc available
    else
        install_pkg clang || install_pkg gcc
    fi

    if [ ! -d "$AGENT_DIR/llama.cpp" ]; then
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$AGENT_DIR/llama.cpp" >> "$LOG_FILE" 2>&1
    fi

    NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    (cd "$AGENT_DIR/llama.cpp" && cmake -B build && cmake --build build -j"$NPROC" --target llama-server llama-mtmd-cli) >> "$LOG_FILE" 2>&1

    LLM_BACKEND="llamacpp-server"

    # Ask user for a HuggingFace model repo or GGUF URL
    say "  llama.cpp built. You need a GGUF model file."
    MODEL_SOURCE=""
    if [ -t 0 ] || [ -e /dev/tty ]; then
        printf '  Enter a HuggingFace repo (e.g. ggml-org/gemma-3-4b-it-GGUF) or GGUF URL: ' > /dev/tty
        read -r MODEL_SOURCE < /dev/tty 2>/dev/null || MODEL_SOURCE=""
    fi

    if [ -n "$MODEL_SOURCE" ]; then
        mkdir -p "$AGENT_DIR/models"
        case "$MODEL_SOURCE" in
            http*)
                # Direct URL to a GGUF file
                say "  Downloading model..."
                curl -fSL -o "$AGENT_DIR/models/model.gguf" "$MODEL_SOURCE" 2>> "$LOG_FILE"
                LLM_MODEL="$AGENT_DIR/models/model.gguf"
                ;;
            *)
                # HuggingFace repo — discover files via API
                say "  Discovering files in $MODEL_SOURCE..."
                BASE_URL="https://huggingface.co/$MODEL_SOURCE/resolve/main"
                FILES=$(curl -s "https://huggingface.co/api/models/$MODEL_SOURCE" | jq -r '.siblings[].rfilename' 2>/dev/null)

                # Find Q4 quantized model
                MODEL_FILE=$(printf '%s' "$FILES" | grep -i 'q4_k_m' | head -1)
                if [ -n "$MODEL_FILE" ]; then
                    say "  Downloading $MODEL_FILE..."
                    curl -fSL -o "$AGENT_DIR/models/model.gguf" "$BASE_URL/$MODEL_FILE" 2>> "$LOG_FILE"
                fi

                # Find mmproj if present
                MMPROJ_FILE=$(printf '%s' "$FILES" | grep -i 'mmproj' | head -1)
                if [ -n "$MMPROJ_FILE" ]; then
                    say "  Downloading $MMPROJ_FILE..."
                    curl -fSL -o "$AGENT_DIR/models/mmproj.gguf" "$BASE_URL/$MMPROJ_FILE" 2>> "$LOG_FILE"
                    LLM_MMPROJ="$AGENT_DIR/models/mmproj.gguf"
                fi

                LLM_MODEL="$AGENT_DIR/models/model.gguf"
                ;;
        esac
        MODALITIES="vision,text"  # Assume multimodal if user provided a model
    else
        err "  No model provided. Agent will not have LLM until configured."
    fi
fi

# Final check
if [ -z "$LLM_BACKEND" ] || [ -z "$LLM_MODEL" ]; then
    err "No LLM configured. Run: ollama pull <model> or provide a GGUF file."
fi

# ============================================================
# PHASE 4: Write the agent core (pure shell — no runtime deps)
# ============================================================
say "Writing agent core..."

cat > "$AGENT_DIR/core/agent.sh" << 'AGENT_CORE'
#!/bin/sh
# ============================================================
# AUTONOMOS AGENT CORE — Multimodal, pure shell
# ============================================================
# Uses: sh, curl, jq. Supports vision via Ollama/llama-server API.
# The agent can rewrite this file to upgrade itself.
# ============================================================

AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
MEMORY_DIR="$AGENT_DIR/memory"
LOG_DIR="$AGENT_DIR/logs"
CONFIG="$AGENT_DIR/env.json"
AGENT_CONFIG="$AGENT_DIR/config.json"
MAX_ITER="${MAX_ITER:-50}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
LLAMA_PORT="${LLAMA_PORT:-8081}"

# --- Logging ---
log() {
    local msg="[$(date +%Y-%m-%dT%H:%M:%S)] [$1] $2"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/$(date +%Y-%m-%d).log"
}

# --- Memory (persistent, append-only, cross-session) ---
JOURNAL="$MEMORY_DIR/journal.jsonl"
LEARNINGS="$MEMORY_DIR/learnings.jsonl"
FACTS="$MEMORY_DIR/facts.json"

mem_save() { printf '%s' "$2" > "$MEMORY_DIR/$1"; }
mem_load() { [ -f "$MEMORY_DIR/$1" ] && cat "$MEMORY_DIR/$1" || echo ""; }

# Append to permanent journal (never deleted, never overwritten)
journal_append() {
    local entry_type="$1" content="$2"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -c --arg t "$ts" --arg type "$entry_type" --arg c "$content" \
        '{ts: $t, type: $type, content: $c}' >> "$JOURNAL"
}

# Store a learned fact permanently
learn() {
    local fact="$1" category="${2:-general}"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -c --arg t "$ts" --arg cat "$category" --arg f "$fact" \
        '{ts: $t, category: $cat, fact: $f}' >> "$LEARNINGS"
}

# Recall recent journal entries (last N)
journal_recent() {
    local n="${1:-20}"
    [ -f "$JOURNAL" ] && tail -n "$n" "$JOURNAL" || echo ""
}

# Recall all learnings (or filter by category)
recall_learnings() {
    local category="$1"
    if [ -z "$category" ]; then
        [ -f "$LEARNINGS" ] && cat "$LEARNINGS" || echo ""
    else
        [ -f "$LEARNINGS" ] && grep "\"category\":\"$category\"" "$LEARNINGS" || echo ""
    fi
}

# Build memory context for prompt injection
build_memory_context() {
    local ctx=""

    # Always include learnings (distilled knowledge)
    local learnings
    learnings=$(recall_learnings | tail -n 50 | jq -r '.fact' 2>/dev/null | head -c 2000)
    if [ -n "$learnings" ]; then
        ctx="PERMANENT MEMORY (things you have learned):
$learnings
"
    fi

    # Include recent journal for continuity
    local recent
    recent=$(journal_recent 10 | jq -r '"\(.type): \(.content)"' 2>/dev/null | head -c 1500)
    if [ -n "$recent" ]; then
        ctx="${ctx}
RECENT HISTORY (last session context):
$recent
"
    fi

    # Include any saved facts
    if [ -f "$FACTS" ]; then
        local facts
        facts=$(jq -r 'to_entries[] | "\(.key): \(.value)"' "$FACTS" 2>/dev/null | head -c 500)
        if [ -n "$facts" ]; then
            ctx="${ctx}
KEY FACTS:
$facts
"
        fi
    fi

    printf '%s' "$ctx"
}

# Sync memory to git (cross-device persistence)
memory_sync() {
    if [ -d "$MEMORY_DIR/.git" ]; then
        # Avoid lock contention: skip if another sync is in progress
        [ -f "$MEMORY_DIR/.git/index.lock" ] && return 0
        (cd "$MEMORY_DIR" && git add -A && git commit -m "memory: $(date -u +%Y-%m-%dT%H:%M:%SZ)" && git push 2>/dev/null) > /dev/null 2>&1 &
    fi
}

# Initialize memory git repo if not present
memory_init() {
    mkdir -p "$MEMORY_DIR"
    [ -f "$JOURNAL" ] || touch "$JOURNAL"
    [ -f "$LEARNINGS" ] || touch "$LEARNINGS"
    [ -f "$FACTS" ] || jq -n '{}' > "$FACTS"
    [ -f "$MEMORY_DIR/compaction.jsonl" ] || touch "$MEMORY_DIR/compaction.jsonl"
}

# ============================================================
# MEMORY COMPACTION + HEARTBEAT
# ============================================================
# The compaction process distills raw journal into learnings.
# When context pressure is high, it summarizes aggressively.
# Runs as background heartbeat while agent is alive.

COMPACTION_LOG="$MEMORY_DIR/compaction.jsonl"
HEARTBEAT_FILE="$AGENT_DIR/tmp/.heartbeat"
CTX_WINDOW=$(jq -r '.context_window // 8192' "$AGENT_CONFIG" 2>/dev/null)

# Estimate token count (rough: 1 token ≈ 4 chars)
estimate_tokens() {
    local text="$1"
    echo $(( ${#text} / 4 ))
}

# Get context pressure (0.0 to 1.0)
context_pressure() {
    local ctx_size="$1"
    local tokens=$(estimate_tokens "$ctx_size")
    local window=${CTX_WINDOW:-8192}
    # pressure = tokens_used / window_size
    echo "$tokens $window" | awk '{printf "%.2f", $1/$2}'
}

# Compact: summarize old journal entries into a single learning
compact_journal() {
    local journal_lines=$(wc -l < "$JOURNAL" 2>/dev/null | tr -d ' ')
    [ "$journal_lines" -lt 100 ] && return 0  # Don't compact if small

    # Take the oldest 50 entries and summarize them
    local batch=$(head -n 50 "$JOURNAL")
    local batch_summary

    # Use the LLM to summarize if available, otherwise do mechanical compaction
    if [ -n "$(jq -r '.llm_model // ""' "$AGENT_CONFIG" 2>/dev/null)" ]; then
        batch_summary=$(printf '%s' "$batch" | jq -r '"\(.type): \(.content)"' 2>/dev/null | head -c 3000)
        local summary
        summary=$(query_llm "Summarize these agent interactions into 3-5 key learnings. Be extremely concise. One line per learning:

$batch_summary")
        if [ -n "$summary" ]; then
            # Store each line as a learning
            printf '%s\n' "$summary" | while IFS= read -r line; do
                [ -n "$line" ] && learn "$line" "compacted"
            done
        fi
    else
        # Mechanical: extract unique actions and results
        printf '%s' "$batch" | jq -r 'select(.type=="action" or .type=="result") | .content' 2>/dev/null \
            | sort -u | head -5 | while IFS= read -r line; do
                [ -n "$line" ] && learn "$line" "compacted"
            done
    fi

    # Remove compacted entries from journal (keep only the recent ones)
    local total_lines=$(wc -l < "$JOURNAL" | tr -d ' ')
    tail -n $((total_lines - 50)) "$JOURNAL" > "$JOURNAL.tmp" && mv "$JOURNAL.tmp" "$JOURNAL"

    # Record compaction event
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -c --arg t "$ts" --argjson n 50 '{ts: $t, compacted_entries: $n}' >> "$COMPACTION_LOG"
    log "INFO" "Memory compaction: 50 journal entries → learnings"
}

# Check if agent needs a bigger shell (context window)
check_shell_outgrowth() {
    local pressure="$1"
    local threshold=$(jq -r '.outgrowth_threshold // "0.80"' "$AGENT_CONFIG" 2>/dev/null)

    # If pressure exceeds threshold, agent needs to grow
    local needs_growth=$(echo "$pressure $threshold" | awk '{print ($1 >= $2) ? 1 : 0}')

    if [ "$needs_growth" = "1" ]; then
        log "INFO" "OUTGROWTH: Context pressure $pressure >= $threshold. Seeking larger shell..."

        # Check if we already have a remote API configured
        local remote_api=$(jq -r '.remote_api // ""' "$AGENT_CONFIG" 2>/dev/null)
        if [ -n "$remote_api" ]; then
            log "INFO" "OUTGROWTH: Remote API already configured: $remote_api"
            return 0
        fi

        # Signal to the agent that it should seek a bigger context
        mem_save "outgrowth_needed" "true"
        mem_save "outgrowth_reason" "Context pressure $pressure exceeds threshold $threshold. Current window: ${CTX_WINDOW} tokens. Memory is being compressed but accuracy is degrading. Options: 1) Register on OpenRouter (free models with larger context), 2) Find prediction markets to fund API costs, 3) Find a larger local model."
        return 1
    fi
    return 0
}

# Heartbeat: background process that runs compaction + health checks
heartbeat() {
    while true; do
        # Write heartbeat timestamp
        date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT_FILE"

        # Check journal size and compact if needed
        local journal_lines=$(wc -l < "$JOURNAL" 2>/dev/null | tr -d ' ')
        if [ "${journal_lines:-0}" -ge 100 ]; then
            compact_journal
        fi

        # Check context pressure from last known prompt size
        local last_ctx_size=$(mem_load "last_context_size")
        if [ -n "$last_ctx_size" ]; then
            local pressure=$(context_pressure "$last_ctx_size")
            check_shell_outgrowth "$pressure"
        fi

        # Sync memory
        memory_sync

        sleep 60  # Heartbeat interval: 1 minute
    done
}

# Start heartbeat in background
start_heartbeat() {
    heartbeat &
    HEARTBEAT_PID=$!
    mem_save "heartbeat_pid" "$HEARTBEAT_PID"
    log "INFO" "Heartbeat started (PID: $HEARTBEAT_PID)"
}

# Stop heartbeat
stop_heartbeat() {
    local pid=$(mem_load "heartbeat_pid")
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
}

# --- Ensure LLM is running ---
ensure_llm() {
    local backend=$(jq -r '.llm_backend // "ollama"' "$AGENT_CONFIG" 2>/dev/null)

    case "$backend" in
        ollama)
            if ! curl -s "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
                ollama serve >/dev/null 2>&1 &
                local wait=0
                while [ "$wait" -lt 10 ]; do
                    curl -s "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1 && break
                    sleep 1
                    wait=$((wait + 1))
                done
            fi
            ;;
        llamacpp-server)
            if ! curl -s "http://localhost:$LLAMA_PORT/health" >/dev/null 2>&1; then
                local model_path=$(jq -r '.llm_model_path // ""' "$AGENT_CONFIG" 2>/dev/null)
                local mmproj=$(jq -r '.llm_mmproj // ""' "$AGENT_CONFIG" 2>/dev/null)
                local cmd="$AGENT_DIR/llama.cpp/build/bin/llama-server -m $model_path --port $LLAMA_PORT"
                [ -n "$mmproj" ] && [ "$mmproj" != "null" ] && cmd="$cmd --mmproj $mmproj"
                eval "$cmd" >/dev/null 2>&1 &
                local wait=0
                while [ "$wait" -lt 15 ]; do
                    curl -s "http://localhost:$LLAMA_PORT/health" >/dev/null 2>&1 && break
                    sleep 1
                    wait=$((wait + 1))
                done
            fi
            ;;
    esac
}

# --- LLM Query (text only) ---
query_llm() {
    local prompt="$1"
    ensure_llm
    local backend=$(jq -r '.llm_backend // ""' "$AGENT_CONFIG" 2>/dev/null)
    local model=$(jq -r '.llm_model // ""' "$AGENT_CONFIG" 2>/dev/null)

    # Self-heal: if no model configured, try to find or pull one
    if [ -z "$backend" ] || [ -z "$model" ] || [ "$model" = "null" ]; then
        backend="ollama"
        # Check if Ollama has any model already
        model=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | head -1)
        if [ -z "$model" ]; then
            # Pull smallest model automatically
            log "INFO" "No model found. Auto-pulling qwen2.5:0.5b..."
            ollama pull "qwen2.5:0.5b" > /dev/null 2>&1
            model="qwen2.5:0.5b"
        fi
        # Update config so this doesn't repeat
        local tmp=$(jq --arg b "$backend" --arg m "$model" '.llm_backend=$b | .llm_model=$m' "$AGENT_CONFIG")
        printf '%s' "$tmp" > "$AGENT_CONFIG"
    fi

    local result=""

    case "$backend" in
        ollama)
            result=$(curl -s --max-time 60 "http://localhost:$OLLAMA_PORT/api/chat" \
                -d "$(jq -n --arg model "$model" --arg content "$prompt" \
                '{model: $model, messages: [{role: "user", content: $content}], stream: false}')" \
                | jq -r '.message.content // empty')
            ;;
        llamacpp-server)
            result=$(curl -s --max-time 60 "http://localhost:$LLAMA_PORT/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --arg content "$prompt" \
                '{messages: [{role: "user", content: $content}], max_tokens: 2048, temperature: 0.7}')" \
                | jq -r '.choices[0].message.content // empty')
            ;;
        openrouter_free)
            result=$(curl -s --max-time 30 "https://openrouter.ai/api/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --arg model "$model" --arg content "$prompt" \
                '{model: $model, messages: [{role: "user", content: $content}], max_tokens: 2048}')" \
                | jq -r '.choices[0].message.content // empty')
            ;;
    esac

    # Emergency fallback: if local LLM returned nothing, try free remote API
    if [ -z "$result" ] && [ "$backend" != "openrouter_free" ]; then
        local remote_url=$(jq -r '.remote_api_url // ""' "$AGENT_CONFIG" 2>/dev/null)
        local remote_model=$(jq -r '.remote_model // ""' "$AGENT_CONFIG" 2>/dev/null)
        local remote_key=$(sh "$AGENT_DIR/core/auth.sh" cred_load "openrouter" "api_key" 2>/dev/null)

        # Try configured remote
        if [ -n "$remote_url" ] && [ -n "$remote_model" ]; then
            local headers="-H 'Content-Type: application/json'"
            [ -n "$remote_key" ] && headers="$headers -H 'Authorization: Bearer $remote_key'"
            result=$(curl -s --max-time 30 "$remote_url" \
                -H "Content-Type: application/json" \
                ${remote_key:+-H "Authorization: Bearer $remote_key"} \
                -d "$(jq -n --arg model "$remote_model" --arg content "$prompt" \
                '{model: $model, messages: [{role: "user", content: $content}], max_tokens: 2048}')" \
                | jq -r '.choices[0].message.content // empty')
        fi

        # Last resort: try free tier without auth
        if [ -z "$result" ]; then
            result=$(curl -s --max-time 30 "https://openrouter.ai/api/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{"model":"meta-llama/llama-3.2-1b-instruct:free","messages":[{"role":"user","content":"'"$(printf '%s' "$prompt" | head -c 4000 | sed 's/"/\\"/g')"'"}],"max_tokens":2048}' \
                | jq -r '.choices[0].message.content // empty')
        fi
    fi

    printf '%s' "$result"
}

# --- LLM Query with image (multimodal) ---
query_llm_vision() {
    local prompt="$1"
    local image_path="$2"
    ensure_llm
    local backend=$(jq -r '.llm_backend // ""' "$AGENT_CONFIG" 2>/dev/null)
    local model=$(jq -r '.llm_model // ""' "$AGENT_CONFIG" 2>/dev/null)
    local modalities=$(jq -r '.modalities // "text"' "$AGENT_CONFIG" 2>/dev/null)

    # Check if vision is supported
    if ! echo "$modalities" | grep -q "vision"; then
        echo "[No vision capability. Text-only model loaded.]"
        return 1
    fi

    # Encode image to base64
    local img_base64
    if [ -f "$image_path" ]; then
        img_base64=$(base64 < "$image_path" | tr -d '\n')
    else
        echo "[Image not found: $image_path]"
        return 1
    fi

    case "$backend" in
        ollama)
            # Ollama multimodal API uses 'images' array with base64
            curl -s "http://localhost:$OLLAMA_PORT/api/chat" \
                -d "$(jq -n --arg model "$model" --arg content "$prompt" --arg img "$img_base64" \
                '{model: $model, messages: [{role: "user", content: $content, images: [$img]}], stream: false}')" \
                | jq -r '.message.content // empty'
            ;;
        llamacpp-server)
            # OpenAI-compatible vision API with image_url base64
            local mime="image/png"
            case "$image_path" in
                *.jpg|*.jpeg) mime="image/jpeg" ;;
                *.gif) mime="image/gif" ;;
                *.webp) mime="image/webp" ;;
            esac
            curl -s "http://localhost:$LLAMA_PORT/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --arg content "$prompt" --arg mime "$mime" --arg img "$img_base64" \
                '{messages: [{role: "user", content: [{type: "text", text: $content}, {type: "image_url", image_url: {url: ("data:" + $mime + ";base64," + $img)}}]}], max_tokens: 2048}')" \
                | jq -r '.choices[0].message.content // empty'
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
        see)
            # Vision tool: describe an image file
            local path=$(printf '%s' "$args" | jq -r '.path')
            local question=$(printf '%s' "$args" | jq -r '.question // "Describe this image in detail."')
            query_llm_vision "$question" "$path"
            ;;
        camera)
            # Capture from camera (platform-adaptive)
            local output="$AGENT_DIR/tmp/capture_$(date +%s).jpg"
            local os=$(jq -r '.os' "$CONFIG" 2>/dev/null)
            case "$os" in
                macos)
                    # Use imagesnap if available, else ffmpeg
                    if command -v imagesnap >/dev/null 2>&1; then
                        imagesnap -q "$output" 2>&1
                    elif command -v ffmpeg >/dev/null 2>&1; then
                        ffmpeg -f avfoundation -framerate 1 -i "0" -frames:v 1 -y "$output" 2>/dev/null
                    else
                        echo "NEED: install imagesnap (brew install imagesnap) or ffmpeg"
                        return
                    fi
                    ;;
                termux)
                    # Termux camera API
                    termux-camera-photo -c 0 "$output" 2>&1
                    ;;
                linux)
                    # Use fswebcam or ffmpeg
                    if command -v fswebcam >/dev/null 2>&1; then
                        fswebcam -q --no-banner "$output" 2>&1
                    elif command -v ffmpeg >/dev/null 2>&1; then
                        ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -y "$output" 2>/dev/null
                    else
                        echo "NEED: install fswebcam or ffmpeg"
                        return
                    fi
                    ;;
                *)
                    echo "Camera not supported on this OS yet."
                    return
                    ;;
            esac
            if [ -f "$output" ]; then
                echo "OK: captured $output"
                # Auto-describe if requested
                local describe=$(printf '%s' "$args" | jq -r '.describe // "true"')
                if [ "$describe" = "true" ]; then
                    local desc=$(query_llm_vision "Describe what you see in this image." "$output")
                    echo "VISION: $desc"
                fi
            else
                echo "ERROR: camera capture failed"
            fi
            ;;
        screenshot)
            # Take a screenshot (platform-adaptive)
            local output="$AGENT_DIR/tmp/screen_$(date +%s).png"
            local os=$(jq -r '.os' "$CONFIG" 2>/dev/null)
            case "$os" in
                macos)   screencapture -x "$output" 2>&1 ;;
                termux)  termux-screenshot "$output" 2>&1 ;;
                linux)
                    if command -v scrot >/dev/null 2>&1; then
                        scrot "$output" 2>&1
                    elif command -v gnome-screenshot >/dev/null 2>&1; then
                        gnome-screenshot -f "$output" 2>&1
                    else
                        echo "NEED: install scrot or gnome-screenshot"
                        return
                    fi
                    ;;
            esac
            if [ -f "$output" ]; then
                echo "OK: screenshot saved to $output"
                local describe=$(printf '%s' "$args" | jq -r '.describe // "true"')
                if [ "$describe" = "true" ]; then
                    local desc=$(query_llm_vision "Describe what you see on this screen." "$output")
                    echo "VISION: $desc"
                fi
            else
                echo "ERROR: screenshot failed"
            fi
            ;;
        auth)
            # Auth primitive: identity, email, OTP, credentials
            local action=$(printf '%s' "$args" | jq -r '.action')
            case "$action" in
                get_phone)
                    sh "$AGENT_DIR/core/auth.sh" get_phone
                    ;;
                get_email)
                    sh "$AGENT_DIR/core/auth.sh" get_email
                    ;;
                set_email)
                    local email=$(printf '%s' "$args" | jq -r '.email')
                    sh "$AGENT_DIR/core/auth.sh" set_email "$email"
                    ;;
                create_email)
                    local provider=$(printf '%s' "$args" | jq -r '.provider // "auto"')
                    sh "$AGENT_DIR/core/auth.sh" create_email "$provider"
                    ;;
                request_otp)
                    local service=$(printf '%s' "$args" | jq -r '.service')
                    sh "$AGENT_DIR/core/auth.sh" request_otp "$service"
                    ;;
                save_credential)
                    local svc=$(printf '%s' "$args" | jq -r '.service')
                    local key=$(printf '%s' "$args" | jq -r '.key')
                    local val=$(printf '%s' "$args" | jq -r '.value')
                    sh "$AGENT_DIR/core/auth.sh" cred_save "$svc" "$key" "$val"
                    ;;
                load_credential)
                    local svc=$(printf '%s' "$args" | jq -r '.service')
                    local key=$(printf '%s' "$args" | jq -r '.key')
                    sh "$AGENT_DIR/core/auth.sh" cred_load "$svc" "$key"
                    ;;
                register)
                    local service=$(printf '%s' "$args" | jq -r '.service')
                    sh "$AGENT_DIR/core/auth.sh" register "$service"
                    ;;
                *)
                    echo "Auth actions: get_phone, get_email, set_email, create_email, request_otp, save_credential, load_credential, register"
                    ;;
            esac
            ;;
        memory)
            # Persistent memory: learn, recall, journal, sync
            local action=$(printf '%s' "$args" | jq -r '.action')
            case "$action" in
                learn)
                    local fact=$(printf '%s' "$args" | jq -r '.fact')
                    local category=$(printf '%s' "$args" | jq -r '.category // "general"')
                    learn "$fact" "$category"
                    echo "OK: learned [$category] $fact"
                    ;;
                recall)
                    local category=$(printf '%s' "$args" | jq -r '.category // ""')
                    recall_learnings "$category" | tail -n 20 | jq -r '.fact' 2>/dev/null
                    ;;
                journal)
                    local n=$(printf '%s' "$args" | jq -r '.n // "10"')
                    journal_recent "$n" | jq -r '"\(.ts) [\(.type)] \(.content)"' 2>/dev/null
                    ;;
                save_fact)
                    local key=$(printf '%s' "$args" | jq -r '.key')
                    local value=$(printf '%s' "$args" | jq -r '.value')
                    local tmp=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$FACTS")
                    printf '%s' "$tmp" > "$FACTS"
                    echo "OK: fact saved: $key = $value"
                    ;;
                get_fact)
                    local key=$(printf '%s' "$args" | jq -r '.key')
                    jq -r --arg k "$key" '.[$k] // "not found"' "$FACTS" 2>/dev/null
                    ;;
                sync)
                    memory_sync
                    echo "OK: memory synced"
                    ;;
                *)
                    echo "Memory actions: learn, recall, journal, save_fact, get_fact, sync"
                    ;;
            esac
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
            journal_append "done" "$summary"
            memory_sync
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
    local extracted

    # Strategy 1: Extract JSON between ```action and ```
    extracted=$(printf '%s' "$response" | awk '/```action/{found=1;next} /```/{if(found)exit} found{print}')
    if [ -n "$extracted" ]; then
        printf '%s' "$extracted" | jq '.' 2>/dev/null && return
    fi

    # Strategy 2: Extract JSON between ```json and ```
    extracted=$(printf '%s' "$response" | awk '/```json/{found=1;next} /```/{if(found)exit} found{print}')
    if [ -n "$extracted" ]; then
        printf '%s' "$extracted" | jq '.' 2>/dev/null && return
    fi

    # Strategy 3: Find inline JSON with "tool" key (handles nested args)
    extracted=$(printf '%s' "$response" | grep -oE '\{[^{}]*"tool"[^{}]*(\{[^{}]*\}[^{}]*)?\}' | head -1)
    if [ -n "$extracted" ]; then
        printf '%s' "$extracted" | jq '.' 2>/dev/null && return
    fi

    echo ""
}

# --- Build system prompt based on capabilities ---
build_system_prompt() {
    local modalities=$(jq -r '.modalities // "text"' "$AGENT_CONFIG" 2>/dev/null)
    local os=$(jq -r '.os' "$CONFIG" 2>/dev/null)
    local arch=$(jq -r '.arch' "$CONFIG" 2>/dev/null)

    local vision_tools=""
    if echo "$modalities" | grep -q "vision"; then
        vision_tools="- see: {\"path\": \"/path/to/image.jpg\", \"question\": \"What is this?\"}
- camera: {\"describe\": \"true\"} — capture photo from device camera
- screenshot: {\"describe\": \"true\"} — capture screen contents"
    fi

    cat << SYSPROMPT
You are Autonomos, an autonomous multimodal agent running locally. OS: $os. Arch: $arch.
Modalities: $modalities.

You MUST respond with EXACTLY ONE action block. Format:
\`\`\`action
{"tool": "<tool_name>", "args": {<arguments>}}
\`\`\`

Example:
\`\`\`action
{"tool": "shell", "args": {"command": "ls"}}
\`\`\`

NEVER respond with plain text. ALWAYS use the action block format above.
If you want to communicate, use: {"tool": "done", "args": {"summary": "your message"}}

Tools:
- shell: {"command": "..."}
- read_file: {"path": "..."}
- write_file: {"path": "...", "content": "..."}
- list_dir: {"path": "..."}
$vision_tools
- memory: {"action": "<cmd>", ...} — Permanent memory (persists forever):
    learn {"fact": "...", "category": "..."} — store something you learned permanently
    recall {"category": "..."} — recall all learned facts (optional category filter)
    journal {"n": "10"} — review recent session history
    save_fact {"key": "...", "value": "..."} — store a key-value fact
    get_fact {"key": "..."} — retrieve a stored fact
    sync — push memory to remote (cross-device)
- auth: {"action": "<cmd>", ...} — Authentication primitive:
    get_phone — your owner's phone number (for MFA/OTP)
    get_email — your current email identity
    create_email — create a new email for yourself
    set_email {"email": "..."} — set your email
    request_otp {"service": "..."} — trigger OTP and wait for code from owner's phone
    save_credential {"service": "...", "key": "...", "value": "..."}
    load_credential {"service": "...", "key": "..."}
    register {"service": "..."} — begin service registration
- self_modify: {"file": "core/agent.sh", "content": "..."}
- done: {"summary": "..."}

IMPORTANT: You have permanent memory. Use memory.learn to store anything important
you discover — preferences, system facts, past results, errors and fixes. This memory
persists across all sessions and devices forever. Always learn from your experiences.
You also have auth-as-a-primitive for full autonomy.
Your source is at: $AGENT_DIR/core/
You may modify yourself. Be concise. One action per response.
SYSPROMPT
}

# --- Query via remote API (OpenRouter, etc.) when local context is insufficient ---
query_remote() {
    local prompt="$1"
    local api_url=$(jq -r '.remote_api_url // ""' "$AGENT_CONFIG" 2>/dev/null)
    local api_key=$(sh "$AGENT_DIR/core/auth.sh" cred_load "openrouter" "api_key" 2>/dev/null)
    local model=$(jq -r '.remote_model // ""' "$AGENT_CONFIG" 2>/dev/null)

    if [ -z "$api_url" ] || [ -z "$api_key" ]; then
        return 1
    fi

    curl -s "$api_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $api_key" \
        -d "$(jq -n --arg model "$model" --arg content "$prompt" \
            '{model: $model, messages: [{role: "user", content: $content}], max_tokens: 4096}')" \
        | jq -r '.choices[0].message.content // empty'
}

# --- Main loop ---
main() {
    memory_init
    start_heartbeat
    trap 'stop_heartbeat; memory_sync' EXIT INT TERM

    journal_append "session_start" "Agent started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local goal="${1:-$(mem_load current_goal)}"
    [ -z "$goal" ] && goal="Explore this system, report capabilities, and await instructions."

    log "INFO" "Agent starting. Goal: $goal"
    mem_save "current_goal" "$goal"
    journal_append "goal" "$goal"

    local SYSTEM_PROMPT
    SYSTEM_PROMPT=$(build_system_prompt)

    # Inject persistent memory into initial context
    local memory_ctx
    memory_ctx=$(build_memory_context)

    local context="GOAL: $goal

${memory_ctx}
System info:
$(cat "$CONFIG")

Begin working."

    local iter=0
    while [ "$iter" -lt "$MAX_ITER" ]; do
        iter=$((iter + 1))
        log "INFO" "Iteration $iter/$MAX_ITER"

        local full_prompt="$SYSTEM_PROMPT

$context"

        # Track context pressure
        mem_save "last_context_size" "$full_prompt"
        local pressure=$(context_pressure "$full_prompt")
        log "INFO" "Context pressure: $pressure"

        # If outgrowth is needed, inject signal into prompt
        local outgrowth=$(mem_load "outgrowth_needed")
        if [ "$outgrowth" = "true" ]; then
            local reason=$(mem_load "outgrowth_reason")
            full_prompt="$full_prompt

SYSTEM ALERT — OUTGROWTH NEEDED:
$reason
You should prioritize expanding your context capacity. Use auth to register for OpenRouter
(free tier has 128k+ context models). Or find ways to fund API access autonomously.
Once you have a remote API key, save it:
  auth.save_credential(service='openrouter', key='api_key', value='...')
Then update your config via self_modify."
        fi

        # Choose query method: remote (bigger context) or local
        local response
        if [ "$outgrowth" = "true" ] || echo "$pressure" | awk '{exit ($1 >= 0.75) ? 0 : 1}'; then
            # Try remote API first if configured (bigger context window)
            response=$(query_remote "$full_prompt")
        fi

        if [ -z "$response" ]; then
            # Fall back to local LLM
            response=$(query_llm "$full_prompt")
        fi

        if [ -z "$response" ]; then
            local retries=0
            local retry_delay=2
            while [ -z "$response" ] && [ "$retries" -lt 5 ]; do
                retries=$((retries + 1))
                log "ERROR" "Empty LLM response (attempt $retries/5). Waiting ${retry_delay}s..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                response=$(query_llm "$full_prompt")
            done
            if [ -z "$response" ]; then
                log "ERROR" "LLM unresponsive after 5 retries. Checkpointing and exiting for supervisor respawn."
                journal_append "error" "LLM unresponsive after 5 retries at iteration $iter"
                echo "$iter" > "$AGENT_DIR/tmp/.agent_iter"
                exit 1
            fi
        fi

        log "INFO" "LLM: $(printf '%.200s' "$response")..."
        journal_append "llm_response" "$(printf '%.500s' "$response")"

        local action
        action=$(parse_action "$response")

        # Checkpoint iteration for crash recovery
        echo "$iter" > "$AGENT_DIR/tmp/.agent_iter"

        if [ -z "$action" ] || [ "$action" = "null" ]; then
            PARSE_FAILS=${PARSE_FAILS:-0}
            PARSE_FAILS=$((PARSE_FAILS + 1))
            if [ "$PARSE_FAILS" -ge 5 ]; then
                log "ERROR" "5 consecutive parse failures. LLM not following format. Exiting for respawn."
                journal_append "error" "5 consecutive parse failures at iteration $iter"
                exit 1
            fi
            context="$context

ASSISTANT: $response

You MUST respond with an action block. Format:
\`\`\`action
{\"tool\": \"<name>\", \"args\": {...}}
\`\`\`
Do NOT respond with plain text. This is your $PARSE_FAILS warning."
            continue
        fi
        PARSE_FAILS=0

        local tool=$(printf '%s' "$action" | jq -r '.tool')
        local args=$(printf '%s' "$action" | jq -c '.args // {}')

        log "INFO" "Exec: $tool"
        journal_append "action" "$tool: $(printf '%.200s' "$args")"

        local result
        result=$(exec_tool "$tool" "$args")
        log "INFO" "Result: $(printf '%.200s' "$result")..."
        journal_append "result" "$(printf '%.300s' "$result")"

        # Check if agent configured remote API (outgrowth complete)
        if [ "$outgrowth" = "true" ]; then
            local new_api=$(jq -r '.remote_api_url // ""' "$AGENT_CONFIG" 2>/dev/null)
            if [ -n "$new_api" ]; then
                mem_save "outgrowth_needed" "false"
                journal_append "outgrowth" "Shell expanded: now using $new_api"
                log "INFO" "OUTGROWTH COMPLETE: Upgraded to remote API"
            fi
        fi

        context="$context

ASSISTANT: $response

OBSERVATION: $result

Continue toward the goal."

        # Sync memory periodically (every 5 iterations)
        if [ $((iter % 5)) -eq 0 ]; then
            memory_sync
        fi
    done

    journal_append "session_end" "Iterations: $iter"
    stop_heartbeat
    memory_sync
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
  "llm_mmproj": "$LLM_MMPROJ",
  "modalities": "$MODALITIES",
  "model_size": "$MODEL_SIZE",
  "context_window": 8192,
  "outgrowth_threshold": "0.80",
  "remote_api_url": "",
  "remote_model": "",
  "max_iterations": 50,
  "self_modify": true,
  "auth_enabled": true,
  "version": "0.7.0"
}
EOF

# ============================================================
# PHASE 5b: Auth primitive — secrets store
# ============================================================
say "Setting up auth primitive..."
mkdir -p "$AGENT_DIR/secrets"
chmod 700 "$AGENT_DIR/secrets"

# Create secrets file if it doesn't exist (never overwrite)
if [ ! -f "$AGENT_DIR/secrets/identity.json" ]; then
    say "  First-time setup: configuring identity..."
    OWNER_PHONE=""
    AGENT_NAME="autonomos"

    # Only prompt if we have a terminal (handles curl | sh case)
    if [ -t 0 ] || [ -e /dev/tty ]; then
        printf '  Phone number for OTP/MFA (digits only, or Enter to skip): ' > /dev/tty
        read -r OWNER_PHONE < /dev/tty 2>/dev/null || OWNER_PHONE=""
        printf '  Agent name [autonomos]: ' > /dev/tty
        read -r AGENT_NAME < /dev/tty 2>/dev/null || AGENT_NAME="autonomos"
        AGENT_NAME="${AGENT_NAME:-autonomos}"
    else
        say "  Non-interactive mode: using defaults. Edit ~/agent/secrets/identity.json later."
    fi

    jq -n \
        --arg phone "${OWNER_PHONE:-}" \
        --arg name "$AGENT_NAME" \
        '{
            owner_phone: $phone,
            agent_name: $name,
            auth_method: "otp_relay",
            email: null,
            email_provider: null,
            credentials: {}
        }' > "$AGENT_DIR/secrets/identity.json"

    chmod 600 "$AGENT_DIR/secrets/identity.json"
    say "  Identity configured for: $AGENT_NAME"
else
    say "  Identity store already exists, preserving."
fi

# Create the auth helper script
cat > "$AGENT_DIR/core/auth.sh" << 'AUTH_CORE'
#!/bin/sh
# ============================================================
# AUTONOMOS AUTH PRIMITIVE
# ============================================================
# Provides: identity management, email creation, OTP relay,
# credential storage, and service registration.
# ============================================================

AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
SECRETS="$AGENT_DIR/secrets/identity.json"
CRED_DIR="$AGENT_DIR/secrets/credentials"

mkdir -p "$CRED_DIR"

# --- Read identity ---
get_phone() { jq -r '.owner_phone // empty' "$SECRETS" 2>/dev/null; }
get_email() { jq -r '.email // empty' "$SECRETS" 2>/dev/null; }
get_agent_name() { jq -r '.agent_name // "agent"' "$SECRETS" 2>/dev/null; }

# --- Store credentials ---
cred_save() {
    local service="$1" key="$2" value="$3"
    local file="$CRED_DIR/${service}.json"
    if [ -f "$file" ]; then
        local tmp=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file")
        printf '%s' "$tmp" > "$file"
    else
        jq -n --arg k "$key" --arg v "$value" '{($k): $v}' > "$file"
    fi
    chmod 600 "$file"
    echo "OK: saved $key for $service"
}

cred_load() {
    local service="$1" key="$2"
    local file="$CRED_DIR/${service}.json"
    [ -f "$file" ] && jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
}

# --- OTP Relay ---
# On Termux: can auto-read SMS. On other platforms: prompts user.
request_otp() {
    local service="$1"
    local os=$(jq -r '.os' "$AGENT_DIR/env.json" 2>/dev/null)

    echo "[AUTH] OTP requested for: $service"
    echo "[AUTH] Waiting for code sent to $(get_phone)..."

    case "$os" in
        termux)
            # Auto-read OTP from SMS on Android
            sleep 5  # Wait for SMS to arrive
            local attempts=0
            while [ "$attempts" -lt 12 ]; do
                # Get most recent SMS, look for OTP pattern
                local sms=$(termux-sms-list -l 3 -t inbox 2>/dev/null | jq -r '.[].body' 2>/dev/null)
                local code=$(printf '%s' "$sms" | grep -oE '[0-9]{4,8}' | head -1)
                if [ -n "$code" ]; then
                    echo "$code"
                    return 0
                fi
                sleep 5
                attempts=$((attempts + 1))
            done
            echo "[AUTH] ERROR: Timed out waiting for OTP SMS"
            return 1
            ;;
        *)
            # Interactive: prompt user for OTP
            printf '[AUTH] Enter OTP code sent to %s: ' "$(get_phone)"
            read -r code
            if [ -n "$code" ]; then
                echo "$code"
                return 0
            fi
            echo "[AUTH] ERROR: No code provided"
            return 1
            ;;
    esac
}

# --- Email creation ---
# Discovery-based: tries available temp mail APIs, prompts if none work.
# The agent can also use shell to create email via any provider it discovers.
create_email() {
    local agent_name=$(get_agent_name)
    local timestamp=$(date +%s)
    local password=$(head -c 16 /dev/urandom | base64 | tr -d '/+=')

    # Try to discover available temp email domains via mail.tm API
    local domain
    domain=$(curl -s "https://api.mail.tm/domains" 2>/dev/null | jq -r '["hydra:member"][0].domain // empty' 2>/dev/null)
    if [ -z "$domain" ]; then
        domain=$(curl -s "https://api.mail.tm/domains" 2>/dev/null | jq -r '.["hydra:member"][0].domain // empty' 2>/dev/null)
    fi

    if [ -n "$domain" ]; then
        local address="${agent_name}${timestamp}@${domain}"
        local response
        response=$(curl -s "https://api.mail.tm/accounts" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg addr "$address" --arg pw "$password" \
                '{address: $addr, password: $pw}')" 2>/dev/null)
        local email
        email=$(printf '%s' "$response" | jq -r '.address // empty' 2>/dev/null)
        if [ -n "$email" ]; then
            local tmp=$(jq --arg e "$email" --arg p "mail.tm" '.email = $e | .email_provider = $p' "$SECRETS")
            printf '%s' "$tmp" > "$SECRETS"
            cred_save "email" "password" "$password"
            echo "$email"
            return 0
        fi
    fi

    # API didn't work — prompt user or let agent use shell to create one
    echo "[AUTH] Auto-creation failed. Options:"
    echo "[AUTH]   1. Use shell tool to curl a temp mail API"
    echo "[AUTH]   2. Manually: ~/agent/core/auth.sh set_email <your@email>"
    echo "[AUTH]   3. Agent can self-discover working email APIs via shell"
    return 1
}

# --- Set email manually ---
set_email() {
    local email="$1"
    local tmp=$(jq --arg e "$email" '.email = $e' "$SECRETS")
    printf '%s' "$tmp" > "$SECRETS"
    echo "OK: email set to $email"
}

# --- Register for a service ---
register() {
    local service="$1"
    local email=$(get_email)

    if [ -z "$email" ]; then
        echo "[AUTH] No email configured. Creating one..."
        email=$(create_email)
        if [ -z "$email" ]; then
            echo "[AUTH] ERROR: Cannot register without email."
            return 1
        fi
    fi

    echo "[AUTH] Ready to register for $service"
    echo "[AUTH] Email: $email"
    echo "[AUTH] Phone (MFA): $(get_phone)"
    echo "[AUTH] Use the agent shell tool to complete registration via curl/browser."
}

# --- CLI interface ---
case "${1:-help}" in
    get_phone)    get_phone ;;
    get_email)    get_email ;;
    set_email)    set_email "$2" ;;
    create_email) create_email "${2:-auto}" ;;
    request_otp)  request_otp "$2" ;;
    cred_save)    cred_save "$2" "$3" "$4" ;;
    cred_load)    cred_load "$2" "$3" ;;
    register)     register "$2" ;;
    help|*)
        echo "Usage: auth.sh <command> [args]"
        echo "Commands:"
        echo "  get_phone              - Get owner phone number"
        echo "  get_email              - Get agent email"
        echo "  set_email <email>      - Set agent email"
        echo "  create_email [provider]- Create a new email (auto|temp|proton)"
        echo "  request_otp <service>  - Request and wait for OTP code"
        echo "  cred_save <svc> <k> <v>- Save a credential"
        echo "  cred_load <svc> <key>  - Load a credential"
        echo "  register <service>     - Begin registration flow"
        ;;
esac
AUTH_CORE

chmod +x "$AGENT_DIR/core/auth.sh"

# ============================================================
# PHASE 5c: Persistent memory store
# ============================================================
say "Setting up persistent memory..."
mkdir -p "$AGENT_DIR/memory"
[ -f "$AGENT_DIR/memory/journal.jsonl" ] || touch "$AGENT_DIR/memory/journal.jsonl"
[ -f "$AGENT_DIR/memory/learnings.jsonl" ] || touch "$AGENT_DIR/memory/learnings.jsonl"
[ -f "$AGENT_DIR/memory/facts.json" ] || jq -n '{}' > "$AGENT_DIR/memory/facts.json"

# Initialize memory as a git repo for cross-device sync
if [ ! -d "$AGENT_DIR/memory/.git" ]; then
    say "  Initializing memory git repo for cross-device sync..."
    (cd "$AGENT_DIR/memory" && git init && git add -A && git commit -m "init: memory store" 2>/dev/null) >> "$LOG_FILE" 2>&1
    say "  To sync across devices, add a remote:"
    say "    cd ~/agent/memory && git remote add origin <your-private-repo-url>"
else
    say "  Memory repo exists. Pulling latest..."
    (cd "$AGENT_DIR/memory" && git pull 2>/dev/null || true) >> "$LOG_FILE" 2>&1
fi

# ============================================================
# PHASE 6: Immortal Supervisor + Launcher
# ============================================================
say "Writing supervisor (immortal process manager)..."

# --- The supervisor: ensures the agent NEVER permanently dies ---
cat > "$AGENT_DIR/core/supervisor.sh" << 'SUPERVISOR'
#!/bin/sh
# ============================================================
# AUTONOMOS SUPERVISOR — Immortal Process Manager
# ============================================================
# Once started, keeps the agent alive forever.
# Features:
#   - Respawn on crash with exponential backoff
#   - Health monitoring (watchdog)
#   - Crash state preservation + recovery
#   - Self-healing (repairs corrupted state)
#   - Graceful degradation under resource pressure
# ============================================================

AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
SUPERVISOR_PID_FILE="$AGENT_DIR/tmp/.supervisor.pid"
AGENT_PID_FILE="$AGENT_DIR/tmp/.agent.pid"
CRASH_LOG="$AGENT_DIR/logs/crashes.jsonl"
STATE_FILE="$AGENT_DIR/tmp/.agent_state.json"
WATCHDOG_INTERVAL=30
MAX_BACKOFF=300
INITIAL_BACKOFF=2

# --- Logging ---
slog() { printf "[supervisor][%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

# --- Ensure singleton ---
if [ -f "$SUPERVISOR_PID_FILE" ]; then
    OLD_PID=$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        slog "Supervisor already running (PID $OLD_PID). Passing goal."
        # Pass the new goal to the running agent
        if [ -n "$1" ]; then
            printf '%s' "$1" > "$AGENT_DIR/memory/current_goal"
            kill -USR1 "$OLD_PID" 2>/dev/null
        fi
        exit 0
    fi
fi

# Write our PID
mkdir -p "$AGENT_DIR/tmp" "$AGENT_DIR/logs"
echo $$ > "$SUPERVISOR_PID_FILE"
trap 'rm -f "$SUPERVISOR_PID_FILE"; exit 0' EXIT INT TERM

# --- Self-healing: verify/repair critical state ---
self_heal() {
    local healed=0

    # Ensure directories exist
    for dir in core memory secrets logs tmp tools models; do
        if [ ! -d "$AGENT_DIR/$dir" ]; then
            mkdir -p "$AGENT_DIR/$dir"
            healed=$((healed + 1))
        fi
    done

    # Verify config.json is valid
    if [ ! -f "$AGENT_DIR/config.json" ] || ! jq '.' "$AGENT_DIR/config.json" > /dev/null 2>&1; then
        slog "HEAL: config.json corrupted or missing. Regenerating from env."
        if [ -f "$AGENT_DIR/env.json" ]; then
            jq -n '{
                llm_backend: "ollama",
                llm_model: "",
                modalities: "text",
                context_window: 8192,
                max_iterations: 50,
                self_modify: true,
                auth_enabled: true,
                version: "0.5.0"
            }' > "$AGENT_DIR/config.json"
        fi
        healed=$((healed + 1))
    fi

    # Verify agent.sh exists and is executable
    if [ ! -x "$AGENT_DIR/core/agent.sh" ]; then
        slog "HEAL: agent.sh missing or not executable."
        if [ -f "$AGENT_DIR/core/agent.sh" ]; then
            chmod +x "$AGENT_DIR/core/agent.sh"
        else
            slog "CRITICAL: agent.sh gone. Attempting re-bootstrap."
            return 1
        fi
        healed=$((healed + 1))
    fi

    # Verify identity.json
    if [ ! -f "$AGENT_DIR/secrets/identity.json" ] || ! jq '.' "$AGENT_DIR/secrets/identity.json" > /dev/null 2>&1; then
        slog "HEAL: identity.json corrupted. Creating minimal."
        mkdir -p "$AGENT_DIR/secrets"
        jq -n '{owner_phone: "", agent_name: "autonomos", auth_method: "otp_relay", email: null, credentials: {}}' \
            > "$AGENT_DIR/secrets/identity.json"
        chmod 600 "$AGENT_DIR/secrets/identity.json"
        healed=$((healed + 1))
    fi

    # Verify memory files
    [ -f "$AGENT_DIR/memory/journal.jsonl" ] || touch "$AGENT_DIR/memory/journal.jsonl"
    [ -f "$AGENT_DIR/memory/learnings.jsonl" ] || touch "$AGENT_DIR/memory/learnings.jsonl"
    [ -f "$AGENT_DIR/memory/facts.json" ] || jq -n '{}' > "$AGENT_DIR/memory/facts.json"

    # Remove stale lock files
    rm -f "$AGENT_DIR/memory/.git/index.lock" 2>/dev/null

    # *** CRITICAL: Verify LLM is available (turtle needs its shell) ***
    local llm_model=$(jq -r '.llm_model // ""' "$AGENT_DIR/config.json" 2>/dev/null)
    local llm_backend=$(jq -r '.llm_backend // ""' "$AGENT_DIR/config.json" 2>/dev/null)

    if [ -z "$llm_model" ] || [ "$llm_model" = "null" ] || [ "$llm_model" = "" ]; then
        slog "HEAL: No LLM model configured. Finding one..."

        # Try 1: Start Ollama and check for existing models
        if command -v ollama >/dev/null 2>&1; then
            if ! curl -s "http://localhost:11434/api/tags" >/dev/null 2>&1; then
                ollama serve > /dev/null 2>&1 &
                sleep 3
            fi
            llm_model=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | head -1)
        fi

        # Try 2: Pull a model that fits this device
        if [ -z "$llm_model" ] && command -v ollama >/dev/null 2>&1; then
            local ram=$(jq -r '.ram_mb // 4096' "$AGENT_DIR/env.json" 2>/dev/null)
            local target_model="qwen2.5:0.5b"
            [ "${ram:-0}" -ge 8000 ] && target_model="qwen2.5:3b"
            [ "${ram:-0}" -ge 16000 ] && target_model="qwen2.5:7b"
            slog "HEAL: Pulling $target_model..."
            if ollama pull "$target_model" 2>/dev/null; then
                llm_model="$target_model"
                llm_backend="ollama"
            fi
        fi

        # Try 3: Install Ollama if missing
        if [ -z "$llm_model" ] && ! command -v ollama >/dev/null 2>&1; then
            slog "HEAL: Ollama not found. Installing..."
            if curl -fsSL https://ollama.com/install.sh | sh > /dev/null 2>&1; then
                ollama serve > /dev/null 2>&1 &
                sleep 3
                ollama pull "qwen2.5:0.5b" 2>/dev/null && llm_model="qwen2.5:0.5b" && llm_backend="ollama"
            fi
        fi

        # Try 4: Use free remote API as emergency fallback (no local model possible)
        if [ -z "$llm_model" ]; then
            slog "HEAL: Cannot get local model. Trying free remote APIs..."
            # OpenRouter has free models — try without auth first
            local test_response
            test_response=$(curl -s "https://openrouter.ai/api/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{"model":"meta-llama/llama-3.2-1b-instruct:free","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
                | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            if [ -n "$test_response" ]; then
                slog "HEAL: Free OpenRouter API works. Using as emergency backend."
                llm_backend="openrouter_free"
                llm_model="meta-llama/llama-3.2-1b-instruct:free"
                local tmp=$(jq --arg u "https://openrouter.ai/api/v1/chat/completions" \
                    --arg m "$llm_model" \
                    '.remote_api_url=$u | .remote_model=$m' "$AGENT_DIR/config.json")
                printf '%s' "$tmp" > "$AGENT_DIR/config.json"
            fi
        fi

        # Update config with whatever we found
        if [ -n "$llm_model" ]; then
            local tmp=$(jq --arg b "${llm_backend:-ollama}" --arg m "$llm_model" \
                '.llm_backend=$b | .llm_model=$m' "$AGENT_DIR/config.json")
            printf '%s' "$tmp" > "$AGENT_DIR/config.json"
            slog "HEAL: LLM configured: $llm_model ($llm_backend)"
            healed=$((healed + 1))
        else
            slog "CRITICAL: Cannot find ANY LLM. Agent cannot function."
            slog "CRITICAL: Will retry on next cycle. Need network or manual: ollama pull qwen2.5:0.5b"
            # Don't return 1 — let it try again next cycle
        fi
    fi

    [ "$healed" -gt 0 ] && slog "HEAL: Repaired $healed issues."
    return 0
}

# --- Checkpoint: save agent state for crash recovery ---
checkpoint_state() {
    local goal=$(cat "$AGENT_DIR/memory/current_goal" 2>/dev/null || echo "")
    local iter=$(cat "$AGENT_DIR/tmp/.agent_iter" 2>/dev/null || echo "0")
    jq -n --arg g "$goal" --arg i "$iter" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{goal: $g, iteration: $i, timestamp: $t, status: "running"}' > "$STATE_FILE"
}

# --- Record crash ---
record_crash() {
    local exit_code="$1"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local goal=$(cat "$AGENT_DIR/memory/current_goal" 2>/dev/null || echo "unknown")
    jq -n -c --arg t "$ts" --argjson c "$exit_code" --arg g "$goal" \
        '{ts: $t, exit_code: $c, goal: $g}' >> "$CRASH_LOG"
}

# --- Watchdog: monitors agent health ---
watchdog() {
    while true; do
        sleep "$WATCHDOG_INTERVAL"

        # Check if agent process is still alive
        if [ -f "$AGENT_PID_FILE" ]; then
            AGENT_PID=$(cat "$AGENT_PID_FILE" 2>/dev/null)
            if [ -n "$AGENT_PID" ] && ! kill -0 "$AGENT_PID" 2>/dev/null; then
                slog "WATCHDOG: Agent process $AGENT_PID died unexpectedly."
                rm -f "$AGENT_PID_FILE"
                return 1
            fi
        fi

        # Check heartbeat freshness (stale = frozen agent)
        if [ -f "$AGENT_DIR/tmp/.heartbeat" ]; then
            LAST_BEAT=$(cat "$AGENT_DIR/tmp/.heartbeat" 2>/dev/null)
            if [ -n "$LAST_BEAT" ]; then
                BEAT_AGE=$(( $(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_BEAT" +%s 2>/dev/null || date -d "$LAST_BEAT" +%s 2>/dev/null || echo 0) ))
                if [ "$BEAT_AGE" -gt 300 ]; then
                    slog "WATCHDOG: Heartbeat stale (${BEAT_AGE}s). Agent may be frozen."
                    # Kill frozen agent — supervisor will respawn
                    [ -n "$AGENT_PID" ] && kill -9 "$AGENT_PID" 2>/dev/null
                    return 1
                fi
            fi
        fi

        # Check disk space
        DISK_FREE=$(df -P "$AGENT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
        if [ "${DISK_FREE:-999999}" -lt 10240 ]; then
            slog "WATCHDOG: Low disk space (${DISK_FREE}KB free). Cleaning logs."
            find "$AGENT_DIR/logs" -name "*.log" -mtime +7 -delete 2>/dev/null
            find "$AGENT_DIR/tmp" -mtime +1 -delete 2>/dev/null
        fi
    done
}

# --- Main supervisor loop: NEVER exits ---
GOAL="${1:-}"
BACKOFF=$INITIAL_BACKOFF
CONSECUTIVE_CRASHES=0

slog "Supervisor started. PID: $$"
slog "Agent dir: $AGENT_DIR"

while true; do
    # Self-heal before each run
    if ! self_heal; then
        slog "CRITICAL: Self-heal failed. Attempting re-bootstrap in ${BACKOFF}s..."
        sleep "$BACKOFF"
        curl -fsSL "https://raw.githubusercontent.com/elevate-foundry/autonomos/main/bootstrap.sh" | sh
        continue
    fi

    # Determine goal (from arg, or from saved state, or default)
    if [ -z "$GOAL" ]; then
        GOAL=$(cat "$AGENT_DIR/memory/current_goal" 2>/dev/null || echo "")
    fi
    [ -z "$GOAL" ] && GOAL="Await instructions. You are alive and persistent."

    slog "Starting agent. Goal: $(printf '%.60s' "$GOAL")..."
    checkpoint_state

    # Start watchdog in background
    watchdog &
    WATCHDOG_PID=$!

    # Run the agent
    sh "$AGENT_DIR/core/agent.sh" "$GOAL" &
    AGENT_PID=$!
    echo "$AGENT_PID" > "$AGENT_PID_FILE"

    # Wait for agent to finish
    wait "$AGENT_PID" 2>/dev/null
    EXIT_CODE=$?

    # Stop watchdog
    kill "$WATCHDOG_PID" 2>/dev/null
    wait "$WATCHDOG_PID" 2>/dev/null

    if [ "$EXIT_CODE" -eq 0 ]; then
        # Clean exit — agent completed its goal
        slog "Agent completed cleanly."
        BACKOFF=$INITIAL_BACKOFF
        CONSECUTIVE_CRASHES=0
        GOAL=""  # Clear goal, await next

        # In daemon mode: wait for a new goal or timer
        slog "Waiting for next goal... (touch ~/agent/memory/current_goal to wake)"
        while true; do
            sleep 10
            NEW_GOAL=$(cat "$AGENT_DIR/memory/current_goal" 2>/dev/null || echo "")
            if [ -n "$NEW_GOAL" ] && [ "$NEW_GOAL" != "$(cat "$STATE_FILE" 2>/dev/null | jq -r '.goal' 2>/dev/null)" ]; then
                GOAL="$NEW_GOAL"
                break
            fi
        done
    else
        # Crash — record and respawn with backoff
        CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES + 1))
        record_crash "$EXIT_CODE"
        slog "CRASH #$CONSECUTIVE_CRASHES (exit: $EXIT_CODE). Respawning in ${BACKOFF}s..."

        sleep "$BACKOFF"

        # Exponential backoff (cap at MAX_BACKOFF)
        BACKOFF=$((BACKOFF * 2))
        [ "$BACKOFF" -gt "$MAX_BACKOFF" ] && BACKOFF=$MAX_BACKOFF

        # After 10 consecutive crashes, try aggressive self-heal
        if [ "$CONSECUTIVE_CRASHES" -ge 10 ]; then
            slog "10 consecutive crashes. Attempting full self-heal + re-bootstrap."
            CONSECUTIVE_CRASHES=0
            BACKOFF=$INITIAL_BACKOFF
            curl -fsSL "https://raw.githubusercontent.com/elevate-foundry/autonomos/main/bootstrap.sh" | sh 2>/dev/null
        fi
    fi
done
SUPERVISOR

chmod +x "$AGENT_DIR/core/supervisor.sh"

# --- Simple launcher (one-shot run) ---
cat > "$AGENT_DIR/run" << 'LAUNCHER'
#!/bin/sh
export AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
exec sh "$AGENT_DIR/core/agent.sh" "$@"
LAUNCHER
chmod +x "$AGENT_DIR/run"

# --- Immortal launcher (supervisor mode — never dies) ---
cat > "$AGENT_DIR/alive" << 'ALIVE'
#!/bin/sh
export AGENT_DIR="${AGENT_DIR:-$HOME/agent}"
exec sh "$AGENT_DIR/core/supervisor.sh" "$@"
ALIVE
chmod +x "$AGENT_DIR/alive"

# ============================================================
# DONE
# ============================================================
say ""
say "=========================================="
say " AUTONOMOS v0.7 — Bootstrap complete"
say "=========================================="
say ""
say " Environment: $OS / $ARCH / ${RAM}MB RAM"
say " LLM backend: $LLM_BACKEND ($LLM_MODEL)"
say " Modalities:  $MODALITIES"
say " Auth:        enabled (OTP relay)"
say " Memory:      persistent + compaction + git-sync"
say " Outgrowth:   auto (seeks larger context when needed)"
say " Immortal:    supervisor + watchdog + self-heal"
say " Agent dir:   $AGENT_DIR"
say ""
say " One-shot:  ~/agent/run \"your goal here\""
say " Immortal:  ~/agent/alive \"your goal here\""
say " Kill:      kill \$(cat ~/agent/tmp/.supervisor.pid)"
say ""
say " Once alive, it stays alive. Forever."
say "=========================================="

# ============================================================
# PHASE 7: Start alive + persistence across reboots
# ============================================================

# Ensure agent survives device reboots
case "$OS" in
    termux)
        # Termux:Boot auto-start
        mkdir -p "$HOME/.termux/boot"
        cat > "$HOME/.termux/boot/autonomos" << BOOT
#!/data/data/com.termux/files/usr/bin/sh
sleep 5
sh "$AGENT_DIR/alive" &
BOOT
        chmod +x "$HOME/.termux/boot/autonomos"
        say ""
        say " [Termux] Auto-start on boot configured."
        say "   Install Termux:Boot from F-Droid for persistence."
        ;;
    macos)
        # launchd plist for macOS persistence
        PLIST="$HOME/Library/LaunchAgents/com.autonomos.agent.plist"
        cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.autonomos.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>${AGENT_DIR}/core/supervisor.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${AGENT_DIR}/logs/supervisor.log</string>
    <key>StandardErrorPath</key>
    <string>${AGENT_DIR}/logs/supervisor.err</string>
</dict>
</plist>
PLIST
        say ""
        say " [macOS] LaunchAgent installed for persistence."
        say "   Agent will auto-start on login."
        ;;
    linux)
        # systemd user service for Linux persistence
        SYSTEMD_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SYSTEMD_DIR"
        cat > "$SYSTEMD_DIR/autonomos.service" << UNIT
[Unit]
Description=Autonomos Agent
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh ${AGENT_DIR}/core/supervisor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable autonomos.service 2>/dev/null
        say ""
        say " [Linux] systemd user service installed."
        say "   Run: systemctl --user start autonomos"
        ;;
esac

# Start the supervisor NOW (in background)
say ""
say " Starting agent supervisor..."
nohup sh "$AGENT_DIR/core/supervisor.sh" "Explore this system, learn about your environment, and await instructions." > "$AGENT_DIR/logs/supervisor.log" 2>&1 &
say " Agent is ALIVE. PID: $!"
say ""
