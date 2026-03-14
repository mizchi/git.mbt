///|
let update_index_wbtest_shim_lock : @async.Semaphore = @async.Semaphore::new(
  1,
  initial_value=1,
)

///|
test "update-index: normalize_update_index_path rejects traversal paths" {
  let bad_paths : Array[String] = ["..", "../a.txt", "/a.txt", "a/../../b.txt"]
  for p in bad_paths {
    assert_true(update_index_path_is_rejected(p))
  }
}

///|
fn update_index_path_is_rejected(path : String) -> Bool {
  let _ = normalize_update_index_path(path) catch { _ => return true }
  false
}

///|
test "update-index: parse_update_index_cacheinfo rejects bad paths" {
  let (blob_id, _) = @bitcore.create_blob_string("cacheinfo")
  assert_true(
    parse_update_index_cacheinfo("100644", blob_id.to_hex(), "../a.txt") is None,
  )
}

///|
test "update-index: parse_update_index_info_line rejects bad paths" {
  let (blob_id, _) = @bitcore.create_blob_string("info line")
  let line = "100644 " + blob_id.to_hex() + "\t../a.txt"
  assert_true(parse_update_index_info_line(line) is None)
}

///|
test "update-index: parse_update_index_version accepts supported values" {
  assert_eq(parse_update_index_version("2"), Some(2))
  assert_eq(parse_update_index_version("3"), Some(3))
  assert_eq(parse_update_index_version("4"), Some(4))
  assert_eq(parse_update_index_version("1"), None)
}

///|
test "update-index: update_index_entry_is_racy matches index mtime" {
  let (blob_id, _) = @bitcore.create_blob_string("racy")
  let entry = @bitlib.IndexEntry::new(
    "file",
    blob_id,
    0o100644,
    4,
    mtime_sec=123,
    mtime_nsec=456,
  )
  assert_true(update_index_entry_is_racy(entry, Some((123, 456))))
  assert_false(update_index_entry_is_racy(entry, Some((123, 457))))
  assert_false(update_index_entry_is_racy(entry, None))
}

///|
test "update-index: preserve symlink mode when restaging existing entry" {
  let (blob_id, _) = @bitcore.create_blob_string("target")
  let before = [@bitlib.IndexEntry::new("symlink", blob_id, 0o120000, 6)]
  let after = [@bitlib.IndexEntry::new("symlink", blob_id, 0o100644, 6)]
  let preserved = update_index_preserve_existing_symlink_modes(before, after)
  assert_eq(preserved.length(), 1)
  assert_eq(preserved[0].mode, 0o120000)
}

///|
async fn update_index_wbtest_run_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let (code, _, _) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd~,
  )
  assert_eq(code, 0)
}

///|
async fn update_index_wbtest_run_sparse_checkout_shim(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  update_index_wbtest_shim_lock.acquire()
  defer update_index_wbtest_shim_lock.release()
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = "/tmp/bit-update-index-sparse-shim-moon.sh"
  let fs = OsFs::new()
  // Build the native binary first so exit codes propagate correctly
  // (moon run swallows non-zero exit codes)
  let bit_exe = repo_root + "/_build/native/release/build/cmd/bit/bit.exe"
  if not(fs.is_file(bit_exe)) {
    let build_code = @process.run(
      "moon",
      ["build", "--target", "native", "--release"],
      inherit_env=true,
    )
    assert_eq(build_code, 0)
  }
  fs.write_string(shim_moon, "#!/bin/sh\nset -eu\nexec '\{bit_exe}' \"$@\"\n")
  let chmod_code = @process.run("chmod", ["+x", shim_moon], inherit_env=true)
  assert_eq(chmod_code, 0)
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": repo_root + "/third_party/git/git",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": shim_moon,
    "SHIM_CMDS": "sparse-checkout",
    "SHIM_STRICT": "1",
  }
  let git_args : Array[String] = ["-C", cwd, "sparse-checkout"]
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
fn update_index_wbtest_restore_cwd(prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var("GIT_SHIM_CWD", value)
    None => @sys.unset_env_var("GIT_SHIM_CWD")
  }
}

///|
async test "update-index: assume-unchanged works for sparse missing path" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-update-index-assume-unchanged-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  update_index_wbtest_run_git(root, ["init", "-q", "repo"])
  update_index_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  update_index_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "text\n")
  fs.write_string(repo_dir + "/b", "text\n")
  fs.mkdir_p(repo_dir + "/dir")
  fs.write_string(repo_dir + "/dir/c", "text\n")
  update_index_wbtest_run_git(repo_dir, ["add", "a", "b", "dir/c"])
  update_index_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let prev_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  update_index_wbtest_run_sparse_checkout_shim(repo_dir, ["init", "--no-cone"])
  update_index_wbtest_run_sparse_checkout_shim(repo_dir, [
    "set", "/*", "!b", "!/*/",
  ])
  assert_false(fs.is_file(repo_dir + "/b"))
  handle_update_index(["--assume-unchanged", "b"])
  update_index_wbtest_restore_cwd(prev_cwd)

  let assume_unchanged = @bitlib.read_assume_unchanged_paths(
    fs,
    repo_dir + "/.git",
  )
  assert_true(assume_unchanged.contains("b"))

  cleanup_tree(fs, root)
}
