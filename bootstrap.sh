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
    # Multimodal-first model selection based on available RAM
    # All selected models support vision natively
    RAM=$(detect_ram_mb)
    if [ "$RAM" -ge 16000 ]; then
        # Qwen2.5-Omni: vision + audio input, 7B active params
        echo "omni-7b"
    elif [ "$RAM" -ge 8000 ]; then
        # Qwen2.5-Omni 3B: vision + audio, fits in 8GB
        echo "omni-3b"
    elif [ "$RAM" -ge 6000 ]; then
        # Gemma 4 E4B: vision + audio + tool-use, ~4B effective
        echo "gemma4-e4b"
    elif [ "$RAM" -ge 4000 ]; then
        # SmolVLM2 2.2B: lightweight vision model
        echo "smolvlm-2b"
    elif [ "$RAM" -ge 2000 ]; then
        # SmolVLM 500M: minimal vision capability
        echo "smolvlm-500m"
    else
        # Ultra-constrained: text-only fallback
        echo "text-0.5b"
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
# PHASE 3: Local LLM — multimodal, adaptive
# ============================================================
say "Setting up multimodal LLM (target: ${MODEL_SIZE})..."

LLM_BACKEND=""
LLM_MODEL=""
LLM_MMPROJ=""
MODALITIES="text"

# Map model selection to concrete model identifiers
# Format: ollama_model|hf_repo|modalities
case "$MODEL_SIZE" in
    omni-7b)
        OLLAMA_MODEL="qwen2.5vl:7b"
        HF_REPO="ggml-org/Qwen2.5-VL-7B-Instruct-GGUF"
        MODALITIES="vision,text"
        ;;
    omni-3b)
        OLLAMA_MODEL="qwen2.5vl:3b"
        HF_REPO="ggml-org/Qwen2.5-VL-3B-Instruct-GGUF"
        MODALITIES="vision,text"
        ;;
    gemma4-e4b)
        OLLAMA_MODEL="gemma4:e4b"
        HF_REPO="ggml-org/gemma-4-E4B-it-GGUF"
        MODALITIES="vision,audio,text"
        ;;
    smolvlm-2b)
        OLLAMA_MODEL="smolvlm:2.2b"
        HF_REPO="ggml-org/SmolVLM2-2.2B-Instruct-GGUF"
        MODALITIES="vision,text"
        ;;
    smolvlm-500m)
        OLLAMA_MODEL="smolvlm:500m"
        HF_REPO="ggml-org/SmolVLM-500M-Instruct-GGUF"
        MODALITIES="vision,text"
        ;;
    text-0.5b)
        OLLAMA_MODEL="qwen2.5:0.5b"
        HF_REPO=""
        MODALITIES="text"
        ;;
esac

say "  Target: $MODEL_SIZE | Modalities: $MODALITIES"

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
    LLM_MODEL="$OLLAMA_MODEL"
    say "  Pulling model: $LLM_MODEL (this may take a while)..."
    ollama pull "$LLM_MODEL" >> "$LOG_FILE" 2>&1 || {
        # Fallback: try pulling without tag specifics
        say "  Primary pull failed, trying alternate tags..."
        case "$MODEL_SIZE" in
            omni-7b)   ollama pull "qwen2.5-vl:7b" >> "$LOG_FILE" 2>&1 && LLM_MODEL="qwen2.5-vl:7b" ;;
            omni-3b)   ollama pull "qwen2.5-vl:3b" >> "$LOG_FILE" 2>&1 && LLM_MODEL="qwen2.5-vl:3b" ;;
            gemma4-e4b) ollama pull "gemma4" >> "$LOG_FILE" 2>&1 && LLM_MODEL="gemma4" ;;
            *)         err "  Model pull failed. Agent will retry on first run." ;;
        esac
    }
fi

# Strategy 2: llama.cpp with multimodal server (if Ollama unavailable)
if [ -z "$LLM_BACKEND" ] && [ -n "$HF_REPO" ]; then
    say "  Building llama.cpp from source (with multimodal support)..."
    install_pkg cmake
    install_pkg make

    if command -v clang >/dev/null 2>&1; then
        CC_FOUND="clang"
    elif command -v gcc >/dev/null 2>&1; then
        CC_FOUND="gcc"
    else
        install_pkg clang || install_pkg gcc
    fi

    if [ ! -d "$AGENT_DIR/llama.cpp" ]; then
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$AGENT_DIR/llama.cpp" >> "$LOG_FILE" 2>&1
    fi

    NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    (cd "$AGENT_DIR/llama.cpp" && cmake -B build && cmake --build build -j"$NPROC" --target llama-server llama-mtmd-cli) >> "$LOG_FILE" 2>&1

    LLM_BACKEND="llamacpp-server"

    # Download model + mmproj from HuggingFace
    say "  Downloading multimodal model from $HF_REPO..."
    mkdir -p "$AGENT_DIR/models"

    # Use huggingface-cli if available, otherwise curl the files
    if command -v huggingface-cli >/dev/null 2>&1; then
        huggingface-cli download "$HF_REPO" --local-dir "$AGENT_DIR/models/multimodal" --include "*Q4_K_M*" "*mmproj*" >> "$LOG_FILE" 2>&1
    else
        # Discover and download the Q4_K_M model + mmproj
        BASE_URL="https://huggingface.co/$HF_REPO/resolve/main"
        # These repos follow a consistent naming pattern
        REPO_NAME=$(echo "$HF_REPO" | awk -F/ '{print $2}' | sed 's/-GGUF//')
        MODEL_FILE=$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

        # Try to fetch the file listing and find Q4_K_M + mmproj
        say "  Fetching model files (Q4_K_M quantization)..."
        curl -fSL -o "$AGENT_DIR/models/model.gguf" \
            "$BASE_URL/${MODEL_FILE}-Q4_K_M.gguf" >> "$LOG_FILE" 2>&1 || \
        curl -fSL -o "$AGENT_DIR/models/model.gguf" \
            $(curl -s "https://huggingface.co/api/models/$HF_REPO" | jq -r '.siblings[].rfilename' 2>/dev/null | grep -i 'q4_k_m' | head -1 | xargs -I{} echo "$BASE_URL/{}") >> "$LOG_FILE" 2>&1

        # Download mmproj
        MMPROJ_FILE=$(curl -s "https://huggingface.co/api/models/$HF_REPO" | jq -r '.siblings[].rfilename' 2>/dev/null | grep -i 'mmproj' | head -1)
        if [ -n "$MMPROJ_FILE" ]; then
            curl -fSL -o "$AGENT_DIR/models/mmproj.gguf" "$BASE_URL/$MMPROJ_FILE" >> "$LOG_FILE" 2>&1
            LLM_MMPROJ="$AGENT_DIR/models/mmproj.gguf"
        fi
    fi

    LLM_MODEL="$AGENT_DIR/models/model.gguf"
fi

# Fallback: text-only if nothing else worked
if [ -z "$LLM_BACKEND" ]; then
    err "Could not set up multimodal LLM. Falling back to text-only."
    MODALITIES="text"
    # Try one more time with Ollama text model
    if command -v ollama >/dev/null 2>&1; then
        LLM_BACKEND="ollama"
        LLM_MODEL="qwen2.5:0.5b"
        ollama pull "$LLM_MODEL" >> "$LOG_FILE" 2>&1
    fi
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

# --- Memory ---
mem_save() { printf '%s' "$2" > "$MEMORY_DIR/$1"; }
mem_load() { [ -f "$MEMORY_DIR/$1" ] && cat "$MEMORY_DIR/$1" || echo ""; }

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
    local backend=$(jq -r '.llm_backend // "ollama"' "$AGENT_CONFIG" 2>/dev/null)
    local model=$(jq -r '.llm_model // "qwen2.5:1.5b"' "$AGENT_CONFIG" 2>/dev/null)

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
    local backend=$(jq -r '.llm_backend // "ollama"' "$AGENT_CONFIG" 2>/dev/null)
    local model=$(jq -r '.llm_model // "qwen2.5:1.5b"' "$AGENT_CONFIG" 2>/dev/null)
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
You are an autonomous multimodal agent running locally. OS: $os. Arch: $arch.
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
- self_modify: {"file": "core/agent.sh", "content": "..."}
- done: {"summary": "..."}

Your source is at: $AGENT_DIR/core/
You may modify yourself. Be concise. One action per response.
SYSPROMPT
}

# --- Main loop ---
main() {
    local goal="${1:-$(mem_load current_goal)}"
    [ -z "$goal" ] && goal="Explore this system, report capabilities, and await instructions."

    log "INFO" "Agent starting. Goal: $goal"
    mem_save "current_goal" "$goal"

    local SYSTEM_PROMPT
    SYSTEM_PROMPT=$(build_system_prompt)

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
  "llm_mmproj": "$LLM_MMPROJ",
  "modalities": "$MODALITIES",
  "model_size": "$MODEL_SIZE",
  "max_iterations": 50,
  "self_modify": true,
  "version": "0.2.0"
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
say " AUTONOMOS v0.2 — Bootstrap complete"
say "=========================================="
say ""
say " Environment: $OS / $ARCH / ${RAM}MB RAM"
say " LLM backend: $LLM_BACKEND ($LLM_MODEL)"
say " Modalities:  $MODALITIES"
say " Agent dir:   $AGENT_DIR"
say ""
say " Run:  ~/agent/run \"your goal here\""
say " Logs: ~/agent/logs/"
say ""
say " Vision tools: camera, screenshot, see"
say "=========================================="
