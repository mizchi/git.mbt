///|
fn rm_wbtest_entry(path : String) -> @bitlib.IndexEntry {
  let zero = @bitcore.ObjectId::new(FixedArray::make(20, b'\x00'))
  @bitlib.IndexEntry::new(path, zero, 0o100644, 0)
}

///|
test "rm pathspec: dot matches repository root entries" {
  let entries = [rm_wbtest_entry("a.txt"), rm_wbtest_entry("dir/b.txt")]
  assert_true(
    rm_collect_matching_paths(".", entries, true, "", "/").length() > 0,
  )
  assert_true(
    rm_collect_matching_paths("./", entries, true, "", "/").length() > 0,
  )
}

///|
test "rm collect target paths: dot expands to all index entries" {
  let entries = [rm_wbtest_entry("a.txt"), rm_wbtest_entry("dir/b.txt")]
  let (removed, sparse_only_specs, unmatched_specs) = rm_partition_target_paths(
    ["."],
    entries,
    true,
    false,
    [],
    false,
    false,
    "",
    "/",
  )
  assert_eq(removed.length(), 2)
  assert_true(removed.contains("a.txt"))
  assert_true(removed.contains("dir/b.txt"))
  assert_eq(sparse_only_specs, [])
  assert_eq(unmatched_specs, [])
}

///|
test "rm options: short flags can be clustered" {
  let opts = parse_rm_options(["-rfq", "."])
  assert_true(opts.recursive)
  assert_true(opts.force)
  assert_true(opts.quiet)
  assert_eq(opts.paths, ["."])
}

///|
test "rm pathspec: wildcard matches tracked entries" {
  let entries = [
    rm_wbtest_entry("a.txt"),
    rm_wbtest_entry("b.txt"),
    rm_wbtest_entry("dir/c.txt"),
  ]
  let (removed, sparse_only_specs, unmatched_specs) = rm_partition_target_paths(
    ["[ab]*"],
    entries,
    false,
    false,
    [],
    false,
    false,
    "",
    "/",
  )
  assert_eq(removed, ["a.txt", "b.txt"])
  assert_eq(sparse_only_specs, [])
  assert_eq(unmatched_specs, [])
}

///|
test "rm pathspec: leading symlink prefix blocks nested match" {
  let has_symlink = fn(path : String) { path == "/repo/d" }
  assert_true(rm_has_symlink_leading_path("d/f", "/repo", has_symlink))
  assert_false(rm_has_symlink_leading_path("d", "/repo", has_symlink))
  assert_false(rm_has_symlink_leading_path("plain/f", "/repo", has_symlink))
}

///|
test "rm sparse: dense matches win over sparse matches" {
  let entries = [rm_wbtest_entry("a"), rm_wbtest_entry("b")]
  let (target_paths, sparse_only_specs, unmatched_specs) = rm_partition_target_paths(
    ["[ab]"],
    entries,
    false,
    true,
    ["a"],
    false,
    false,
    "",
    "/repo",
  )
  assert_eq(target_paths, ["a"])
  assert_eq(sparse_only_specs, [])
  assert_eq(unmatched_specs, [])
}

///|
test "rm sparse: sparse-only pathspec is reported when --sparse is absent" {
  let entries = [rm_wbtest_entry("a"), rm_wbtest_entry("b")]
  let (target_paths, sparse_only_specs, unmatched_specs) = rm_partition_target_paths(
    ["b"],
    entries,
    false,
    true,
    ["a"],
    false,
    false,
    "",
    "/repo",
  )
  assert_eq(target_paths, [])
  assert_eq(sparse_only_specs, ["b"])
  assert_eq(unmatched_specs, [])
}

///|
test "rm sparse: --sparse allows sparse-only pathspecs" {
  let entries = [rm_wbtest_entry("a"), rm_wbtest_entry("b")]
  let (target_paths, sparse_only_specs, unmatched_specs) = rm_partition_target_paths(
    ["b"],
    entries,
    false,
    true,
    ["a"],
    true,
    false,
    "",
    "/repo",
  )
  assert_eq(target_paths, ["b"])
  assert_eq(sparse_only_specs, [])
  assert_eq(unmatched_specs, [])
}

///|
test "rm sparse: recursive pathspec removes dense entries only by default" {
  let entries = [rm_wbtest_entry("sub/d"), rm_wbtest_entry("sub/dir/e")]
  let (target_paths, sparse_only_specs, unmatched_specs) = rm_partition_target_paths(
    ["sub"],
    entries,
    true,
    true,
    ["sub/dir"],
    false,
    false,
    "",
    "/repo",
  )
  assert_eq(target_paths, ["sub/dir/e"])
  assert_eq(sparse_only_specs, [])
  assert_eq(unmatched_specs, [])
}

///|
test "rm conflict: mixed categories are sorted and keep hints" {
  let lines = rm_conflict_error_lines(["foo1.txt"], ["bar1.txt"], [], true)
  assert_eq(lines, [
    "error: the following file has staged content different from both the", "file and the HEAD:",
    "    foo1.txt", "(use -f to force removal)", "error: the following file has changes staged in the index:",
    "    bar1.txt", "(use --cached to keep the file, or -f to force removal)",
  ])
}

///|
test "rm conflict: advice.rmhints=false omits hint lines" {
  let lines = rm_conflict_error_lines([], [], ["bar.txt"], false)
  assert_eq(lines, [
    "error: the following file has local modifications:", "    bar.txt",
  ])
}

///|
async test "rm: stage-only missing submodule is removable" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rm-stage-added-submodule-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/a", "a\n")
  submodule_wbtest_run_git(source_dir, ["add", "a"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(super_dir + "/t", "t\n")
  submodule_wbtest_run_git(super_dir, ["add", "t"])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-m", "base"])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, [
    "submodule", "add", "./../source", "repo",
  ])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
  cleanup_tree(fs, super_dir + "/repo")

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", super_dir)
  @sys.set_env_var("GIT_SHIM_PWD", super_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  handle_rm(["-q", "repo"])

  let status = submodule_wbtest_git_stdout(super_dir, ["status", "--short"])
  assert_false(status.contains("repo"))
  assert_true(status.contains("A  .gitmodules"))

  submodule_wbtest_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  submodule_wbtest_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  submodule_wbtest_restore_env("GIT_DIR", prev_git_dir)
  submodule_wbtest_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "rm: orphan checkout keeps tracked files removable" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rm-orphan-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, [
    "checkout", "-q", "--orphan", "orphan1",
  ])
  handle_rm(["-q", "-rf", "."])

  assert_eq(add_test_git_stdout(repo_dir, ["ls-files"]), "")
  assert_false(fs.is_file(repo_dir + "/init.t"))

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "rm: removing named submodule clears matching gitmodules section only" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rm-named-submodule-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/a", "a\n")
  submodule_wbtest_run_git(source_dir, ["add", "a"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(super_dir + "/t", "t\n")
  submodule_wbtest_run_git(super_dir, ["add", "t"])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-m", "base"])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  handle_submodule_add(fs, super_dir, super_dir + "/.git", [
    "--quiet", "--name", "repo_new", "./../source", "repo",
  ])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-am", "add submodule"])

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", super_dir)
  @sys.set_env_var("GIT_SHIM_PWD", super_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  handle_rm(["-q", "repo"])

  let gitmodules = if fs.is_file(super_dir + "/.gitmodules") {
    decode_bytes(fs.read_file(super_dir + "/.gitmodules"))
  } else {
    ""
  }
  let config_content = decode_bytes(fs.read_file(super_dir + "/.git/config"))
  assert_false(gitmodules.contains("[submodule \"repo_new\"]"))
  assert_false(gitmodules.contains("path = repo"))
  assert_false(gitmodules.contains(normalize_path(source_dir)))
  assert_true(config_content.contains("[submodule \"repo_new\"]"))
  assert_true(config_content.contains("url = " + normalize_path(source_dir)))
  assert_false(fs.is_dir(super_dir + "/repo"))

  submodule_wbtest_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  submodule_wbtest_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  submodule_wbtest_restore_env("GIT_DIR", prev_git_dir)
  submodule_wbtest_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "rm: cached submodule removal preserves gitmodules entry" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rm-cached-submodule-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/a", "a\n")
  submodule_wbtest_run_git(source_dir, ["add", "a"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(super_dir + "/t", "t\n")
  submodule_wbtest_run_git(super_dir, ["add", "t"])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-m", "base"])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  handle_submodule_add(fs, super_dir, super_dir + "/.git", [
    "--quiet", "--name", "repo_new", "./../source", "repo",
  ])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-am", "add submodule"])

  let before_gitmodules = decode_bytes(fs.read_file(super_dir + "/.gitmodules"))

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", super_dir)
  @sys.set_env_var("GIT_SHIM_PWD", super_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  handle_rm(["-q", "--cached", "repo"])

  let after_gitmodules = decode_bytes(fs.read_file(super_dir + "/.gitmodules"))
  let tracked = submodule_wbtest_git_stdout(super_dir, ["ls-files"])
  assert_eq(after_gitmodules, before_gitmodules)
  assert_true(after_gitmodules.contains("[submodule \"repo_new\"]"))
  assert_true(after_gitmodules.contains("path = repo"))
  assert_true(fs.is_dir(super_dir + "/repo"))
  assert_false(tracked.contains("repo\n"))
  assert_true(tracked.contains(".gitmodules"))

  submodule_wbtest_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  submodule_wbtest_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  submodule_wbtest_restore_env("GIT_DIR", prev_git_dir)
  submodule_wbtest_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}
