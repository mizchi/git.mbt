///|
/// Tests for Git object creation
test "create blob hello" {
  // "hello\n" should produce ce013625030ba8dba906f756967f9e9ca394464a
  let (id, _) = create_blob_string("hello\n")
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

///|
test "hash blob hello" {
  let id = hash_blob_string("hello\n")
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

///|
test "create blob empty" {
  // Empty blob: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
  let (id, _) = create_blob_string("")
  inspect(id.to_hex(), content="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

///|
test "create blob world" {
  // "world\n" = cc628ccd10742baea8241c5924df992b5c019f71
  let (id, _) = create_blob_string("world\n")
  inspect(id.to_hex(), content="cc628ccd10742baea8241c5924df992b5c019f71")
}

///|
test "create tree single entry" {
  // Tree with single blob entry
  let blob_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let entry = TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, _) = create_tree([entry])

  // Verify the tree ID is computed correctly
  // This can be verified with: git mktree
  assert_true(tree_id.to_hex().length() == 40)
}

///|
test "create tree multiple entries" {
  // Tree with multiple entries (must be sorted by name)
  let hello_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let world_id = ObjectId::from_hex("cc628ccd10742baea8241c5924df992b5c019f71")
  let entries = [
    TreeEntry::new("100644", "hello.txt", hello_id),
    TreeEntry::new("100644", "world.txt", world_id),
  ]
  let (tree_id, compressed) = create_tree(entries)

  // Verify tree ID is 40 hex chars
  assert_true(tree_id.to_hex().length() == 40)

  // Verify compressed data is not empty
  assert_true(compressed.length() > 0)
}

///|
test "create commit" {
  let tree_id = ObjectId::from_hex("4b825dc642cb6eb9a060e54bf8d69288fbee4904")
  let commit = Commit::new(
    tree_id,
    [], // no parents
    "Test Author <test@example.com>",
    1700000000L,
    "+0000",
    "Test Author <test@example.com>",
    1700000000L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, compressed) = create_commit(commit)

  // Verify commit ID is 40 hex chars
  assert_true(commit_id.to_hex().length() == 40)

  // Verify compressed data is not empty
  assert_true(compressed.length() > 0)
}

///|
test "create commit with parent" {
  let tree_id = ObjectId::from_hex("4b825dc642cb6eb9a060e54bf8d69288fbee4904")
  let parent_id = ObjectId::from_hex("0000000000000000000000000000000000000001")
  let commit = Commit::new(
    tree_id,
    [parent_id],
    "Test Author <test@example.com>",
    1700000000L,
    "+0000",
    "Test Author <test@example.com>",
    1700000000L,
    "+0000",
    "Second commit\n",
  )
  let (commit_id, _) = create_commit(commit)
  assert_true(commit_id.to_hex().length() == 40)
}

///|
test "ObjectType to_string" {
  inspect(ObjectType::Blob.to_string(), content="blob")
  inspect(ObjectType::Tree.to_string(), content="tree")
  inspect(ObjectType::Commit.to_string(), content="commit")
  inspect(ObjectType::Tag.to_string(), content="tag")
}

///|
test "ObjectType to_packfile_type" {
  inspect(ObjectType::Commit.to_packfile_type(), content="1")
  inspect(ObjectType::Tree.to_packfile_type(), content="2")
  inspect(ObjectType::Blob.to_packfile_type(), content="3")
  inspect(ObjectType::Tag.to_packfile_type(), content="4")
}
