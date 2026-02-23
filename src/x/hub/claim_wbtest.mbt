///| Whitebox tests for work-item claim logic

///|
test "ClaimMessage::to_json serializes correctly" {
  let msg = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  let json = msg.to_json()
  guard json is Json::Object(obj) else { fail("expected object") }
  assert_eq(obj.get("type"), Some(Json::string("work-item.claim")))
  assert_eq(obj.get("issue_id"), Some(Json::string("issue-0001")))
  assert_eq(obj.get("action"), Some(Json::string("claim")))
  assert_eq(obj.get("claimer"), Some(Json::string("mizchi")))
}

///|
test "ClaimMessage::to_json unclaim action" {
  let msg = ClaimMessage::new(
    "issue-0002",
    ClaimAction::Unclaim,
    "alice",
    1708700100L,
  )
  let json = msg.to_json()
  guard json is Json::Object(obj) else { fail("expected object") }
  assert_eq(obj.get("action"), Some(Json::string("unclaim")))
}

///|
test "parse_claim_message roundtrip" {
  let msg = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  let json = msg.to_json()
  let parsed = parse_claim_message(json)
  guard parsed is Some(result) else { fail("expected Some") }
  assert_eq(result.issue_id(), "issue-0001")
  assert_eq(result.action(), ClaimAction::Claim)
  assert_eq(result.claimer(), "mizchi")
  assert_eq(result.timestamp(), 1708700000L)
}

///|
test "parse_claim_message returns None for invalid JSON" {
  let json = Json::string("not an object")
  assert_eq(parse_claim_message(json), None)
}

///|
test "parse_claim_message returns None for wrong type" {
  let obj : Map[String, Json] = {}
  obj["type"] = Json::string("something-else")
  obj["issue_id"] = Json::string("issue-0001")
  obj["action"] = Json::string("claim")
  obj["claimer"] = Json::string("mizchi")
  obj["timestamp"] = Json::number(1708700000.0)
  assert_eq(parse_claim_message(Json::object(obj)), None)
}

///|
test "parse_claim_message returns None for missing fields" {
  let obj : Map[String, Json] = {}
  obj["type"] = Json::string("work-item.claim")
  obj["issue_id"] = Json::string("issue-0001")
  // missing action, claimer, timestamp
  assert_eq(parse_claim_message(Json::object(obj)), None)
}

///|
test "parse_claim_message returns None for invalid action" {
  let obj : Map[String, Json] = {}
  obj["type"] = Json::string("work-item.claim")
  obj["issue_id"] = Json::string("issue-0001")
  obj["action"] = Json::string("invalid")
  obj["claimer"] = Json::string("mizchi")
  obj["timestamp"] = Json::number(1708700000.0)
  assert_eq(parse_claim_message(Json::object(obj)), None)
}

///|
test "parse_claims_from_envelopes extracts claims" {
  let claim1 = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  let claim2 = ClaimMessage::new(
    "issue-0002",
    ClaimAction::Claim,
    "alice",
    1708700100L,
  )
  let envelopes : Array[Json] = [
    make_test_envelope(claim1.to_json()),
    make_test_envelope(claim2.to_json()),
  ]
  let claims = parse_claims_from_envelopes(envelopes)
  assert_eq(claims.length(), 2)
  assert_eq(claims[0].issue_id(), "issue-0001")
  assert_eq(claims[1].issue_id(), "issue-0002")
}

///|
test "parse_claims_from_envelopes skips non-claim envelopes" {
  let claim = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  let other_payload : Map[String, Json] = {}
  other_payload["kind"] = Json::string("hub.record")
  let envelopes : Array[Json] = [
    make_test_envelope(claim.to_json()),
    make_test_envelope(Json::object(other_payload)),
    Json::string("invalid"),
  ]
  let claims = parse_claims_from_envelopes(envelopes)
  assert_eq(claims.length(), 1)
}

///|
test "resolve_active_claims keeps latest claim per issue" {
  let claims = [
    ClaimMessage::new("issue-0001", ClaimAction::Claim, "mizchi", 1708700000L),
    ClaimMessage::new("issue-0001", ClaimAction::Claim, "alice", 1708700100L),
    ClaimMessage::new("issue-0002", ClaimAction::Claim, "bob", 1708700050L),
  ]
  let active = resolve_active_claims(claims)
  assert_eq(active.length(), 2)
  let issue1 = active.iter().find_first(fn(c) { c.issue_id() == "issue-0001" })
  guard issue1 is Some(c1) else { fail("expected issue-0001") }
  assert_eq(c1.claimer(), "alice")
}

///|
test "resolve_active_claims removes unclaimed issues" {
  let claims = [
    ClaimMessage::new("issue-0001", ClaimAction::Claim, "mizchi", 1708700000L),
    ClaimMessage::new("issue-0001", ClaimAction::Unclaim, "mizchi", 1708700100L),
  ]
  let active = resolve_active_claims(claims)
  assert_eq(active.length(), 0)
}

///|
test "resolve_active_claims reclaim after unclaim" {
  let claims = [
    ClaimMessage::new("issue-0001", ClaimAction::Claim, "mizchi", 1708700000L),
    ClaimMessage::new("issue-0001", ClaimAction::Unclaim, "mizchi", 1708700100L),
    ClaimMessage::new("issue-0001", ClaimAction::Claim, "alice", 1708700200L),
  ]
  let active = resolve_active_claims(claims)
  assert_eq(active.length(), 1)
  assert_eq(active[0].claimer(), "alice")
}

///|
test "is_stale returns true when past threshold" {
  let claim = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  // 25 hours later
  let now = 1708700000L + 25L * 3600L
  assert_true(claim.is_stale(now))
}

///|
test "is_stale returns false when within threshold" {
  let claim = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  // 23 hours later
  let now = 1708700000L + 23L * 3600L
  assert_false(claim.is_stale(now))
}

///|
test "is_stale custom threshold" {
  let claim = ClaimMessage::new(
    "issue-0001",
    ClaimAction::Claim,
    "mizchi",
    1708700000L,
  )
  // 5 hours later, threshold = 4 hours
  let now = 1708700000L + 5L * 3600L
  assert_true(claim.is_stale(now, threshold_hours=4))
  // 3 hours later, threshold = 4 hours
  let now2 = 1708700000L + 3L * 3600L
  assert_false(claim.is_stale(now2, threshold_hours=4))
}

///|
test "ClaimAction::to_string" {
  assert_eq(ClaimAction::Claim.to_string(), "claim")
  assert_eq(ClaimAction::Unclaim.to_string(), "unclaim")
}

///|
test "parse_claim_action" {
  assert_eq(parse_claim_action("claim"), Some(ClaimAction::Claim))
  assert_eq(parse_claim_action("unclaim"), Some(ClaimAction::Unclaim))
  assert_eq(parse_claim_action("invalid"), None)
}

///|
fn make_test_envelope(payload : Json) -> Json {
  let obj : Map[String, Json] = {}
  obj["payload"] = payload
  obj["topic"] = Json::string("work-item.claim")
  obj["sender"] = Json::string("test")
  Json::object(obj)
}
