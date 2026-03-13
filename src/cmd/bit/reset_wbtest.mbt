///|
test "reset normalize path strips leading and trailing separators" {
  assert_eq(reset_normalize_path("init/"), "init")
  assert_eq(reset_normalize_path("./init/"), "init")
  assert_eq(reset_normalize_path("./init"), "init")
}

///|
async fn reset_wbtest_git_exit_code(
  cwd : String,
  args : Array[String],
) -> Int raise Error {
  let (code, _, _) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd~,
  )
  code
}

///|
async test "reset pathspec: trailing slash unstages submodule gitlink" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-reset-submodule-trailing-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  add_test_run_git(init_dir, ["config", "user.name", "Test User"])
  add_test_run_git(init_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(init_dir + "/a", "a\n")
  add_test_run_git(init_dir, ["add", "a"])
  add_test_run_git(init_dir, ["commit", "-q", "-m", "initial"])

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "super"])
  add_test_run_git(super_dir, ["config", "user.name", "Test User"])
  add_test_run_git(super_dir, ["config", "user.email", "test@example.com"])
  add_test_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  add_test_run_git(super_dir, ["commit", "-qam", "initial"])
  add_test_run_git(super_dir + "/init", ["config", "user.name", "Test User"])
  add_test_run_git(super_dir + "/init", [
    "config", "user.email", "test@example.com",
  ])

  fs.write_string(super_dir + "/init/a", "b\n")
  add_test_run_git(super_dir + "/init", ["commit", "-m", "update a", "a"])
  add_test_run_git(super_dir, ["add", "init/"])

  let diff_before = reset_wbtest_git_exit_code(super_dir, [
    "diff", "--exit-code", "--cached", "init",
  ])
  assert_eq(diff_before, 1)

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", super_dir)
  @sys.set_env_var("GIT_SHIM_PWD", super_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_reset(["init/"])

  let diff_after = reset_wbtest_git_exit_code(super_dir, [
    "diff", "--exit-code", "--cached", "init",
  ])
  assert_eq(diff_after, 0)

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  add_test_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
  cleanup_tree(fs, root)
}

///|
async test "reset: hard restores a valid root cache-tree for indexed-object negation" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-reset-hard-indexed-objects-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  add_test_run_git(repo_dir, ["add", "one", "two/three"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "that"])
  add_test_run_git(repo_dir, ["commit", "--allow-empty", "-q", "-m", "another"])
  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  add_test_run_git(repo_dir, ["add", "only-in-index"])

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_reset(["-q", "--hard", "HEAD"])

  let head = add_test_trim_trailing_newline(
    add_test_git_stdout(repo_dir, ["rev-parse", "HEAD"]),
  )
  let actual = add_test_trim_trailing_newline(
    add_test_git_stdout(repo_dir, [
      "rev-list", "-1", "--objects", "HEAD", "--not", "--indexed-objects",
    ]),
  )
  assert_eq(actual, head)

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}
