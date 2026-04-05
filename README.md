# Multi-AI Platform (MAP)

Cross-client LLM session sharing and persistent memory system.

Any LLM (Claude, Gemini, Codex) across any interface shares sessions and knowledge through simple markdown files.

## Quick Start

```bash
# Install (coming soon)
brew tap CYRok90/multi-ai-platform
brew install multi-ai-platform

# Initialize a workspace
map init ~/my-project

# Start a tracked LLM session
map start claude "building feature X"

# Check active sessions and wiki
map status

# Re-sync protocol to config files
map sync
```

## What it creates

```
your-project/
├── CLAUDE.md        # Protocol injected
├── GEMINI.md        # Protocol injected
├── AGENTS.md        # Protocol injected
├── SESSIONS.md      # Active session registry (gitignored)
└── wiki/            # Persistent knowledge base
    ├── Index.md     # Topic catalog
    ├── Log.md       # Chronological change log
    └── topics/      # Individual knowledge pages
```

## How it works

### Session Layer (SESSIONS.md)
- Session start: register yourself, see what other sessions are doing
- Session end: unregister (or `map start` wrapper handles it via trap)
- Stale entries (>2h) are auto-cleaned by the next session

### Memory Layer (wiki/)
- Karpathy-style LLM-maintained wiki ([reference](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f))
- LLMs discover knowledge during work and write it to topic pages
- Index.md is the only mandatory read on session start (token-efficient)
- Topics are loaded selectively, not all at once

### Protocol
The same protocol is injected into CLAUDE.md, GEMINI.md, and AGENTS.md.
Every LLM follows identical rules regardless of which client is used.

## Commands

| Command | Description |
|---------|-------------|
| `map init [path]` | Initialize workspace with sessions + wiki |
| `map start <claude\|gemini\|codex> [task]` | Start tracked session |
| `map status` | Show active sessions and wiki stats |
| `map sync` | Re-inject protocol into config files |

## Design Principles

- **File-based**: No database, no server, no infrastructure
- **Flat structure**: Everything at project root, no nested config paths
- **Optimistic concurrency**: Single user, low contention, append-preferred
- **Graceful degradation**: If an LLM ignores the protocol, nothing breaks
- **Token-efficient**: Read Index.md (~750 tokens), load only relevant topics

## License

MIT
