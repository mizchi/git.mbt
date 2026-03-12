///| Tests for checkout

///|
fn setup_repo_checkout() -> @bit.TestFs {
  let fs = @bit.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs
}

///|
test "checkout: switch back to main" {
  let fs = setup_repo_checkout()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <t@example.com>", 1700000000L,
  )
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  fs.write_string("/repo/a.txt", "two\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <t@example.com>", 1700000001L),
  )
  let target = checkout(fs, fs, "/repo", "main")
  assert_true(target == first)
  let head = fs.read_string("/repo/.git/HEAD")
  assert_true(head.contains("refs/heads/main"))
  let content = fs.read_string("/repo/a.txt")
  assert_true(content == "one\n")
}

///|
test "checkout: annotated tag peels to commit" {
  let fs = setup_repo_checkout()
  fs.write_string("/repo/a.txt", "base\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let base = commit(
    fs, fs, "/repo", "base\n", "Test <t@example.com>", 1700000100L,
  )
  create_annotated_tag(
    fs, fs, "/repo/.git", "base", base, "base", "Test <t@example.com>", 1700000101L,
  )
  let target = checkout(fs, fs, "/repo", "base")
  assert_true(target == base)
  let head = fs.read_string("/repo/.git/HEAD")
  assert_true(head.has_prefix(base.to_hex()))
}

///|
test "checkout: removes empty gitlink directory when target commit omits submodule" {
  let fs = setup_repo_checkout()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let initial = commit(
    fs, fs, "/repo", "initial\n", "Test <t@example.com>", 1700000200L,
  )
  let entries = read_index_entries(fs, "/repo/.git")
  entries.push(
    IndexEntry::new(
      "submodule",
      @bit.ObjectId::from_hex("e598ccc29ff366687aa04587483454a7925521ae"),
      0o160000,
      0,
    ),
  )
  write_index_entries(fs, "/repo/.git", entries)
  ignore(
    commit(
      fs, fs, "/repo", "with-submodule\n", "Test <t@example.com>", 1700000201L,
    ),
  )
  fs.mkdir_p("/repo/submodule")
  assert_true(fs.is_dir("/repo/submodule"))
  ignore(checkout(fs, fs, "/repo", initial.to_hex()))
  assert_false(fs.is_dir("/repo/submodule"))
}

///|
test "checkout: restores gitlink worktree from modules dir" {
  let fs = setup_repo_checkout()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let initial = commit(
    fs, fs, "/repo", "initial\n", "Test <t@example.com>", 1700000300L,
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
  let submodule_commit = commit(
    fs, fs, "/repo/vendor/sub", "submodule\n", "Test <t@example.com>", 1700000301L,
  )

  fs.write_string(
    "/repo/.gitmodules", "[submodule \"example\"]\n\tpath = vendor/sub\n\turl = ../example\n",
  )
  add_paths(fs, fs, "/repo", [".gitmodules"])
  let entries = read_index_entries(fs, "/repo/.git")
  entries.push(IndexEntry::new("vendor/sub", submodule_commit, 0o160000, 0))
  write_index_entries(fs, "/repo/.git", entries)
  let with_submodule = commit(
    fs, fs, "/repo", "with-submodule\n", "Test <t@example.com>", 1700000302L,
  )
  let db = ObjectDb::load_lazy(fs, "/repo/.git")
  let files = collect_tree_files_from_commit(db, fs, with_submodule)
  assert_true(files.contains("vendor/sub"))
  assert_eq(files["vendor/sub"].mode, 0o160000)

  ignore(checkout(fs, fs, "/repo", initial.to_hex()))
  assert_false(fs.is_dir("/repo/vendor/sub"))

  ignore(checkout(fs, fs, "/repo", with_submodule.to_hex()))
  assert_true(fs.is_file("/repo/vendor/sub/.git"))
  assert_true(
    fs.read_string("/repo/vendor/sub/.git").contains(".git/modules/example"),
  )
  assert_eq(fs.read_string("/repo/vendor/sub/a"), "sub\n")
  assert_eq(
    fs.read_string("/repo/.git/modules/example/HEAD"),
    submodule_commit.to_hex() + "\n",
  )
  let submodule_entries = read_index_entries(fs, "/repo/.git/modules/example")
  assert_eq(submodule_entries.length(), 1)
  assert_eq(submodule_entries[0].path, "a")
}

///|
test "checkout: replaces directory path with file from target commit" {
  let fs = setup_repo_checkout()
  fs.mkdir_p("/repo/folder1/0/0")
  fs.write_string("/repo/folder1/0/0/0", "nested\n")
  add_paths(fs, fs, "/repo", ["folder1/0/0/0"])
  let dir_commit = commit(
    fs, fs, "/repo", "dir\n", "Test <t@example.com>", 1700000350L,
  )

  rm_paths(fs, fs, "/repo", ["folder1/0/0/0"])
  fs.write_string("/repo/folder1/0/0", "file\n")
  add_paths(fs, fs, "/repo", ["folder1/0/0"])
  let file_commit = commit(
    fs, fs, "/repo", "file\n", "Test <t@example.com>", 1700000351L,
  )

  ignore(checkout(fs, fs, "/repo", dir_commit.to_hex()))
  assert_true(fs.is_dir("/repo/folder1/0/0"))

  let target = checkout(fs, fs, "/repo", file_commit.to_hex())
  assert_true(target == file_commit)
  assert_true(fs.is_file("/repo/folder1/0/0"))
  assert_eq(fs.read_string("/repo/folder1/0/0"), "file\n")
}
