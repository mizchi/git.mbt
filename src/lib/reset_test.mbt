///| Tests for reset

///|
fn setup_repo_reset() -> @bit.TestFs {
  let fs = @bit.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs
}

///|
test "reset: hard to previous commit" {
  let fs = setup_repo_reset()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <t@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "two\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <t@example.com>", 1700000001L),
  )
  let target = reset(fs, fs, "/repo", first.to_hex(), ResetMode::Hard)
  assert_true(target == first)
  let content = fs.read_string("/repo/a.txt")
  assert_true(content == "one\n")
  let ref_text = fs.read_string("/repo/.git/refs/heads/main")
  assert_true(ref_text.contains(first.to_hex()))
  let reflog = read_reflog(fs, "/repo/.git", "refs/heads/main")
  assert_eq(reflog.length(), 3)
  assert_eq(reflog[2].message, "reset: moving to " + first.to_hex())
}

///|
test "reset: soft keeps worktree" {
  let fs = setup_repo_reset()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <t@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "two\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <t@example.com>", 1700000001L),
  )
  ignore(reset(fs, fs, "/repo", first.to_hex(), ResetMode::Soft))
  let content = fs.read_string("/repo/a.txt")
  assert_true(content == "two\n")
}

///|
test "reset: mixed keeps worktree" {
  let fs = setup_repo_reset()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <t@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "two\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <t@example.com>", 1700000001L),
  )
  ignore(reset(fs, fs, "/repo", first.to_hex(), ResetMode::Mixed))
  let content = fs.read_string("/repo/a.txt")
  assert_true(content == "two\n")
}

///|
test "reset: hard preserves initialized submodule worktree state" {
  let fs = setup_repo_reset()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "initial\n", "Test <t@example.com>", 1700000100L),
  )

  init_repo_with_options(fs, "/repo/vendor/sub", {
    default_branch: "main",
    bare: false,
    separate_git_dir: Some("/repo/.git/modules/example"),
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
    is_reinit: false,
    git_dir: None,
    work_tree: Some("/repo/vendor/sub"),
    shared: None,
  })
  fs.write_string("/repo/vendor/sub/a", "sub\n")
  add_paths(fs, fs, "/repo/vendor/sub", ["a"])
  let submodule_first = commit(
    fs, fs, "/repo/vendor/sub", "sub-1\n", "Test <t@example.com>", 1700000101L,
  )

  fs.write_string(
    "/repo/.gitmodules", "[submodule \"example\"]\n\tpath = vendor/sub\n\turl = ../example\n",
  )
  add_paths(fs, fs, "/repo", [".gitmodules"])
  let entries = read_index_entries(fs, "/repo/.git")
  entries.push(IndexEntry::new("vendor/sub", submodule_first, 0o160000, 0))
  write_index_entries(fs, "/repo/.git", entries)
  let with_submodule = commit(
    fs, fs, "/repo", "with-submodule\n", "Test <t@example.com>", 1700000102L,
  )

  fs.write_string("/repo/vendor/sub/b", "change\n")
  add_paths(fs, fs, "/repo/vendor/sub", ["b"])
  let submodule_second = commit(
    fs, fs, "/repo/vendor/sub", "sub-2\n", "Test <t@example.com>", 1700000103L,
  )
  let head_before_reset = fs.read_string("/repo/.git/modules/example/HEAD")

  ignore(reset(fs, fs, "/repo", with_submodule.to_hex(), ResetMode::Hard))

  assert_eq(
    fs.read_string("/repo/.git/modules/example/HEAD"),
    head_before_reset,
  )
  assert_eq(
    resolve_head_commit(fs, "/repo/.git/modules/example"),
    Some(submodule_second),
  )
  assert_true(fs.is_file("/repo/vendor/sub/b"))
}

///|
test "reset: hard replaces directory path with file from target commit" {
  let fs = setup_repo_reset()
  fs.mkdir_p("/repo/folder1/0/0")
  fs.write_string("/repo/folder1/0/0/0", "nested\n")
  add_paths(fs, fs, "/repo", ["folder1/0/0/0"])
  let dir_commit = commit(
    fs, fs, "/repo", "dir\n", "Test <t@example.com>", 1700000200L,
  )

  rm_paths(fs, fs, "/repo", ["folder1/0/0/0"])
  fs.write_string("/repo/folder1/0/0", "file\n")
  add_paths(fs, fs, "/repo", ["folder1/0/0"])
  let file_commit = commit(
    fs, fs, "/repo", "file\n", "Test <t@example.com>", 1700000201L,
  )

  ignore(checkout(fs, fs, "/repo", dir_commit.to_hex()))
  assert_true(fs.is_dir("/repo/folder1/0/0"))

  let target = reset(fs, fs, "/repo", file_commit.to_hex(), ResetMode::Hard)
  assert_true(target == file_commit)
  assert_true(fs.is_file("/repo/folder1/0/0"))
  assert_eq(fs.read_string("/repo/folder1/0/0"), "file\n")
}
