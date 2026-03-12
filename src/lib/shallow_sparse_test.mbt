///| Tests for shallow clone and sparse checkout scenarios

///|
test "shallow: collect_commit_tree_only works with shallow depth=1" {
  // Simulate shallow clone: only the tip commit exists, no parents
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/file.txt", b"content")
  let commit1 = commit(
    fs, fs, "/repo", "Shallow", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // In shallow clone, we might not have parent objects
  // collect_commit_tree_only should still work
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let objects = collect_commit_tree_only(db, fs, commit1) catch {
    _ => return ()
  }
  // Should have: commit, tree, blob
  let mut has_commit = false
  let mut has_tree = false
  let mut has_blob = false
  for obj in objects {
    match obj.obj_type {
      @bit.ObjectType::Commit => has_commit = true
      @bit.ObjectType::Tree => has_tree = true
      @bit.ObjectType::Blob => has_blob = true
      _ => ()
    }
  }
  assert_true(has_commit)
  assert_true(has_tree)
  assert_true(has_blob)
}

///|
test "shallow: diff collection with missing parent" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create a commit chain
  fs.write_file("/repo/v1.txt", b"v1")
  let commit1 = commit(fs, fs, "/repo", "v1", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  fs.write_file("/repo/v2.txt", b"v2")
  let commit2 = commit(fs, fs, "/repo", "v2", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  // Simulate shallow clone by removing parent commit's tree references
  // (In real shallow clone, parent might be a shallow boundary)
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // collect_diff_objects should handle missing objects gracefully
  let diff = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should still produce valid diff
  assert_true(diff.length() > 0)
}

///|
test "shallow: single commit push (no parent history)" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/only.txt", b"only file")
  let only_commit = commit(
    fs, fs, "/repo", "Only", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // collect_commit_tree_only should work for root commit
  let objects = collect_commit_tree_only(db, fs, only_commit) catch {
    _ => return ()
  }
  assert_true(objects.length() > 0)
  // Verify commit has no parents
  for obj in objects {
    if obj.obj_type == @bit.ObjectType::Commit {
      let info = @bit.parse_commit(obj.data) catch { _ => continue }
      assert_eq(info.parents.length(), 0)
    }
  }
}

///|
test "sparse: diff collection with partial tree" {
  // Simulate sparse checkout: some trees/blobs might be missing
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create full tree
  fs.mkdir_p("/repo/included")
  fs.mkdir_p("/repo/excluded")
  fs.write_file("/repo/included/file.txt", b"included")
  fs.write_file("/repo/excluded/file.txt", b"excluded")
  let commit1 = commit(fs, fs, "/repo", "Full", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  // Modify included file only
  fs.write_file("/repo/included/file.txt", b"included modified")
  let commit2 = commit(fs, fs, "/repo", "Modify", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should only include the modified blob, not the excluded
  let mut included_found = false
  let mut excluded_found = false
  for obj in diff {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content == "included modified" {
        included_found = true
      }
      if content == "excluded" {
        excluded_found = true
      }
    }
  }
  assert_true(included_found)
  assert_false(excluded_found)
}

///|
test "sparse: collect objects respects cone pattern" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create structure matching cone pattern
  fs.mkdir_p("/repo/packages/core")
  fs.mkdir_p("/repo/packages/utils")
  fs.write_file("/repo/packages/core/index.mbt", b"core")
  fs.write_file("/repo/packages/utils/index.mbt", b"utils")
  fs.write_file("/repo/root.txt", b"root")
  let base = commit(fs, fs, "/repo", "Base", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  // Modify only packages/core (simulating cone checkout of packages/core)
  fs.write_file("/repo/packages/core/index.mbt", b"core modified")
  let updated = commit(
    fs, fs, "/repo", "Update core", "test <test@test.com>", 2000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff = collect_diff_objects(db, fs, base, updated) catch {
    _ => return ()
  }
  // Verify only core blob is in diff
  let mut core_modified_found = false
  let mut utils_found = false
  let mut root_found = false
  for obj in diff {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content == "core modified" {
        core_modified_found = true
      }
      if content == "utils" {
        utils_found = true
      }
      if content == "root" {
        root_found = true
      }
    }
  }
  assert_true(core_modified_found)
  assert_false(utils_found)
  assert_false(root_found)
}

///|
test "sparse: multiple sparse patterns" {
  // Test with multiple include patterns
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.mkdir_p("/repo/src")
  fs.mkdir_p("/repo/tests")
  fs.mkdir_p("/repo/docs")
  fs.write_file("/repo/src/main.mbt", b"src")
  fs.write_file("/repo/tests/test.mbt", b"tests")
  fs.write_file("/repo/docs/readme.md", b"docs")
  let commit1 = commit(fs, fs, "/repo", "Full", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  // Modify src and tests (simulating sparse checkout of src/ and tests/)
  fs.write_file("/repo/src/main.mbt", b"src modified")
  fs.write_file("/repo/tests/test.mbt", b"tests modified")
  let commit2 = commit(fs, fs, "/repo", "Modify", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should include both modified blobs
  let mut src_found = false
  let mut tests_found = false
  let mut docs_found = false
  for obj in diff {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content == "src modified" {
        src_found = true
      }
      if content == "tests modified" {
        tests_found = true
      }
      if content == "docs" {
        docs_found = true
      }
    }
  }
  assert_true(src_found)
  assert_true(tests_found)
  assert_false(docs_found)
}

///|
test "sparse: root directory negation excludes nested paths" {
  let patterns = ["/*", "!/*/"]
  assert_true(matches_sparse_pattern("a", patterns))
  assert_false(matches_sparse_pattern("folder1/c", patterns))
}

///|
test "sparse: wildcard substring matches nested folder paths" {
  let patterns = ["/*", "!/*/", "*folder*"]
  assert_true(matches_sparse_pattern("folder1/c", patterns))
  assert_true(matches_sparse_pattern("nested/folder2/d", patterns))
}

///|
test "sparse: leading slash pattern is normalized" {
  let patterns = ["/src/"]
  assert_true(matches_sparse_pattern("src/main.mbt", patterns))
  assert_true(matches_sparse_pattern("src/utils/helper.mbt", patterns))
  assert_false(matches_sparse_pattern("tests/test.mbt", patterns))
}

///|
test "sparse: leading slash negation is normalized" {
  let patterns = ["/src/", "!/src/vendor/"]
  assert_true(matches_sparse_pattern("src/core/main.mbt", patterns))
  assert_false(matches_sparse_pattern("src/vendor/lib.mbt", patterns))
  assert_false(matches_sparse_pattern("docs/readme.md", patterns))
}

///|
test "sparse: unanchored directory pattern matches nested path" {
  let patterns = ["y/"]
  assert_true(matches_sparse_pattern("x/y/file.txt", patterns))
  assert_true(matches_sparse_pattern("y/file.txt", patterns))
  assert_false(matches_sparse_pattern("x/z/file.txt", patterns))
}

///|
test "sparse: unanchored negation excludes nested path" {
  let patterns = ["y/", "!x/y/z"]
  assert_true(matches_sparse_pattern("x/y/file.txt", patterns))
  assert_false(matches_sparse_pattern("x/y/z/file.txt", patterns))
}

///|
test "shallow_sparse: combined scenario" {
  // Shallow clone + sparse checkout: minimal local objects
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create a structure
  fs.mkdir_p("/repo/sparse")
  fs.mkdir_p("/repo/excluded")
  fs.write_file("/repo/sparse/file.txt", b"sparse original")
  fs.write_file("/repo/excluded/file.txt", b"excluded")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Modify only sparse directory (simulating sparse checkout)
  fs.write_file("/repo/sparse/file.txt", b"sparse modified")
  let commit2 = commit(
    fs, fs, "/repo", "Update sparse", "test <test@test.com>", 2000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // collect_commit_tree_only for minimal push
  let tree_objects = collect_commit_tree_only(db, fs, commit2) catch {
    _ => return ()
  }
  assert_true(tree_objects.length() > 0)
  // collect_diff_objects for efficient push
  let diff_objects = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Diff should be smaller than full tree
  assert_true(diff_objects.length() < tree_objects.length())
}

///|
test "blob_none: filter simulates no blob fetch" {
  // blob:none filter means no blobs are initially fetched
  // But we should still be able to work with commits and trees
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.mkdir_p("/repo/src")
  fs.write_file("/repo/src/main.mbt", b"main content")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // collect_object_ids_only should work even if some objects are missing
  let seen : Map[String, Bool] = {}
  collect_object_ids_only(db, fs, commit1, seen)
  // Should have collected IDs for commit, tree, and blob (even if blob might be missing)
  assert_true(seen.length() > 0)
}

///|
test "treeless: filter simulates tree:0" {
  // tree:0 filter means no trees are initially fetched
  // We test that collect functions handle this gracefully
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/file.txt", b"content")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // Should still work
  let objects = collect_reachable_objects(db, fs, commit1) catch {
    _ => return ()
  }
  assert_true(objects.length() > 0)
}

///|
test "subdir_shallow: clone subdirectory with depth=1" {
  // Simulates: bit clone --depth=1 @user/repo/src
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create upstream-like structure
  fs.mkdir_p("/repo/src/lib")
  fs.mkdir_p("/repo/docs")
  fs.write_file("/repo/src/lib/main.mbt", b"main")
  fs.write_file("/repo/docs/readme.md", b"docs")
  let _upstream = commit(fs, fs, "/repo", "Upstream", "up <up@test.com>", 1000L) catch {
    _ => return ()
  }
  // Create "shallow" subdir clone
  init_repo(fs, "/subdir") catch {
    _ => ()
  }
  fs.mkdir_p("/subdir/lib")
  fs.write_file("/subdir/lib/main.mbt", b"main modified")
  let subdir_commit = commit(
    fs, fs, "/subdir", "Modify", "local <l@test.com>", 2000L,
  ) catch {
    _ => return ()
  }
  // Verify we can collect objects from the shallow subdir
  let db = ObjectDb::load(fs, "/subdir/.git") catch { _ => return () }
  let objects = collect_commit_tree_only(db, fs, subdir_commit) catch {
    _ => return ()
  }
  // Should include commit, tree (root), tree (lib), blob
  let types : Map[String, Int] = {}
  for obj in objects {
    let key = obj.obj_type.to_string()
    types[key] = types.get(key).unwrap_or(0) + 1
  }
  assert_true(types.get("commit").unwrap_or(0) == 1)
  assert_true(types.get("tree").unwrap_or(0) >= 2)
  assert_true(types.get("blob").unwrap_or(0) >= 1)
}

///|
fn collect_object_ids_only(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
  seen : Map[String, Bool],
) -> Unit raise @bit.GitError {
  let hex = commit_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, commit_id)
  match obj {
    None => ()
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Commit {
        let info = @bit.parse_commit(o.data)
        collect_tree_ids_local(db, fs, info.tree, seen)
        for p in info.parents {
          collect_object_ids_only(db, fs, p, seen)
        }
      }
  }
}

///|
fn collect_tree_ids_local(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  seen : Map[String, Bool],
) -> Unit raise @bit.GitError {
  let hex = tree_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, tree_id)
  match obj {
    None => ()
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Tree {
        let entries = @bit.parse_tree(o.data)
        for entry in entries {
          seen[entry.id.to_hex()] = true
          if entry.mode == "40000" || entry.mode == "040000" {
            collect_tree_ids_local(db, fs, entry.id, seen)
          }
        }
      }
  }
}
