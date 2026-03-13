///|
test "add: sha256 repository requires real git fallback" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tobjectformat = sha256\n",
  )
  assert_true(add_repo_requires_real_git(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[core]\n\trepositoryformatversion = 0\n",
  )
  assert_false(add_repo_requires_real_git(fs, "/repo/.git"))
}

///|
test "add: compatobjectformat=sha256 does not require real git fallback" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha256\n",
  )
  assert_false(add_repo_requires_real_git(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha1\n",
  )
  assert_false(add_repo_requires_real_git(fs, "/repo/.git"))
}

///|
test "add: storage runtime routing only for add-all without pathspecs" {
  assert_true(add_should_use_storage_runtime(["-A"]))
  assert_true(add_should_use_storage_runtime(["--all"]))

  assert_false(add_should_use_storage_runtime(["a.txt"]))
  assert_false(add_should_use_storage_runtime(["--", "-literal"]))
  assert_false(add_should_use_storage_runtime(["-A", "a.txt"]))
  assert_false(add_should_use_storage_runtime(["--refresh"]))
  assert_false(add_should_use_storage_runtime(["-n", "a.txt"]))
}

///|
test "add: intent-to-add stages empty blob entries" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  fs.write_string("/repo/file", "hello\n")

  let staged = add_apply_intent_to_add(fs, fs, "/repo", "/repo/.git", ["file"])
  assert_eq(staged.length(), 1)
  assert_eq(staged[0], "file")

  let entries = @bitlib.read_index_entries(fs, "/repo/.git")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "file")
  assert_true(entries[0].intent_to_add)
  assert_eq(entries[0].size, 0)
  assert_eq(entries[0].id.to_hex(), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

///|
test "add: intent-to-add does not clobber existing index entries" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  fs.write_string("/repo/file", "hello\n")
  ignore(try? @bitlib.add_paths(fs, fs, "/repo", ["file"]))

  let before = @bitlib.read_index_entries(fs, "/repo/.git")
  assert_eq(before.length(), 1)
  let staged = add_apply_intent_to_add(fs, fs, "/repo", "/repo/.git", ["file"])
  assert_eq(staged.length(), 0)

  let after = @bitlib.read_index_entries(fs, "/repo/.git")
  assert_eq(after.length(), 1)
  assert_eq(after[0].id.to_hex(), before[0].id.to_hex())
  assert_false(after[0].intent_to_add)
}

///|
test "add: no-all ignores removed tracked paths" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo")
  fs.write_string("/repo/file", "hello\n")

  let filtered = add_filter_stage_paths_for_no_all(
    fs,
    "/repo",
    ["file", "gone"],
    {},
  )
  match filtered {
    Ok(paths) => {
      assert_eq(paths.length(), 1)
      assert_eq(paths[0], "file")
    }
    Err(path) => fail("unexpected missing unmerged path: \{path}")
  }
}

///|
test "add: no-all rejects removed unmerged paths" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo")
  let unmerged : Map[String, Bool] = { "gone": true }

  let filtered = add_filter_stage_paths_for_no_all(
    fs,
    "/repo",
    ["gone"],
    unmerged,
  )
  match filtered {
    Ok(_) => fail("expected missing unmerged path error")
    Err(path) => assert_eq(path, "gone")
  }
}

///|
async test "add: explicit submodule directory expands to gitlink path" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.mkdir_p("/repo/submod/.git")
  fs.write_string("/repo/submod/first.t", "first\n")

  let staged = expand_add_stage_paths(fs, "/repo", ["submod"], false)
  assert_eq(staged.length(), 1)
  assert_eq(staged[0], "submod")
}

///|
async test "add: dot expansion includes submodule gitlink path" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string("/repo/file", "root\n")
  fs.mkdir_p("/repo/submod/.git")
  fs.write_string("/repo/submod/first.t", "first\n")

  let staged = expand_add_stage_paths(fs, "/repo", ["."], false)
  assert_true(staged.contains("file"))
  assert_true(staged.contains("submod"))
  assert_false(staged.contains("submod/first.t"))
}

///|
async test "add: stages parent-relative path from subdirectory" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-add-parent-relative-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/top/sub")
  add_test_run_git(root, ["init", "-q"])
  fs.write_string(root + "/top/x", "hello\n")

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", root + "/top/sub")
  @sys.set_env_var("GIT_SHIM_PWD", root + "/top/sub")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_add(["../x"])

  let entries = @bitlib.read_index_entries(fs, root + "/.git")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "top/x")

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "add: explicit add is clean for real git diff-files" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-add-real-git-clean-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  add_test_run_git(root, ["init", "-q"])
  add_test_run_git(root, ["config", "user.name", "Test User"])
  add_test_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "initial\n")
  add_test_run_git(root, ["add", "file"])
  add_test_run_git(root, ["commit", "-q", "-m", "initial"])
  fs.write_string(root + "/file", "changed\n")

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", root)
  @sys.set_env_var("GIT_SHIM_PWD", root)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_add(["file"])

  let diff = add_test_git_stdout(root, ["diff-files", "--name-only", "file"])
  assert_eq(add_test_trim_trailing_newline(diff), "")

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "add: update from subdirectory is clean for real git diff-files" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-add-update-subdir-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/dir1")
  add_test_run_git(root, ["init", "-q"])
  add_test_run_git(root, ["config", "user.name", "Test User"])
  add_test_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/dir1/sub2", "initial\n")
  add_test_run_git(root, ["add", "dir1/sub2"])
  add_test_run_git(root, ["commit", "-q", "-m", "initial"])
  fs.write_string(root + "/dir1/sub2", "changed\n")

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", root + "/dir1")
  @sys.set_env_var("GIT_SHIM_PWD", root + "/dir1")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_add(["-u", "sub2"])

  let diff = add_test_git_stdout(root, [
    "diff-files", "--name-only", "dir1/sub2",
  ])
  assert_eq(add_test_trim_trailing_newline(diff), "")

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "add: update refreshes touched tracked files for real git diff-files" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-add-update-touch-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  add_test_run_git(root, ["init", "-q"])
  add_test_run_git(root, ["config", "user.name", "Test User"])
  add_test_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/check", "initial\n")
  add_test_run_git(root, ["add", "check"])
  add_test_run_git(root, ["commit", "-q", "-m", "initial"])
  let touch_code = @process.run(
    "sh",
    ["-c", "sleep 1 && touch check"],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(touch_code, 0)

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", root)
  @sys.set_env_var("GIT_SHIM_PWD", root)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_add(["-u"])

  let diff = add_test_git_stdout(root, ["diff-files", "--name-only", "check"])
  assert_eq(add_test_trim_trailing_newline(diff), "")

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn add_test_run_git(
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let (code, _, _) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code, 0)
}

///|
async fn add_test_git_stdout(
  root : String,
  args : Array[String],
) -> String raise Error {
  let (code, stdout, _) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code, 0)
  stdout.text() catch {
    _ => ""
  }
}

///|
fn add_test_trim_trailing_newline(s : String) -> String {
  if s.has_suffix("\n") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
fn add_test_restore_env(name : String, value : String?) -> Unit {
  match value {
    Some(v) => @sys.set_env_var(name, v)
    None => @sys.unset_env_var(name)
  }
}
