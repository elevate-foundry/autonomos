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
    # Discover the best multimodal model available
    say "  Discovering best multimodal model for ${MODEL_SIZE} budget..."
    LLM_MODEL=$(discover_multimodal_model "$MODEL_SIZE")

    if [ -z "$LLM_MODEL" ]; then
        # No model discovered — search ollama for vision-capable models
        say "  No local vision model found. Searching Ollama library..."
        # Let ollama search and pick first result that mentions vision
        LLM_MODEL=$(ollama search vision 2>/dev/null | awk 'NR==2{print $1}')
    fi

    if [ -z "$LLM_MODEL" ]; then
        # Still nothing — ask the user
        say "  Could not auto-discover a multimodal model."
        printf '  Enter an Ollama model name (or press Enter to skip): '
        read -r LLM_MODEL
    fi

    if [ -n "$LLM_MODEL" ]; then
        say "  Pulling model: $LLM_MODEL (this may take a while)..."
        ollama pull "$LLM_MODEL" 2>> "$LOG_FILE" || {
            err "  Model pull failed. You can manually run: ollama pull <model>"
        }
        # Detect modalities from model name/metadata
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
    printf '  Enter a HuggingFace repo (e.g. ggml-org/gemma-3-4b-it-GGUF) or GGUF URL: '
    read -r MODEL_SOURCE

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
        (cd "$MEMORY_DIR" && git add -A && git commit -m "memory: $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null && git push 2>/dev/null) &
    fi
}

# Initialize memory git repo if not present
memory_init() {
    mkdir -p "$MEMORY_DIR"
    [ -f "$JOURNAL" ] || touch "$JOURNAL"
    [ -f "$LEARNINGS" ] || touch "$LEARNINGS"
    [ -f "$FACTS" ] || jq -n '{}' > "$FACTS"
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

    if [ -z "$backend" ] || [ -z "$model" ]; then
        echo "[ERROR] No LLM configured. Run bootstrap or set config.json manually."
        return 1
    fi

    case "$backend" in
        ollama)
            curl -s "http://localhost:$OLLAMA_PORT/api/chat" \
                -d "$(jq -n --arg model "$model" --arg content "$prompt" \
                '{model: $model, messages: [{role: "user", content: $content}], stream: false}')" \
                | jq -r '.message.content // empty'
            ;;
        llamacpp-server)
            curl -s "http://localhost:$LLAMA_PORT/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --arg content "$prompt" \
                '{messages: [{role: "user", content: $content}], max_tokens: 2048, temperature: 0.7}')" \
                | jq -r '.choices[0].message.content // empty'
            ;;
    esac
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
    # Extract JSON between ```action and ``` (portable awk, works on BSD+GNU)
    printf '%s' "$response" | awk '/```action/{found=1;next} /```/{if(found)exit} found{print}' | jq '.' 2>/dev/null
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

You execute actions by responding with:
\`\`\`action
{"tool": "shell", "args": {"command": "ls"}}
\`\`\`

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

# --- Main loop ---
main() {
    memory_init
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
        local response
        response=$(query_llm "$full_prompt")

        if [ -z "$response" ]; then
            log "ERROR" "Empty LLM response. Retrying..."
            sleep 2
            continue
        fi

        log "INFO" "LLM: $(printf '%.200s' "$response")..."
        journal_append "llm_response" "$(printf '%.500s' "$response")"

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
        journal_append "action" "$tool: $(printf '%.200s' "$args")"

        local result
        result=$(exec_tool "$tool" "$args")
        log "INFO" "Result: $(printf '%.200s' "$result")..."
        journal_append "result" "$(printf '%.300s' "$result")"

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
  "max_iterations": 50,
  "self_modify": true,
  "auth_enabled": true,
  "version": "0.4.0"
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
    printf '  Phone number for OTP/MFA (digits only, or Enter to skip): '
    read -r OWNER_PHONE
    printf '  Agent name [autonomos]: '
    read -r AGENT_NAME
    AGENT_NAME="${AGENT_NAME:-autonomos}"

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
    (cd "$AGENT_DIR/memory" && git pull 2>/dev/null) >> "$LOG_FILE" 2>&1
fi

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
say " AUTONOMOS v0.4 — Bootstrap complete"
say "=========================================="
say ""
say " Environment: $OS / $ARCH / ${RAM}MB RAM"
say " LLM backend: $LLM_BACKEND ($LLM_MODEL)"
say " Modalities:  $MODALITIES"
say " Auth:        enabled (OTP relay)"
say " Memory:      persistent + cross-device"
say " Agent dir:   $AGENT_DIR"
say ""
say " Run:  ~/agent/run \"your goal here\""
say " Logs: ~/agent/logs/"
say " Memory: ~/agent/memory/ (git-synced)"
say ""
say " Primitives: vision, memory, auth, self-modify"
say "=========================================="
