///| Cross-platform relay signing: shared types and pure logic.

///|
pub struct RelayHttpSigningConfig {
  private_key_source : String
  public_key : String
}

///|
pub struct RelayPublishHttpSignature {
  public_key : String
  signature : String
  timestamp_sec : Int64
  nonce : String
}

///|
pub fn relay_base64_to_base64url(base64 : String) -> String {
  let out = StringBuilder::new()
  for c in base64 {
    if c == '+' {
      out.write_char('-')
    } else if c == '/' {
      out.write_char('_')
    } else if c == '=' {
      ()
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
pub fn relay_extract_ed25519_public_key_from_der(der : Bytes) -> String? {
  if der.length() != 44 {
    return None
  }
  let prefix : Array[Byte] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
  ]
  for i = 0; i < prefix.length(); i = i + 1 {
    if der[i] != prefix[i] {
      return None
    }
  }
  let raw_key = der[12:44]
  let base64 = @base64.encode(raw_key, padding=false)
  Some(relay_base64_to_base64url(base64))
}

///|
fn relay_is_hex_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
pub fn relay_extract_sha256_hex(output : String) -> String? {
  for line_view in output.split("\n") {
    let line = line_view.trim(chars=" \n\r\t").to_string()
    if line.length() == 0 {
      continue
    }
    let candidate_with_label = match line.find("=") {
      Some(eq_idx) =>
        String::unsafe_substring(line, start=eq_idx + 1, end=line.length())
      None => line
    }
    let candidate_trimmed = candidate_with_label
      .trim(chars=" \n\r\t")
      .to_string()
    let token = match candidate_trimmed.find(" ") {
      Some(space_idx) =>
        String::unsafe_substring(candidate_trimmed, start=0, end=space_idx)
      None => candidate_trimmed
    }
    if token.length() == 64 {
      let mut ok = true
      for c in token.to_array() {
        if not(relay_is_hex_char(c)) {
          ok = false
          break
        }
      }
      if ok {
        return Some(token.to_lower())
      }
    }
  }
  None
}

///|
pub fn relay_canonicalize_json(value : Json) -> String {
  match value {
    Json::Null => "null"
    Json::True => "true"
    Json::False => "false"
    Json::String(text) => Json::string(text).stringify()
    Json::Number(number, ..) => Json::number(number).stringify()
    Json::Array(items) => {
      let parts : Array[String] = []
      for item in items {
        parts.push(relay_canonicalize_json(item))
      }
      "[" + parts.join(",") + "]"
    }
    Json::Object(obj) => {
      let entries = obj.to_array()
      entries.sort_by((a, b) => String::compare(a.0, b.0))
      let parts : Array[String] = []
      for entry in entries {
        let (key, item) = entry
        let quoted_key = Json::string(key).stringify()
        parts.push(quoted_key + ":" + relay_canonicalize_json(item))
      }
      "{" + parts.join(",") + "}"
    }
  }
}

///|
pub fn relay_build_publish_signing_message(
  sender : String,
  room : String,
  id : String,
  topic : String,
  timestamp_sec : Int64,
  nonce : String,
  payload_sha256 : String,
) -> String {
  [
    "v1",
    "sender=" + sender,
    "room=" + room,
    "id=" + id,
    "topic=" + topic,
    "ts=" + timestamp_sec.to_string(),
    "nonce=" + nonce,
    "payload_sha256=" + payload_sha256,
  ].join("\n")
}

///|
pub fn relay_headers_with_publish_signature(
  headers : Map[String, String],
  signature : RelayPublishHttpSignature?,
) -> Map[String, String] {
  let out = headers
  match signature {
    Some(auth) => {
      out["x-relay-public-key"] = auth.public_key
      out["x-relay-signature"] = auth.signature
      out["x-relay-timestamp"] = auth.timestamp_sec.to_string()
      out["x-relay-nonce"] = auth.nonce
    }
    None => ()
  }
  out
}

///|
pub async fn relay_sign_publish_payload(
  config : RelayHttpSigningConfig?,
  sender : String,
  room : String,
  topic : String,
  id : String,
  payload : Json,
) -> RelayPublishHttpSignature? raise @bit.GitError {
  match config {
    None => None
    Some(signing) => {
      let timestamp_sec = relay_unix_timestamp_sec()
      let nonce_now = @env.now().to_int().to_int64()
      let nonce = "\{timestamp_sec}-\{nonce_now}-\{id}"
      let payload_sha256 = relay_sha256_hex(relay_canonicalize_json(payload))
      let message = relay_build_publish_signing_message(
        sender, room, id, topic, timestamp_sec, nonce, payload_sha256,
      )
      let signature = relay_sign_ed25519(signing.private_key_source, message)
      Some({ public_key: signing.public_key, signature, timestamp_sec, nonce })
    }
  }
}

///|
pub async fn relay_http_signing_config() -> RelayHttpSigningConfig? raise @bit.GitError {
  match relay_load_signing_key() {
    None => None
    Some(key_source) => {
      let public_key = relay_resolve_public_key(key_source)
      Some({ private_key_source: key_source, public_key })
    }
  }
}
