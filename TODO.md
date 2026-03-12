# TODO (Active Only)

最終整理日: 2026-03-09
方針: 完了ログは一旦外し、未完了タスクのみ管理する。
現バージョン: v0.28.0
allowlist: 906 テスト（重複除去済み）
CI 失敗: **101/906** (2026-03-09, commit b3f62de)

## P0: Git compatibility — CI 失敗削減 (101 tests)

### Easy Wins (1 failure, 高ROI — 計18テスト)

| テスト | 失敗数 | 内容 |
|--------|--------|------|
| t0002-gitfile.sh | 2/14 | gitfile リンク |
| t0004-unwritable.sh | 1/9 | 書込不可ディレクトリ |
| t0090-cache-tree.sh | 1/22 | cache-tree 検証 |
| t1091-sparse-checkout-builtin.sh | 1/74 | sparse-checkout |
| t1601-index-bogus.sh | 1/4 | bogus index |
| t1700-split-index.sh | 1/29 | split index |
| t3404-rebase-interactive.sh | 1/132 | rebase -i |
| t3408-rebase-multi-line.sh | 1/2 | rebase multi-line |
| t4010-diff-pathspec.sh | 1/17 | diff pathspec |
| t5318-commit-graph.sh | 1/109 | commit-graph |
| t5404-tracking-branches.sh | 1/7 | tracking branches |
| t5537-fetch-shallow.sh | 1/16 | fetch shallow |
| t6020-bundle-misc.sh | 1/37 | bundle |
| t6060-merge-index.sh | 1/7 | merge-index |
| t6120-describe.sh | 1/103 | describe |
| t6404-recursive-merge.sh | 1/6 | recursive merge |
| t6426-merge-skip-unneeded-updates.sh | 1/13 | merge skip updates |
| t6700-tree-depth.sh | 1/10 | tree depth |
| t7003-filter-branch.sh | 1/48 | filter-branch |
| t8008-blame-formats.sh | 1/5 | blame format |
| t9305-fast-import-signatures.sh | 1/15 | fast-import signatures |
| t9903-bash-prompt.sh | 1/67 | bash prompt |

### Small (2-4 failures — 計21テスト)

| テスト | 失敗数 | 内容 |
|--------|--------|------|
| t0033-safe-directory.sh | 3/22 | safe.directory 設定 |
| t0041-usage.sh | 3/16 | usage メッセージ |
| t0601-reffiles-pack-refs.sh | 3/47 | pack-refs |
| t1463-refs-optimize.sh | 3/47 | refs optimize |
| t1500-rev-parse.sh | 4/81 | `--path-format`, `--show-ref-format` |
| t1504-ceiling-dirs.sh | 2/44 | ceiling dirs |
| t2070-restore.sh | 4/15 | restore |
| t2400-worktree-add.sh | 1/232 | worktree add |
| t2402-worktree-list.sh | 5/27 | worktree list |
| t2404-worktree-config.sh | 2/12 | worktree config |
| t3207-branch-submodule.sh | 4/20 | branch submodule |
| t3430-rebase-merges.sh | 2/34 | rebase merges |
| t3600-rm.sh | 2/81 | rm |
| t3705-add-sparse-checkout.sh | 2/20 | add sparse checkout |
| t3902-quoted.sh | 2/13 | quoted paths |
| t3905-stash-include-untracked.sh | 2/34 | stash --include-untracked |
| t4203-mailmap.sh | 4/74 | mailmap |
| t5306-pack-nobase.sh | 2/4 | pack no-base |
| t5313-pack-bounds-checks.sh | 2/9 | pack bounds |
| t5334-incremental-multi-pack-index.sh | 2/16 | incremental MIDX |
| t5510-fetch.sh | 4/215 | atomic fetch, branch merge config |
| t6030-bisect-porcelain.sh | 4/96 | bisect porcelain |
| t6601-path-walk.sh | 2/15 | path-walk |
| t7424-submodule-mixed-ref-formats.sh | 2/7 | submodule ref formats |
| t9350-fast-export.sh | 2/73 | fast-export |
| t9502-gitweb-standalone-parse-output.sh | 2/20 | gitweb parse |

### Medium (5-10 failures — 計11テスト)

| テスト | 失敗数 | 内容 |
|--------|--------|------|
| t0001-init.sh | 6/101 | init |
| t0021-conversion.sh | 7/42 | filter=clean/smudge |
| t0028-working-tree-encoding.sh | 4/22 | working-tree-encoding |
| t1415-worktree-refs.sh | 5/10 | worktree refs |
| t1450-fsck.sh | 8/95 | fsck validation |
| t5505-remote.sh | 1/129 | remote |
| t5615-alternate-env.sh | 7/9 | GIT_ALTERNATE_OBJECT_DIRECTORIES |
| t5801-remote-helpers.sh | 6/34 | remote helpers |
| t6050-replace.sh | 9/37 | replace refs |
| t6300-for-each-ref.sh | 11/428 | signatures, signed tag body |
| t6600-test-reach.sh | 10/45 | commit-graph reachability |
| t7700-repack.sh | 5/47 | alternate ODB, `--filter-to` |
| t7817-grep-sparse-checkout.sh | 4/8 | grep sparse |
| t8008-blame-formats.sh | 1/5 | blame formats |
| t9902-completion.sh | 8/263 | shell completion |

### Large (10+ failures — 計12テスト)

| テスト | 失敗数 | 内容 |
|--------|--------|------|
| t0035-safe-bare-repository.sh | 10/12 | safe.bareRepository 設定 |
| t0060-path-utils.sh | 24/219 | パスユーティリティ |
| t1006-cat-file.sh | 31/420 | commit size/content, `--batch` |
| t1007-hash-object.sh | 17/40 | `--stdin`, `--path`, `--no-filters` |
| t1092-sparse-checkout-compatibility.sh | 14/102 | sparse checkout |
| t1451-fsck-buffer.sh | 62/72 | truncated commit fsck |
| t1460-refs-migrate.sh | 25/37 | reftable migration |
| t1501-work-tree.sh | 15/39 | work-tree 設定 |
| t1506-rev-parse-diagnosis.sh | 22/30 | pathspec/revision 曖昧性解消 |
| t1512-rev-parse-disambiguation.sh | 22/35 | ambiguous object resolution |
| t1517-outside-repo.sh | 8/293 | outside repo `-h` output |
| t3800-mktag.sh | 23/151 | mktag validation |
| t3903-stash.sh | 13/140 | stash |
| t5323-pack-redundant.sh | 14/18 | pack-redundant |
| t6416-recursive-corner-cases.sh | 13/37 | criss-cross merge |
| t6422-merge-rename-corner-cases.sh | 14/19 | rename/add conflict |
| t6423-merge-rename-directories.sh | 17/80 | directory rename |
| t6424-merge-unrelated-index-changes.sh | 11/19 | index preservation |
| t7002-mv-sparse-checkout.sh | 14/22 | mv sparse checkout |
| t7400-submodule-basic.sh | 8/124 | submodule basic |

### 横断カテゴリ別サマリ

| カテゴリ | テスト数 | 合計失敗数 | 主要テスト |
|----------|----------|------------|------------|
| **Merge engine** | 5 | 56 | t6416, t6422, t6423, t6424, t6426 |
| **rev-parse** | 3 | 48 | t1506(22), t1512(22), t1500(4) |
| **Sparse/Index** | 5 | 44 | t1092(14), t7002(14), t3903(13), t1091(1), t3705(2) |
| **Reftable/Refs** | 3 | 42 | t1460(25), t0610(14), t1463(3) |
| **Object/Hash** | 3 | 110 | t1451(62), t1006(31), t1007(17) |
| **Worktree** | 4 | 13 | t2402(5), t1415(5), t2404(2), t2400(1) |
| **Submodule** | 3 | 14 | t7400(8), t3207(4), t7424(2) |
| **Pack/MIDX** | 5 | 24 | t5323(14), t5319(4), t5334(2), t5306(2), t5313(2) |

### スコープ外

- **t1016-compatObjectFormat.sh** (181/202) — SHA-256 compat
- **t9700-perl-git.sh** (1/3) — Perl Git.pm
- **t7510-signed-commit.sh** (1/28) — GPG 署名検証
- **t7528-signed-commit-ssh.sh** (1/26) — SSH 署名検証
- **t0610-reftable-basics.sh** (14/91) — reftable format
- **t1460-refs-migrate.sh** (25/37) — reftable migration

完了済みタスクは [docs/DONE.md](docs/DONE.md) を参照。

## P1: Relay / P2P collaboration

- [ ] SSH clone の JS target 対応（Issue #18）
  - [ ] HTTP smart protocol で JS 対応

## P2: パフォーマンス

- [ ] 大規模リポジトリでのベンチマーク継続（clone/fetch/status/log）

### pack-objects 高速化 (10-20x 遅い → 目標 2x 以内)

ベースライン (2026-03-04): E2E で 500obj bit=1970ms vs git=101ms (19.5x)
ボトルネック: zlib (55%) + MoonBit ランタイム起動 (~150ms)

- [ ] **RefDelta base SHA-1 キャッシュ** (低優先)
- [ ] **オブジェクトのソート (type + size desc)** — デルタ効率向上
- [ ] **スライディングウィンドウ (--window)** — 直近N個を候補に
- [ ] **build_delta のブロックインデックス再利用**
- [ ] **find_best_match の候補数制限緩和** (64 → 128-256)

## P3: Git互換の残タスク

### allowlist 残り

- t0: t0012, t0450（`-h` テスト、shim コマンドの出力不一致）
- t4: t4137（apply submodule、4/28 failures）
- t7: t7450（test-tool submodule 依存）
- t9: svn/cvs/p4 は明示的にサポート外

### その他

- [ ] `--help` 移植: 外部 help テキスト実体の整備（必要コマンド分）

## P3.5: realgit 委譲の削減

方針: CI SHIM_STRICT=1 で bit に通すコマンドを段階的に増やす。
CI SHIM_CMDS: 54 コマンド (init add diff diff-files diff-index ls-files tag branch checkout switch commit log show reflog reset update-ref update-index status merge rebase clone push fetch pull mv notes stash rm submodule worktree config show-ref for-each-ref rev-parse symbolic-ref cherry-pick remote cat-file hash-object ls-tree write-tree commit-tree receive-pack upload-pack pack-objects index-pack format-patch describe gc clean sparse-checkout restore blame grep shell)

### Tier 1: 超高頻度（1000+ 呼出）
- [x] `checkout` (3765)
- [x] `commit` (3596)
- [x] `add` (3268)
- [x] `reset` (1923)
- [x] `branch` (1749)
- [x] `init` (1667)
- [x] `tag` (1199)
- [x] `diff` (1196)
- [x] `log` (1173)
- [x] `ls-files` (1162)

### Tier 2: 高頻度（400–999 呼出）
- [x] `rebase` (991)
- [x] `clone` (953)
- [x] `merge` (889)
- [x] `update-ref` (824)
- [x] `update-index` (720)
- [x] `status` (608)
- [x] `push` (534)
- [x] `notes` (600)
- [x] `submodule` (603)
- [x] `fetch` (461)
- [x] `mv` (488)
- [x] `stash` (472)
- [x] `rm` (470)
- [x] `worktree` (421)
- [ ] `bisect` (420)

### Tier 3-4: 中低頻度
- [x] `show` (362)
- [x] `symbolic-ref` (335)
- [x] `cherry-pick` (324)
- [x] `switch` (251)
- [x] `remote` (298)
- [x] `grep` (312)
  - [x] big grep ベンチマークを取得
    - worktree medium literal: `95.54 ms ± 13.86 ms`
    - worktree large literal: `452.19 ms ± 66.31 ms`
    - cached large literal: `1.28 s ± 202.85 ms`
    - head large literal: `1.24 s ± 193.86 ms`
  - [x] `t7817-grep-sparse-checkout.sh` (`8/8`)
- [x] `format-patch` (300)
- [x] `reflog` (296)
- [x] `diff-index` (219), `diff-files` (170)
- [x] `pull` (250)
- [x] `clean` (232)
- [x] `sparse-checkout` (113)
- [x] `restore` (117)
- [x] `blame` (110)
- [x] `gc` (81)
- [x] `describe` (53)

### 未実装コマンド（新規実装候補）
- [ ] `rev-list` (521), `apply` (398), `repack` (302)
- [ ] `am` (235), `diff-tree` (224), `fast-import` (196), `read-tree` (176)
- [ ] `fsck` (159), `commit-graph` (137), `multi-pack-index` (133)
- [ ] `ls-remote` (127), `bundle` (110), `stripspace` (108)

## P4: WASM / クロスプラットフォーム

- [ ] WASM target での機能カバレッジ拡大
- [ ] JS target の SSH clone 代替（HTTP smart protocol 検討）→ Issue #18

## P5: プラットフォーム/将来タスク

- [ ] Moonix integration: ToolEnvironment <-> AgentRuntime（moonix release 待ち）
- [ ] bit mount: ファイルシステムにマウントする機能
- [ ] bit mcp: MCP 対応
- [ ] BIT~ 環境変数の対応
- [ ] `.bitignore` 対応
- [ ] `.bit` 対応（`.git` → `.bit` ディレクトリ切替）
- [ ] bit jj: jj 相当の対応
