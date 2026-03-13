///|
async fn restore_test_run_git(
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
async fn restore_test_git_stdout(
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
async fn restore_test_git_stderr(
  root : String,
  args : Array[String],
) -> (Int, String) raise Error {
  let (code, _, stderr) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd=root,
  )
  let text = stderr.text() catch { _ => "" }
  (code, text)
}

///|
async fn restore_test_git_output(
  root : String,
  args : Array[String],
) -> (Int, String, String) raise Error {
  let (code, stdout, stderr) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd=root,
  )
  let stdout_text = stdout.text() catch { _ => "" }
  let stderr_text = stderr.text() catch { _ => "" }
  (code, stdout_text, stderr_text)
}

///|
fn restore_test_read_string(fs : OsFs, path : String) -> String {
  decode_bytes(fs.read_file(path) catch { _ => b"" })
}

///|
async fn restore_wbtest_case_command_path_basic() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-restore-basic-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  restore_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  restore_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  restore_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/first.t", "first\n")
  restore_test_run_git(repo_dir, ["add", "first.t"])
  restore_test_run_git(repo_dir, ["commit", "-q", "-m", "first"])
  restore_test_run_git(repo_dir, ["tag", "first"])
  fs.write_string(repo_dir + "/first.t", "first\nfirst-and-a-half\n")
  restore_test_run_git(repo_dir, ["commit", "-qam", "second"])
  fs.write_string(repo_dir + "/one", "one\n")
  restore_test_run_git(repo_dir, ["add", "one"])
  restore_test_run_git(repo_dir, ["branch", "one"])

  let (missing_code, missing_stderr) = restore_test_git_stderr(repo_dir, [
    "restore",
  ])
  assert_eq(missing_code, 128)
  assert_true(missing_stderr.contains("you must specify path(s) to restore"))

  fs.write_string(repo_dir + "/one", "one\ndirty\n")
  restore_test_run_git(repo_dir, ["restore", "one"])
  assert_eq(restore_test_read_string(fs, repo_dir + "/one"), "one\n")

  let head_first = restore_test_git_stdout(repo_dir, [
    "cat-file", "blob", "HEAD:./first.t",
  ])
  let first_blob = restore_test_git_stdout(repo_dir, [
    "cat-file", "blob", "first:./first.t",
  ])
  let head_show = restore_test_git_stdout(repo_dir, ["show", "HEAD:./first.t"])
  assert_eq(head_show, head_first)

  restore_test_run_git(repo_dir, ["restore", "--source=first", "first.t"])
  assert_eq(restore_test_read_string(fs, repo_dir + "/first.t"), first_blob)
  let restored_worktree_index = restore_test_git_stdout(repo_dir, [
    "cat-file", "blob", ":./first.t",
  ])
  assert_eq(restored_worktree_index, head_first)

  restore_test_run_git(repo_dir, ["reset", "--hard", "-q"])
  restore_test_run_git(repo_dir, [
    "restore", "--source=first", "--staged", "first.t",
  ])
  let staged_only_index = restore_test_git_stdout(repo_dir, [
    "cat-file", "blob", ":./first.t",
  ])
  assert_eq(staged_only_index, first_blob)
  assert_eq(restore_test_read_string(fs, repo_dir + "/first.t"), head_first)

  restore_test_run_git(repo_dir, [
    "restore", "--source=first", "--staged", "--worktree", "first.t",
  ])
  let staged_and_worktree_index = restore_test_git_stdout(repo_dir, [
    "cat-file", "blob", ":./first.t",
  ])
  assert_eq(staged_and_worktree_index, first_blob)
  assert_eq(restore_test_read_string(fs, repo_dir + "/first.t"), first_blob)

  restore_test_run_git(repo_dir, ["reset", "--hard", "-q"])
  fs.write_string(
    repo_dir + "/first.t",
    "first\nfirst-and-a-half\nindex-dirty\n",
  )
  restore_test_run_git(repo_dir, ["add", "first.t"])
  let head_again = restore_test_git_stdout(repo_dir, [
    "cat-file", "blob", "HEAD:./first.t",
  ])
  restore_test_run_git(repo_dir, ["restore", "--staged", "first.t"])
  let unstaged_index = restore_test_git_stdout(repo_dir, ["show", ":./first.t"])
  assert_eq(unstaged_index, head_again)

  cleanup_tree(fs, root)
}

///|
async fn restore_wbtest_case_ignore_unmerged() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-restore-unmerged-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  restore_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  restore_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  restore_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/unmerged", "one\n")
  fs.write_string(repo_dir + "/common", "one\n")
  restore_test_run_git(repo_dir, ["add", "unmerged", "common"])
  restore_test_run_git(repo_dir, ["commit", "-q", "-m", "common"])
  restore_test_run_git(repo_dir, ["switch", "-q", "-c", "first"])
  fs.write_string(repo_dir + "/unmerged", "first\n")
  restore_test_run_git(repo_dir, ["commit", "-qam", "first"])
  restore_test_run_git(repo_dir, ["switch", "-q", "-c", "second", "main"])
  fs.write_string(repo_dir + "/unmerged", "second\n")
  restore_test_run_git(repo_dir, ["commit", "-qam", "second"])
  let (merge_code, _) = restore_test_git_stderr(repo_dir, ["merge", "first"])
  assert_not_eq(merge_code, 0)

  fs.write_string(repo_dir + "/common", "one\ndirty\n")
  let (plain_code, _) = restore_test_git_stderr(repo_dir, ["restore", "."])
  assert_not_eq(plain_code, 0)
  assert_eq(restore_test_read_string(fs, repo_dir + "/common"), "one\ndirty\n")

  let (quiet_code, quiet_stdout, quiet_stderr) = restore_test_git_output(
    repo_dir,
    ["restore", "--ignore-unmerged", "--quiet", "."],
  )
  assert_eq(quiet_code, 0)
  assert_eq(quiet_stdout, "")
  assert_eq(quiet_stderr, "")
  assert_eq(restore_test_read_string(fs, repo_dir + "/common"), "one\n")
  let diff_stdout = restore_test_git_stdout(repo_dir, ["diff", "--", "common"])
  assert_eq(diff_stdout, "")

  cleanup_tree(fs, root)
}

///|
test "restore: path resolution respects cwd prefix" {
  let resolved = restore_resolve_cli_paths("/repo", ["a.txt"])
  assert_eq(resolved.length(), 1)
  assert_eq(resolved[0], "a.txt")
}

///|
async test "restore: command path basic cases stay compatible" {
  restore_wbtest_case_command_path_basic()
}

///|
async test "restore: ignore-unmerged skips conflicted paths when quiet" {
  restore_wbtest_case_ignore_unmerged()
}
