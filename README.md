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

## Model Selection (automatic)

| RAM | Model | Size |
|-----|-------|------|
| <4GB | qwen2.5:0.5b | ~400MB |
| 4-8GB | qwen2.5:1.5b | ~1GB |
| 8-16GB | qwen2.5:3b | ~2GB |
| 16GB+ | qwen2.5:7b | ~4.5GB |

## Agent Capabilities

The agent can:
- Execute shell commands
- Read/write files
- List directories
- Modify its own source code
- Persist memory across runs
- Install new tools and packages via shell

## License

MIT
