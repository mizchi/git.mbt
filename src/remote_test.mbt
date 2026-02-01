///|
/// Tests for Git HTTP push protocol
test "Remote info_refs_url" {
  let remote = Remote::new("https://github.com/user/repo.git")
  inspect(
    remote.info_refs_url(),
    content="https://github.com/user/repo/info/refs?service=git-receive-pack",
  )
}

///|
test "Remote info_refs_url without .git" {
  let remote = Remote::new("https://github.com/user/repo")
  inspect(
    remote.info_refs_url(),
    content="https://github.com/user/repo/info/refs?service=git-receive-pack",
  )
}

///|
test "Remote receive_pack_url" {
  let remote = Remote::new("https://github.com/user/repo.git")
  inspect(
    remote.receive_pack_url(),
    content="https://github.com/user/repo/git-receive-pack",
  )
}

///|
test "build_receive_pack_body" {
  let old_id = ObjectId::zero()
  let new_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let packfile = Bytes::from_array([b'P', b'A', b'C', b'K'])
  let req = PushRequest::new(old_id, new_id, "refs/heads/main", packfile)
  let body = build_receive_pack_body(req)

  // Should start with pkt-line
  assert_true(body.length() > 4)

  // Should contain PACK at the end
  let pack_start = body.length() - 4
  inspect(body[pack_start], content="b'\\x50'") // 'P'
  inspect(body[pack_start + 1], content="b'\\x41'") // 'A'
  inspect(body[pack_start + 2], content="b'\\x43'") // 'C'
  inspect(body[pack_start + 3], content="b'\\x4B'") // 'K'
}

///|
test "parse_receive_pack_response success" {
  // Simulate successful response
  let lines : Array[Byte] = []

  // "unpack ok\n"
  let unpack_ok = pktline_encode("unpack ok\n")
  for b in unpack_ok {
    lines.push(b)
  }

  // "ok refs/heads/main\n"
  let ref_ok = pktline_encode("ok refs/heads/main\n")
  for b in ref_ok {
    lines.push(b)
  }

  // flush
  let flush = pktline_flush()
  for b in flush {
    lines.push(b)
  }
  let data = Bytes::from_array(
    FixedArray::makei(lines.length(), fn(i) { lines[i] }),
  )
  let result = parse_receive_pack_response(data)
  match result {
    Ok(msg) => inspect(msg, content="Push successful")
    Err(e) => {
      let _ = e
      assert_true(false)
    }
  }
}

///|
test "parse_receive_pack_response failure" {
  let lines : Array[Byte] = []

  // "unpack error - invalid pack"
  let unpack_err = pktline_encode("unpack error - invalid pack\n")
  for b in unpack_err {
    lines.push(b)
  }
  let flush = pktline_flush()
  for b in flush {
    lines.push(b)
  }
  let data = Bytes::from_array(
    FixedArray::makei(lines.length(), fn(i) { lines[i] }),
  )
  let result = parse_receive_pack_response(data)
  match result {
    Ok(_) => assert_true(false)
    Err(GitError::ProtocolError(msg)) =>
      assert_true(msg.find("unpack error") is Some(_))
    Err(_) => assert_true(false)
  }
}

///|
test "parse_sideband" {
  // Channel 1 with data
  let data = Bytes::from_array([b'\x01', b'h', b'e', b'l', b'l', b'o'])
  let (channel, content) = parse_sideband(data)
  inspect(channel, content="1")
  inspect(content.length(), content="5")
}

///|
test "parse_sideband empty" {
  let data = Bytes::from_array([])
  let (channel, content) = parse_sideband(data)
  inspect(channel, content="0")
  inspect(content.length(), content="0")
}

///|
test "extract_capabilities" {
  // Simulate refs response with capabilities
  let line = "ce013625030ba8dba906f756967f9e9ca394464a refs/heads/main\u0000report-status side-band-64k\n"
  let pkt = pktline_encode(line)
  let flush = pktline_flush()
  let data : Array[Byte] = []
  for b in pkt {
    data.push(b)
  }
  for b in flush {
    data.push(b)
  }
  let caps = extract_capabilities(
    Bytes::from_array(FixedArray::makei(data.length(), fn(i) { data[i] })),
  )
  assert_true(caps.length() >= 2)
  assert_true(caps.contains("report-status"))
  assert_true(caps.contains("side-band-64k"))
}
