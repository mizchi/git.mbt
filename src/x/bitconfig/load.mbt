///|
/// ~/.config/bit/bitconfig.toml のパスを解決
fn config_path() -> String? {
  match @sys.get_env_var("HOME") {
    Some(home) => Some(home + "/.config/bit/bitconfig.toml")
    None => None
  }
}

///|
/// TOML テーブルから文字列値を取得
fn get_string(table : Map[String, @toml.TomlValue], key : String) -> String? {
  guard table.get(key) is Some(@toml.TomlValue::TomlString(v)) else {
    return None
  }
  Some(v)
}

///|
/// TOML テーブルから bool 値を取得し文字列に変換
fn get_bool_string(
  table : Map[String, @toml.TomlValue],
  key : String,
) -> String? {
  guard table.get(key) is Some(@toml.TomlValue::TomlBoolean(v)) else {
    return None
  }
  Some(if v { "true" } else { "false" })
}

///|
/// TOML テーブルからサブテーブルを取得
fn get_table(
  table : Map[String, @toml.TomlValue],
  key : String,
) -> Map[String, @toml.TomlValue]? {
  guard table.get(key) is Some(@toml.TomlValue::TomlTable(t)) else {
    return None
  }
  Some(t)
}

///|
/// 環境変数が未設定の場合のみ値を注入
fn inject_if_unset(env_key : String, value : String) -> Unit {
  match @sys.get_env_var(env_key) {
    Some(existing) if existing.length() > 0 => () // 既存値を優先
    _ => @sys.set_env_var(env_key, value)
  }
}

///|
/// ~ をホームディレクトリに展開
fn expand_home(path : String, home : String) -> String {
  if path.has_prefix("~/") {
    let rest = path[1:].to_string() catch { _ => path }
    home + rest
  } else {
    path
  }
}

///|
/// [bit] セクション配下の設定を環境変数に注入
fn inject_from_bit_table(
  bit : Map[String, @toml.TomlValue],
  home : String,
) -> Unit {
  // [bit.user]
  if get_table(bit, "user") is Some(user) {
    if get_string(user, "sender") is Some(v) {
      inject_if_unset("BIT_RELAY_SENDER", v)
    }
    if get_string(user, "github_username") is Some(v) {
      inject_if_unset("BIT_GITHUB_USERNAME", v)
    }
  }
  // [bit.relay]
  if get_table(bit, "relay") is Some(relay) {
    if get_string(relay, "url") is Some(v) {
      inject_if_unset("BIT_RELAY_URL", v)
    }
    if get_string(relay, "auth_token") is Some(v) {
      inject_if_unset("BIT_RELAY_AUTH_TOKEN", v)
    }
  }
  // [bit.key]
  if get_table(bit, "key") is Some(key) {
    if get_string(key, "private_key_file") is Some(v) {
      inject_if_unset("BIT_RELAY_SIGN_PRIVATE_KEY_FILE", expand_home(v, home))
    }
    if get_string(key, "public_key") is Some(v) {
      inject_if_unset("BIT_RELAY_SIGN_PUBLIC_KEY", v)
    }
  }
  // [bit.serve]
  if get_table(bit, "serve") is Some(serve) {
    if get_bool_string(serve, "allow_push") is Some(v) {
      inject_if_unset("BIT_SERVE_ALLOW_PUSH", v)
    }
    if get_bool_string(serve, "broadcast") is Some(v) {
      inject_if_unset("BIT_SERVE_BROADCAST", v)
    }
    if get_bool_string(serve, "auto_fetch") is Some(v) {
      inject_if_unset("BIT_SERVE_AUTO_FETCH", v)
    }
    if get_string(serve, "room") is Some(v) {
      inject_if_unset("BIT_SERVE_ROOM", v)
    }
  }
  // [bit.hub]
  if get_table(bit, "hub") is Some(hub) {
    if get_string(hub, "conflict_policy") is Some(v) {
      inject_if_unset("BIT_HUB_CONFLICT_POLICY", v)
    }
    if get_string(hub, "collab_sign_key") is Some(v) {
      inject_if_unset("BIT_COLLAB_SIGN_KEY", v)
    }
    if get_bool_string(hub, "require_signed") is Some(v) {
      inject_if_unset("BIT_COLLAB_REQUIRE_SIGNED", v)
    }
  }
}

///| TOML 設定を読み込み、未設定の環境変数に注入する。

///|
/// エラーは静かに無視する（設定ファイルはオプション）。
pub fn load_and_inject() -> Unit {
  let path = match config_path() {
    Some(p) => p
    None => return
  }
  if not(@fs.path_exists(path)) {
    return
  }
  let content = @fs.read_file_to_string(path) catch { _ => return }
  let root = @toml.parse(content) catch { _ => return }
  guard root is @toml.TomlValue::TomlTable(top) else { return }
  let home = @sys.get_env_var("HOME").unwrap_or("")
  // [bit.*] セクションから bit 固有の設定を注入
  if get_table(top, "bit") is Some(bit) {
    inject_from_bit_table(bit, home)
  }
}
