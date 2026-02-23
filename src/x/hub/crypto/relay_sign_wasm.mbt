///| WASM relay signing: stub implementation (not yet supported).

///|
pub fn relay_unix_timestamp_sec() -> Int64 {
  0L
}

///|
pub fn relay_load_signing_key() -> String? {
  None
}

///|
pub fn relay_sha256_hex(_text : String) -> String raise @bit.GitError {
  raise @bit.GitError::IoError(
    "relay sign: SHA-256 not supported on WASM target",
  )
}

///|
pub fn relay_sign_ed25519(
  _key_source : String,
  _message : String,
) -> String raise @bit.GitError {
  raise @bit.GitError::IoError(
    "relay sign: Ed25519 signing not supported on WASM target",
  )
}

///|
pub fn relay_resolve_public_key(
  _key_source : String,
) -> String raise @bit.GitError {
  raise @bit.GitError::IoError(
    "relay sign: public key export not supported on WASM target",
  )
}
