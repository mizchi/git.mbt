///| Relay claim publish and poll functions

///|
fn relay_claim_publish_url(
  base_url : String,
  room : String,
  sender : String,
  event_id : String,
  room_token~ : String?,
) -> String {
  let topic = @hub.claim_topic()
  let base_query = "room=\{room}&sender=\{sender}&topic=\{topic}&id=\{event_id}"
  let query = match room_token {
    Some(token) => base_query + "&room_token=" + token
    None => base_query
  }
  "\{base_url}/api/v1/publish?\{query}"
}

///|
fn relay_claim_event_id(
  sender : String,
  issue_id : String,
  action : String,
  timestamp : Int64,
) -> String {
  let stable_text = "claim\n\{sender}\n\{issue_id}\n\{action}\n\{timestamp}"
  let (blob_id, _) = @bit.create_blob_string(stable_text)
  "claim-" + blob_id.to_hex()
}

///|
async fn relay_publish_claim_with_http(
  remote_url : String,
  claim : @hub.ClaimMessage,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @bit.HttpResponse,
    Bytes,
  ) raise @bit.GitError,
  auth_token~ : String?,
) -> Bool raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let sender = relay_sender()
  let payload_json = claim.to_json()
  let payload_text = payload_json.stringify()
  let event_id = relay_claim_event_id(
    sender,
    claim.issue_id(),
    claim.action().to_string(),
    claim.timestamp(),
  )
  let base_headers = relay_headers_with_auth(
    { "Content-Type": "application/json" },
    auth_token,
  )
  let relay_signing = @crypto.relay_http_signing_config()
  let publish_signature = @crypto.relay_sign_publish_payload(
    relay_signing,
    sender,
    endpoint.room,
    @hub.claim_topic(),
    event_id,
    payload_json,
  )
  let headers = @crypto.relay_headers_with_publish_signature(
    relay_copy_headers(base_headers),
    publish_signature,
  )
  let url = relay_claim_publish_url(
    endpoint.base_url,
    endpoint.room,
    sender,
    event_id,
    room_token=endpoint.room_token,
  )
  let (response, response_body) = http_post(
    url,
    @utf8.encode(payload_text),
    headers,
  )
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(response_body[:])
    raise @bit.GitError::ProtocolError(
      "Relay claim publish failed: HTTP \{response.code} \{body_text}",
    )
  }
  parse_relay_publish_accepted(@utf8.decode_lossy(response_body[:]))
}

///|
async fn relay_poll_claims_with_http(
  remote_url : String,
  http_get : async (String, Map[String, String]) -> (@bit.HttpResponse, Bytes) raise @bit.GitError,
  auth_token~ : String?,
) -> Array[@hub.ClaimMessage] raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let headers = relay_headers_with_auth(
    { "Accept": "application/json" },
    auth_token,
  )
  let url = relay_poll_url(
    endpoint.base_url,
    endpoint.room,
    0,
    1000,
    room_token=endpoint.room_token,
  )
  let (response, response_body) = http_get(url, headers)
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(response_body[:])
    raise @bit.GitError::ProtocolError(
      "Relay claim poll failed: HTTP \{response.code} \{body_text}",
    )
  }
  let poll_text = @utf8.decode_lossy(response_body[:])
  let parsed = @json.parse(poll_text) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "invalid relay poll response: \{err.to_string()}",
      )
  }
  guard parsed is Json::Object(root) else {
    raise @bit.GitError::InvalidObject(
      "invalid relay poll response: expected object",
    )
  }
  match root.get("envelopes") {
    Some(Json::Array(items)) => @hub.parse_claims_from_envelopes(items)
    _ => []
  }
}

///|
pub async fn relay_publish_claim(
  remote_url : String,
  claim : @hub.ClaimMessage,
  auth_token~ : String?,
) -> Bool raise @bit.GitError {
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  relay_publish_claim_with_http(
    remote_url,
    claim,
    @bitnative.native_http_post,
    auth_token=effective_auth_token,
  )
}

///|
pub async fn relay_poll_claims(
  remote_url : String,
  auth_token~ : String?,
) -> Array[@hub.ClaimMessage] raise @bit.GitError {
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  relay_poll_claims_with_http(
    remote_url,
    @bitnative.native_http_get,
    auth_token=effective_auth_token,
  )
}

///|
async fn relay_poll_claims_after_with_http(
  remote_url : String,
  cursor : Int,
  limit : Int,
  http_get : async (String, Map[String, String]) -> (@bit.HttpResponse, Bytes) raise @bit.GitError,
  auth_token~ : String?,
) -> (Int, Array[@hub.ClaimMessage]) raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let headers = relay_headers_with_auth(
    { "Accept": "application/json" },
    auth_token,
  )
  let url = relay_poll_url(
    endpoint.base_url,
    endpoint.room,
    cursor,
    limit,
    room_token=endpoint.room_token,
  )
  let (response, response_body) = http_get(url, headers)
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(response_body[:])
    raise @bit.GitError::ProtocolError(
      "Relay claim poll failed: HTTP \{response.code} \{body_text}",
    )
  }
  let poll_text = @utf8.decode_lossy(response_body[:])
  let parsed = @json.parse(poll_text) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "invalid relay poll response: \{err.to_string()}",
      )
  }
  guard parsed is Json::Object(root) else {
    raise @bit.GitError::InvalidObject(
      "invalid relay poll response: expected object",
    )
  }
  let next_cursor = json_get_int(root, "next_cursor", cursor)
  let claims = match root.get("envelopes") {
    Some(Json::Array(items)) => @hub.parse_claims_from_envelopes(items)
    _ => []
  }
  (next_cursor, claims)
}

///|
pub async fn relay_poll_claims_after(
  remote_url : String,
  cursor : Int,
  limit : Int,
  auth_token~ : String?,
) -> (Int, Array[@hub.ClaimMessage]) raise @bit.GitError {
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  relay_poll_claims_after_with_http(
    remote_url,
    cursor,
    limit,
    @bitnative.native_http_get,
    auth_token=effective_auth_token,
  )
}

///|
fn relay_ws_url(
  base_url : String,
  room : String,
  room_token~ : String?,
) -> String raise @bit.GitError {
  let ws_base = if base_url.has_prefix("https://") {
    let rest = base_url[8:].to_string() catch {
      _ => raise @bit.GitError::InvalidObject("invalid base_url: \{base_url}")
    }
    "wss://" + rest
  } else if base_url.has_prefix("http://") {
    let rest = base_url[7:].to_string() catch {
      _ => raise @bit.GitError::InvalidObject("invalid base_url: \{base_url}")
    }
    "ws://" + rest
  } else {
    "ws://" + base_url
  }
  let query = match room_token {
    Some(token) => "room=\{room}&room_token=\{token}"
    None => "room=\{room}"
  }
  "\{ws_base}/ws?\{query}"
}

///|
fn parse_ws_claim_message(text : String) -> @hub.ClaimMessage? {
  let parsed = @json.parse(text) catch { _ => return None }
  guard parsed is Json::Object(obj) else { return None }
  let msg_type = match obj.get("type") {
    Some(Json::String(value)) => value
    _ => return None
  }
  if msg_type != @hub.claim_topic() {
    return None
  }
  match obj.get("envelope") {
    Some(Json::Object(envelope)) =>
      match envelope.get("payload") {
        Some(payload) => @hub.parse_claim_message(payload)
        _ => None
      }
    _ =>
      // Try parsing payload directly from top-level
      match obj.get("payload") {
        Some(payload) => @hub.parse_claim_message(payload)
        _ => None
      }
  }
}

///|
pub async fn relay_watch_claims_ws(
  remote_url : String,
  on_claim : (@hub.ClaimMessage) -> Unit,
  auth_token~ : String?,
) -> Unit raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let ws_url = relay_ws_url(
    endpoint.base_url,
    endpoint.room,
    room_token=endpoint.room_token,
  )
  let headers : Map[String, String] = {}
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  match effective_auth_token {
    Some(token) => headers["Authorization"] = "Bearer \{token}"
    None => ()
  }
  let conn = @xws.Conn::connect(ws_url, headers~) catch {
    err =>
      raise @bit.GitError::ProtocolError(
        "WebSocket connect failed: \{err.to_string()}",
      )
  }
  // Read ready message
  let _ = conn.recv() catch {
    err =>
      raise @bit.GitError::ProtocolError(
        "WebSocket recv ready failed: \{err.to_string()}",
      )
  }
  // Message loop
  while true {
    let msg = conn.recv() catch {
      @xws.ConnectionClosed(_, _) as err =>
        raise @bit.GitError::ProtocolError(
          "WebSocket closed: \{err.to_string()}",
        )
      err =>
        raise @bit.GitError::ProtocolError(
          "WebSocket recv failed: \{err.to_string()}",
        )
    }
    let text = match msg {
      @xws.Message::Text(value) => value
      @xws.Message::Binary(bytes) => @utf8.decode_lossy(bytes[:])
    }
    // Handle ping
    let parsed = @json.parse(text) catch { _ => continue }
    guard parsed is Json::Object(obj) else { continue }
    match obj.get("type") {
      Some(Json::String("ping")) => {
        conn.send_text("{\"type\":\"pong\"}") catch {
          _ => ()
        }
        continue
      }
      _ => ()
    }
    match parse_ws_claim_message(text) {
      Some(claim) => on_claim(claim)
      None => continue
    }
  }
}

///|
pub fn relay_sender_name() -> String {
  relay_sender()
}
