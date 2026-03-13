///|
let switch_wbtest_shim_lock : @async.Semaphore = @async.Semaphore::new(
  1,
  initial_value=1,
)

///|
async fn switch_wbtest_run_shim_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  switch_wbtest_shim_lock.acquire()
  defer switch_wbtest_shim_lock.release()
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = "/tmp/bit-switch-shim-moon.sh"
  let target_dir = "/tmp/bit-switch-shim-target"
  let fs = OsFs::new()
  fs.write_string(
    shim_moon,
    "#!/bin/sh\nset -eu\ncd '\{repo_root}'\nexec moon run --target native --target-dir '\{target_dir}' src/cmd/bit -- \"$@\"\n",
  )
  let chmod_code = @process.run("chmod", ["+x", shim_moon], inherit_env=true)
  assert_eq(chmod_code, 0)
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": repo_root + "/third_party/git/git",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": shim_moon,
    "SHIM_CMDS": "switch rm",
    "SHIM_STRICT": "1",
  }
  let git_args : Array[String] = ["-C", cwd]
  for arg in args {
    git_args.push(arg)
  }
  let (code, _stdout, stderr) = @process.collect_output(
    shim_git,
    git_args[:],
    extra_env=env,
    inherit_env=true,
  )
  assert_eq(code, 0)
  let stderr_text = stderr.text() catch { _ => "" }
  assert_eq(stderr_text, "")
}

///|
async fn switch_wbtest_case_tracking_config_uses_short_branch_names() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-switch-tracking-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  add_test_run_git(repo_dir, ["branch", "foo"])
  add_test_run_git(repo_dir, ["config", "branch.foo.remote", "origin"])
  add_test_run_git(repo_dir, ["config", "branch.foo.merge", "refs/heads/foo"])

  switch_apply_tracking_config(
    fs,
    fs,
    git_dir,
    "refs/heads/foo2",
    Some("foo"),
    Some("inherit"),
  )
  switch_apply_tracking_config(
    fs,
    fs,
    git_dir,
    "refs/heads/foo4",
    Some("foo"),
    Some("direct"),
  )

  let (_, branches) = @bitlib.read_repo_config(fs, git_dir)
  match branches.get("foo2") {
    Some(cfg) => {
      assert_eq(cfg.remote, Some("origin"))
      assert_eq(cfg.merges, ["refs/heads/foo"])
    }
    None => fail("expected inherited tracking config for foo2")
  }
  match branches.get("foo4") {
    Some(cfg) => {
      assert_eq(cfg.remote, Some("."))
      assert_eq(cfg.merges, ["refs/heads/foo"])
    }
    None => fail("expected direct tracking config for foo4")
  }
  assert_true(branches.get("refs/heads/foo2") is None)
  assert_true(branches.get("refs/heads/foo4") is None)

  cleanup_tree(fs, root)
}

///|
async fn switch_wbtest_case_branch_in_use_path_accepts_full_ref() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-switch-branch-in-use-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let linked_dir = repo_dir + "/wt1"

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  add_test_run_git(repo_dir, ["checkout", "-q", "-b", "shared"])
  fs.write_string(repo_dir + "/init.t", "shared\n")
  add_test_run_git(repo_dir, ["commit", "-qam", "shared"])
  add_test_run_git(repo_dir, ["worktree", "add", "-f", "wt1", "shared"])
  add_test_run_git(linked_dir, ["checkout", "--detach", "-q", "HEAD"])
  let expected_repo = add_test_git_stdout(repo_dir, [
      "rev-parse", "--show-toplevel",
    ])
    |> add_test_trim_trailing_newline

  assert_eq(
    switch_branch_in_use_path(fs, linked_dir, "refs/heads/shared"),
    Some(expected_repo),
  )

  cleanup_tree(fs, root)
}

///|
async fn switch_wbtest_case_orphan_preserves_index_entries() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-switch-orphan-index-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  switch_wbtest_run_shim_git(repo_dir, ["switch", "-q", "--orphan", "unborn"])

  let entries = @bitlib.read_index_entries(fs, git_dir)
  assert_true(entries.length() > 0)
  cleanup_tree(fs, root)
}

///|
async fn switch_wbtest_case_orphan_allows_cached_rm() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-switch-orphan-cached-rm-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  switch_wbtest_run_shim_git(repo_dir, ["switch", "-q", "--orphan", "unborn"])
  switch_wbtest_run_shim_git(repo_dir, ["rm", "-q", "--cached", "-r", "."])

  assert_eq(add_test_git_stdout(repo_dir, ["ls-files"]), "")
  assert_true(fs.is_file(repo_dir + "/init.t"))
  cleanup_tree(fs, root)
}

///|
async fn switch_wbtest_case_create_branch_in_unborn_repo_keeps_ref_unborn() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-switch-unborn-create-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])

  switch_wbtest_run_shim_git(repo_dir, ["switch", "-q", "-c", "topic"])

  assert_eq(
    decode_bytes(fs.read_file(git_dir + "/HEAD")),
    "ref: refs/heads/topic\n",
  )
  assert_true(not(fs.is_file(git_dir + "/refs/heads/topic")))

  fs.write_string(repo_dir + "/topic.t", "topic\n")
  add_test_run_git(repo_dir, ["add", "topic.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "topic"])

  assert_eq(
    add_test_git_stdout(repo_dir, ["rev-parse", "--abbrev-ref", "HEAD"])
    |> add_test_trim_trailing_newline,
    "topic",
  )

  cleanup_tree(fs, root)
}

///|
async test "switch: helper cases stay compatible" {
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  switch_wbtest_case_tracking_config_uses_short_branch_names()
  switch_wbtest_case_branch_in_use_path_accepts_full_ref()
  switch_wbtest_case_orphan_preserves_index_entries()
  switch_wbtest_case_orphan_allows_cached_rm()
  switch_wbtest_case_create_branch_in_unborn_repo_keeps_ref_unborn()
}
