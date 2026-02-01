///|
/// Tests for Git pkt-line protocol
test "pktline encode simple" {
  let encoded = pktline_encode("hello\n")
  // Length = 6 + 4 = 10 = 0x000a
  inspect(encoded[0], content="b'\\x30'") // '0'
  inspect(encoded[1], content="b'\\x30'") // '0'
  inspect(encoded[2], content="b'\\x30'") // '0'
  inspect(encoded[3], content="b'\\x61'") // 'a'
  inspect(encoded[4], content="b'\\x68'") // 'h'
  inspect(encoded[9], content="b'\\x0A'") // '\n'
}

///|
test "pktline flush" {
  let flush = pktline_flush()
  inspect(flush.length(), content="4")
  inspect(flush[0], content="b'\\x30'")
  inspect(flush[1], content="b'\\x30'")
  inspect(flush[2], content="b'\\x30'")
  inspect(flush[3], content="b'\\x30'")
}

///|
test "pktline delim" {
  let delim = pktline_delim()
  inspect(delim.length(), content="4")
  inspect(delim[0], content="b'\\x30'")
  inspect(delim[1], content="b'\\x30'")
  inspect(delim[2], content="b'\\x30'")
  inspect(delim[3], content="b'\\x31'")
}

///|
test "pktline decode simple" {
  // "000ahello\n"
  let data = Bytes::from_array([
    b'0', b'0', b'0', b'a', b'h', b'e', b'l', b'l', b'o', b'\n',
  ])
  let result = pktline_decode(data)
  inspect(result.length(), content="1")
  let (payload, is_flush) = result[0]
  inspect(is_flush, content="false")
  inspect(payload.length(), content="6")
}

///|
test "pktline decode with flush" {
  // "000ahello\n0000"
  let data = Bytes::from_array([
    b'0', b'0', b'0', b'a', b'h', b'e', b'l', b'l', b'o', b'\n', b'0', b'0', b'0',
    b'0',
  ])
  let result = pktline_decode(data)
  inspect(result.length(), content="2")
  let (_, is_flush1) = result[0]
  let (_, is_flush2) = result[1]
  inspect(is_flush1, content="false")
  inspect(is_flush2, content="true")
}

///|
test "pktline encode decode roundtrip" {
  let original = "test message\n"
  let encoded = pktline_encode(original)
  let decoded = pktline_decode(encoded)
  inspect(decoded.length(), content="1")
  let (payload, is_flush) = decoded[0]
  inspect(is_flush, content="false")
  let result = StringBuilder::new()
  for b in payload {
    result.write_char(b.to_int().unsafe_to_char())
  }
  inspect(
    result.to_string(),
    content=(
      #|test message
      #|
    ),
  )
}

///|
test "build ref update" {
  let old_id = ObjectId::zero()
  let new_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let cmd = build_ref_update(old_id, new_id, "refs/heads/main", "report-status")
  assert_true(cmd.has_prefix("0000000000000000000000000000000000000000"))
  assert_true(cmd.find("ce013625030ba8dba906f756967f9e9ca394464a") is Some(_))
  assert_true(cmd.find("refs/heads/main") is Some(_))
  assert_true(cmd.find("report-status") is Some(_))
}

///|
test "build ref update simple" {
  let old_id = ObjectId::zero()
  let new_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let cmd = build_ref_update_simple(old_id, new_id, "refs/heads/main")
  inspect(
    cmd,
    content=(
      #|0000000000000000000000000000000000000000 ce013625030ba8dba906f756967f9e9ca394464a refs/heads/main
      #|
    ),
  )
}

///|
test "pktline encode bytes" {
  let data = Bytes::from_array([b'\x00', b'\x01', b'\x02'])
  let encoded = pktline_encode_bytes(data)
  // Length = 3 + 4 = 7 = 0x0007
  inspect(encoded[0], content="b'\\x30'")
  inspect(encoded[1], content="b'\\x30'")
  inspect(encoded[2], content="b'\\x30'")
  inspect(encoded[3], content="b'\\x37'") // '7'
  inspect(encoded[4], content="b'\\x00'")
  inspect(encoded[5], content="b'\\x01'")
  inspect(encoded[6], content="b'\\x02'")
}
