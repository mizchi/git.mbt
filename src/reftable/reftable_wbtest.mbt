///|
test "varint roundtrip" {
  let values : Array[UInt64] = [
    0UL, 1UL, 127UL, 128UL, 255UL, 256UL, 16383UL, 16384UL, 0xFFFFUL, 0xFFFFFFUL,
  ]
  for v in values {
    let buf : Array[Byte] = []
    encode_varint(buf, v)
    let bytes = Bytes::from_array(
      FixedArray::makei(buf.length(), fn(i) { buf[i] }),
    )
    let (decoded, consumed) = decode_varint(bytes, 0)
    assert_eq(decoded, v)
    assert_eq(consumed, buf.length())
  }
}

///|
test "write and read reftable with single Val1 record" {
  let oid = @object.ObjectId::from_hex(
    "aabbccddee00112233445566778899aabbccddee",
  )
  let records : Array[RefRecord] = [
    { refname: "refs/heads/main", update_index: 1UL, value: Val1(oid) },
  ]
  let data = write_reftable(records, 4096, 1UL, 1UL)
  let header = parse_header(data)
  assert_true(header is Some(_))
  let h = header.unwrap()
  assert_eq(h.version, 1)
  assert_eq(h.block_size, 4096)
  assert_eq(h.min_update_index, 1UL)
  assert_eq(h.max_update_index, 1UL)
  let read = read_refs(data)
  assert_true(read is Some(_))
  let refs = read.unwrap()
  assert_eq(refs.length(), 1)
  assert_eq(refs[0].refname, "refs/heads/main")
  assert_eq(refs[0].update_index, 1UL)
  assert_eq(refs[0].value, Val1(oid))
}

///|
test "write and read reftable with symref" {
  let records : Array[RefRecord] = [
    { refname: "HEAD", update_index: 1UL, value: Symref("refs/heads/main") },
  ]
  let data = write_reftable(records, 4096, 1UL, 1UL)
  let read = read_refs(data)
  assert_true(read is Some(_))
  let refs = read.unwrap()
  assert_eq(refs.length(), 1)
  assert_eq(refs[0].refname, "HEAD")
  assert_eq(refs[0].value, Symref("refs/heads/main"))
}

///|
test "write and read reftable with multiple records" {
  let oid1 = @object.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let oid2 = @object.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  let oid3 = @object.ObjectId::from_hex(
    "3333333333333333333333333333333333333333",
  )
  let records : Array[RefRecord] = [
    { refname: "HEAD", update_index: 1UL, value: Symref("refs/heads/main") },
    { refname: "refs/heads/feature", update_index: 1UL, value: Val1(oid2) },
    { refname: "refs/heads/main", update_index: 1UL, value: Val1(oid1) },
    { refname: "refs/tags/v1.0", update_index: 1UL, value: Val2(oid3, oid1) },
  ]
  let data = write_reftable(records, 4096, 1UL, 1UL)
  let read = read_refs(data)
  assert_true(read is Some(_))
  let refs = read.unwrap()
  assert_eq(refs.length(), 4)
  assert_eq(refs[0].refname, "HEAD")
  assert_eq(refs[1].refname, "refs/heads/feature")
  assert_eq(refs[2].refname, "refs/heads/main")
  assert_eq(refs[3].refname, "refs/tags/v1.0")
}

///|
test "lookup_ref finds existing ref" {
  let oid = @object.ObjectId::from_hex(
    "aabbccddee00112233445566778899aabbccddee",
  )
  let records : Array[RefRecord] = [
    { refname: "refs/heads/main", update_index: 1UL, value: Val1(oid) },
  ]
  let data = write_reftable(records, 4096, 1UL, 1UL)
  let result = lookup_ref(data, "refs/heads/main")
  assert_true(result is Some(_))
  assert_eq(result.unwrap().value, Val1(oid))
  let missing = lookup_ref(data, "refs/heads/nonexistent")
  assert_true(missing is None)
}

///|
test "iter_refs filters by prefix" {
  let oid1 = @object.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let oid2 = @object.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  let records : Array[RefRecord] = [
    { refname: "HEAD", update_index: 1UL, value: Symref("refs/heads/main") },
    { refname: "refs/heads/main", update_index: 1UL, value: Val1(oid1) },
    { refname: "refs/tags/v1.0", update_index: 1UL, value: Val1(oid2) },
  ]
  let data = write_reftable(records, 4096, 1UL, 1UL)
  let heads = iter_refs([data], "refs/heads/")
  assert_eq(heads.length(), 1)
  assert_eq(heads[0].refname, "refs/heads/main")
  let tags = iter_refs([data], "refs/tags/")
  assert_eq(tags.length(), 1)
  assert_eq(tags[0].refname, "refs/tags/v1.0")
}

///|
test "stacked tables: newer table wins" {
  let oid1 = @object.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let oid2 = @object.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  let table1 = write_reftable(
    [{ refname: "refs/heads/main", update_index: 1UL, value: Val1(oid1) }],
    4096,
    1UL,
    1UL,
  )
  let table2 = write_reftable(
    [{ refname: "refs/heads/main", update_index: 2UL, value: Val1(oid2) }],
    4096,
    2UL,
    2UL,
  )
  let result = lookup_ref_in_stack([table1, table2], "refs/heads/main")
  assert_true(result is Some(_))
  assert_eq(result.unwrap().value, Val1(oid2))
}

///|
test "stacked tables: deletion removes ref" {
  let oid1 = @object.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let table1 = write_reftable(
    [{ refname: "refs/heads/main", update_index: 1UL, value: Val1(oid1) }],
    4096,
    1UL,
    1UL,
  )
  let table2 = write_reftable(
    [{ refname: "refs/heads/main", update_index: 2UL, value: Deletion }],
    4096,
    2UL,
    2UL,
  )
  let refs = iter_refs([table1, table2], "refs/")
  assert_eq(refs.length(), 0)
}

///|
test "footer CRC32 verification" {
  let oid = @object.ObjectId::from_hex(
    "aabbccddee00112233445566778899aabbccddee",
  )
  let records : Array[RefRecord] = [
    { refname: "refs/heads/main", update_index: 1UL, value: Val1(oid) },
  ]
  let data = write_reftable(records, 4096, 1UL, 1UL)
  let footer = parse_footer(data)
  assert_true(footer is Some(_))
}
