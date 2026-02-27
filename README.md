# bit

Git implementation in [MoonBit](https://docs.moonbitlang.com) with practical compatibility extensions.

> **Warning**: This is an experimental implementation. Do not use in production. Data corruption may occur in worst case scenarios. Always keep backups of important repositories.

## Install

**Supported platforms**: Linux x64, macOS arm64/x64

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/mizchi/bit-vcs/main/install.sh | bash

# Or install via MoonBit toolchain
moon install mizchi/bit/cmd/bit
```

## Shell Completion

```bash
# bash (~/.bashrc)
eval "$(bit completion bash)"

# zsh (~/.zshrc)
eval "$(bit completion zsh)"
```

## Quick Start

```bash
bit clone https://github.com/user/repo
bit checkout -b feature
bit add .
bit commit -m "changes"
bit push origin feature
```

## Bit Extension Commands Quick Guide

### bit fingerprint

`bit fingerprint` is currently a feature set (workspace/hub integration), not a standalone top-level command.

```bash
# Workspace flow uses per-node directory fingerprints
BIT_WORKSPACE_FINGERPRINT_MODE=git bit workspace flow test
BIT_WORKSPACE_FINGERPRINT_MODE=fast bit workspace flow test

# Hub workflow records can carry a workspace fingerprint
bit hub pr workflow submit 123 \
  --task test --status success \
  --fingerprint <workspace-fingerprint> \
  --txn <txn-id>
```

### bit subdir

Use `bit subdir-clone` (or clone shorthand) to work on a repository subdirectory as an independent repo.

```bash
# Explicit command
bit subdir-clone https://github.com/user/repo src/lib mylib

# Shorthand via clone
bit clone user/repo:src/lib
bit clone user/repo@main:src/lib

# GitHub tree/blob URL is also supported
bit clone https://github.com/user/repo/tree/main/packages/core
bit clone https://github.com/user/repo/blob/main/README.md
```

Cloned subdirectories have their own `.git` directory. When placed inside another git repository, git treats them as embedded repositories (similar to submodules), and the parent repo does not commit their contents.

### bit hub

Git-native PR/Issue workflow stored in repository data.

```bash
bit hub init

# PR / Issue
bit hub pr list --open
bit hub issue list --open

# Sync metadata
bit hub sync push
bit hub sync fetch

# Search
bit hub search "cache" --type pr --state open

# Shortcuts
bit pr list --open
bit issue list --open
```

### bit ai

AI-assisted rebase conflict resolution (OpenRouter, default model `moonshotai/kimi-k2`).
Subcommands:
  - `rebase` (alias: `rebase-ai`)
  - `merge`
  - `commit`
  - `cherry-pick`
  - `revert`

```bash
export OPENROUTER_API_KEY=...

# Start / continue / abort / skip
bit ai rebase main
bit ai rebase --continue
bit ai rebase --abort
bit ai rebase --skip
bit ai merge --continue
bit ai merge --abort

# Options
bit ai rebase --model moonshotai/kimi-k2 --max-ai-rounds 16 main
bit ai rebase --agent-loop --agent-max-steps 24 main
bit ai merge --agent-loop --agent-max-steps 24 branch
bit ai commit --split
bit ai commit
bit ai cherry-pick abc1234
bit ai revert abc1234

# Alias (legacy)
bit rebase-ai main
```

### bit ai commit

Experimental AI-assisted commit message helper entrypoint (currently delegates to `bit commit` for compatibility).
`bit ai commit` は `rebase` と同じ AI 設定引数を受け付けます（`--model`, `--max-ai-rounds`, `--agent-loop`, `--agent-max-steps`）。

```bash
bit ai commit -m "message..."
bit ai commit
```

### bit mcp

Start the MCP server via `bit mcp` (native target).

```bash
# Start MCP server (stdio)
bit mcp

# Help
bit mcp --help
bit help mcp

# Standalone MoonBit entrypoint (equivalent server implementation)
moon run src/x/mcp --target native
```

### bit hq

`ghq`-compatible repository manager (default root: `~/bhq`).

```bash
bit hq get mizchi/git
bit hq get -u mizchi/git
bit hq get --shallow mizchi/git
bit hq list
bit hq list mizchi
bit hq root
```

## Agent Storage Runtime

`bit` core operations can run against any storage backend that implements:

- `@bit.FileSystem` (write side)
- `@bit.RepoFileSystem` (read side)

Entry point:

- `/Users/mz/ghq/github.com/mizchi/bit/src/cmd/bit/storage_runtime.mbt`
- `run_storage_command(fs, rfs, root, cmd, args)`

One in-memory implementation is `@bit.TestFs`, which can be used as agent storage:

```moonbit
let fs = @bit.TestFs::new()
let root = "/agent-repo"
run_storage_command(fs, fs, root, "init", ["-q"])
fs.write_string(root + "/note.txt", "hello")
run_storage_command(fs, fs, root, "add", ["note.txt"])
run_storage_command(fs, fs, root, "commit", ["-m", "agent snapshot"])
```

## Compatibility

- Git config: reads global aliases from `~/.gitconfig` (or `GIT_CONFIG_GLOBAL`) only.
- Generic `filter=` attributes (clean/smudge) are handled natively.
- Detailed standalone scope, unsupported paths, fallback points, and git/t coverage are documented in [`docs/git-compatibility.md`](docs/git-compatibility.md).

### Explicitly Unsupported Features

The following features are **not supported** and will produce a fatal error:

**Repository formats**
- SHA-256 repositories (`--object-format=sha256`)
- Reftable ref format (`--ref-format=reftable`)
- Incremental multi-pack-index chains

**Gitattributes**
- `filter=lfs` (Git LFS)
- `working-tree-encoding=`

**Commit & rebase**
- Signed commits (`-S`, `--gpg-sign`)
- Interactive rebase (`-i`, `--interactive`)

**Clone**
- Recursive clone (`--recursive`, submodule auto-init)

**Network**
- SSH URLs (`git@...`) in `bit cat` / `bit tree` commands

**Shell**
- Shell aliases (prefixed with `!`)

## Environment Variables

- `BIT_BENCH_GIT_DIR`: override .git path for bench_real (x/fs benchmarks).
- `BIT_PACK_CACHE_LIMIT`: max number of pack files to keep in memory (default: 2; 0 disables cache).
- `BIT_RACY_GIT`: when set, rehash even if stat matches to avoid racy-git false negatives.
- `BIT_WORKSPACE_FINGERPRINT_MODE`: workspace fingerprint mode (`git` default, `fast` optional). `git` mode follows add-all-style Git-compatible directory snapshots for flow cache decisions.

## Library Extensions

### Fs - Virtual Filesystem

Mount any commit as a filesystem with lazy blob loading:

```moonbit
let fs = Fs::from_commit(fs, ".git", commit_id)
let files = fs.readdir(fs, "src")
let content = fs.read_file(fs, "src/main.mbt")
```

### Kv - Distributed KV Store

Git-backed key-value store with Gossip protocol sync:

```moonbit
let db = Kv::init(fs, fs, git_dir, node_id)
db.set(fs, fs, "users/alice/profile", value, ts)
db.sync_with_peer(fs, fs, peer_url)
```

### Hub - Git-Native Huboration

Pull Requests and Issues stored as Git objects:

```moonbit
let hub = Hub::init(fs, fs, git_dir)
let pr = hub.create_pr(fs, fs, "Fix bug", "...",
  source_branch, target_branch, author, ts)
```

## License

Apache-2.0
