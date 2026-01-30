# moongit TODO

## テスト結果サマリー (2026-01-30)

### allowlist テスト (shim モード)
- 成功: 1284 / 1299
- 失敗: 0
- broken: 3 (GPG等の前提条件不足)

### allowlist テスト (strict モード) ✅
- 成功: 1284 / 1299
- 失敗: 0
- broken: 3

**strict モード:** `SHIM_CMDS="pack-objects index-pack upload-pack receive-pack" SHIM_STRICT=1`
moongit が処理するコマンドでフォールバックなしで全テスト通過

### 個別テスト結果

| テスト | 結果 | 備考 |
|--------|------|------|
| t0000-basic.sh | 92/92 ✅ | |
| t0001-init.sh | 98/102 ✅ | 4つはMINGW用スキップ |
| t0002-t0011 | 全通過 ✅ | |
| t0012-help.sh | 172/178 ❌ | 6件失敗 |
| t5300-pack-object.sh | 60/63 ❌ | 3件失敗 |
| t5500-fetch-pack.sh | 376/377 ❌ | 1件失敗 |
| t5504-fetch-receive-strict.sh | 29/29 ✅ | |
| t5516-fetch-push.sh | 123/123 ✅ | |
| t5702-protocol-v2.sh | 85/85 ✅ | |

---

## 修正が必要な項目

### 高優先度: `-h` オプション対応

moongit の `receive-pack` と `upload-pack` で `-h` オプションが正しく処理されていない。

**失敗テスト:** t0012-help.sh
- `not ok 131 - receive-pack can handle -h`
- `not ok 170 - upload-pack can handle -h`

**期待動作:**
- `-h` で usage メッセージを stderr に出力
- exit code 129 を返す

**修正箇所:**
- `src/cmd/moongit/handlers_remote.mbt`: `handle_receive_pack`, `handle_upload_pack`

---

### 中優先度: index-pack SHA1 collision detection

**失敗テスト:** t5300-pack-object.sh
- `not ok 53 - make sure index-pack detects the SHA1 collision`

**原因:**
moongit の index-pack が SHA1 collision を検出していない

**修正箇所:**
- `src/lib/pack_index.mbt` または関連ファイル

---

### 中優先度: index-pack outside sha256 repository

**失敗テスト:** t5300-pack-object.sh
- `not ok 59 - index-pack outside of a sha256 repository`

**原因:**
sha256 フォーマットの pack ファイルを repository 外で処理できない

---

### 低優先度: fetch deepen-since with commit-graph

**失敗テスト:** t5500-fetch-pack.sh
- 1件失敗 (deepen-since + commit-graph 関連)

---

### 低優先度: git help -c 関連

**失敗テスト:** t0012-help.sh
- `not ok 8 - invalid usage of '-c' with [-i|-m|-w]`
- `not ok 25 - git help -c`
- `not ok 26 - git help --config-for-completion`
- `not ok 27 - git help --config-sections-for-completion`

**備考:** これは git-shim がパススルーしているはずなので、git 本体の問題の可能性あり

---

### 参考: git stripspace -c の問題

**失敗テスト:** t0030-stripspace.sh (8件)

**備考:** moongit とは無関係。git 本体の stripspace -c オプションの問題

---

## 次のステップ

1. [ ] `receive-pack -h` と `upload-pack -h` の実装
2. [ ] strict モードでの allowlist テスト実行
3. [ ] SHA1 collision detection の実装
4. [ ] sha256 pack 対応の確認
