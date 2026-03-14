///|
test "merge help is handled by merge command path" {
  assert_true(command_handles_builtin_help("merge"))
}

///|
test "split_cmdline quote validation" {
  assert_true(split_cmdline_has_unclosed_quote("echo \""))
  assert_false(split_cmdline_has_unclosed_quote("echo \\\""))
  assert_false(split_cmdline_has_unclosed_quote("--no-ff -m \"ok\""))
}

///|
test "merge: strategy options fall back to real git" {
  assert_true(merge_need_real_git(["-s", "ours", "topic"]))
  assert_true(merge_need_real_git(["--strategy=ours", "topic"]))
  assert_true(merge_need_real_git(["-Xtheirs", "topic"]))
  assert_true(merge_need_real_git(["--strategy-option=theirs", "topic"]))
  assert_true(merge_need_real_git(["--allow-unrelated-histories", "topic"]))
  assert_true(merge_need_real_git(["side", "another"]))
  assert_true(merge_need_real_git(["-m", "octopus", "side", "another"]))
  assert_false(merge_need_real_git(["--squash", "topic"]))
}

///|
let merge_wbtest_shim_lock : @async.Semaphore = @async.Semaphore::new(
  1,
  initial_value=1,
)

///|
fn merge_wbtest_safe_dir_component(path : String) -> String {
  let buf = StringBuilder::new()
  for ch in path {
    if (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') {
      buf.write_char(ch)
    } else {
      buf.write_char('_')
    }
  }
  buf.to_string()
}

///|
async fn merge_wbtest_collect_shim_git(
  cwd : String,
  args : Array[String],
) -> (Int, String, String) raise Error {
  merge_wbtest_shim_lock.acquire()
  defer merge_wbtest_shim_lock.release()
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = "/tmp/bit-merge-shim-moon.sh"
  let target_dir = "/tmp/bit-merge-shim-target-" +
    merge_wbtest_safe_dir_component(cwd)
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
    "SHIM_CMDS": "merge",
    "SHIM_STRICT": "1",
  }
  let git_args : Array[String] = ["-C", cwd]
  for arg in args {
    git_args.push(arg)
  }
  let (code, stdout, stderr) = @process.collect_output(
    shim_git,
    git_args[:],
    extra_env=env,
    inherit_env=true,
  )
  let stdout_text = stdout.text() catch { _ => "" }
  let stderr_text = stderr.text() catch { _ => "" }
  (code, stdout_text, stderr_text)
}

///|
async test "merge: command path supports strategy ours via fallback" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-merge-strategy-ours-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])

  fs.write_string(repo_dir + "/file", "base\n")
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])

  grep_test_run_git(repo_dir, ["checkout", "-q", "-b", "side"])
  fs.write_string(repo_dir + "/file", "side\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "side"])

  grep_test_run_git(repo_dir, ["checkout", "-q", "main"])
  fs.write_string(repo_dir + "/file", "main\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "main"])

  grep_test_run_git(repo_dir, [
    "merge", "-q", "-s", "ours", "-m", "ours", "side",
  ])

  assert_eq(
    trim_string(grep_test_git_stdout(repo_dir, ["log", "-1", "--format=%s"])),
    "ours",
  )
  assert_eq(decode_bytes(fs.read_file(repo_dir + "/file")), "main\n")

  cleanup_tree(fs, root)
}

///|
async test "merge: command path falls back when target is a merge commit" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-merge-merge-target-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])

  fs.write_string(repo_dir + "/file", "base\n")
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "I"])
  grep_test_run_git(repo_dir, ["tag", "I"])

  grep_test_run_git(repo_dir, ["switch", "-q", "-c", "topic"])
  fs.write_string(repo_dir + "/file", "A\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "A"])

  grep_test_run_git(repo_dir, ["switch", "-q", "-c", "branchB", "I"])
  fs.write_string(repo_dir + "/file", "B\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "B"])

  grep_test_run_git(repo_dir, ["switch", "-q", "topic"])
  let (conflict_code, _) = grep_test_git_stderr(repo_dir, [
    "merge", "-m", "M", "branchB",
  ])
  assert_true(conflict_code != 0)
  fs.write_string(repo_dir + "/file", "A\nB\n")
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "--no-edit"])
  grep_test_run_git(repo_dir, ["tag", "M"])

  fs.write_string(repo_dir + "/other", "C\n")
  grep_test_run_git(repo_dir, ["add", "other"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "C"])

  grep_test_run_git(repo_dir, ["switch", "-q", "-c", "branchY", "I"])
  fs.write_string(repo_dir + "/file", "Y\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "Y"])

  grep_test_run_git(repo_dir, ["switch", "-q", "-c", "branchR", "M"])
  grep_test_run_git(repo_dir, ["merge", "-q", "-m", "R", "-Xtheirs", "branchY"])

  grep_test_run_git(repo_dir, ["switch", "-q", "topic"])
  let (merge_code, merge_stdout, merge_stderr) = merge_wbtest_collect_shim_git(
    repo_dir,
    ["merge", "-q", "-m", "N", "branchR"],
  )
  assert_eq(merge_code, 0)
  assert_eq(merge_stdout, "")
  assert_eq(merge_stderr, "")

  assert_eq(
    trim_string(grep_test_git_stdout(repo_dir, ["log", "-1", "--format=%s"])),
    "N",
  )
  cleanup_tree(fs, root)
}

///|
async test "merge: --continue records MERGE_HEAD as second parent" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-merge-continue-parents-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])

  fs.write_string(repo_dir + "/file", "base\n")
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "I"])

  grep_test_run_git(repo_dir, ["switch", "-q", "-c", "side"])
  fs.write_string(repo_dir + "/file", "side\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "side"])

  grep_test_run_git(repo_dir, ["switch", "-q", "main"])
  fs.write_string(repo_dir + "/file", "main\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "main"])

  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  let (conflict_code, _) = grep_test_git_stderr(repo_dir, [
    "merge", "-m", "merge", "side",
  ])
  assert_true(conflict_code != 0)

  let merge_head = decode_bytes(fs.read_file(repo_dir + "/.git/MERGE_HEAD"))
    |> trim_string
  fs.write_string(repo_dir + "/file", "main\nside\n")
  grep_test_run_git(repo_dir, ["add", "file"])

  let (continue_code, continue_stdout, continue_stderr) = merge_wbtest_collect_shim_git(
    repo_dir,
    ["merge", "-q", "--continue"],
  )
  assert_eq(continue_code, 0)
  assert_eq(continue_stdout, "")
  assert_eq(continue_stderr, "")

  let git_dir = repo_dir + "/.git"
  let head = @bitlib.resolve_head_commit(fs, git_dir).unwrap()
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  let commit_obj = db.get(fs, head).unwrap()
  let info = @bitcore.parse_commit(commit_obj.data)
  assert_eq(info.parents.length(), 2)
  assert_eq(info.parents[1].to_hex(), merge_head)
  assert_false(fs.is_file(repo_dir + "/.git/MERGE_HEAD"))
  cleanup_tree(fs, root)
}

///|
async test "merge: command path supports octopus merge via fallback" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-merge-octopus-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])

  fs.write_string(repo_dir + "/base.txt", "base\n")
  grep_test_run_git(repo_dir, ["add", "base.txt"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])

  grep_test_run_git(repo_dir, ["checkout", "-q", "-b", "side"])
  fs.write_string(repo_dir + "/side.txt", "side\n")
  grep_test_run_git(repo_dir, ["add", "side.txt"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "side"])

  grep_test_run_git(repo_dir, ["checkout", "-q", "-b", "another", "main"])
  fs.write_string(repo_dir + "/another.txt", "another\n")
  grep_test_run_git(repo_dir, ["add", "another.txt"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "another"])

  grep_test_run_git(repo_dir, ["checkout", "-q", "main"])
  fs.write_string(repo_dir + "/main.txt", "main\n")
  grep_test_run_git(repo_dir, ["add", "main.txt"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  grep_test_run_git(repo_dir, [
    "merge", "-q", "-m", "octopus", "side", "another",
  ])

  let git_dir = repo_dir + "/.git"
  let head = @bitlib.resolve_head_commit(fs, git_dir).unwrap()
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  let commit_obj = db.get(fs, head).unwrap()
  let info = @bitcore.parse_commit(commit_obj.data)
  assert_eq(info.parents.length(), 3)
  assert_eq(
    trim_string(grep_test_git_stdout(repo_dir, ["log", "-1", "--format=%s"])),
    "octopus",
  )

  cleanup_tree(fs, root)
}
