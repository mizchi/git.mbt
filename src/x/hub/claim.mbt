///| Work-item claim broadcasting types and logic

///|
pub(all) enum ClaimAction {
  Claim
  Unclaim
} derive(Eq)

///|
pub fn ClaimAction::to_string(self : ClaimAction) -> String {
  match self {
    Claim => "claim"
    Unclaim => "unclaim"
  }
}

///|
pub impl Show for ClaimAction with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
pub fn parse_claim_action(s : String) -> ClaimAction? {
  match s {
    "claim" => Some(ClaimAction::Claim)
    "unclaim" => Some(ClaimAction::Unclaim)
    _ => None
  }
}

///|
pub struct ClaimMessage {
  issue_id : String
  action : ClaimAction
  claimer : String
  timestamp : Int64
} derive(Eq, Show)

///|
pub fn ClaimMessage::new(
  issue_id : String,
  action : ClaimAction,
  claimer : String,
  timestamp : Int64,
) -> ClaimMessage {
  { issue_id, action, claimer, timestamp }
}

///|
pub fn ClaimMessage::issue_id(self : ClaimMessage) -> String {
  self.issue_id
}

///|
pub fn ClaimMessage::action(self : ClaimMessage) -> ClaimAction {
  self.action
}

///|
pub fn ClaimMessage::claimer(self : ClaimMessage) -> String {
  self.claimer
}

///|
pub fn ClaimMessage::timestamp(self : ClaimMessage) -> Int64 {
  self.timestamp
}

///|
pub fn ClaimMessage::to_json(self : ClaimMessage) -> Json {
  let obj : Map[String, Json] = {}
  obj["type"] = Json::string("work-item.claim")
  obj["issue_id"] = Json::string(self.issue_id)
  obj["action"] = Json::string(self.action.to_string())
  obj["claimer"] = Json::string(self.claimer)
  obj["timestamp"] = Json::number(self.timestamp.to_double())
  Json::object(obj)
}

///|
pub fn parse_claim_message(json : Json) -> ClaimMessage? {
  guard json is Json::Object(obj) else { return None }
  let msg_type = match obj.get("type") {
    Some(Json::String(value)) => value
    _ => return None
  }
  if msg_type != "work-item.claim" {
    return None
  }
  let issue_id = match obj.get("issue_id") {
    Some(Json::String(value)) => value
    _ => return None
  }
  let action = match obj.get("action") {
    Some(Json::String(value)) =>
      match parse_claim_action(value) {
        Some(a) => a
        None => return None
      }
    _ => return None
  }
  let claimer = match obj.get("claimer") {
    Some(Json::String(value)) => value
    _ => return None
  }
  let timestamp : Int64 = match obj.get("timestamp") {
    Some(Json::Number(value, ..)) => value.to_int64()
    _ => return None
  }
  Some(ClaimMessage::new(issue_id, action, claimer, timestamp))
}

///|
/// Parse claim messages from relay poll envelopes.
/// Each envelope has shape: { "payload": { ... }, "topic": "...", ... }
pub fn parse_claims_from_envelopes(
  envelopes : Array[Json],
) -> Array[ClaimMessage] {
  let claims : Array[ClaimMessage] = []
  for item in envelopes {
    guard item is Json::Object(envelope_obj) else { continue }
    guard envelope_obj.get("payload") is Some(payload) else { continue }
    match parse_claim_message(payload) {
      Some(claim) => claims.push(claim)
      None => continue
    }
  }
  claims
}

///|
/// Resolve active claims: for each issue_id, keep only the latest action.
/// If the latest action is Unclaim, the issue is not actively claimed.
pub fn resolve_active_claims(
  claims : Array[ClaimMessage],
) -> Array[ClaimMessage] {
  let latest : Map[String, ClaimMessage] = {}
  for claim in claims {
    match latest.get(claim.issue_id) {
      Some(existing) =>
        if claim.timestamp > existing.timestamp {
          latest[claim.issue_id] = claim
        }
      None => latest[claim.issue_id] = claim
    }
  }
  let active : Array[ClaimMessage] = []
  for entry in latest.to_array() {
    let (_, claim) = entry
    if claim.action == ClaimAction::Claim {
      active.push(claim)
    }
  }
  active
}

///|
/// Check if a claim is stale based on the threshold.
pub fn ClaimMessage::is_stale(
  self : ClaimMessage,
  now : Int64,
  threshold_hours? : Int = 24,
) -> Bool {
  let threshold_seconds = threshold_hours.to_int64() * 3600L
  now - self.timestamp > threshold_seconds
}

///|
/// Topic string for claim messages.
pub fn claim_topic() -> String {
  "work-item.claim"
}
