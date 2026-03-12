///|
async fn sparse_checkout_wbtest_run_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let code = @process.run("git", args[:], inherit_env=true, cwd~)
  assert_eq(code, 0)
}

///|
async fn sparse_checkout_wbtest_git_stdout(
  cwd : String,
  args : Array[String],
) -> String raise Error {
  let (code, stdout) = @process.collect_stdout(
    "git",
    args[:],
    inherit_env=true,
    cwd~,
  )
  assert_eq(code, 0)
  stdout.text() catch {
    _ => ""
  }
}

///|
async fn sparse_checkout_wbtest_shell_stdout(
  cwd : String,
  script : String,
) -> String raise Error {
  let (code, stdout) = @process.collect_stdout(
    "bash",
    ["-lc", script],
    inherit_env=true,
    cwd~,
  )
  assert_eq(code, 0)
  stdout.text() catch {
    _ => ""
  }
}

///|
async fn sparse_checkout_wbtest_shim_moon_path(
  repo_root : String,
) -> String raise Error {
  let fs = OsFs::new()
  let nonce = get_current_timestamp().to_string()
  let wrapper_path = "/tmp/bit-sparse-shim-moon-" +
    nonce +
    ".sh"
  let target_dir = "/tmp/bit-sparse-shim-target-" + nonce
  fs.write_string(
    wrapper_path,
    "#!/bin/sh\nset -eu\ncd '\{repo_root}'\nexec moon run --target native --target-dir '\{target_dir}' src/cmd/bit -- \"$@\"\n",
  )
  let chmod_code = @process.run("chmod", ["+x", wrapper_path], inherit_env=true)
  assert_eq(chmod_code, 0)
  let (warmup_code, _, _) = @process.collect_output(
    wrapper_path,
    ["--version"],
    inherit_env=true,
  )
  assert_eq(warmup_code, 0)
  wrapper_path
}

///|
fn sparse_checkout_wbtest_strip_moon_warnings(text : String) -> String {
  let lines : Array[String] = []
  let mut skipping_warning = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("Warning: [") {
      skipping_warning = true
      continue
    }
    if skipping_warning {
      if line.starts_with("────") {
        skipping_warning = false
      }
      continue
    }
    if line.has_prefix("Blocking waiting for file lock ") {
      continue
    }
    lines.push(line)
  }
  if lines.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  for i, line in lines {
    if i > 0 {
      out.write_char('\n')
    }
    out.write_string(line)
  }
  out.to_string()
}

///|
async fn sparse_checkout_wbtest_collect_shim_git_output(
  cwd : String,
  args : Array[String],
) -> (Int, String, String) raise Error {
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = sparse_checkout_wbtest_shim_moon_path(repo_root)
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": repo_root + "/third_party/git/git",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": shim_moon,
    "SHIM_CMDS": "sparse-checkout",
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
  let stderr_text = sparse_checkout_wbtest_strip_moon_warnings(
    stderr.text() catch { _ => "" },
  )
  let normalized_code = if code == 0 && stderr_text.has_prefix("fatal:") {
    1
  } else {
    code
  }
  (normalized_code, stdout_text, stderr_text)
}

///|
async fn sparse_checkout_wbtest_collect_shim_git_shell_output(
  cwd : String,
  script : String,
) -> (Int, String, String) raise Error {
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = sparse_checkout_wbtest_shim_moon_path(repo_root)
  let env : Map[String, String] = {
    "SHIM_GIT": shim_git,
    "SHIM_REAL_GIT": repo_root + "/third_party/git/git",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": shim_moon,
    "SHIM_CMDS": "sparse-checkout",
    "SHIM_STRICT": "1",
  }
  let (code, stdout, stderr) = @process.collect_output(
    "bash",
    ["-lc", script],
    extra_env=env,
    inherit_env=true,
    cwd~,
  )
  let stdout_text = stdout.text() catch { _ => "" }
  let stderr_text = sparse_checkout_wbtest_strip_moon_warnings(
    stderr.text() catch { _ => "" },
  )
  let normalized_code = if code == 0 && stderr_text.has_prefix("fatal:") {
    1
  } else {
    code
  }
  (normalized_code, stdout_text, stderr_text)
}

///|
async fn sparse_checkout_wbtest_init_repo(
  root : String,
  name : String,
) -> String raise Error {
  let fs = OsFs::new()
  let repo_dir = root + "/" + name
  sparse_checkout_wbtest_run_git(root, ["init", "-q", name])
  sparse_checkout_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  fs.write_string(repo_dir + "/b", "b\n")
  fs.mkdir_p(repo_dir + "/folder1")
  fs.mkdir_p(repo_dir + "/folder2")
  fs.write_string(repo_dir + "/folder1/c", "c\n")
  fs.write_string(repo_dir + "/folder2/d", "d\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "add", "a", "b", "folder1/c", "folder2/d",
  ])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  sparse_checkout_wbtest_run_git(repo_dir, ["branch", "-M", "main"])
  repo_dir
}

///|
async test "sparse-checkout: init re-enables sparse mode after disable and branch commits" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-reinit-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--no-cone"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "/*", "!b", "!/*/"])
  assert_false(fs.is_file(repo_dir + "/b"))
  assert_false(fs.is_dir(repo_dir + "/folder1"))
  assert_false(fs.is_dir(repo_dir + "/folder2"))

  handle_sparse_checkout_at_root(repo_dir, ["disable"])
  let skip_paths_after_disable = @bitlib.read_skip_worktree_paths(
    fs,
    repo_dir + "/.git",
  )
  assert_eq(skip_paths_after_disable.length(), 0)
  assert_true(fs.is_file(repo_dir + "/b"))
  assert_true(fs.is_dir(repo_dir + "/folder1"))
  assert_true(fs.is_dir(repo_dir + "/folder2"))

  sparse_checkout_wbtest_run_git(repo_dir, [
    "checkout", "-q", "-b", "branchY", "main",
  ])
  fs.write_string(repo_dir + "/b", "branch-y\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "commit", "-qam", "modified-b-in-branchY",
  ])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "checkout", "-q", "-b", "branchX", "main",
  ])
  fs.write_string(repo_dir + "/b", "branch-x\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "commit", "-qam", "modified-b-in-branchX",
  ])

  handle_sparse_checkout_at_root(repo_dir, ["init"])
  let config = @utf8.decode_lossy(fs.read_file(repo_dir + "/.git/config")[:])
  assert_true(config.contains("sparseCheckout = true"))
  assert_false(fs.is_file(repo_dir + "/b"))
  assert_false(fs.is_dir(repo_dir + "/folder1"))
  assert_false(fs.is_dir(repo_dir + "/folder2"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: list fails when worktree is not sparse" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-list-fatal-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  match sparse_checkout_list_state(fs, repo_dir + "/.git") {
    Fatal(msg) => assert_eq(msg, "this worktree is not sparse")
    _ => fail("expected sparse list to fail for non-sparse worktree")
  }

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: set without patterns initializes defaults and config.worktree" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-set-defaults-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["set"])

  let patterns = @bitlib.read_sparse_patterns(fs, repo_dir + "/.git")
  assert_eq(patterns, @bitlib.sparse_default_patterns())
  let config = @utf8.decode_lossy(fs.read_file(repo_dir + "/.git/config")[:])
  assert_true(config.contains("repositoryformatversion = 1"))
  assert_true(config.contains("worktreeConfig = true"))
  let worktree_config = @utf8.decode_lossy(
    fs.read_file(repo_dir + "/.git/config.worktree")[:],
  )
  assert_true(worktree_config.contains("sparseCheckout = true"))
  assert_true(fs.is_file(repo_dir + "/a"))
  assert_true(fs.is_file(repo_dir + "/b"))
  assert_false(fs.is_dir(repo_dir + "/folder1"))
  assert_false(fs.is_dir(repo_dir + "/folder2"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: init and reapply update sparse-index worktree config" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-index-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  let worktree_config = @utf8.decode_lossy(
    fs.read_file(repo_dir + "/.git/config.worktree")[:],
  )
  assert_true(worktree_config.contains("[index]"))
  assert_true(worktree_config.contains("sparse = true"))

  handle_sparse_checkout_at_root(repo_dir, ["reapply", "--no-sparse-index"])
  let updated_config = @utf8.decode_lossy(
    fs.read_file(repo_dir + "/.git/config.worktree")[:],
  )
  assert_true(updated_config.contains("sparse = false"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: init --no-sparse-index expands sparse directories in on-disk index" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-no-index-expand-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder1"])
  let sparse_output = sparse_checkout_wbtest_git_stdout(repo_dir, [
    "ls-files", "--sparse", "--stage",
  ])
  assert_true(sparse_output.contains("\tfolder2/\n"))

  handle_sparse_checkout_at_root(repo_dir, ["init", "--no-sparse-index"])
  let raw_entries = @bitlib.read_index_stage_entries(fs, repo_dir + "/.git")
  assert_false(
    raw_entries.any(fn(item) {
      item.stage == 0 && item.entry.path == "folder2/"
    }),
  )
  assert_true(
    raw_entries.any(fn(item) {
      item.stage == 0 && item.entry.path == "folder2/d"
    }),
  )
  let expanded_output = sparse_checkout_wbtest_git_stdout(repo_dir, [
    "ls-files", "--sparse", "--stage",
  ])
  assert_false(expanded_output.contains("\tfolder2/\n"))
  assert_true(expanded_output.contains("\tfolder2/d\n"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: set with sparse-index collapses skipped directories in index" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-index-collapse-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder1"])

  let entries = @bitlib.read_index_stage_entries(fs, repo_dir + "/.git")
  assert_true(
    entries.any(fn(item) {
      item.stage == 0 &&
      item.entry.mode == 0o040000 &&
      item.entry.path == "folder2/"
    }),
  )
  assert_true(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "folder1/c" }),
  )
  assert_false(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "folder2/d" }),
  )

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: reapply preserves staged deletions while collapsing skipped dirs" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-reapply-index-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder1"])
  sparse_checkout_wbtest_run_git(repo_dir, ["rm", "-r", "."])
  handle_sparse_checkout_at_root(repo_dir, ["reapply"])

  let entries = @bitlib.read_index_stage_entries(fs, repo_dir + "/.git")
  assert_true(
    entries.any(fn(item) {
      item.stage == 0 &&
      item.entry.mode == 0o040000 &&
      item.entry.path == "folder2/"
    }),
  )
  assert_false(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "a" }),
  )
  assert_false(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "b" }),
  )
  assert_false(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "folder1/c" }),
  )

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: deep cone path collapses sibling subtree into sparse dir" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-deep-cone-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  sparse_checkout_wbtest_run_git(root, ["init", "-q", "repo"])
  sparse_checkout_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  fs.mkdir_p(repo_dir + "/folder2/0/0")
  fs.mkdir_p(repo_dir + "/folder2/2")
  fs.write_string(repo_dir + "/folder2/a", "a\n")
  fs.write_string(repo_dir + "/folder2/0/1", "one\n")
  fs.write_string(repo_dir + "/folder2/0/0/0", "zero\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "add", "a", "folder2/a", "folder2/0/1", "folder2/0/0/0",
  ])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder2/2/3"])

  let entries = @bitlib.read_index_stage_entries(fs, repo_dir + "/.git")
  assert_true(
    entries.any(fn(item) {
      item.stage == 0 &&
      item.entry.mode == 0o040000 &&
      item.entry.path == "folder2/0/"
    }),
  )
  assert_true(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "folder2/a" }),
  )
  assert_false(
    entries.any(fn(item) { item.stage == 0 && item.entry.path == "folder2/0/1" }),
  )
  let tracked_entries = ls_files_collect_cached_entries(
    fs,
    repo_dir,
    repo_dir + "/.git",
    "",
    show_sparse=true,
  )
  assert_true(tracked_entries.any(fn(entry) { entry.path == "folder2/0/" }))
  assert_true(tracked_entries.any(fn(entry) { entry.path == "folder2/a" }))
  assert_false(tracked_entries.any(fn(entry) { entry.path == "folder2/0/1" }))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: narrowing from parent cone to deep cone re-collapses sibling subtree" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-narrow-cone-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  sparse_checkout_wbtest_run_git(root, ["init", "-q", "repo"])
  sparse_checkout_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  fs.mkdir_p(repo_dir + "/folder2/0/0")
  fs.mkdir_p(repo_dir + "/folder2/2")
  fs.write_string(repo_dir + "/folder2/a", "a\n")
  fs.write_string(repo_dir + "/folder2/0/1", "one\n")
  fs.write_string(repo_dir + "/folder2/0/0/0", "zero\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "add", "a", "folder2/a", "folder2/0/1", "folder2/0/0/0",
  ])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder2"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder2/2/3"])

  let tracked_entries = ls_files_collect_cached_entries(
    fs,
    repo_dir,
    repo_dir + "/.git",
    "",
    show_sparse=true,
  )
  assert_true(tracked_entries.any(fn(entry) { entry.path == "folder2/0/" }))
  assert_true(tracked_entries.any(fn(entry) { entry.path == "folder2/a" }))
  assert_false(tracked_entries.any(fn(entry) { entry.path == "folder2/0/1" }))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: repeated cone updates preserve nested sparse dirs" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-repeated-cone-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  sparse_checkout_wbtest_run_git(root, ["init", "-q", "repo"])
  sparse_checkout_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  fs.mkdir_p(repo_dir + "/before")
  fs.write_string(repo_dir + "/before/a", "before\n")
  fs.mkdir_p(repo_dir + "/x")
  fs.write_string(repo_dir + "/x/a", "x\n")
  fs.mkdir_p(repo_dir + "/folder1/0/0")
  fs.write_string(repo_dir + "/folder1/a", "folder1\n")
  fs.write_string(repo_dir + "/folder1/0/0/0", "folder1-deep\n")
  fs.mkdir_p(repo_dir + "/folder2/0/0")
  fs.mkdir_p(repo_dir + "/folder2/2")
  fs.write_string(repo_dir + "/folder2/a", "folder2\n")
  fs.write_string(repo_dir + "/folder2/0/1", "folder2-one\n")
  fs.write_string(repo_dir + "/folder2/0/0/0", "folder2-zero\n")
  fs.mkdir_p(repo_dir + "/deep/deeper1")
  fs.mkdir_p(repo_dir + "/deep/deeper2")
  fs.write_string(repo_dir + "/deep/e", "deep\n")
  fs.write_string(repo_dir + "/deep/deeper1/a", "deep-one\n")
  fs.write_string(repo_dir + "/deep/deeper2/a", "deep-two\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "add", "a", "before/a", "x/a", "folder1/a", "folder1/0/0/0", "folder2/a", "folder2/0/1",
    "folder2/0/0/0", "deep/e", "deep/deeper1/a", "deep/deeper2/a",
  ])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder1", "folder2", "x"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "deep", "folder2", "x"])
  handle_sparse_checkout_at_root(repo_dir, [
    "set", "deep/deeper2", "folder1", "folder2", "x",
  ])
  handle_sparse_checkout_at_root(repo_dir, [
    "set", "bogus", "deep/deeper1", "folder1/0/0", "folder2/2/3", "x",
  ])

  let tracked_entries = ls_files_collect_cached_entries(
    fs,
    repo_dir,
    repo_dir + "/.git",
    "",
    show_sparse=true,
  )
  assert_true(tracked_entries.any(fn(entry) { entry.path == "before/" }))
  assert_true(tracked_entries.any(fn(entry) { entry.path == "deep/deeper2/" }))
  assert_true(tracked_entries.any(fn(entry) { entry.path == "folder2/0/" }))
  assert_true(tracked_entries.any(fn(entry) { entry.path == "folder2/a" }))
  assert_false(tracked_entries.any(fn(entry) { entry.path == "folder2/0/1" }))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: repeated cone updates preserve nested sparse dirs in ls-files output" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-repeated-cone-command-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  sparse_checkout_wbtest_run_git(root, ["init", "-q", "repo"])
  sparse_checkout_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  fs.mkdir_p(repo_dir + "/before")
  fs.write_string(repo_dir + "/before/a", "before\n")
  fs.mkdir_p(repo_dir + "/x")
  fs.write_string(repo_dir + "/x/a", "x\n")
  fs.mkdir_p(repo_dir + "/folder1/0/0")
  fs.write_string(repo_dir + "/folder1/a", "folder1\n")
  fs.write_string(repo_dir + "/folder1/0/0/0", "folder1-deep\n")
  fs.mkdir_p(repo_dir + "/folder2/0/0")
  fs.mkdir_p(repo_dir + "/folder2/2")
  fs.write_string(repo_dir + "/folder2/a", "folder2\n")
  fs.write_string(repo_dir + "/folder2/0/1", "folder2-one\n")
  fs.write_string(repo_dir + "/folder2/0/0/0", "folder2-zero\n")
  fs.mkdir_p(repo_dir + "/deep/deeper1")
  fs.mkdir_p(repo_dir + "/deep/deeper2")
  fs.write_string(repo_dir + "/deep/e", "deep\n")
  fs.write_string(repo_dir + "/deep/deeper1/a", "deep-one\n")
  fs.write_string(repo_dir + "/deep/deeper2/a", "deep-two\n")
  sparse_checkout_wbtest_run_git(repo_dir, [
    "add", "a", "before/a", "x/a", "folder1/a", "folder1/0/0/0", "folder2/a", "folder2/0/1",
    "folder2/0/0/0", "deep/e", "deep/deeper1/a", "deep/deeper2/a",
  ])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder1", "folder2", "x"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "deep", "folder2", "x"])
  handle_sparse_checkout_at_root(repo_dir, [
    "set", "deep/deeper2", "folder1", "folder2", "x",
  ])
  handle_sparse_checkout_at_root(repo_dir, [
    "set", "bogus", "deep/deeper1", "folder1/0/0", "folder2/2/3", "x",
  ])

  let output = sparse_checkout_wbtest_git_stdout(repo_dir, [
    "ls-files", "--sparse", "--stage",
  ])
  assert_true(output.contains("\tbefore/\n"))
  assert_true(output.contains("\tdeep/deeper2/\n"))
  assert_true(output.contains("\tfolder2/0/\n"))
  assert_true(output.contains("\tfolder2/a\n"))
  assert_false(output.contains("\tfolder2/0/1\n"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: add keeps skipped paths out of porcelain status" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-add-status-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "folder1"])
  fs.write_string(repo_dir + "/README.md", "readme\n")
  @bitlib.add_paths_async(fs, fs, repo_dir, ["README.md"])

  let lines = @bitlib.status_porcelain(fs, repo_dir)
  assert_eq(lines, ["A  README.md"])

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: list warns when sparse-checkout file is missing" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-list-warning-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["set"])
  fs.remove_file(repo_dir + "/.git/info/sparse-checkout")

  match sparse_checkout_list_state(fs, repo_dir + "/.git") {
    Warning(msg) =>
      assert_eq(
        msg, "this worktree is not sparse (sparse-checkout file may not exist)",
      )
    _ => fail("expected sparse list warning when sparse file is missing")
  }

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: set --stdin in cone mode updates list and worktree" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-stdin-cone-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  let (init_code, init_stdout, init_stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    ["sparse-checkout", "init", "--cone"],
  )
  assert_eq(init_code, 0)
  assert_eq(init_stdout, "Sparse checkout initialized\n")
  assert_eq(init_stderr, "")

  let (code, stdout, stderr) = sparse_checkout_wbtest_collect_shim_git_shell_output(
    repo_dir,
    "printf 'folder1\\nfolder2\\n' | \"$SHIM_GIT\" -C . sparse-checkout set --stdin >/dev/null && \"$SHIM_GIT\" -C . sparse-checkout list",
  )
  assert_eq(code, 0)
  assert_eq(stdout, "folder1\nfolder2\n")
  assert_eq(stderr, "")
  assert_true(fs.is_dir(repo_dir + "/folder1"))
  assert_true(fs.is_dir(repo_dir + "/folder2"))
  assert_true(fs.is_file(repo_dir + "/folder1/c"))
  assert_true(fs.is_file(repo_dir + "/folder2/d"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: reapply restores worktree from current patterns" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-reapply-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--no-cone"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "/*", "!b", "!/*/"])

  let initial_patterns = @bitlib.read_sparse_patterns(fs, repo_dir + "/.git")
  assert_eq(initial_patterns, ["/*", "!b", "!/*/"])
  let initial_skip_paths = @bitlib.read_skip_worktree_paths(
    fs,
    repo_dir + "/.git",
  )
  assert_true(initial_skip_paths.contains("b"))
  assert_false(fs.is_file(repo_dir + "/b"))
  fs.write_string(repo_dir + "/b", "manual\n")
  assert_true(fs.is_file(repo_dir + "/b"))

  handle_sparse_checkout_at_root(repo_dir, ["reapply"])
  assert_false(fs.is_file(repo_dir + "/b"))
  assert_false(fs.is_dir(repo_dir + "/folder1"))
  assert_false(fs.is_dir(repo_dir + "/folder2"))
  let patterns = @bitlib.read_sparse_patterns(fs, repo_dir + "/.git")
  assert_eq(patterns, ["/*", "!b", "!/*/"])

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: cone set collapses nested explicit paths to parent" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-cone-collapse-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  sparse_checkout_wbtest_run_git(root, ["init", "-q", "repo"])
  sparse_checkout_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  fs.mkdir_p(repo_dir + "/deep/deeper1/deepest")
  fs.write_string(repo_dir + "/deep/deeper1/deepest/a", "deep\n")
  sparse_checkout_wbtest_run_git(repo_dir, ["add", "a", "deep/deeper1/deepest/a"])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone"])
  handle_sparse_checkout_at_root(repo_dir, ["set", "deep", "deep/deeper1/deepest"])

  let file_patterns = @bitlib.read_sparse_patterns(fs, repo_dir + "/.git")
  assert_eq(file_patterns, ["/*", "!/*/", "/deep/"])
  let display_patterns = @bitlib.read_sparse_display_patterns(fs, repo_dir + "/.git")
  assert_eq(display_patterns, ["deep"])

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: add fails when cone mode is enabled for non-cone patterns" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-cone-guard-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--no-cone"])
  handle_sparse_checkout_at_root(repo_dir, ["add", "dir"])
  sparse_checkout_wbtest_run_git(repo_dir, [
    "config", "--worktree", "core.sparseCheckoutCone", "true",
  ])

  let rejected = try {
    handle_sparse_checkout_at_root(repo_dir, ["add", "dir"])
    false
  } catch {
    @bitcore.GitError::InvalidObject(msg) =>
      msg == "existing sparse-checkout patterns do not use cone mode"
    _ => false
  }
  assert_true(rejected)

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: init warns when dirty tracked path is preserved" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-dirty-warning-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")
  fs.write_string(repo_dir + "/folder1/c", "dirty\n")

  let (code, stdout, stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    ["sparse-checkout", "init", "--no-cone"],
  )
  assert_eq(code, 0)
  assert_eq(stdout, "Sparse checkout initialized\n")
  assert_true(stderr.contains("warning: The following paths are not up to date"))
  assert_true(stderr.contains("folder1"))
  assert_true(fs.is_file(repo_dir + "/folder1/c"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: reapply updates cone and sparse-index config" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-reapply-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["init", "--cone", "--sparse-index"])
  handle_sparse_checkout_at_root(repo_dir, ["reapply", "--no-cone", "--no-sparse-index"])

  let config = @utf8.decode_lossy(fs.read_file(repo_dir + "/.git/config.worktree")[:])
  assert_true(config.contains("sparseCheckout = true"))
  assert_true(config.contains("sparseCheckoutCone = false"))
  assert_true(config.contains("sparse = false"))
  assert_false(@bitlib.is_sparse_checkout_cone_enabled(fs, repo_dir + "/.git"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: set fails when sparse-checkout lock exists" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-lock-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  fs.mkdir_p(repo_dir + "/.git/info")
  fs.write_string(repo_dir + "/.git/info/sparse-checkout.lock", "held\n")
  let rejected = try {
    handle_sparse_checkout_at_root(repo_dir, ["set", "folder1"])
    false
  } catch {
    @bitcore.GitError::InvalidObject(msg) =>
      msg.contains("Unable to create") && msg.contains(".lock")
    _ => false
  }
  assert_true(rejected)

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: no-checkout clone keeps worktree empty until switch" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-no-checkout-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let origin_dir = sparse_checkout_wbtest_init_repo(root, "origin")
  let clone_dir = root + "/clone"

  sparse_checkout_wbtest_run_git(root, [
    "clone", "--no-checkout", origin_dir, "clone",
  ])
  handle_sparse_checkout_at_root(clone_dir, ["init", "--cone"])
  handle_sparse_checkout_at_root(clone_dir, ["set", "folder1"])

  let patterns = @bitlib.read_sparse_display_patterns(fs, clone_dir + "/.git")
  assert_eq(patterns, ["folder1"])
  assert_false(fs.is_file(clone_dir + "/a"))
  assert_false(fs.is_dir(clone_dir + "/folder1"))
  assert_false(fs.is_file(clone_dir + "/.git/index"))

  sparse_checkout_wbtest_run_git(clone_dir, ["switch", "main"])
  assert_true(fs.is_file(clone_dir + "/a"))
  assert_true(fs.is_dir(clone_dir + "/folder1"))
  assert_false(fs.is_dir(clone_dir + "/deep"))
  assert_false(fs.is_dir(clone_dir + "/folder2"))

  cleanup_tree(fs, root)
}

///|
test "sparse-checkout: check-rules helper preserves quoted and nul-delimited matches" {
  let patterns = sparse_checkout_compile_cone_patterns(["folder\" a"])
  let quoted = sparse_checkout_filter_check_rules_input(
    "\"folder\\\" a/file\"\n\"folder\\\" b/file\"\n",
    patterns,
    false,
  )
  assert_eq(quoted, "\"folder\\\" a/file\"\n")

  let nul_input = StringBuilder::new()
  nul_input.write_string("folder\" a/a")
  nul_input.write_char('\u{0}')
  nul_input.write_string("folder\" b/file")
  nul_input.write_char('\u{0}')
  let nul_output = sparse_checkout_filter_check_rules_input(
    nul_input.to_string(),
    patterns,
    true,
  )
  let expect = StringBuilder::new()
  expect.write_string("folder\" a/a")
  expect.write_char('\u{0}')
  assert_eq(nul_output, expect.to_string())
}

///|
async test "sparse-checkout: check-rules defaults to cone mode for rules files" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_moon = sparse_checkout_wbtest_shim_moon_path(repo_root)
  let root = "/tmp/bit-test-sparse-check-rules-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")
  let rules_path = root + "/rules"
  let input_path = root + "/files"

  fs.write_string(rules_path, "folder1\n")
  fs.write_string(input_path, "a\nfolder1/c\nfolder2/d\n")
  let actual = sparse_checkout_wbtest_shell_stdout(
    repo_root,
    "SHIM_REAL_GIT=\{repo_root}/third_party/git/git SHIM_EXEC_PATH=\{repo_root}/third_party/git SHIM_MOON=\{shim_moon} SHIM_CMDS='sparse-checkout' SHIM_STRICT=1 \{repo_root}/tools/git-shim/bin/git -C \{repo_dir} sparse-checkout check-rules --rules-file \{rules_path} < \{input_path}",
  )
  assert_eq(actual, "a\nfolder1/c\n")

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: clean refuses without force by default" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-clean-force-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["set", "--cone", "folder1"])
  fs.mkdir_p(repo_dir + "/folder2/extra")
  fs.write_string(repo_dir + "/folder2/extra/file", "untracked\n")

  let (code, _stdout, stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    [
    "sparse-checkout", "clean",
  ],
  )
  assert_eq(code, 1)
  assert_true(stderr.contains("refusing to clean"))
  assert_true(fs.is_file(repo_dir + "/folder2/extra/file"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: clean dry-run collapses outside sparse paths" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-clean-dry-run-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["set", "--cone", "folder1"])
  fs.mkdir_p(repo_dir + "/folder2/extra")
  fs.write_string(repo_dir + "/folder2/extra/file", "untracked\n")

  let (dry_code, dry_stdout, dry_stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    ["sparse-checkout", "clean", "--dry-run"],
  )
  assert_eq(dry_code, 0)
  assert_eq(dry_stdout, "Would remove folder2/\n")
  assert_eq(dry_stderr, "")
  assert_true(fs.is_file(repo_dir + "/folder2/extra/file"))

  let (verbose_code, verbose_stdout, verbose_stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    ["sparse-checkout", "clean", "--dry-run", "--verbose"],
  )
  assert_eq(verbose_code, 0)
  assert_eq(verbose_stdout, "Would remove folder2/extra/file\n")
  assert_eq(verbose_stderr, "")
  assert_true(fs.is_file(repo_dir + "/folder2/extra/file"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: clean skips roots with tracked paths still present" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-clean-tracked-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["set", "--cone", "folder1"])
  fs.mkdir_p(repo_dir + "/folder2")
  fs.write_string(repo_dir + "/folder2/d", "dirty tracked\n")
  fs.write_string(repo_dir + "/folder2/file", "untracked\n")

  let stage_entries = @bitlib.read_index_stage_entries(fs, repo_dir + "/.git")
  let skip_worktree_paths = @bitlib.read_skip_worktree_paths(fs, repo_dir + "/.git")
  let skipped_paths : Array[String] = []
  let kept_paths : Array[String] = []
  for item in stage_entries {
    if item.stage != 0 {
      continue
    }
    if skip_worktree_paths.contains(item.entry.path) {
      skipped_paths.push(item.entry.path)
    } else {
      kept_paths.push(item.entry.path)
    }
  }
  assert_true(skipped_paths.contains("folder2/d"))
  assert_eq(
    sparse_checkout_clean_managed_root("folder2/d", skipped_paths, kept_paths),
    Some("folder2"),
  )
  assert_eq(
    sparse_checkout_clean_managed_root("folder2/file", skipped_paths, kept_paths),
    Some("folder2"),
  )

  let (code, stdout, stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    [
    "sparse-checkout", "clean", "-f",
  ],
  )
  assert_eq(code, 0)
  assert_eq(stdout, "")
  assert_eq(stderr, "")
  assert_true(fs.is_file(repo_dir + "/folder2/d"))
  assert_true(fs.is_file(repo_dir + "/folder2/file"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: clean defers all managed roots while tracked sparse paths remain" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-clean-global-block-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  fs.mkdir_p(repo_dir + "/folder3")
  fs.write_string(repo_dir + "/folder3/e", "e\n")
  sparse_checkout_wbtest_run_git(repo_dir, ["add", "folder3/e"])
  sparse_checkout_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "add folder3"])

  handle_sparse_checkout_at_root(repo_dir, ["set", "--cone", "folder1"])
  fs.mkdir_p(repo_dir + "/folder2")
  fs.write_string(repo_dir + "/folder2/d", "dirty tracked\n")
  fs.write_string(repo_dir + "/folder2/file", "untracked\n")
  fs.mkdir_p(repo_dir + "/folder3/extra")
  fs.write_string(repo_dir + "/folder3/extra/file", "other untracked\n")

  let (code, stdout, stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    [
    "sparse-checkout", "clean", "-f",
  ],
  )
  assert_eq(code, 0)
  assert_eq(stdout, "")
  assert_eq(stderr, "")
  assert_true(fs.is_file(repo_dir + "/folder2/d"))
  assert_true(fs.is_file(repo_dir + "/folder2/file"))
  assert_true(fs.is_file(repo_dir + "/folder3/extra/file"))

  cleanup_tree(fs, root)
}

///|
async test "sparse-checkout: reapply warns about tracked sparse paths left in place" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-sparse-reapply-warn-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = sparse_checkout_wbtest_init_repo(root, "repo")

  handle_sparse_checkout_at_root(repo_dir, ["set", "--cone", "folder1"])
  fs.mkdir_p(repo_dir + "/folder2")
  fs.write_string(repo_dir + "/folder2/d", "dirty tracked\n")
  fs.write_string(repo_dir + "/folder2/file", "untracked\n")

  let (code, stdout, stderr) = sparse_checkout_wbtest_collect_shim_git_output(
    repo_dir,
    [
    "sparse-checkout", "reapply",
  ],
  )
  assert_eq(code, 0)
  assert_eq(stdout, "")
  assert_true(stderr.contains("warning"))
  assert_true(stderr.contains("not up to date"))
  assert_true(stderr.contains("folder2"))
  assert_true(fs.is_file(repo_dir + "/folder2/d"))
  assert_true(fs.is_file(repo_dir + "/folder2/file"))

  cleanup_tree(fs, root)
}
