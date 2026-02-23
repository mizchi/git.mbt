///|
test "get_string extracts string value" {
  let table : Map[String, @toml.TomlValue] = {
    "name": @toml.TomlValue::TomlString("alice"),
    "count": @toml.TomlValue::TomlInteger(42L),
  }
  assert_eq(get_string(table, "name"), Some("alice"))
  assert_eq(get_string(table, "count"), None)
  assert_eq(get_string(table, "missing"), None)
}

///|
test "get_bool_string extracts boolean as string" {
  let table : Map[String, @toml.TomlValue] = {
    "enabled": @toml.TomlValue::TomlBoolean(true),
    "disabled": @toml.TomlValue::TomlBoolean(false),
    "name": @toml.TomlValue::TomlString("test"),
  }
  assert_eq(get_bool_string(table, "enabled"), Some("true"))
  assert_eq(get_bool_string(table, "disabled"), Some("false"))
  assert_eq(get_bool_string(table, "name"), None)
  assert_eq(get_bool_string(table, "missing"), None)
}

///|
test "get_table extracts sub-table" {
  let sub : Map[String, @toml.TomlValue] = {
    "key": @toml.TomlValue::TomlString("val"),
  }
  let table : Map[String, @toml.TomlValue] = {
    "section": @toml.TomlValue::TomlTable(sub),
    "name": @toml.TomlValue::TomlString("test"),
  }
  assert_true(get_table(table, "section") is Some(_))
  assert_eq(get_table(table, "name"), None)
  assert_eq(get_table(table, "missing"), None)
}

///|
test "expand_home expands tilde prefix" {
  assert_eq(
    expand_home("~/keys/ed25519.pem", "/home/user"),
    "/home/user/keys/ed25519.pem",
  )
  assert_eq(expand_home("/absolute/path", "/home/user"), "/absolute/path")
  assert_eq(expand_home("relative/path", "/home/user"), "relative/path")
  assert_eq(expand_home("~nope", "/home/user"), "~nope")
}

///|
test "inject_if_unset sets when unset" {
  let key = "BIT_TEST_INJECT_UNSET_1"
  @sys.unset_env_var(key)
  inject_if_unset(key, "hello")
  assert_eq(@sys.get_env_var(key), Some("hello"))
  @sys.unset_env_var(key)
}

///|
test "inject_if_unset preserves existing value" {
  let key = "BIT_TEST_INJECT_UNSET_2"
  @sys.set_env_var(key, "original")
  inject_if_unset(key, "new")
  assert_eq(@sys.get_env_var(key), Some("original"))
  @sys.unset_env_var(key)
}

///|
test "inject_if_unset overwrites empty string" {
  let key = "BIT_TEST_INJECT_UNSET_3"
  @sys.set_env_var(key, "")
  inject_if_unset(key, "filled")
  assert_eq(@sys.get_env_var(key), Some("filled"))
  @sys.unset_env_var(key)
}

///|
test "inject_from_bit_table injects all sections" {
  let keys = [
    "BIT_RELAY_SENDER", "BIT_GITHUB_USERNAME", "BIT_RELAY_URL", "BIT_RELAY_AUTH_TOKEN",
    "BIT_RELAY_SIGN_PRIVATE_KEY_FILE", "BIT_RELAY_SIGN_PUBLIC_KEY", "BIT_SERVE_ALLOW_PUSH",
    "BIT_SERVE_BROADCAST", "BIT_SERVE_AUTO_FETCH", "BIT_SERVE_ROOM", "BIT_HUB_CONFLICT_POLICY",
    "BIT_COLLAB_SIGN_KEY", "BIT_COLLAB_REQUIRE_SIGNED",
  ]
  for key in keys {
    @sys.unset_env_var(key)
  }
  let toml_str =
    #|[bit.user]
    #|sender = "mizchi"
    #|github_username = "mizchi"
    #|
    #|[bit.relay]
    #|url = "relay+https://relay.sprites.dev"
    #|auth_token = "secret-token"
    #|
    #|[bit.key]
    #|private_key_file = "~/.config/bit/keys/ed25519.pem"
    #|public_key = "base64url_encoded_public_key"
    #|
    #|[bit.serve]
    #|allow_push = false
    #|broadcast = true
    #|auto_fetch = false
    #|room = "my-room"
    #|
    #|[bit.hub]
    #|conflict_policy = "ours"
    #|collab_sign_key = "key-value"
    #|require_signed = true
  let root = @toml.parse(toml_str)
  guard root is @toml.TomlValue::TomlTable(top) else { fail("expected table") }
  guard get_table(top, "bit") is Some(bit) else { fail("expected [bit] table") }
  inject_from_bit_table(bit, "/home/test")
  assert_eq(@sys.get_env_var("BIT_RELAY_SENDER"), Some("mizchi"))
  assert_eq(@sys.get_env_var("BIT_GITHUB_USERNAME"), Some("mizchi"))
  assert_eq(
    @sys.get_env_var("BIT_RELAY_URL"),
    Some("relay+https://relay.sprites.dev"),
  )
  assert_eq(@sys.get_env_var("BIT_RELAY_AUTH_TOKEN"), Some("secret-token"))
  assert_eq(
    @sys.get_env_var("BIT_RELAY_SIGN_PRIVATE_KEY_FILE"),
    Some("/home/test/.config/bit/keys/ed25519.pem"),
  )
  assert_eq(
    @sys.get_env_var("BIT_RELAY_SIGN_PUBLIC_KEY"),
    Some("base64url_encoded_public_key"),
  )
  assert_eq(@sys.get_env_var("BIT_SERVE_ALLOW_PUSH"), Some("false"))
  assert_eq(@sys.get_env_var("BIT_SERVE_BROADCAST"), Some("true"))
  assert_eq(@sys.get_env_var("BIT_SERVE_AUTO_FETCH"), Some("false"))
  assert_eq(@sys.get_env_var("BIT_SERVE_ROOM"), Some("my-room"))
  assert_eq(@sys.get_env_var("BIT_HUB_CONFLICT_POLICY"), Some("ours"))
  assert_eq(@sys.get_env_var("BIT_COLLAB_SIGN_KEY"), Some("key-value"))
  assert_eq(@sys.get_env_var("BIT_COLLAB_REQUIRE_SIGNED"), Some("true"))
  for key in keys {
    @sys.unset_env_var(key)
  }
}

///|
test "inject_from_bit_table respects existing env vars" {
  let key = "BIT_RELAY_SENDER"
  @sys.set_env_var(key, "existing-sender")
  let toml_str =
    #|[bit.user]
    #|sender = "new-sender"
  let root = @toml.parse(toml_str)
  guard root is @toml.TomlValue::TomlTable(top) else { fail("expected table") }
  guard get_table(top, "bit") is Some(bit) else { fail("expected [bit] table") }
  inject_from_bit_table(bit, "/home/test")
  assert_eq(@sys.get_env_var(key), Some("existing-sender"))
  @sys.unset_env_var(key)
}

///|
test "inject_from_bit_table handles partial config" {
  @sys.unset_env_var("BIT_RELAY_SENDER")
  @sys.unset_env_var("BIT_RELAY_URL")
  let toml_str =
    #|[bit.user]
    #|sender = "mizchi"
  let root = @toml.parse(toml_str)
  guard root is @toml.TomlValue::TomlTable(top) else { fail("expected table") }
  guard get_table(top, "bit") is Some(bit) else { fail("expected [bit] table") }
  inject_from_bit_table(bit, "/home/test")
  assert_eq(@sys.get_env_var("BIT_RELAY_SENDER"), Some("mizchi"))
  assert_eq(@sys.get_env_var("BIT_RELAY_URL"), None)
  @sys.unset_env_var("BIT_RELAY_SENDER")
}

///|
test "no bit section does not crash" {
  @sys.unset_env_var("BIT_RELAY_SENDER")
  let toml_str =
    #|[user]
    #|name = "mizchi"
    #|email = "test@example.com"
  let root = @toml.parse(toml_str)
  guard root is @toml.TomlValue::TomlTable(top) else { fail("expected table") }
  // no [bit] section — should be a no-op
  assert_true(get_table(top, "bit") is None)
  assert_eq(@sys.get_env_var("BIT_RELAY_SENDER"), None)
}

///|
test "invalid toml does not crash" {
  let result : @toml.TomlValue? = Some(@toml.parse("invalid [[ toml")) catch {
    _ => None
  }
  assert_true(result is None)
}
