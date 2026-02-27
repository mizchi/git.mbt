# TODO (Active Only)

最終整理日: 2026-02-27
方針: 完了ログは一旦外し、未完了タスクのみ管理する。
現バージョン: v0.24.3

## P0: Git compatibility / 計測

- [x] multi-pack-index の崩れを修正する（2026-02-27）
  - [x] t5317 filter-objects: `--filter` unsupported フラグ除去（33/33）
  - [x] t5310 pack-bitmaps: --local/--honor-pack-keep, trace2, bitmap 破損検知（233/233）
  - [x] t5332 multi-pack-reuse: trace2 data イベント, OFS_DELTA クロスパック判定（14/14）
  - [x] t5316 delta-depth: index-pack --fix-thin 許可, trace2 region イベント（5/5）
  - [x] bitmap/rev 生成検証: pack-reused カウント修正（単一パック bitmap フォールバック）
  - [x] `rev-list --test-bitmap`: 単一パック bitmap フォールバック追加（2026-02-27）
  - [x] incremental layer/relink（2026-02-27）
- [x] allowlist/full の全流し再計測を実施する（2026-02-27, CI 5 shard 全通過）
- [x] SHIM_STRICT=1 known breakage 6→0 修正（2026-02-27）
  - [x] t5300 #40: pack-objects sort + 1 MiB packSizeLimit clamp
  - [x] t5302 #20/#23/#26: delta reuse / corruption propagation（type-only stable sort）
  - [x] t5510 #187: index-pack --fix-thin に外部ベースオブジェクト追加 + pack_path 対応
  - [x] t5510 #188: fix-thin パック再生成で REF_DELTA 解消
  - [x] lib-bitmap `setup midx with base from later pack` (2 tests) — size descending ソート追加で修正（2026-02-27）

## P1: Relay / P2P collaboration

- [x] `bit hub serve` コマンドと relay session clone サポート（2026-02-21）
- [x] P2P collaboration: bidirectional git, broadcast, work-item sync（2026-02-21）
- [x] relay invite URL with room token（2026-02-21）
- [x] signed relay publish headers（2026-02-21）
- [x] proxied relay URL 検出修正（2026-02-24, PR #16）
- [x] `bit relay serve` を JS target で有効化（2026-02-23）
- [ ] SSH clone の JS target 対応（Issue #18）
  - native-only の制約を文書化 or HTTP smart protocol で JS 対応
  - relay 経由 clone は両 target で動作済み

## P2: パフォーマンス

- [x] `bit status` index-guided walk: 1860ms → 9ms（2026-02-23, PR #11）
- [x] lazy ObjectDb loading for log/commit（2026-02-22）
- [x] single lstat() FFI で worktree_entry_meta 置換（2026-02-22）
- [x] checkout -b same commit で tree checkout スキップ（2026-02-22）
- [x] incremental MIDX と worktree stat skip（2026-02-23）
- [ ] 大規模リポジトリでのベンチマーク継続（clone/fetch/status/log）

## P3: Git互換の残タスク

- [ ] Git 互換を一度に全件化するため、`hash-object` で確立した方針を順次展開する
  - [ ] コマンド別に「storage runtime で実装不十分になりやすい領域」を洗い出す（filter / autocrlf / gitattributes / pathspec など）
  - [ ] 各コマンドで `--random` でも壊れにくいフォールバックを設計し、`real git` と `storage runtime` の振り分け差を最小化する
  - [ ] 方針適用ごとに既存テストを回して短時間で固定し、失敗は allowlist/full で再確認する
  - [ ] フォールバックルールを横断的に共通化して、将来コマンド追加時の抜け漏れを抑制する
- [ ] `t5540-http-push-webdav.sh`（known-breakage 登録済み）
- [ ] `t9001-send-email.sh`（known-breakage 登録済み）
- [ ] `t1300-config.sh` の残 `--config-env` ケース
  - [x] shim の `resolve_real_git` shift バグ修正（2026-02-17）
- [ ] `full allowlist (just git-t-allowlist-shim-strict)` を CI で完走させる
- [ ] `--help` 移植: 外部 help テキスト実体の整備（必要コマンド分）
  - [x] spec 駆動化 / 回帰テスト / オプトイン外部読込 / shim fallback 判定（完了済み）

## P4: WASM / クロスプラットフォーム

- [x] WASM Component Model ビルド追加（2026-02-22）
- [x] clone/fetch/push ネットワークオペレーションの WASM Component 実装（2026-02-22）
- [x] cross-platform crypto パッケージ抽出（2026-02-22）
- [ ] WASM target での機能カバレッジ拡大
- [ ] JS target の SSH clone 代替（HTTP smart protocol 検討）→ Issue #18

## P5: プラットフォーム/将来タスク

- [x] `~/.config/bit/bitconfig.toml` config ファイルサポート（2026-02-23）
- [x] `bit hub` → `bit pr`/`bit issue`/`bit debug` 再編（2026-02-23）
- [x] `bit hooks` 管理と safe execution（2026-02-17）
- [x] hook approval flow: `.bit/hooks` ↔ `.git/hooks`（2026-02-17）
- [x] `bit hub issue watch` daemon with WebSocket/poll fallback（2026-02-23）
- [x] AI コマンドスイート整備（rebase-ai 連携, 2026-02-18）
- [x] `x/doc` コマンド追加（2026-02-20）
- [x] SSH clone: native interactive protocol 実装（2026-02-24, PR #17）
- [ ] Moonix integration: ToolEnvironment <-> AgentRuntime（moonix release 待ち）
- [ ] bit mount: ファイルシステムにマウントする機能
- [ ] bit mcp: MCP 対応
- [ ] BIT~ 環境変数の対応
- [ ] `.bitignore` 対応
- [ ] `.bit` 対応（`.git` → `.bit` ディレクトリ切替）
- [ ] bit jj: jj 相当の対応
