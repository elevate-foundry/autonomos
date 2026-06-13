# AUTONOMOS

A self-bootstrapping autonomous agent. Zero assumptions. One command.

## Bootstrap

```sh
curl -fsSL https://raw.githubusercontent.com/elevate-foundry/autonomos/main/bootstrap.sh | sh
```

That's it. The script will:
1. Detect your OS, architecture, RAM, and package manager
2. Install only what's missing (curl, git, jq)
3. Install or build a local LLM (Ollama preferred, llama.cpp fallback)
4. Select a model size appropriate for your device's RAM
5. Write a self-modifying agent loop in pure POSIX shell
6. Create a launcher at `~/agent/run`

## Usage

```sh
~/agent/run "your goal here"
```

## Design Principles

- **Zero assumptions** — no hardcoded paths, languages, or package names
- **Environment discovery** — detects OS, arch, RAM, shell, package manager at runtime
- **Pure shell core** — the agent loop requires only `sh`, `curl`, and `jq`
- **Self-modifying** — the agent can rewrite its own source via the `self_modify` tool
- **Offline-first** — everything runs locally, no cloud dependency
- **Adaptive model selection** — picks model size based on available RAM

## Supported Environments

| Platform | Package Manager | Status |
|----------|----------------|--------|
| Termux (Android) | pkg | ✓ |
| Ubuntu/Debian | apt | ✓ |
| Fedora/RHEL | dnf | ✓ |
| Arch Linux | pacman | ✓ |
| macOS | brew | ✓ |
| Alpine | apk | ✓ |
| WSL | apt/varies | ✓ |

## Architecture

```
~/agent/
├── run              # Launcher (entry point)
├── config.json      # Runtime config (backend, model, settings)
├── env.json         # Discovered environment snapshot
├── core/
│   └── agent.sh    # Agent loop (self-modifiable)
├── tools/           # Agent-created tool scripts
├── memory/          # Persistent key-value store (plain files)
├── models/          # Local GGUF models (llama.cpp path)
├── logs/            # Daily log files
└── tmp/             # Scratch space
```

## Model Selection (automatic, multimodal-first)

| RAM | Model | Modalities | Size |
|-----|-------|-----------|------|
| <2GB | qwen2.5:0.5b | text | ~400MB |
| 2-4GB | SmolVLM 500M | vision, text | ~350MB |
| 4-6GB | SmolVLM2 2.2B | vision, text | ~1.5GB |
| 6-8GB | Gemma 4 E4B | vision, audio, text | ~3GB |
| 8-16GB | Qwen2.5-VL 3B | vision, text | ~2GB |
| 16GB+ | Qwen2.5-VL 7B | vision, text | ~4.5GB |

All models except the text-only fallback support **native vision** — the agent can see.

## Agent Capabilities

The agent can:
- **See** — analyze images via the local multimodal model
- **Camera** — capture photos (Termux camera API / imagesnap / ffmpeg)
- **Screenshot** — capture screen contents
- Execute shell commands
- Read/write files
- List directories
- Modify its own source code
- Persist memory across runs
- Install new tools and packages via shell

## Vision Tools

```sh
# The agent can use these autonomously:
~/agent/run "take a photo and describe what you see"
~/agent/run "screenshot my desktop and tell me what apps are open"
~/agent/run "look at ~/photos/receipt.jpg and extract the total"
```

## License

MIT
