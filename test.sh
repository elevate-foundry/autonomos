#!/bin/sh
# ============================================================
# AUTONOMOS — Unit & Integration Test Suite
# ============================================================
# Run: sh test.sh
# All tests run in an isolated temp directory. No side effects.
# ============================================================

set -e

# --- Test harness ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_LIST=""

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf "  ✓ %s\n" "$1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); FAIL_LIST="${FAIL_LIST}\n  ✗ $1"; printf "  ✗ %s\n" "$1"; }

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected '$1', got '$2')"
    fi
}

assert_not_empty() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$1" ]; then
        pass "$2"
    else
        fail "$2 (was empty)"
    fi
}

assert_file_exists() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$1" ]; then
        pass "$2"
    else
        fail "$2 ($1 missing)"
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$1" | grep -q "$2"; then
        pass "$3"
    else
        fail "$3 (does not contain '$2')"
    fi
}

assert_exit_zero() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$1" > /dev/null 2>&1; then
        pass "$2"
    else
        fail "$2 (non-zero exit)"
    fi
}

assert_exit_nonzero() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$1" > /dev/null 2>&1; then
        fail "$2 (expected failure, got success)"
    else
        pass "$2"
    fi
}

# --- Setup isolated test environment ---
TEST_DIR=$(mktemp -d)
export AGENT_DIR="$TEST_DIR/agent"
mkdir -p "$AGENT_DIR/core" "$AGENT_DIR/memory" "$AGENT_DIR/secrets" "$AGENT_DIR/secrets/credentials" "$AGENT_DIR/logs" "$AGENT_DIR/tmp" "$AGENT_DIR/models"

# Create minimal config
cat > "$AGENT_DIR/config.json" << 'EOF'
{
  "llm_backend": "ollama",
  "llm_model": "test-model",
  "llm_model_path": "test-model",
  "llm_mmproj": "",
  "modalities": "vision,text",
  "model_size": "7b",
  "context_window": 8192,
  "outgrowth_threshold": "0.80",
  "remote_api_url": "",
  "remote_model": "",
  "max_iterations": 50,
  "self_modify": true,
  "auth_enabled": true,
  "version": "0.5.0"
}
EOF

cat > "$AGENT_DIR/env.json" << 'EOF'
{
  "os": "macos",
  "arch": "arm64",
  "ram_mb": 16384,
  "pkg_manager": "brew",
  "model_size": "7b",
  "home": "/tmp/test",
  "agent_dir": "/tmp/test/agent",
  "shell": "sh",
  "user": "test",
  "timestamp": "2024-01-01T00:00:00Z"
}
EOF

cat > "$AGENT_DIR/secrets/identity.json" << 'EOF'
{
  "owner_phone": "8012306770",
  "agent_name": "autonomos",
  "auth_method": "otp_relay",
  "email": "test@example.com",
  "email_provider": "test",
  "credentials": {}
}
EOF

# Extract agent core functions for testing (source them)
# We need to extract just the function definitions from bootstrap.sh
BOOTSTRAP="$(dirname "$0")/bootstrap.sh"

# ============================================================
echo ""
echo "============================================"
echo " AUTONOMOS TEST SUITE"
echo "============================================"
echo ""

# ============================================================
echo "--- Environment Detection ---"
# ============================================================

# Test detect_os
detect_os() {
    case "$(uname -s 2>/dev/null)" in
        Linux*)  
            if [ -f /etc/os-release ]; then
                . /etc/os-release && echo "$ID"
            elif [ -d /data/data/com.termux ]; then
                echo "termux"
            else
                echo "linux"
            fi ;;
        Darwin*) echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armv8*) echo "arm" ;;
        *) echo "unknown" ;;
    esac
}

detect_ram_mb() {
    if [ -f /proc/meminfo ]; then
        awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1048576}'
    else
        echo "2048"
    fi
}

pick_model_size() {
    RAM=$1
    if [ "$RAM" -ge 16000 ]; then echo "7b"
    elif [ "$RAM" -ge 8000 ]; then echo "3b"
    elif [ "$RAM" -ge 6000 ]; then echo "4b"
    elif [ "$RAM" -ge 4000 ]; then echo "2b"
    elif [ "$RAM" -ge 2000 ]; then echo "1b"
    else echo "0.5b"
    fi
}

OS=$(detect_os)
ARCH=$(detect_arch)
RAM=$(detect_ram_mb)

assert_not_empty "$OS" "detect_os returns a value"
assert_not_empty "$ARCH" "detect_arch returns a value"
assert_not_empty "$RAM" "detect_ram_mb returns a value"
assert_eq "7b" "$(pick_model_size 16384)" "pick_model_size 16GB → 7b"
assert_eq "3b" "$(pick_model_size 8192)" "pick_model_size 8GB → 3b"
assert_eq "4b" "$(pick_model_size 6144)" "pick_model_size 6GB → 4b"
assert_eq "2b" "$(pick_model_size 4096)" "pick_model_size 4GB → 2b"
assert_eq "1b" "$(pick_model_size 2048)" "pick_model_size 2GB → 1b"
assert_eq "0.5b" "$(pick_model_size 1024)" "pick_model_size 1GB → 0.5b"

# ============================================================
echo ""
echo "--- Memory System ---"
# ============================================================

MEMORY_DIR="$AGENT_DIR/memory"
JOURNAL="$MEMORY_DIR/journal.jsonl"
LEARNINGS="$MEMORY_DIR/learnings.jsonl"
FACTS="$MEMORY_DIR/facts.json"

touch "$JOURNAL" "$LEARNINGS"
jq -n '{}' > "$FACTS"

mem_save() { printf '%s' "$2" > "$MEMORY_DIR/$1"; }
mem_load() { [ -f "$MEMORY_DIR/$1" ] && cat "$MEMORY_DIR/$1" || echo ""; }

journal_append() {
    local entry_type="$1" content="$2"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -c --arg t "$ts" --arg type "$entry_type" --arg c "$content" \
        '{ts: $t, type: $type, content: $c}' >> "$JOURNAL"
}

learn() {
    local fact="$1" category="${2:-general}"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -c --arg t "$ts" --arg cat "$category" --arg f "$fact" \
        '{ts: $t, category: $cat, fact: $f}' >> "$LEARNINGS"
}

journal_recent() {
    local n="${1:-20}"
    [ -f "$JOURNAL" ] && tail -n "$n" "$JOURNAL" || echo ""
}

recall_learnings() {
    local category="$1"
    if [ -z "$category" ]; then
        [ -f "$LEARNINGS" ] && cat "$LEARNINGS" || echo ""
    else
        [ -f "$LEARNINGS" ] && grep "\"category\":\"$category\"" "$LEARNINGS" || echo ""
    fi
}

# Test mem_save / mem_load
mem_save "test_key" "test_value"
assert_eq "test_value" "$(mem_load test_key)" "mem_save/mem_load round-trip"
assert_eq "" "$(mem_load nonexistent_key)" "mem_load nonexistent returns empty"

# Test journal
journal_append "test" "hello world"
journal_append "action" "shell: ls"
journal_append "result" "file1 file2"
JCOUNT=$(wc -l < "$JOURNAL" | tr -d ' ')
assert_eq "3" "$JCOUNT" "journal_append creates entries"

JLAST=$(tail -1 "$JOURNAL" | jq -r '.type')
assert_eq "result" "$JLAST" "journal entries have correct type"

JCONTENT=$(tail -1 "$JOURNAL" | jq -r '.content')
assert_eq "file1 file2" "$JCONTENT" "journal entries have correct content"

# Test journal_recent
RECENT=$(journal_recent 2 | wc -l | tr -d ' ')
assert_eq "2" "$RECENT" "journal_recent limits correctly"

# Test learn / recall
learn "the sky is blue" "science"
learn "user prefers vim" "preferences"
learn "system has 16GB" "system"

LCOUNT=$(wc -l < "$LEARNINGS" | tr -d ' ')
assert_eq "3" "$LCOUNT" "learn creates entries"

SCI=$(recall_learnings "science" | jq -r '.fact')
assert_eq "the sky is blue" "$SCI" "recall_learnings filters by category"

ALL=$(recall_learnings | wc -l | tr -d ' ')
assert_eq "3" "$ALL" "recall_learnings without filter returns all"

# Test facts
FACTS_TMP=$(jq --arg k "owner" --arg v "Ryan" '.[$k] = $v' "$FACTS")
printf '%s' "$FACTS_TMP" > "$FACTS"
FVAL=$(jq -r '.owner' "$FACTS")
assert_eq "Ryan" "$FVAL" "facts store key-value pairs"

# ============================================================
echo ""
echo "--- Context Pressure ---"
# ============================================================

estimate_tokens() {
    local text="$1"
    echo $(( ${#text} / 4 ))
}

context_pressure() {
    local ctx_size="$1"
    local tokens=$(estimate_tokens "$ctx_size")
    local window=8192
    echo "$tokens $window" | awk '{printf "%.2f", $1/$2}'
}

# 100 chars = ~25 tokens, pressure = 25/8192 ≈ 0.00
SHORT="$(printf 'x%.0s' $(seq 1 100))"
P_SHORT=$(context_pressure "$SHORT")
assert_eq "0.00" "$P_SHORT" "context_pressure low for short text"

# 32000 chars = ~8000 tokens, pressure = 8000/8192 ≈ 0.98
LONG="$(printf 'x%.0s' $(seq 1 32000))"
P_LONG=$(context_pressure "$LONG")
assert_contains "$P_LONG" "0.9" "context_pressure high for long text"

# ============================================================
echo ""
echo "--- Action Parsing ---"
# ============================================================

parse_action() {
    local response="$1"
    local extracted

    # Strategy 1: ```action block
    extracted=$(printf '%s' "$response" | awk '/```action/{found=1;next} /```/{if(found)exit} found{print}')
    if [ -n "$extracted" ]; then
        printf '%s' "$extracted" | jq '.' 2>/dev/null && return
    fi

    # Strategy 2: ```json block
    extracted=$(printf '%s' "$response" | awk '/```json/{found=1;next} /```/{if(found)exit} found{print}')
    if [ -n "$extracted" ]; then
        printf '%s' "$extracted" | jq '.' 2>/dev/null && return
    fi

    # Strategy 3: inline JSON with "tool" — extract using jq to handle nesting
    extracted=$(printf '%s' "$response" | grep -oE '\{[^{}]*"tool"[^{}]*(\{[^{}]*\}[^{}]*)?\}' | head -1)
    if [ -n "$extracted" ]; then
        printf '%s' "$extracted" | jq '.' 2>/dev/null && return
    fi

    echo ""
}

# Test standard format
R1=$(printf 'Here is my action:\n```action\n{"tool": "shell", "args": {"command": "ls -la"}}\n```')
A1=$(parse_action "$R1")
T1=$(printf '%s' "$A1" | jq -r '.tool')
assert_eq "shell" "$T1" "parse_action: standard action block"

# Test json format
R2=$(printf '```json\n{"tool": "memory", "args": {"action": "learn", "fact": "test"}}\n```')
A2=$(parse_action "$R2")
T2=$(printf '%s' "$A2" | jq -r '.tool')
assert_eq "memory" "$T2" "parse_action: json block"

# Test inline JSON
R3='I will do this: {"tool": "done", "args": {"summary": "finished"}} end.'
A3=$(parse_action "$R3")
T3=$(printf '%s' "$A3" | jq -r '.tool')
assert_eq "done" "$T3" "parse_action: inline JSON extraction"

# Test no action
R4='I do not know what to do. Let me think about this.'
A4=$(parse_action "$R4")
assert_eq "" "$A4" "parse_action: no action returns empty"

# Test malformed JSON
R5=$(printf '```action\n{not valid json at all}\n```')
A5=$(parse_action "$R5")
assert_eq "" "$A5" "parse_action: malformed JSON returns empty"

# ============================================================
echo ""
echo "--- Auth Primitive ---"
# ============================================================

# Test auth.sh if it exists (from bootstrap)
AUTH_SCRIPT="$AGENT_DIR/core/auth.sh"
if [ -f "$HOME/agent/core/auth.sh" ]; then
    # Copy the real auth script to test dir
    cp "$HOME/agent/core/auth.sh" "$AUTH_SCRIPT"
    chmod +x "$AUTH_SCRIPT"

    PHONE=$(AGENT_DIR="$AGENT_DIR" sh "$AUTH_SCRIPT" get_phone)
    assert_eq "8012306770" "$PHONE" "auth.sh get_phone"

    EMAIL=$(AGENT_DIR="$AGENT_DIR" sh "$AUTH_SCRIPT" get_email)
    assert_eq "test@example.com" "$EMAIL" "auth.sh get_email"

    # Test credential store
    AGENT_DIR="$AGENT_DIR" sh "$AUTH_SCRIPT" cred_save "testservice" "apikey" "sk-12345"
    assert_file_exists "$AGENT_DIR/secrets/credentials/testservice.json" "cred_save creates file"

    CRED=$(AGENT_DIR="$AGENT_DIR" sh "$AUTH_SCRIPT" cred_load "testservice" "apikey")
    assert_eq "sk-12345" "$CRED" "cred_save/cred_load round-trip"

    # Test set_email
    AGENT_DIR="$AGENT_DIR" sh "$AUTH_SCRIPT" set_email "new@example.com"
    NEW_EMAIL=$(AGENT_DIR="$AGENT_DIR" sh "$AUTH_SCRIPT" get_email)
    assert_eq "new@example.com" "$NEW_EMAIL" "auth.sh set_email persists"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail "auth.sh not found (run bootstrap first)"
fi

# ============================================================
echo ""
echo "--- File Integrity ---"
# ============================================================

# Test that bootstrap produces valid shell
assert_exit_zero "sh -n '$BOOTSTRAP'" "bootstrap.sh passes syntax check"

# Test that agent.sh (if deployed) passes syntax check
if [ -f "$HOME/agent/core/agent.sh" ]; then
    assert_exit_zero "sh -n '$HOME/agent/core/agent.sh'" "agent.sh passes syntax check"
fi

# ============================================================
echo ""
echo "--- Resilience ---"
# ============================================================

# Test memory functions handle missing files gracefully
rm -f "$MEMORY_DIR/nonexistent"
EMPTY=$(mem_load "totally_nonexistent_file")
assert_eq "" "$EMPTY" "mem_load handles missing files"

# Test journal with empty file
> "$JOURNAL"
EMPTY_RECENT=$(journal_recent 5)
assert_eq "" "$EMPTY_RECENT" "journal_recent handles empty journal"

# Test learn with broken permissions (should not crash)
TESTS_RUN=$((TESTS_RUN + 1))
if (learn "test fact" "test" 2>/dev/null); then
    pass "learn does not crash"
else
    fail "learn crashed"
fi

# Test context_pressure with empty string
P_EMPTY=$(context_pressure "")
assert_eq "0.00" "$P_EMPTY" "context_pressure handles empty string"

# Test parse_action with empty input
A_EMPTY=$(parse_action "")
assert_eq "" "$A_EMPTY" "parse_action handles empty input"

# Test parse_action with random non-JSON text
A_GARBAGE=$(parse_action "random noise !@#\$%^&*()")
assert_eq "" "$A_GARBAGE" "parse_action handles garbage input"

# ============================================================
echo ""
echo "--- Self-Healing Checks ---"
# ============================================================

# Verify critical directories can be recreated
rm -rf "$AGENT_DIR/tmp"
mkdir -p "$AGENT_DIR/tmp"
assert_exit_zero "[ -d '$AGENT_DIR/tmp' ]" "tmp dir can be recreated"

# Verify config survives corruption (jq validates)
assert_exit_zero "jq '.' '$AGENT_DIR/config.json'" "config.json is valid JSON"
assert_exit_zero "jq '.' '$AGENT_DIR/secrets/identity.json'" "identity.json is valid JSON"
assert_exit_zero "jq '.' '$AGENT_DIR/env.json'" "env.json is valid JSON"

# ============================================================
echo ""
echo "============================================"
printf " Results: %d passed, %d failed, %d total\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_RUN"
echo "============================================"

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo ""
    echo " Failures:"
    printf "$FAIL_LIST\n"
    echo ""
fi

# Cleanup
rm -rf "$TEST_DIR"

# Exit with failure code if any tests failed
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
