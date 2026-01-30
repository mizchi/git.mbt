///| Tests verifying compatibility with real Git

///|
/// All expected values were generated using git command-line tools

// =============================================================================
// Blob Hash Tests
// =============================================================================

test "git compat: blob hash 'hello' (no newline)" {
  // echo -n "hello" | git hash-object --stdin
  let id = hash_blob_string("hello")
  inspect(id.to_hex(), content="b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
}

///|
test "git compat: blob hash 'hello\\n'" {
  // echo "hello" | git hash-object --stdin
  let id = hash_blob_string("hello\n")
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

///|
test "git compat: blob hash 'world\\n'" {
  // echo "world" | git hash-object --stdin
  let id = hash_blob_string("world\n")
  inspect(id.to_hex(), content="cc628ccd10742baea8241c5924df992b5c019f71")
}

///|
test "git compat: blob hash single newline" {
  // echo "" | git hash-object --stdin
  let id = hash_blob_string("\n")
  inspect(id.to_hex(), content="8b137891791fe96927ad78e64b0aad7bded08bdc")
}

///|
test "git compat: blob hash multiline" {
  // printf "line1\nline2\nline3\n" | git hash-object --stdin
  let id = hash_blob_string("line1\nline2\nline3\n")
  inspect(id.to_hex(), content="83db48f84ec878fbfb30b46d16630e944e34f205")
}

///|
test "git compat: blob hash empty" {
  // git hash-object -t blob /dev/null
  let id = hash_blob_string("")
  inspect(id.to_hex(), content="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

// =============================================================================
// Tree Hash Tests
// =============================================================================

///|
test "git compat: tree with single file" {
  // Tree containing: hello.txt -> "hello\n"
  // git write-tree after: echo "hello" > hello.txt && git add hello.txt
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entry = @git.TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, _) = create_tree([entry])
  inspect(tree_id.to_hex(), content="aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
}

///|
test "git compat: tree with two files" {
  // Tree containing:
  //   hello.txt -> "hello\n"
  //   world.txt -> "world\n"
  // Entries must be sorted by name
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("100644", "world.txt", world_id),
  ]
  let (tree_id, _) = create_tree(entries)
  inspect(tree_id.to_hex(), content="88e38705fdbd3608cddbe904b67c731f3234c45b")
}

// =============================================================================
// Commit Hash Tests
// =============================================================================

///|
test "git compat: initial commit" {
  // Commit with:
  //   tree: 88e38705fdbd3608cddbe904b67c731f3234c45b
  //   author: Test <test@example.com> 1700000000 +0000
  //   committer: Test <test@example.com> 1700000000 +0000
  //   message: Initial commit
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let commit = @git.Commit::new(
    tree_id,
    [], // no parents
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, _) = create_commit(commit)
  inspect(
    commit_id.to_hex(),
    content="681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
}

// =============================================================================
// Zlib Tests
// =============================================================================

///|
test "git compat: zlib roundtrip" {
  let original = "Hello, Git!\n"
  let data : Array[Byte] = []
  for c in original {
    data.push(c.to_int().to_byte())
  }
  let bytes = Bytes::from_array(
    FixedArray::makei(data.length(), fn(i) { data[i] }),
  )
  let compressed = @zlib.zlib_compress_stored(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  assert_true(decompressed.length() == bytes.length())
  for i = 0; i < bytes.length(); i = i + 1 {
    assert_true(decompressed[i] == bytes[i])
  }
}

///|
test "git compat: zlib header" {
  let data = Bytes::from_array([b'x'])
  let compressed = @zlib.zlib_compress_stored(data)

  // Zlib header: 0x78 0x01 (deflate, fastest)
  inspect(compressed[0], content="b'\\x78'")
  inspect(compressed[1], content="b'\\x01'")
}

// =============================================================================
// Packfile Tests
// =============================================================================

///|
test "git compat: packfile header" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = create_blob_packfile(content)

  // Magic: "PACK"
  inspect(packfile[0], content="b'\\x50'") // 'P'
  inspect(packfile[1], content="b'\\x41'") // 'A'
  inspect(packfile[2], content="b'\\x43'") // 'C'
  inspect(packfile[3], content="b'\\x4B'") // 'K'

  // Version: 2 (big-endian)
  inspect(packfile[4], content="b'\\x00'")
  inspect(packfile[5], content="b'\\x00'")
  inspect(packfile[6], content="b'\\x00'")
  inspect(packfile[7], content="b'\\x02'")

  // Object count: 1 (big-endian)
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x01'")
}

///|
test "git compat: packfile with 3 objects" {
  let blob_content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o', b'\n'])
  let commit = @git.Commit::new(
    @git.ObjectId::zero(),
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test\n",
  )
  let (_, packfile) = create_commit_packfile(blob_content, "hello.txt", commit)

  // Object count should be 3 (blob, tree, commit)
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x03'")
}

// =============================================================================
// pkt-line Tests
// =============================================================================

///|
test "git compat: pktline encode" {
  // "hello\n" with 4-byte length prefix
  // Length = 6 + 4 = 10 = 0x000a
  let encoded = pktline_encode("hello\n")
  inspect(encoded[0], content="b'\\x30'") // '0'
  inspect(encoded[1], content="b'\\x30'") // '0'
  inspect(encoded[2], content="b'\\x30'") // '0'
  inspect(encoded[3], content="b'\\x61'") // 'a'
  inspect(encoded[4], content="b'\\x68'") // 'h'
}

///|
test "git compat: pktline flush" {
  // Flush packet: 0000
  let flush = pktline_flush()
  inspect(flush.length(), content="4")
  inspect(flush[0], content="b'\\x30'")
  inspect(flush[1], content="b'\\x30'")
  inspect(flush[2], content="b'\\x30'")
  inspect(flush[3], content="b'\\x30'")
}

///|
test "git compat: pktline delim" {
  // Delimiter packet: 0001
  let delim = pktline_delim()
  inspect(delim.length(), content="4")
  inspect(delim[0], content="b'\\x30'")
  inspect(delim[1], content="b'\\x30'")
  inspect(delim[2], content="b'\\x30'")
  inspect(delim[3], content="b'\\x31'")
}

// =============================================================================
// ObjectId Tests
// =============================================================================

///|
test "git compat: ObjectId zero" {
  let id = @git.ObjectId::zero()
  inspect(id.to_hex(), content="0000000000000000000000000000000000000000")
}

///|
test "git compat: ObjectId from_hex roundtrip" {
  let hex = "ce013625030ba8dba906f756967f9e9ca394464a"
  let id = @git.ObjectId::from_hex(hex)
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

// =============================================================================
// SHA-1 Known Values Tests
// =============================================================================

///|
test "git compat: SHA-1 empty string" {
  // SHA-1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
  let hash = sha1(Bytes::from_array([]))
  inspect(hash.to_hex(), content="da39a3ee5e6b4b0d3255bfef95601890afd80709")
}

///|
test "git compat: SHA-1 'abc'" {
  // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
  let hash = sha1(Bytes::from_array([b'a', b'b', b'c']))
  inspect(hash.to_hex(), content="a9993e364706816aba3e25717850c26c9cd0d89d")
}

///|
test "git compat: SHA-1 quick brown fox" {
  // SHA-1("The quick brown fox jumps over the lazy dog")
  // = 2fd4e1c67a2d28fced849ee1bb76e7391b93eb12
  let msg = "The quick brown fox jumps over the lazy dog"
  let data : Array[Byte] = []
  for c in msg {
    data.push(c.to_int().to_byte())
  }
  let hash = sha1(
    Bytes::from_array(FixedArray::makei(data.length(), fn(i) { data[i] })),
  )
  inspect(hash.to_hex(), content="2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
}

// =============================================================================
// Nested Tree Tests
// =============================================================================

///|
test "git compat: subtree with single file" {
  // Tree containing: world.txt -> "world\n"
  // This is the "subdir" tree in a nested structure
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entry = @git.TreeEntry::new("100644", "world.txt", world_id)
  let (tree_id, _) = create_tree([entry])
  inspect(tree_id.to_hex(), content="b032d4b998c65562e088abaa88fdd859476c089e")
}

///|
test "git compat: nested tree with subdirectory" {
  // Tree containing:
  //   hello.txt -> "hello\n"
  //   subdir/   -> tree(world.txt -> "world\n")
  // Structure:
  //   .
  //   ├── hello.txt
  //   └── subdir/
  //       └── world.txt
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let subdir_id = @git.ObjectId::from_hex(
    "b032d4b998c65562e088abaa88fdd859476c089e",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("40000", "subdir", subdir_id),
  ]
  let (tree_id, _) = create_tree(entries)
  inspect(tree_id.to_hex(), content="117040856e0066e76d38c559f9d2127fd6a10858")
}

// =============================================================================
// Commit with Parent Tests
// =============================================================================

///|
test "git compat: commit with parent" {
  // Second commit with parent
  // tree: 88e38705fdbd3608cddbe904b67c731f3234c45b (hello.txt + world.txt)
  // parent: 681226a87c4a64f59b7b47bd497af25e16ac4635 (initial commit)
  // author/committer: Test <test@example.com> 1700000100 +0000
  // message: Second commit
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let parent_id = @git.ObjectId::from_hex(
    "681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
  let commit = @git.Commit::new(
    tree_id,
    [parent_id],
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Second commit\n",
  )
  let (commit_id, _) = create_commit(commit)
  // Verified against git hash-object -t commit
  inspect(
    commit_id.to_hex(),
    content="2fe96b04b8c1f081765898435f0d2497cfef21ea",
  )
}

// =============================================================================
// Blob Integrity Tests (Binary Data)
// =============================================================================

///|
test "blob integrity: null bytes preserved" {
  // Verify null bytes are not truncated or corrupted
  let data = Bytes::from_array([b'\x00', b'a', b'\x00', b'b', b'\x00'])
  let (id, compressed) = @git.create_blob(data)
  let decompressed = @zlib.zlib_decompress(compressed)
  // Skip header "blob 5\0" (7 bytes)
  let header_len = 7
  assert_true(decompressed.length() == header_len + data.length())
  for i = 0; i < data.length(); i = i + 1 {
    assert_true(decompressed[header_len + i] == data[i])
  }
  // Verify hash is consistent
  let id2 = @git.hash_blob(data)
  assert_true(id == id2)
}

///|
test "blob integrity: high bytes (0x80-0xFF)" {
  // Verify bytes > 127 are handled correctly
  let data = Bytes::from_array([b'\x80', b'\xFF', b'\xFE', b'\xAB', b'\xCD'])
  let (id, compressed) = @git.create_blob(data)
  let decompressed = @zlib.zlib_decompress(compressed)
  let header_len = 7 // "blob 5\0"
  assert_true(decompressed.length() == header_len + data.length())
  for i = 0; i < data.length(); i = i + 1 {
    assert_true(decompressed[header_len + i] == data[i])
  }
  let id2 = @git.hash_blob(data)
  assert_true(id == id2)
}

///|
test "blob integrity: all byte values roundtrip" {
  // Create blob with all 256 possible byte values
  let data : Array[Byte] = []
  for i = 0; i < 256; i = i + 1 {
    data.push(i.to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(256, fn(i) { data[i] }))
  let (id, compressed) = @git.create_blob(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  let header_len = 9 // "blob 256\0"
  assert_true(decompressed.length() == header_len + 256)
  for i = 0; i < 256; i = i + 1 {
    assert_true(decompressed[header_len + i] == i.to_byte())
  }
  // Verify hash consistency
  let id2 = @git.hash_blob(bytes)
  assert_true(id == id2)
}

///|
test "blob integrity: single byte" {
  let data = Bytes::from_array([b'X'])
  let (id, compressed) = @git.create_blob(data)
  let decompressed = @zlib.zlib_decompress(compressed)
  let header_len = 7 // "blob 1\0"
  assert_true(decompressed.length() == header_len + 1)
  assert_true(decompressed[header_len] == b'X')
  let id2 = @git.hash_blob(data)
  assert_true(id == id2)
}

///|
test "blob integrity: 1KB binary data" {
  // Test with larger binary data
  let size = 1024
  let data : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    data.push((i % 256).to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(size, fn(i) { data[i] }))
  let (id, compressed) = @git.create_blob(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  // header: "blob 1024\0" = 10 bytes
  let header_len = 10
  assert_true(decompressed.length() == header_len + size)
  for i = 0; i < size; i = i + 1 {
    assert_true(decompressed[header_len + i] == (i % 256).to_byte())
  }
  let id2 = @git.hash_blob(bytes)
  assert_true(id == id2)
}

///|
test "blob integrity: 100KB binary data" {
  // Test with data larger than single zlib block
  let size = 100 * 1024
  let data : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    data.push((i % 256).to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(size, fn(i) { data[i] }))
  let (id, compressed) = @git.create_blob(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  // header: "blob 102400\0" = 12 bytes
  let header_len = 12
  assert_true(decompressed.length() == header_len + size)
  // Check first and last bytes
  assert_true(decompressed[header_len] == b'\x00')
  assert_true(decompressed[header_len + 255] == b'\xFF')
  assert_true(
    decompressed[header_len + size - 1] == ((size - 1) % 256).to_byte(),
  )
  let id2 = @git.hash_blob(bytes)
  assert_true(id == id2)
}

///|
test "blob integrity: zlib compress/decompress roundtrip" {
  // Test zlib roundtrip independently
  let original = Bytes::from_array([
    b'\x00', b'\x01', b'\x7F', b'\x80', b'\xFF', b'a', b'b', b'c',
  ])
  let compressed = @zlib.zlib_compress(original)
  let decompressed = @zlib.zlib_decompress(compressed)
  assert_true(decompressed.length() == original.length())
  for i = 0; i < original.length(); i = i + 1 {
    assert_true(decompressed[i] == original[i])
  }
}

///|
test "blob integrity: create_object and hash_object_content consistent" {
  // Verify create_object and hash_object_content produce same ID
  let data = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let (id1, _) = @git.create_object(@git.ObjectType::Blob, data)
  let id2 = @git.hash_object_content(@git.ObjectType::Blob, data)
  assert_true(id1 == id2)
}

///|
test "blob integrity: repeated creation yields same ID" {
  // Verify idempotency
  let data = Bytes::from_array([b't', b'e', b's', b't'])
  let (id1, _) = @git.create_blob(data)
  let (id2, _) = @git.create_blob(data)
  let (id3, _) = @git.create_blob(data)
  assert_true(id1 == id2)
  assert_true(id2 == id3)
}

// =============================================================================
// ObjectId Tests (Additional)
// =============================================================================

///|
test "ObjectId: equality for same hex" {
  let hex = "ce013625030ba8dba906f756967f9e9ca394464a"
  let id1 = @git.ObjectId::from_hex(hex)
  let id2 = @git.ObjectId::from_hex(hex)
  assert_true(id1 == id2)
}

///|
test "ObjectId: inequality for different hex" {
  let id1 = @git.ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let id2 = @git.ObjectId::from_hex("cc628ccd10742baea8241c5924df992b5c019f71")
  assert_true(id1 != id2)
}

// =============================================================================
// Git-Verified Binary Blob Hash Tests
// =============================================================================

///|
test "git compat: blob hash binary 0x00 0x01 0x7f 0x80 0xff" {
  // printf '\x00\x01\x7f\x80\xff' | git hash-object --stdin
  let data = Bytes::from_array([b'\x00', b'\x01', b'\x7F', b'\x80', b'\xFF'])
  let id = @git.hash_blob(data)
  inspect(id.to_hex(), content="3f841d7e56eef5a4d10f557d3db2228bb9948b2b")
}

///|
test "git compat: blob hash all 256 byte values" {
  // python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)))' | git hash-object --stdin
  let data : Array[Byte] = []
  for i = 0; i < 256; i = i + 1 {
    data.push(i.to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(256, fn(i) { data[i] }))
  let id = @git.hash_blob(bytes)
  inspect(id.to_hex(), content="c86626638e0bc8cf47ca49bb1525b40e9737ee64")
}

// =============================================================================
// Object Roundtrip Tests (create -> compress -> decompress -> parse -> verify)
// =============================================================================

///|
/// Helper: parse header from raw loose object format "type size\0content"
/// Returns (type_str, content_start_index)
fn parse_loose_header(raw : Bytes) -> (String, Int) {
  let type_buf = StringBuilder::new()
  let mut i = 0
  // Read type until space
  while i < raw.length() && raw[i] != b' ' {
    type_buf.write_char(raw[i].to_int().unsafe_to_char())
    i += 1
  }
  i += 1 // skip space
  // Skip size digits until null byte
  while i < raw.length() && raw[i] != b'\x00' {
    i += 1
  }
  i += 1 // skip null byte
  (type_buf.to_string(), i)
}

///|
test "roundtrip: binary blob create -> compress -> decompress" {
  // Create blob with binary data including null bytes and high bytes
  let original = Bytes::from_array([
    b'\x00', b'\x01', b'\x7F', b'\x80', b'\xFE', b'\xFF',
  ])
  let (expected_id, compressed) = @git.create_blob(original)

  // Decompress
  let raw = @zlib.zlib_decompress(compressed)

  // Parse header
  let (type_str, content_start) = parse_loose_header(raw)

  // Verify type
  assert_true(type_str == "blob")

  // Extract content
  let content_len = raw.length() - content_start
  assert_true(content_len == original.length())

  // Verify every byte matches original
  for i = 0; i < original.length(); i = i + 1 {
    assert_true(raw[content_start + i] == original[i])
  }

  // Verify re-hashing gives same ID
  let computed_id = @git.hash_blob(original)
  assert_true(computed_id == expected_id)
}

///|
test "roundtrip: tree create -> compress -> decompress" {
  // Create tree
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entries = [@git.TreeEntry::new("100644", "test.txt", blob_id)]
  let (expected_id, compressed) = @git.create_tree(entries)

  // Decompress
  let raw = @zlib.zlib_decompress(compressed)

  // Parse header
  let (type_str, content_start) = parse_loose_header(raw)
  assert_true(type_str == "tree")

  // Extract content
  let content_len = raw.length() - content_start
  let content = Bytes::from_array(
    FixedArray::makei(content_len, fn(i) { raw[content_start + i] }),
  )

  // Verify tree can be parsed
  let parsed_entries = @git.parse_tree(content)
  assert_true(parsed_entries.length() == 1)
  assert_true(parsed_entries[0].name == "test.txt")
  assert_true(parsed_entries[0].mode == "100644")
  assert_true(parsed_entries[0].id == blob_id)

  // Verify re-hashing gives same ID
  let computed_id = @git.hash_object_content(@git.ObjectType::Tree, content)
  assert_true(computed_id == expected_id)
}

///|
test "roundtrip: commit create -> compress -> decompress" {
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let commit = @git.Commit::new(
    tree_id,
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test commit\n",
  )
  let (expected_id, compressed) = @git.create_commit(commit)

  // Decompress
  let raw = @zlib.zlib_decompress(compressed)

  // Parse header
  let (type_str, content_start) = parse_loose_header(raw)
  assert_true(type_str == "commit")

  // Extract content
  let content_len = raw.length() - content_start
  let content = Bytes::from_array(
    FixedArray::makei(content_len, fn(i) { raw[content_start + i] }),
  )

  // Verify commit can be parsed
  let parsed = @git.parse_commit(content)
  assert_true(parsed.tree == tree_id)
  assert_true(parsed.parents.length() == 0)

  // Verify re-hashing gives same ID
  let computed_id = @git.hash_object_content(@git.ObjectType::Commit, content)
  assert_true(computed_id == expected_id)
}
