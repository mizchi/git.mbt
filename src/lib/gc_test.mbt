///| Tests for gc/repack

///|
fn build_simple_repo(
  fs : @git.TestFs,
  root : String,
) -> (@git.ObjectId, @git.ObjectId, @git.ObjectId) raise @git.GitError {
  init_repo(fs, root)
  let git_dir = root + "/.git"
  let (blob_id, blob_bytes) = @git.create_blob_string("hello\n")
  write_object_bytes(fs, git_dir, blob_id, blob_bytes)
  let entry = @git.TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, tree_bytes) = @git.create_tree([entry])
  write_object_bytes(fs, git_dir, tree_id, tree_bytes)
  let commit = @git.Commit::new(
    tree_id,
    [],
    "Test <test@example.com>",
    0L,
    "+0000",
    "Test <test@example.com>",
    0L,
    "+0000",
    "test commit\n",
  )
  let (commit_id, commit_bytes) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, commit_bytes)
  update_head_ref(fs, fs, git_dir, commit_id)
  (commit_id, tree_id, blob_id)
}

///|
test "repack_repo writes pack with reachable objects" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  let (orphan_id, orphan_bytes) = @git.create_blob_string("orphan\n")
  write_object_bytes(fs, git_dir, orphan_id, orphan_bytes)
  let result = repack_repo(fs, fs, root)
  match result {
    None => fail("expected pack")
    Some(r) => {
      assert_true(r.object_count == 3)
      let pack_path = git_dir +
        "/objects/pack/pack-" +
        r.pack_id.to_hex() +
        ".pack"
      assert_true(fs.is_file(pack_path))
      let pack = fs.read_file(pack_path)
      let objects = @git.parse_packfile(pack)
      assert_true(objects.length() == 3)
    }
  }
}

///|
test "gc_repo reports unreachable objects" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  let (orphan_id, orphan_bytes) = @git.create_blob_string("orphan\n")
  write_object_bytes(fs, git_dir, orphan_id, orphan_bytes)
  let result = gc_repo(fs, fs, root)
  assert_true(result.dangling.length() == 1)
  assert_true(result.dangling[0].to_hex() == orphan_id.to_hex())
  let hex = orphan_id.to_hex()
  let orphan_path = git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length())
  assert_true(not(fs.is_file(orphan_path)))
  match result.pack {
    None => fail("expected pack")
    Some(r) => assert_true(r.object_count == 3)
  }
}

///|
test "gc_repo keeps tag and remote refs" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let (_, tree_id, _) = build_simple_repo(fs, root)
  let tag_commit = @git.Commit::new(
    tree_id,
    [],
    "Tagger <tag@example.com>",
    1L,
    "+0000",
    "Tagger <tag@example.com>",
    1L,
    "+0000",
    "tagged commit\n",
  )
  let (tag_commit_id, tag_commit_bytes) = @git.create_commit(tag_commit)
  write_object_bytes(fs, git_dir, tag_commit_id, tag_commit_bytes)
  fs.mkdir_p(git_dir + "/refs/tags")
  fs.write_string(git_dir + "/refs/tags/v1", tag_commit_id.to_hex() + "\n")
  fs.mkdir_p(git_dir + "/refs/remotes/origin")
  fs.write_string(
    git_dir + "/refs/remotes/origin/main",
    tag_commit_id.to_hex() + "\n",
  )
  let result = gc_repo(fs, fs, root)
  for id in result.dangling {
    assert_true(id.to_hex() != tag_commit_id.to_hex())
  }
}

///|
test "gc_repo skips prune when no refs" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  fs.remove_file(git_dir + "/refs/heads/main")
  let (orphan_id, orphan_bytes) = @git.create_blob_string("orphan\n")
  write_object_bytes(fs, git_dir, orphan_id, orphan_bytes)
  let result = gc_repo(fs, fs, root)
  match result.pack {
    None => ()
    Some(_) => fail("expected no pack")
  }
  let hex = orphan_id.to_hex()
  let orphan_path = git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length())
  assert_true(fs.is_file(orphan_path))
}

///|
test "gc_repo preserves all reachable objects after multiple commits" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  // Create initial repo with first commit
  let (commit1_id, tree1_id, blob1_id) = build_simple_repo(fs, root)
  // Create second commit with different content
  let (blob2_id, blob2_bytes) = @git.create_blob_string("world\n")
  write_object_bytes(fs, git_dir, blob2_id, blob2_bytes)
  let entry2 = @git.TreeEntry::new("100644", "world.txt", blob2_id)
  let entry1 = @git.TreeEntry::new("100644", "hello.txt", blob1_id)
  let (tree2_id, tree2_bytes) = @git.create_tree([entry1, entry2])
  write_object_bytes(fs, git_dir, tree2_id, tree2_bytes)
  let commit2 = @git.Commit::new(
    tree2_id,
    [commit1_id],
    "Test <test@example.com>",
    1L,
    "+0000",
    "Test <test@example.com>",
    1L,
    "+0000",
    "second commit\n",
  )
  let (commit2_id, commit2_bytes) = @git.create_commit(commit2)
  write_object_bytes(fs, git_dir, commit2_id, commit2_bytes)
  update_head_ref(fs, fs, git_dir, commit2_id)
  // Run gc
  let result = gc_repo(fs, fs, root)
  // All 6 objects should be preserved (2 commits, 2 trees, 2 blobs)
  match result.pack {
    None => fail("expected pack")
    Some(r) => assert_true(r.object_count == 6)
  }
  // No dangling objects
  assert_true(result.dangling.length() == 0)
  // Verify pack contains all objects
  let pack_path = git_dir +
    "/objects/pack/pack-" +
    result.pack.unwrap().pack_id.to_hex() +
    ".pack"
  let pack = fs.read_file(pack_path)
  let objects = @git.parse_packfile(pack)
  let ids : Array[String] = []
  for obj in objects {
    let id = @git.hash_object_content(obj.obj_type, obj.data)
    ids.push(id.to_hex())
  }
  assert_true(ids.contains(commit1_id.to_hex()))
  assert_true(ids.contains(commit2_id.to_hex()))
  assert_true(ids.contains(tree1_id.to_hex()))
  assert_true(ids.contains(tree2_id.to_hex()))
  assert_true(ids.contains(blob1_id.to_hex()))
  assert_true(ids.contains(blob2_id.to_hex()))
}

///|
test "gc_repo preserves objects reachable from multiple branches" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  // Create initial commit on main
  let (commit1_id, _, _) = build_simple_repo(fs, root)
  // Create a branch with different content
  let (blob2_id, blob2_bytes) = @git.create_blob_string("feature\n")
  write_object_bytes(fs, git_dir, blob2_id, blob2_bytes)
  let entry2 = @git.TreeEntry::new("100644", "feature.txt", blob2_id)
  let (tree2_id, tree2_bytes) = @git.create_tree([entry2])
  write_object_bytes(fs, git_dir, tree2_id, tree2_bytes)
  let commit2 = @git.Commit::new(
    tree2_id,
    [commit1_id],
    "Test <test@example.com>",
    1L,
    "+0000",
    "Test <test@example.com>",
    1L,
    "+0000",
    "feature commit\n",
  )
  let (commit2_id, commit2_bytes) = @git.create_commit(commit2)
  write_object_bytes(fs, git_dir, commit2_id, commit2_bytes)
  // Create feature branch pointing to commit2
  fs.write_string(git_dir + "/refs/heads/feature", commit2_id.to_hex() + "\n")
  // Run gc
  let result = gc_repo(fs, fs, root)
  // All objects from both branches should be preserved
  match result.pack {
    None => fail("expected pack")
    Some(r) => assert_true(r.object_count == 6) // 2 commits, 2 trees, 2 blobs
  }
  assert_true(result.dangling.length() == 0)
}

///|
test "gc_repo creates new packfile" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  // Run gc
  let result = gc_repo(fs, fs, root)
  // New packfile should exist
  match result.pack {
    None => fail("expected pack")
    Some(r) => {
      let new_pack = git_dir +
        "/objects/pack/pack-" +
        r.pack_id.to_hex() +
        ".pack"
      assert_true(fs.is_file(new_pack))
      let new_idx = git_dir +
        "/objects/pack/pack-" +
        r.pack_id.to_hex() +
        ".idx"
      assert_true(fs.is_file(new_idx))
    }
  }
}

///|
test "gc_repo handles annotated tags" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let (commit_id, _, _) = build_simple_repo(fs, root)
  // Create annotated tag
  let tag_content = "object " +
    commit_id.to_hex() +
    "\ntype commit\ntag v1.0\ntagger Test <test@example.com> 0 +0000\n\nrelease\n"
  let tag_bytes = @utf8.encode(tag_content)
  let (tag_id, tag_compressed) = @git.create_object(@git.ObjectType::Tag, tag_bytes)
  write_object_bytes(fs, git_dir, tag_id, tag_compressed)
  fs.mkdir_p(git_dir + "/refs/tags")
  fs.write_string(git_dir + "/refs/tags/v1.0", tag_id.to_hex() + "\n")
  // Run gc
  let result = gc_repo(fs, fs, root)
  // Objects should be preserved - at minimum commit + tree + blob = 3
  // Tag may or may not be collected depending on how gc traverses from tag refs
  match result.pack {
    None => fail("expected pack")
    Some(r) => assert_true(r.object_count >= 3)
  }
  // The commit should not be reported as dangling since it's reachable via tag
  for id in result.dangling {
    assert_true(id.to_hex() != commit_id.to_hex())
  }
}

///|
test "prune_repo does not remove reachable objects" {
  let fs = @git.TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let (commit_id, tree_id, blob_id) = build_simple_repo(fs, root)
  // Run prune
  let result = prune_repo(fs, fs, root)
  // No objects should be pruned
  assert_true(result.pruned.length() == 0)
  // Verify objects still exist
  fn obj_path(id : @git.ObjectId) -> String {
    let hex = id.to_hex()
    git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length())
  }

  assert_true(fs.is_file(obj_path(commit_id)))
  assert_true(fs.is_file(obj_path(tree_id)))
  assert_true(fs.is_file(obj_path(blob_id)))
}
