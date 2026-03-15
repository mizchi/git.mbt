///|
fn submodule_wbtest_entry(path : String, mode : Int) -> @bitlib.IndexEntry {
  let zero = @bitcore.ObjectId::new(FixedArray::make(20, b'\x00'))
  @bitlib.IndexEntry::new(path, zero, mode, 0)
}

///|
fn submodule_wbtest_id(byte : Byte) -> @bitcore.ObjectId {
  @bitcore.ObjectId::new(FixedArray::make(20, byte))
}

///|
async fn submodule_wbtest_run_git(
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
async fn submodule_wbtest_git_stdout(
  cwd : String,
  args : Array[String],
) -> String raise Error {
  let (code, stdout, _) = @process.collect_output(
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
async fn submodule_wbtest_git_stderr(
  cwd : String,
  args : Array[String],
) -> (Int, String) raise Error {
  let (code, _, stderr) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd~,
  )
  let text = stderr.text() catch { _ => "" }
  (code, text)
}

///|
fn submodule_wbtest_restore_env(name : String, value : String?) -> Unit {
  match value {
    Some(v) => @sys.set_env_var(name, v)
    None => @sys.unset_env_var(name)
  }
}

///|
async fn submodule_wbtest_collect_shim_git_stderr(
  cwd : String,
  args : Array[String],
) -> (Int, String) raise Error {
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": wbtest_resolve_real_git(repo_root),
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": repo_root + "/_build/native/release/build/cmd/bit/bit.exe",
    "SHIM_CMDS": "submodule submodule--helper",
    "SHIM_STRICT": "1",
  }
  let git_args : Array[String] = ["-C", cwd]
  for arg in args {
    git_args.push(arg)
  }
  let (code, _, stderr) = @process.collect_output(
    shim_git,
    git_args[:],
    extra_env=env,
    inherit_env=true,
  )
  let text = stderr.text() catch { _ => "" }
  (code, text)
}

///|
async fn submodule_wbtest_run_shim_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let (code, stderr) = submodule_wbtest_collect_shim_git_stderr(cwd, args)
  assert_eq(code, 0)
  assert_eq(stderr, "")
}

///|
async fn submodule_wbtest_setup_deinit_repo(
  root : String,
) -> String raise Error {
  let fs = OsFs::new()
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])
  fs.write_string(init_dir + "/a", "b\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "second"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
  super_dir
}

///|
async test "submodule absorbgitdirs: gitlink without gitmodules entry is fatal" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-absorbgitdirs-missing-name-" +
    get_current_timestamp().to_string()
  ignore(@process.run("rm", ["-rf", root], inherit_env=true))
  fs.mkdir_p(root)
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "."])
  submodule_wbtest_run_git(root, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "sub2"])
  submodule_wbtest_run_git(root + "/sub2", ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root + "/sub2", [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(root + "/sub2/a", "a\n")
  submodule_wbtest_run_git(root + "/sub2", ["add", "a"])
  submodule_wbtest_run_git(root + "/sub2", ["commit", "-q", "-m", "initial"])
  submodule_wbtest_run_git(root, ["add", "sub2"])

  let (code, stderr) = submodule_wbtest_collect_shim_git_stderr(root, [
    "submodule", "absorbgitdirs",
  ])
  assert_eq(code, 128)
  assert_eq(stderr, "fatal: could not lookup name for submodule 'sub2'\n")
}

///|
async test "submodule absorbgitdirs: embedded repo migrates and update reuses modules repo" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-absorbgitdirs-update-" +
    get_current_timestamp().to_string()
  ignore(@process.run("rm", ["-rf", root], inherit_env=true))
  fs.mkdir_p(root)
  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "."])
  submodule_wbtest_run_git(root, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "sub1"])
  submodule_wbtest_run_git(root + "/sub1", ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root + "/sub1", [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(root + "/sub1/a", "a\n")
  submodule_wbtest_run_git(root + "/sub1", ["add", "a"])
  submodule_wbtest_run_git(root + "/sub1", ["commit", "-q", "-m", "initial"])

  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  let (add_code, add_stderr) = submodule_wbtest_collect_shim_git_stderr(root, [
    "submodule", "add", "./sub1",
  ])
  assert_eq(add_code, 0)
  assert_eq(add_stderr, "")
  assert_true(fs.is_dir(root + "/sub1/.git"))
  assert_false(fs.is_dir(root + "/.git/modules/sub1"))
  submodule_wbtest_run_git(root, ["commit", "-q", "-am", "superproject"])

  let (absorb_code, absorb_stderr) = submodule_wbtest_collect_shim_git_stderr(
    root,
    ["submodule", "absorbgitdirs"],
  )
  assert_eq(absorb_code, 0)
  assert_eq(
    absorb_stderr,
    "Migrating git directory of 'sub1' from\n" +
    "'\{root}/sub1/.git' to\n" +
    "'\{root}/.git/modules/sub1'\n",
  )
  assert_true(fs.is_file(root + "/sub1/.git"))
  assert_true(fs.is_dir(root + "/.git/modules/sub1"))

  submodule_wbtest_run_shim_git(root, ["submodule", "deinit", "--all"])
  assert_false(fs.is_file(root + "/sub1/.git"))
  submodule_wbtest_run_shim_git(root, ["submodule", "absorbgitdirs"])
  submodule_wbtest_run_shim_git(root, ["submodule", "update", "--init"])
  assert_true(fs.is_file(root + "/sub1/.git"))
  let head = submodule_wbtest_git_stdout(root + "/sub1", ["rev-parse", "HEAD"])
  assert_true(head.trim().length() > 0)
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
}

///|
async test "submodule add: relative local url works from absorbed submodule root" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-nested-relative-" +
    get_current_timestamp().to_string()
  ignore(@process.run("rm", ["-rf", root], inherit_env=true))
  fs.mkdir_p(root)
  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "."])
  submodule_wbtest_run_git(root, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "sub1"])
  submodule_wbtest_run_git(root + "/sub1", ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root + "/sub1", [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(root + "/sub1/a", "a\n")
  submodule_wbtest_run_git(root + "/sub1", ["add", "a"])
  submodule_wbtest_run_git(root + "/sub1", ["commit", "-q", "-m", "initial"])

  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_shim_git(root, ["submodule", "add", "./sub1"])
  submodule_wbtest_run_git(root, ["commit", "-q", "-am", "superproject"])
  let (absorb_code, _absorb_stderr) = submodule_wbtest_collect_shim_git_stderr(
    root,
    ["submodule", "absorbgitdirs"],
  )
  assert_eq(absorb_code, 0)

  submodule_wbtest_run_git(root + "/sub1", [
    "init", "--initial-branch=main", "-q", "nested",
  ])
  submodule_wbtest_run_git(root + "/sub1/nested", [
    "config", "user.name", "Test User",
  ])
  submodule_wbtest_run_git(root + "/sub1/nested", [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(root + "/sub1/nested/n", "n\n")
  submodule_wbtest_run_git(root + "/sub1/nested", ["add", "n"])
  submodule_wbtest_run_git(root + "/sub1/nested", [
    "commit", "-q", "-m", "nested",
  ])

  let (code, stderr) = submodule_wbtest_collect_shim_git_stderr(
    root + "/sub1",
    ["submodule", "add", "./nested"],
  )
  assert_eq(code, 0)
  assert_eq(stderr, "")
  assert_true(fs.is_dir(root + "/sub1/nested/.git"))
  assert_true(fs.is_file(root + "/sub1/.gitmodules"))
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)
}

///|
async test "submodule deinit: failure on untracked file keeps config" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-deinit-untracked-keeps-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let super_dir = submodule_wbtest_setup_deinit_repo(root)
  fs.write_string(super_dir + "/init/untracked", "x\n")

  let (code, stderr) = submodule_wbtest_collect_shim_git_stderr(super_dir, [
    "submodule", "deinit", "init",
  ])

  assert_eq(code, 1)
  assert_true(stderr.contains("local modifications"))
  let config_content = decode_bytes(fs.read_file(super_dir + "/.git/config"))
  assert_true(config_content.contains("[submodule \"init\"]"))
  assert_true(fs.is_file(super_dir + "/init/.git"))
  cleanup_tree(fs, root)
}

///|
async test "submodule deinit: failure on head mismatch keeps config" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-deinit-head-mismatch-keeps-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let super_dir = submodule_wbtest_setup_deinit_repo(root)
  submodule_wbtest_run_git(super_dir + "/init", ["checkout", "-q", "HEAD^"])

  let (code, stderr) = submodule_wbtest_collect_shim_git_stderr(super_dir, [
    "submodule", "deinit", "init",
  ])

  assert_eq(code, 1)
  assert_true(stderr.contains("local modifications"))
  let config_content = decode_bytes(fs.read_file(super_dir + "/.git/config"))
  assert_true(config_content.contains("[submodule \"init\"]"))
  assert_true(fs.is_file(super_dir + "/init/.git"))
  cleanup_tree(fs, root)
}

///|
async test "submodule update --init: active filters keep named active unset for active path" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let root = "/tmp/bit-test-submodule-init-active-filter-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let super_dir = root
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir)
  fs.write_string(
    git_dir + "/config",
    "[core]\n\trepositoryformatversion = 0\n" +
    "[submodule]\n\tactive = .\n\tactive = :(exclude)sub0\n",
  )
  fs.write_string(
    root + "/.gitmodules",
    "[submodule \"sub0\"]\n\tpath = sub0\n\turl = ./sub0\n" +
    "[submodule \"sub1\"]\n\tpath = sub1\n\turl = ./sub1\n",
  )
  handle_submodule_update(fs, super_dir, git_dir, ["--quiet", "--init"])

  let sub0_active = read_submodule_config_value(rfs, git_dir, "sub0", "active")
  let sub1_active = read_submodule_config_value(rfs, git_dir, "sub1", "active")
  let sub1_url = read_submodule_config_value(rfs, git_dir, "sub1", "url")
  assert_eq(sub0_active, None)
  assert_eq(sub1_active, None)
  assert_true(sub1_url is Some(_))
  cleanup_tree(fs, root)
}

///|
async test "submodule update --init: no global active filters reinitialize all known paths" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let root = "/tmp/bit-test-submodule-update-init-known-paths-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir)
  fs.write_string(
    git_dir + "/config",
    "[core]\n\trepositoryformatversion = 0\n" +
    "[submodule \"example2\"]\n\turl = ./sub1\n\tactive = true\n",
  )
  fs.write_string(
    root + "/.gitmodules",
    "[submodule \"example\"]\n\tpath = init\n\turl = ./sub0\n" +
    "[submodule \"example2\"]\n\tpath = example2\n\turl = ./sub1\n",
  )

  handle_submodule_update(fs, root, git_dir, ["--quiet", "--init"])

  let example_url = read_submodule_config_value(rfs, git_dir, "example", "url")
  let example2_url = read_submodule_config_value(
    rfs, git_dir, "example2", "url",
  )
  assert_true(example_url is Some(_))
  assert_true(example2_url is Some(_))
  cleanup_tree(fs, root)
}

///|
async test "submodule add: writes explicit active when global pathspec does not match" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let root = "/tmp/bit-test-submodule-add-active-unmatched-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/t", "source\n")
  submodule_wbtest_run_git(source_dir, ["add", "t"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "source"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "--add", "submodule.active", "sub*",
  ])

  handle_submodule_add(fs, addtest_dir, addtest_dir + "/.git", [
    "-q",
    normalize_path(source_dir),
    "mod",
  ])

  let active = read_submodule_config_value(
    rfs,
    addtest_dir + "/.git",
    "mod",
    "active",
  )
  assert_eq(active, Some("true"))
  cleanup_tree(fs, root)
}

///|
async test "submodule add: skips explicit active when global pathspec matches" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let root = "/tmp/bit-test-submodule-add-active-matched-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/t", "source\n")
  submodule_wbtest_run_git(source_dir, ["add", "t"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "source"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "--add", "submodule.active", "sub*",
  ])

  handle_submodule_add(fs, addtest_dir, addtest_dir + "/.git", [
    "-q",
    normalize_path(source_dir),
    "sub1",
  ])

  let active = read_submodule_config_value(
    rfs,
    addtest_dir + "/.git",
    "sub1",
    "active",
  )
  assert_eq(active, None)
  cleanup_tree(fs, root)
}

///|
async test "submodule update: missing gitmodules path prints not initialized" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-update-missing-gitmodules-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  submodule_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/t", "t\n")
  submodule_wbtest_run_git(repo_dir, ["add", "t"])
  submodule_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  let head = trim_string(
    submodule_wbtest_git_stdout(repo_dir, ["rev-parse", "HEAD"]),
  )
  submodule_wbtest_run_git(repo_dir, [
    "update-index",
    "--add",
    "--cacheinfo",
    "160000,\{head},sub",
  ])

  let (code, stderr) = submodule_wbtest_collect_shim_git_stderr(repo_dir, [
    "submodule", "update", "sub",
  ])

  assert_eq(code, 0)
  assert_true(stderr.contains("Submodule path 'sub' not initialized"))
  cleanup_tree(fs, root)
}

///|
async test "submodule update --remote: moved source fails until set-url" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-update-remote-set-url-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let moved_source_dir = root + "/source-new"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/file", "a\n")
  submodule_wbtest_run_git(source_dir, ["add", "file"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "a"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "../source"])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-am", "add submodule"])

  fs.write_string(source_dir + "/file", "a\nb\n")
  submodule_wbtest_run_git(source_dir, ["add", "file"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "b"])
  let move_code = @process.run("mv", [source_dir, moved_source_dir])
  assert_eq(move_code, 0)

  let (update_code, _update_stderr) = submodule_wbtest_collect_shim_git_stderr(
    super_dir,
    ["submodule", "update", "--remote"],
  )
  assert_true(update_code != 0)

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "set-url", "source", "../source-new",
  ])
  let (update_after_set_url_code, _update_after_set_url_stderr) = submodule_wbtest_collect_shim_git_stderr(
    super_dir,
    ["submodule", "update", "--remote"],
  )
  assert_eq(update_after_set_url_code, 0)
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  let actual_head = submodule_wbtest_git_stdout(super_dir + "/source", [
      "rev-parse", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  let expected_head = submodule_wbtest_git_stdout(moved_source_dir, [
      "rev-parse", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(actual_head, expected_head)
  cleanup_tree(fs, root)
}

///|
async test "submodule add: template dir is read from global config" {
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-template-dir-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/home")
  let global_config = root + "/home/.gitconfig"
  fs.write_string(global_config, "[init]\n\ttemplateDir = ~/templates\n")
  let prev_home = @sys.get_env_var("HOME")
  let prev_global = @sys.get_env_var("GIT_CONFIG_GLOBAL")
  @sys.set_env_var("HOME", root + "/home")
  @sys.set_env_var("GIT_CONFIG_GLOBAL", global_config)
  let actual = submodule_add_template_dir(fs)
  submodule_wbtest_restore_env("HOME", prev_home)
  submodule_wbtest_restore_env("GIT_CONFIG_GLOBAL", prev_global)
  assert_eq(actual, Some(root + "/home/templates"))
  cleanup_tree(fs, root)
}

///|
async test "submodule add: post-checkout hook runs in submodule worktree" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-post-checkout-hook-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let work_tree = root + "/work"
  let git_dir = root + "/git"
  let hook_path = git_dir + "/hooks/post-checkout"
  fs.mkdir_p(work_tree)
  fs.mkdir_p(git_dir + "/hooks")
  fs.write_string(
    hook_path,
    "#!/bin/sh\n" + "echo hook >hook.run\n" + "exit 1\n",
  )
  let chmod_code = @process.run("chmod", ["+x", hook_path], inherit_env=true)
  assert_eq(chmod_code, 0)
  let code = submodule_run_post_checkout_hook(
    work_tree,
    git_dir,
    submodule_wbtest_id(1),
  )
  assert_eq(code, 1)
  assert_true(fs.is_file(work_tree + "/hook.run"))
  cleanup_tree(fs, root)
}

///|
async test "submodule add: template hook keeps executable bit" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-template-hook-mode-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let super_git_dir = root + "/super.git"
  let template_dir = root + "/tmpl"
  let hook_path = template_dir + "/hooks/post-checkout"
  let modules_dir = root + "/modules/sub"
  fs.mkdir_p(template_dir + "/hooks")
  fs.write_string(hook_path, "#!/bin/sh\nexit 0\n")
  let chmod_code = @process.run("chmod", ["+x", hook_path], inherit_env=true)
  assert_eq(chmod_code, 0)
  let prev_template_dir = @sys.get_env_var("GIT_TEMPLATE_DIR")
  @sys.set_env_var("GIT_TEMPLATE_DIR", template_dir)
  @bitlib.init_repo(fs, super_git_dir, bare=true)
  submodule_init_modules_repo(fs, super_git_dir, modules_dir)
  submodule_wbtest_restore_env("GIT_TEMPLATE_DIR", prev_template_dir)
  let mode = @bitio.lstat_entry_meta(modules_dir + "/hooks/post-checkout").map(meta => {
    meta.mode
  })
  assert_eq(mode, Some(0o100755))
  cleanup_tree(fs, root)
}

///|
test "submodule gitmodules: incomplete section is completed in place" {
  let content = "[submodule \"one\"]\n\tignore = all\n"
  let mut updated = submodule_upsert_config_value(content, "one", "path", "one")
  updated = submodule_upsert_config_value(updated, "one", "url", "./one")
  assert_eq(
    updated, "[submodule \"one\"]\n\tignore = all\n\tpath = one\n\turl = ./one\n",
  )
}

///|
test "submodule dispatch: quiet implies status" {
  let dispatch = parse_submodule_dispatch(["--quiet"])
  assert_eq(dispatch.subcmd, "status")
  assert_eq(dispatch.args, ["--quiet"])
  assert_false(dispatch.usage_error)
}

///|
test "submodule dispatch: leading status flag keeps explicit status" {
  let dispatch = parse_submodule_dispatch(["--cached", "status", "path"])
  assert_eq(dispatch.subcmd, "status")
  assert_eq(dispatch.args, ["--cached", "path"])
  assert_false(dispatch.usage_error)
}

///|
test "submodule dispatch: recursive without command is usage error" {
  let dispatch = parse_submodule_dispatch(["--recursive"])
  assert_true(dispatch.usage_error)
}

///|
test "submodule gitmodules: existing key is replaced before next section" {
  let content = "[submodule \"one\"]\n\tpath = wrong\n[submodule \"two\"]\n\tpath = two\n"
  let updated = submodule_upsert_config_value(content, "one", "path", "one")
  assert_eq(
    updated, "[submodule \"one\"]\n\tpath = one\n[submodule \"two\"]\n\tpath = two\n",
  )
}

///|
test "submodule index: gitlink path extraction ignores non-gitlinks" {
  let paths = submodule_index_gitlink_paths([
    submodule_wbtest_entry("plain.txt", 0o100644),
    submodule_wbtest_entry("sub", 0o160000),
  ])
  assert_eq(paths, ["sub"])
}

///|
test "submodule missing url: index gitlink without config entry is reported" {
  let missing = submodule_missing_url_paths([], ["sub"], [])
  assert_eq(missing, ["sub"])
}

///|
test "submodule missing url: empty url is treated as missing" {
  let missing = submodule_missing_url_paths(
    [{ name: "s", path: "sub", url: "" }],
    ["sub"],
    [],
  )
  assert_eq(missing, ["sub"])
}

///|
test "submodule missing url: non-index path is ignored" {
  let missing = submodule_missing_url_paths([], [], ["inner"])
  assert_eq(missing, [])
}

///|
test "submodule update: missing config url marks path uninitialized" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-uninitialized-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git")
  let submodules = [{ name: "example", path: "init", url: "./init" }]
  assert_eq(
    submodule_uninitialized_paths(fs, root + "/.git", submodules, ["init"]),
    ["init"],
  )
  fs.write_string(
    root + "/.git/config",
    "[submodule \"example\"]\n\turl = ./init\n",
  )
  assert_eq(
    submodule_uninitialized_paths(fs, root + "/.git", submodules, ["init"]),
    [],
  )
  cleanup_tree(fs, root)
}

///|
test "submodule update: missing gitmodules entry still prints not initialized path" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-update-notice-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git")
  assert_eq(
    submodule_update_notice_paths(fs, root + "/.git", [], ["sub"], ["sub"]),
    ["sub"],
  )
  fs.write_string(
    root + "/.git/config",
    "[submodule \"example\"]\n\turl = ./init\n",
  )
  assert_eq(
    submodule_update_notice_paths(
      fs,
      root + "/.git",
      [{ name: "example", path: "init", url: "./init" }],
      ["init"],
      ["init"],
    ),
    [],
  )
  cleanup_tree(fs, root)
}

///|
test "submodule add: existing index conflict requires force for gitlinks only" {
  let plain = submodule_add_existing_index_error(
    [submodule_wbtest_entry("dir-tracked/bar", 0o100644)],
    "dir-tracked",
    false,
  )
  assert_eq(plain, Some("fatal: 'dir-tracked' already exists in the index"))
  let existing_gitlink = submodule_add_existing_index_error(
    [submodule_wbtest_entry("submod", 0o160000)],
    "submod",
    false,
  )
  assert_eq(
    existing_gitlink,
    Some("fatal: 'submod' already exists in the index"),
  )
  let forced = submodule_add_existing_index_error(
    [submodule_wbtest_entry("submod", 0o160000)],
    "submod",
    true,
  )
  assert_eq(forced, None)
}

///|
test "submodule add: ignored path message includes path and hints" {
  assert_eq(submodule_add_ignored_error_lines("submod"), [
    "The following paths are ignored by one of your .gitignore files:", "submod",
    "hint: Use -f if you really want to add them.", "hint: Disable this message with \"git config set advice.addIgnoredFile false\"",
  ])
}

///|
test "submodule status: explicit non-gitlink path is unmatched" {
  let unmatched = submodule_unmatched_index_paths(["sub"], ["inner", "sub"])
  assert_eq(unmatched, ["inner"])
}

///|
test "submodule known paths: merges gitmodules and index paths" {
  let known = submodule_known_paths(
    [{ name: "s", path: "sub", url: "./sub" }],
    ["indexed"],
  )
  assert_eq(known, ["indexed", "sub"])
}

///|
test "submodule update blocker: file path rejects" {
  assert_true(submodule_update_path_blocker_kind(true, [], false))
}

///|
test "submodule update blocker: nonempty dir rejects" {
  assert_true(submodule_update_path_blocker_kind(false, ["a"], false))
}

///|
test "submodule update blocker: empty dir is allowed" {
  assert_false(submodule_update_path_blocker_kind(false, [], false))
}

///|
test "submodule update blocker: git entry is allowed" {
  assert_false(submodule_update_path_blocker_kind(false, ["a"], true))
}

///|
test "submodule add blocker: file path rejects" {
  assert_eq(submodule_add_path_blocker_kind(true, [], false), Some("path"))
}

///|
test "submodule add blocker: empty dir rejects as invalid repo" {
  assert_eq(
    submodule_add_path_blocker_kind(false, [], false),
    Some("empty_dir"),
  )
}

///|
test "submodule add blocker: existing repo is allowed" {
  assert_eq(submodule_add_path_blocker_kind(false, ["a"], true), None)
}

///|
test "submodule add blocker: occupied dir rejects" {
  assert_eq(submodule_add_path_blocker_kind(false, ["a"], false), Some("path"))
}

///|
test "submodule status: display path is relative to cwd prefix" {
  assert_eq(make_display_path("init", "sub"), "../init")
}

///|
test "submodule status: missing worktree shows index sha with dash prefix" {
  let id = submodule_wbtest_id(b'\x11')
  assert_eq(
    submodule_status_output("init", Some(id), None, false, None),
    "-\{id.to_hex()} init",
  )
}

///|
test "submodule status: cached shows index sha for modified submodule" {
  let index_id = submodule_wbtest_id(b'\x11')
  let head_id = submodule_wbtest_id(b'\x22')
  assert_eq(
    submodule_status_output("init", Some(index_id), Some(head_id), true, None),
    "+\{index_id.to_hex()} init",
  )
}

///|
test "submodule status: attached head shows branch suffix" {
  assert_eq(
    submodule_status_head_label("ref: refs/heads/main\n"),
    Some("heads/main"),
  )
  let id = submodule_wbtest_id(b'\x33')
  assert_eq(
    submodule_status_output(
      "repo",
      Some(id),
      Some(id),
      false,
      Some("heads/main"),
    ),
    " \{id.to_hex()} repo (heads/main)",
  )
}

///|
test "submodule status: detached head shows exact tag suffix" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-status-detached-label-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git/refs/tags")
  let id = submodule_wbtest_id(b'\x44')
  fs.write_string(root + "/.git/HEAD", id.to_hex() + "\n")
  fs.write_string(root + "/.git/refs/tags/test2", id.to_hex() + "\n")
  assert_eq(
    read_submodule_status_head_label(fs, root + "/.git", id),
    Some("test2"),
  )
  cleanup_tree(fs, root)
}

///|
test "submodule status: path arguments are normalized from cwd prefix" {
  let paths = normalize_submodule_status_paths(["../init"], "sub", "/repo")
  assert_eq(paths, ["init"])
}

///|
test "submodule target paths: exclude-only pathspec applies to all known paths" {
  let (paths, restrict, unmatched) = submodule_resolve_target_paths(
    @bitcore.TestFs::new(),
    "/repo/.git",
    [
      { name: "sub0", path: "sub0", url: "./sub0" },
      { name: "sub1", path: "sub1", url: "./sub1" },
      { name: "sub2", path: "sub2", url: "./sub2" },
      { name: "sub3", path: "sub3", url: "./sub3" },
    ],
    ["sub0", "sub1", "sub2", "sub3"],
    [":(exclude)sub0"],
    "/repo",
  )
  assert_true(restrict)
  assert_eq(unmatched, None)
  assert_eq(paths, ["sub1", "sub2", "sub3"])
}

///|
test "submodule target paths: dot active filter selects all known paths" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-active-dot-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git")
  fs.write_string(root + "/.git/config", "[submodule]\n\tactive = .\n")
  let (paths, restrict, unmatched) = submodule_resolve_target_paths(
    fs,
    root + "/.git",
    [
      { name: "sub0", path: "sub0", url: "./sub0" },
      { name: "sub1", path: "sub1", url: "./sub1" },
    ],
    ["sub0", "sub1"],
    [],
    root,
  )
  assert_true(restrict)
  assert_eq(unmatched, None)
  assert_eq(paths, ["sub0", "sub1"])
  cleanup_tree(fs, root)
}

///|
test "submodule target paths: global active filters restrict default update set" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-active-filters-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git")
  fs.write_string(
    root + "/.git/config",
    "[submodule]\n\tactive = .\n\tactive = :(exclude)sub0\n",
  )
  let (paths, restrict, unmatched) = submodule_resolve_target_paths(
    fs,
    root + "/.git",
    [
      { name: "sub0", path: "sub0", url: "./sub0" },
      { name: "sub1", path: "sub1", url: "./sub1" },
      { name: "sub2", path: "sub2", url: "./sub2" },
      { name: "sub3", path: "sub3", url: "./sub3" },
    ],
    ["sub0", "sub1", "sub2", "sub3"],
    [],
    root,
  )
  assert_true(restrict)
  assert_eq(unmatched, None)
  assert_eq(paths, ["sub1", "sub2", "sub3"])
  cleanup_tree(fs, root)
}

///|
test "submodule target paths: per-submodule active overrides global filters" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-active-bool-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git")
  fs.write_string(
    root + "/.git/config",
    "[submodule]\n\tactive = .\n\tactive = :(exclude)sub0\n" +
    "[submodule \"sub0\"]\n\tactive = true\n" +
    "[submodule \"sub1\"]\n\tactive = false\n",
  )
  let (paths, restrict, unmatched) = submodule_resolve_target_paths(
    fs,
    root + "/.git",
    [
      { name: "sub0", path: "sub0", url: "./sub0" },
      { name: "sub1", path: "sub1", url: "./sub1" },
      { name: "sub2", path: "sub2", url: "./sub2" },
      { name: "sub3", path: "sub3", url: "./sub3" },
    ],
    ["sub0", "sub1", "sub2", "sub3"],
    [],
    root,
  )
  assert_true(restrict)
  assert_eq(unmatched, None)
  assert_eq(paths, ["sub0", "sub2", "sub3"])
  cleanup_tree(fs, root)
}

///|
test "submodule relative url resolver matches git semantics" {
  assert_eq(
    submodule_resolve_relative_url("ssh://hostname/repo", "../subrepo", None),
    "ssh://hostname/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("ssh://hostname:22/repo", "../subrepo", None),
    "ssh://hostname:22/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("//somewhere else/repo", "../subrepo", None),
    "//somewhere else/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("file:///tmp/repo", "../subrepo", None),
    "file:///tmp/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url(
      "helper:://hostname/repo",
      "../subrepo",
      None,
    ),
    "helper:://hostname/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("user@host:repo", "../subrepo", None),
    "user@host:subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("user@host:path/to/repo", "../subrepo", None),
    "user@host:path/to/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("foo", "../subrepo", None),
    "subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("foo/bar", "../subrepo", None),
    "foo/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("./foo", "../subrepo", None),
    "subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("./foo/bar", "../subrepo", None),
    "foo/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("../foo", "../subrepo", None),
    "../subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("../foo/bar", "../subrepo", None),
    "../foo/subrepo",
  )
  assert_eq(
    submodule_resolve_relative_url("../parent.git", "../repo", Some("../")),
    "../../repo",
  )
}

///|
test "submodule add args: parses quiet progress force branch and depth" {
  let args = parse_submodule_add_args([
    "-q", "--progress", "--force", "-b", "topic", "--depth=2", "--name", "mod", "repo",
    "path",
  ])
  assert_true(args.quiet)
  assert_true(args.progress)
  assert_true(args.force)
  assert_eq(args.branch, Some("topic"))
  assert_eq(args.depth, Some(2))
  assert_eq(args.name, Some("mod"))
  assert_eq(args.url, "repo")
  assert_eq(args.path, "path")
}

///|
test "submodule add path: normalizes cwd relative and absolute destinations" {
  assert_eq(
    normalize_submodule_add_path("../realsubmod3", "sub", "/repo"),
    "realsubmod3",
  )
  assert_eq(
    normalize_submodule_add_path("././dotsubmod/./frotz/./", "", "/repo"),
    "dotsubmod/frotz",
  )
  assert_eq(
    normalize_submodule_add_path("/repo/add-abs", "", "/repo"),
    "add-abs",
  )
}

///|
test "submodule add: no-commit message uses destination path" {
  assert_eq(
    submodule_add_no_commit_message("./repo-no-commits"),
    "fatal: 'repo-no-commits' does not have a commit checked out",
  )
}

///|
test "submodule deinit paths: dot selects all and normalizes relative paths" {
  let (select_all, normalized) = normalize_submodule_deinit_paths(
    [".", "../init"],
    "sub",
    "/repo",
    false,
  )
  assert_true(select_all)
  assert_eq(normalized, ["init"])
}

///|
test "submodule config: remove core.worktree key from core section" {
  let content = "[core]\n\trepositoryformatversion = 0\n\tworktree = ../../init\n\tbare = false\n"
  let updated = remove_config_key(content, "[core]", "worktree")
  assert_false(updated.contains("worktree ="))
  assert_true(updated.contains("repositoryformatversion = 0"))
  assert_true(updated.contains("bare = false"))
}

///|
test "submodule config: parser reads path and url entries" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-config-parse-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root + "/.git")
  fs.write_string(
    root + "/.git/config",
    "[submodule \"example\"]\n\tpath = init\n\turl = ./init\n",
  )
  assert_eq(parse_submodule_config(fs, root + "/.git"), [
    { name: "example", path: "init", url: "./init" },
  ])
  cleanup_tree(fs, root)
}

///|
test "submodule status infos: ignores config-only path" {
  let merged = submodule_status_infos(
    [{ name: "example", path: "init", url: "./init" }],
    [
      { name: "example", path: "init", url: "./override" },
      { name: "example2", path: "example2", url: "./init2" },
    ],
  )
  assert_eq(merged, [{ name: "example", path: "init", url: "./override" }])
}

///|
async test "submodule status: ignores config-only entries" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-status-config-only-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  submodule_wbtest_run_git(super_dir, ["commit", "-qam", "initial"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  submodule_wbtest_run_git(super_dir, [
    "config", "submodule.add-abs.path", "add-abs",
  ])
  submodule_wbtest_run_git(super_dir, [
    "config",
    "submodule.add-abs.url",
    root + "/init",
  ])

  let status = submodule_wbtest_git_stdout(super_dir, ["submodule", "status"])
  let lines : Array[String] = []
  for line_view in status.split("\n") {
    let line = line_view.to_string()
    if line.length() > 0 {
      lines.push(line)
    }
  }
  assert_eq(lines.length(), 1)
  assert_true(lines[0].contains(" init"))

  cleanup_tree(fs, root)
}

///|
async test "submodule add: detects hash mismatch before writing gitmodules" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-hash-mismatch-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let super_dir = root + "/super"
  let sub_dir = root + "/sub"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "--object-format=sha256", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(super_dir + "/a", "a\n")
  submodule_wbtest_run_git(super_dir, ["add", "a"])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-m", "super"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "--object-format=sha1", "sub",
  ])
  submodule_wbtest_run_git(sub_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(sub_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(sub_dir + "/b", "b\n")
  submodule_wbtest_run_git(sub_dir, ["add", "b"])
  submodule_wbtest_run_git(sub_dir, ["commit", "-q", "-m", "sub"])

  let rfs : &@bitcore.RepoFileSystem = fs
  let super_git_dir = @bitlib.detect_git_dir(rfs, super_dir)
    .map(pair => pair.0)
    .unwrap()
  let sub_git_dir = @bitlib.detect_git_dir(rfs, sub_dir).map(pair => pair.0)
  assert_true(submodule_add_hash_mismatch(rfs, super_git_dir, sub_git_dir))
  assert_false(
    submodule_add_hash_mismatch(rfs, super_git_dir, Some(super_git_dir)),
  )

  let reverse_super_dir = root + "/reverse-super"
  let reverse_sub_dir = root + "/reverse-sub"
  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "--object-format=sha1", "reverse-super",
  ])
  submodule_wbtest_run_git(reverse_super_dir, [
    "config", "user.name", "Test User",
  ])
  submodule_wbtest_run_git(reverse_super_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(reverse_super_dir + "/c", "c\n")
  submodule_wbtest_run_git(reverse_super_dir, ["add", "c"])
  submodule_wbtest_run_git(reverse_super_dir, [
    "commit", "-q", "-m", "reverse-super",
  ])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "--object-format=sha256", "reverse-sub",
  ])
  submodule_wbtest_run_git(reverse_sub_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(reverse_sub_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(reverse_sub_dir + "/d", "d\n")
  submodule_wbtest_run_git(reverse_sub_dir, ["add", "d"])
  submodule_wbtest_run_git(reverse_sub_dir, [
    "commit", "-q", "-m", "reverse-sub",
  ])

  let reverse_super_git_dir = @bitlib.detect_git_dir(rfs, reverse_super_dir)
    .map(pair => pair.0)
    .unwrap()
  let reverse_sub_git_dir = @bitlib.detect_git_dir(rfs, reverse_sub_dir).map(pair => {
    pair.0
  })
  assert_true(
    submodule_add_hash_mismatch(rfs, reverse_super_git_dir, reverse_sub_git_dir),
  )

  cleanup_tree(fs, root)
}

///|
async test "submodule deinit: unregisters config and removes worktree gitfile" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-deinit-basic-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  handle_submodule_deinit(fs, super_dir, super_dir + "/.git", ["-q", "init"])

  let config_content = decode_bytes(fs.read_file(super_dir + "/.git/config"))
  let module_config = decode_bytes(
    fs.read_file(super_dir + "/.git/modules/init/config"),
  )
  assert_false(config_content.contains("[submodule \"init\"]"))
  assert_false(module_config.contains("worktree ="))
  assert_false(fs.is_file(super_dir + "/init/.git"))
  assert_true(fs.is_dir(super_dir + "/init"))
  assert_eq(fs.readdir(super_dir + "/init").length(), 0)

  cleanup_tree(fs, root)
}

///|
async test "submodule deinit: missing worktree path is recreated as empty directory" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-deinit-missing-worktree-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  submodule_wbtest_run_git(super_dir, ["commit", "-qam", "initial"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  cleanup_tree(fs, super_dir + "/init")
  submodule_wbtest_run_shim_git(super_dir, ["submodule", "init", "--quiet"])
  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "deinit", "--quiet", "init",
  ])

  let config_content = decode_bytes(fs.read_file(super_dir + "/.git/config"))
  assert_false(config_content.contains("[submodule \"init\"]"))
  assert_true(fs.is_dir(super_dir + "/init"))
  assert_eq(fs.readdir(super_dir + "/init").length(), 0)
  assert_false(fs.is_file(super_dir + "/init/.git"))

  cleanup_tree(fs, root)
}

///|
async test "submodule deinit: cli path removes config-only entry from gitmodules path" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-deinit-cli-config-only-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  fs.mkdir_p(super_dir + "/init")
  fs.mkdir_p(super_dir + "/.git/modules/example")
  fs.write_string(
    super_dir + "/.gitmodules",
    "[submodule \"example\"]\n\tpath = init\n\turl = " +
    root +
    "/init2\n" +
    "[submodule \"example2\"]\n\tpath = example2\n\turl = ./init2\n",
  )
  fs.write_string(
    super_dir + "/.git/config",
    "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n" +
    "[submodule \"example\"]\n\tactive = true\n\turl = " +
    root +
    "/init2\n\tfoo = bar\n" +
    "[submodule \"example2\"]\n\turl = ./init2\n\tpath = example2\n\tfrotz = nitfol\n",
  )
  fs.write_string(
    super_dir + "/.git/modules/example/config",
    "[core]\n\tworktree = ../../../init\n",
  )

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "deinit", "--quiet", "init",
  ])

  let config_content = decode_bytes(fs.read_file(super_dir + "/.git/config"))
  let module_config = decode_bytes(
    fs.read_file(super_dir + "/.git/modules/example/config"),
  )
  assert_false(config_content.contains("[submodule \"example\"]"))
  assert_true(config_content.contains("[submodule \"example2\"]"))
  assert_false(module_config.contains("worktree ="))

  cleanup_tree(fs, root)
}

///|
test "submodule gitmodules: url without path is treated as unmapped" {
  assert_true(
    gitmodules_has_unmapped_paths(
      "[submodule \"example\"]\n\turl = git://example.com/init.git\n",
    ),
  )
  assert_false(
    gitmodules_has_unmapped_paths("[submodule \"one\"]\n\tignore = all\n"),
  )
}

///|
async test "submodule update: recreates missing worktree before writing gitfile" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-update-recreate-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])
  let rev1 = submodule_wbtest_git_stdout(init_dir, ["rev-parse", "HEAD"])
    |> add_test_trim_trailing_newline

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  submodule_wbtest_run_git(super_dir, ["commit", "-qam", "initial"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  cleanup_tree(fs, super_dir + "/init")
  submodule_wbtest_run_shim_git(super_dir, ["submodule", "init", "--quiet"])
  submodule_wbtest_run_shim_git(super_dir, ["submodule", "update", "-q"])

  assert_true(fs.is_dir(super_dir + "/init"))
  assert_true(fs.is_file(super_dir + "/init/.git"))
  assert_true(fs.is_file(super_dir + "/init/a"))
  let head = submodule_wbtest_git_stdout(super_dir + "/init", [
      "rev-parse", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(head, rev1)

  cleanup_tree(fs, root)
}

///|
async test "submodule update: linked worktree reads shared submodule config" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-update-linked-worktree-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let super_dir = submodule_wbtest_setup_deinit_repo(root)
  let linked_dir = super_dir + "/to-remove"

  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-am", "initial"])
  submodule_wbtest_run_git(super_dir, ["worktree", "add", "to-remove", "HEAD"])
  let linked_git_dir = submodule_wbtest_git_stdout(linked_dir, [
      "rev-parse", "--git-dir",
    ])
    |> add_test_trim_trailing_newline
  assert_true(
    read_submodule_config_value(fs, linked_git_dir, "init", "url") is Some(_),
  )

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_shim_git(linked_dir, ["submodule", "update", "--quiet"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  assert_true(fs.is_file(linked_dir + "/init/.git"))
  let head = submodule_wbtest_git_stdout(linked_dir + "/init", [
    "rev-parse", "HEAD",
  ])
  assert_true(add_test_trim_trailing_newline(head).length() > 0)
  cleanup_tree(fs, root)
}

///|
async test "submodule update: restores deinitialized worktree when another submodule exists" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-update-two-submodules-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let other_dir = root + "/other"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])
  let init_head = submodule_wbtest_git_stdout(init_dir, ["rev-parse", "HEAD"])
    |> add_test_trim_trailing_newline

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "other",
  ])
  submodule_wbtest_run_git(other_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(other_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(other_dir + "/b", "b\n")
  submodule_wbtest_run_git(other_dir, ["add", "b"])
  submodule_wbtest_run_git(other_dir, ["commit", "-q", "-m", "initial"])
  let other_head = submodule_wbtest_git_stdout(other_dir, ["rev-parse", "HEAD"])
    |> add_test_trim_trailing_newline

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, ["submodule", "add", "./../init", "init"])
  submodule_wbtest_run_git(super_dir, [
    "submodule", "add", "./../other", "other",
  ])
  submodule_wbtest_run_git(super_dir, ["commit", "-qam", "initial"])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "deinit", "--quiet", "init",
  ])
  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "update", "--quiet", "--init",
  ])

  assert_true(fs.is_dir(super_dir + "/init"))
  assert_true(fs.is_file(super_dir + "/init/.git"))
  assert_true(fs.is_file(super_dir + "/init/a"))
  let restored_init = submodule_wbtest_git_stdout(super_dir + "/init", [
      "rev-parse", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(restored_init, init_head)

  assert_true(fs.is_dir(super_dir + "/other"))
  assert_true(fs.is_file(super_dir + "/other/.git"))
  let restored_other = submodule_wbtest_git_stdout(super_dir + "/other", [
      "rev-parse", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(restored_other, other_head)

  cleanup_tree(fs, root)
}

///|
async test "submodule init: relative url resolves against origin remote" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-init-relative-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let reltest_dir = root + "/reltest"
  let sub_dir = reltest_dir + "/sub"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "reltest",
  ])
  submodule_wbtest_run_git(reltest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(reltest_dir, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(reltest_dir, [
    "init", "--initial-branch=main", "-q", "sub",
  ])
  submodule_wbtest_run_git(sub_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(sub_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(sub_dir + "/a", "a\n")
  submodule_wbtest_run_git(sub_dir, ["add", "a"])
  submodule_wbtest_run_git(sub_dir, ["commit", "-q", "-m", "initial"])
  submodule_wbtest_run_git(reltest_dir, ["add", "sub"])
  submodule_wbtest_run_git(reltest_dir, [
    "config", "-f", ".gitmodules", "submodule.sub.path", "sub",
  ])
  submodule_wbtest_run_git(reltest_dir, [
    "config", "-f", ".gitmodules", "submodule.sub.url", "../subrepo",
  ])
  submodule_wbtest_run_git(reltest_dir, [
    "config", "remote.origin.url", "ssh://hostname/repo",
  ])

  submodule_wbtest_run_shim_git(reltest_dir, ["submodule", "init", "--quiet"])

  let config_url = submodule_wbtest_git_stdout(reltest_dir, [
      "config", "--get", "submodule.sub.url",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(config_url, "ssh://hostname/subrepo")

  cleanup_tree(fs, root)
}

///|
async test "submodule add: relative repo with normalized path keeps resolved config url" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-relative-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let reltest_dir = root + "/reltest"
  let nested_dir = reltest_dir + "/a/b/c"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "reltest",
  ])
  submodule_wbtest_run_git(reltest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(reltest_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.mkdir_p(nested_dir)
  submodule_wbtest_run_git(nested_dir, ["init", "--initial-branch=main", "-q"])
  submodule_wbtest_run_git(nested_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(nested_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(nested_dir + "/msg", "msg\n")
  submodule_wbtest_run_git(nested_dir, ["add", "msg"])
  submodule_wbtest_run_git(nested_dir, ["commit", "-q", "-m", "msg"])
  submodule_wbtest_run_git(reltest_dir, [
    "config", "remote.origin.url", "../foo/bar.git",
  ])

  submodule_wbtest_run_shim_git(reltest_dir, [
    "submodule", "add", "-q", "../bar/a/b/c", "./a/b/c",
  ])
  submodule_wbtest_run_shim_git(reltest_dir, ["submodule", "init", "--quiet"])

  let config_url = submodule_wbtest_git_stdout(reltest_dir, [
      "config", "--get", "submodule.a/b/c.url",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(config_url, "../foo/bar/a/b/c")

  cleanup_tree(fs, root)
}

///|
async test "submodule add: quiet suppresses fetch stderr and writes expected gitdir layout" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-quiet-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  submodule_wbtest_run_git(root, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/a", "a\n")
  submodule_wbtest_run_git(root, ["add", "a"])
  submodule_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])

  submodule_wbtest_run_shim_git(addtest_dir, [
    "submodule",
    "add",
    "-q",
    normalize_path(root),
    "submod",
  ])

  let dotgit = decode_bytes(fs.read_file(addtest_dir + "/submod/.git"))
  let core_worktree = submodule_wbtest_git_stdout(addtest_dir + "/submod", [
      "config", "--get", "core.worktree",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(dotgit, "gitdir: ../.git/modules/submod\n")
  assert_eq(core_worktree, "../../../submod")

  cleanup_tree(fs, root)
}

///|
async test "submodule add: depth=1 keeps shallow history for local file url" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit test-submodule-add-depth-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/example2"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "example2",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/a", "one\n")
  submodule_wbtest_run_git(source_dir, ["add", "a"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "one"])
  fs.write_string(source_dir + "/b", "two\n")
  submodule_wbtest_run_git(source_dir, ["add", "b"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "two"])
  let head_id = submodule_wbtest_git_stdout(source_dir, ["rev-parse", "HEAD"])
    |> add_test_trim_trailing_newline

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule",
    "add",
    "-q",
    "--depth=1",
    "file://" + normalize_path(source_dir),
    "submodule",
  ])

  let count = submodule_wbtest_git_stdout(super_dir + "/submodule", [
      "rev-list", "--count", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  let shallow = decode_bytes(
    fs.read_file(super_dir + "/.git/modules/submodule/shallow"),
  )
  assert_eq(count, "1")
  assert_eq(shallow, head_id + "\n")

  cleanup_tree(fs, root)
}

///|
async test "submodule add: detached local source still copies target history" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-detached-source-" +
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
  fs.write_string(source_dir + "/a", "one\n")
  submodule_wbtest_run_git(source_dir, ["add", "a"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "one"])
  fs.write_string(source_dir + "/b", "two\n")
  submodule_wbtest_run_git(source_dir, ["add", "b"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "two"])
  submodule_wbtest_run_git(source_dir, ["checkout", "--detach", "-q", "HEAD"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule",
    "add",
    "-q",
    normalize_path(source_dir),
    "submodule",
  ])

  let count = submodule_wbtest_git_stdout(super_dir + "/submodule", [
      "rev-list", "--count", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  submodule_wbtest_run_git(super_dir + "/submodule", ["checkout", "-q", "HEAD^"])
  assert_eq(count, "2")

  cleanup_tree(fs, root)
}

///|
async test "submodule add: cloned gitlink repo stays clean for diff-files" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-clean-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let addtest_dir = root + "/addtest"
  let init_dir = root + "/init"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  submodule_wbtest_run_git(root, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/t", "")
  submodule_wbtest_run_git(root, ["add", "t"])
  submodule_wbtest_run_git(root, ["commit", "-q", "-m", "initial commit"])

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "init"])
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, [
    "commit", "-q", "-m", "submodule commit 1",
  ])

  fs.write_string(root + "/a", "a\n")
  fs.write_string(root + "/z", "z\n")
  submodule_wbtest_run_git(root, ["add", "a", "init", "z"])
  submodule_wbtest_run_git(root, ["commit", "-q", "-m", "super commit 1"])
  let mv_code = @process.run(
    "mv",
    [init_dir, root + "/.subrepo"],
    inherit_env=true,
  )
  assert_eq(mv_code, 0)

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])

  submodule_wbtest_run_shim_git(addtest_dir, [
    "submodule",
    "add",
    "-q",
    normalize_path(root),
    "submod",
  ])
  submodule_wbtest_run_git(addtest_dir + "/submod", [
    "update-index", "--refresh",
  ])

  let stale = collect_diff_index_stale_entries(fs, addtest_dir + "/submod", [])
  assert_eq(stale.map(entry => entry.path), [])

  cleanup_tree(fs, root)
}

///|
async test "submodule add: target id follows requested branch" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-branch-target-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  submodule_wbtest_run_git(root, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/t", "main\n")
  submodule_wbtest_run_git(root, ["add", "t"])
  submodule_wbtest_run_git(root, ["commit", "-q", "-m", "main"])
  submodule_wbtest_run_git(root, ["branch", "initial"])
  submodule_wbtest_run_git(root, ["checkout", "-q", "initial"])
  fs.write_string(root + "/t", "initial\n")
  submodule_wbtest_run_git(root, ["commit", "-qam", "initial"])
  let initial_id = submodule_wbtest_git_stdout(root, ["rev-parse", "HEAD"])
    |> add_test_trim_trailing_newline
  submodule_wbtest_run_git(root, ["checkout", "-q", "main"])

  let resolved = resolve_submodule_target_id(
    fs,
    root,
    normalize_path(root),
    Some("initial"),
  )
  assert_eq(resolved.to_hex(), initial_id)

  cleanup_tree(fs, root)
}

///|
async test "submodule add: force reconfigure existing submodule does not refetch" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-force-reconfigure-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/t", "source\n")
  submodule_wbtest_run_git(source_dir, ["add", "t"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "source"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])
  let addtest_git_dir = addtest_dir + "/.git"
  handle_submodule_add(fs, addtest_dir, addtest_git_dir, [
    "-q",
    normalize_path(source_dir),
    "submod",
  ])
  let bogus_url = normalize_path(addtest_dir + "/bogus-url")
  handle_submodule_add(fs, addtest_dir, addtest_git_dir, [
    "-q", "--force", bogus_url, "submod",
  ])

  let gitmodules_url = submodule_wbtest_git_stdout(addtest_dir, [
      "config", "-f", ".gitmodules", "--get", "submodule.submod.url",
    ])
    |> add_test_trim_trailing_newline
  let config_url = submodule_wbtest_git_stdout(addtest_dir, [
      "config", "--get", "submodule.submod.url",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(gitmodules_url, bogus_url)
  assert_eq(config_url, bogus_url)
  cleanup_tree(fs, root)
}

///|
async test "submodule add: reused name requires force after git rm" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-force-reuse-name-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/t", "source\n")
  submodule_wbtest_run_git(source_dir, ["add", "t"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "source"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])
  let source_url = normalize_path(source_dir)
  let bogus_url = normalize_path(root + "/missing-source.git")
  submodule_wbtest_run_git(addtest_dir, [
    "submodule", "add", "--name", "repo_new", source_url, "repo",
  ])
  cleanup_tree(fs, addtest_dir + "/repo")
  submodule_wbtest_run_git(addtest_dir, ["rm", "-q", "repo"])
  let addtest_git_dir = addtest_dir + "/.git"
  assert_true(fs.is_dir(addtest_dir + "/.git/modules/repo_new"))

  let (fail_code, _fail_stderr) = submodule_wbtest_git_stderr(addtest_dir, [
    "submodule", "add", "-q", "--name", "repo_new", bogus_url, "repo",
  ])
  assert_eq(fail_code, 128)
  assert_false(fs.is_dir(addtest_dir + "/repo"))
  let preserved_url = submodule_wbtest_git_stdout(addtest_dir, [
      "config", "--get", "submodule.repo_new.url",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(preserved_url, source_url)

  handle_submodule_add(fs, addtest_dir, addtest_git_dir, [
    "-f", "-q", "--name", "repo_new", bogus_url, "repo",
  ])

  let gitmodules_url = submodule_wbtest_git_stdout(addtest_dir, [
      "config", "-f", ".gitmodules", "--get", "submodule.repo_new.url",
    ])
    |> add_test_trim_trailing_newline
  let config_url = submodule_wbtest_git_stdout(addtest_dir, [
      "config", "--get", "submodule.repo_new.url",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(gitmodules_url, bogus_url)
  assert_eq(config_url, bogus_url)
  assert_eq(
    decode_bytes(fs.read_file(addtest_dir + "/repo/.git")),
    "gitdir: ../.git/modules/repo_new\n",
  )
  cleanup_tree(fs, root)
}

///|
async test "submodule add: --name keeps separate module name and path" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-name-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/t", "source\n")
  submodule_wbtest_run_git(source_dir, ["add", "t"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "source"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])
  let addtest_git_dir = addtest_dir + "/.git"
  handle_submodule_add(fs, addtest_dir, addtest_git_dir, [
    "-q",
    "--name",
    "repo_new",
    normalize_path(source_dir),
    "repo",
  ])

  let gitmodules = decode_bytes(fs.read_file(addtest_dir + "/.gitmodules"))
  let config_content = decode_bytes(fs.read_file(addtest_dir + "/.git/config"))
  assert_true(gitmodules.contains("[submodule \"repo_new\"]"))
  assert_true(gitmodules.contains("path = repo"))
  assert_true(config_content.contains("[submodule \"repo_new\"]"))
  assert_true(config_content.contains("path = repo"))
  assert_true(fs.is_dir(addtest_dir + "/.git/modules/repo_new"))
  assert_eq(
    decode_bytes(fs.read_file(addtest_dir + "/repo/.git")),
    "gitdir: ../.git/modules/repo_new\n",
  )

  cleanup_tree(fs, root)
}

///|
async test "submodule add: moved submodule name stays reserved" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-name-reserved-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let super_dir = root + "/super"
  let child_origin = root + "/child-origin"
  let child2_origin = root + "/child2-origin"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(super_dir, [
    "commit", "--allow-empty", "-q", "-m", "init",
  ])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "child-origin",
  ])
  submodule_wbtest_run_git(child_origin, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(child_origin, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(child_origin, [
    "commit", "--allow-empty", "-q", "-m", "init",
  ])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "child2-origin",
  ])
  submodule_wbtest_run_git(child2_origin, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(child2_origin, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(child2_origin, [
    "commit", "--allow-empty", "-q", "-m", "init",
  ])

  submodule_wbtest_run_git(super_dir, [
    "submodule",
    "add",
    normalize_path(child_origin),
    "child",
  ])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-m", "add child"])
  submodule_wbtest_run_git(super_dir, ["mv", "child", "child_old"])
  submodule_wbtest_run_git(super_dir, ["commit", "-q", "-m", "move child"])

  let reserved_path = submodule_add_reserved_name_path(
    fs,
    super_dir,
    super_dir + "/.git",
    "child",
  )
  assert_eq(reserved_path, Some("child_old"))
  assert_true(
    submodule_add_name_in_use_error("child", "child_old").contains(
      "already used for",
    ),
  )
  cleanup_tree(fs, root)
}

///|
async test "submodule add: branch keeps default branch head alongside requested branch" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-add-branch-heads-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let source_dir = root + "/source"
  let addtest_dir = root + "/addtest"

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "source",
  ])
  submodule_wbtest_run_git(source_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(source_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(source_dir + "/t", "main\n")
  submodule_wbtest_run_git(source_dir, ["add", "t"])
  submodule_wbtest_run_git(source_dir, ["commit", "-q", "-m", "main"])
  submodule_wbtest_run_git(source_dir, ["branch", "initial"])
  submodule_wbtest_run_git(source_dir, ["checkout", "-q", "initial"])
  fs.write_string(source_dir + "/t", "initial\n")
  submodule_wbtest_run_git(source_dir, ["commit", "-qam", "initial"])
  submodule_wbtest_run_git(source_dir, ["checkout", "-q", "main"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "addtest",
  ])
  submodule_wbtest_run_git(addtest_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(addtest_dir, [
    "config", "user.email", "test@example.com",
  ])
  let addtest_git_dir = addtest_dir + "/.git"
  handle_submodule_add(fs, addtest_dir, addtest_git_dir, [
    "-q",
    "-b",
    "initial",
    normalize_path(source_dir),
    "submod-branch",
  ])
  handle_submodule_init(fs, addtest_dir, addtest_git_dir, ["--quiet"])

  let head_ref = submodule_wbtest_git_stdout(addtest_dir + "/submod-branch", [
      "symbolic-ref", "HEAD",
    ])
    |> add_test_trim_trailing_newline
  let branch_heads = submodule_wbtest_git_stdout(
      addtest_dir + "/submod-branch",
      ["for-each-ref", "--format=%(refname)", "refs/heads/*"],
    )
    |> add_test_trim_trailing_newline
  assert_eq(head_ref, "refs/heads/initial")
  assert_eq(branch_heads, "refs/heads/initial\nrefs/heads/main")
  cleanup_tree(fs, root)
}

///|
async test "submodule sync: relative url resolves against superproject root when origin is absent" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-sync-relative-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  submodule_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  submodule_wbtest_run_git(repo_dir, ["add", "a"])
  submodule_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, [
    "submodule", "add", "../repo", "relative",
  ])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "sync", "--quiet", "relative",
  ])

  let config_url = submodule_wbtest_git_stdout(super_dir, [
      "config", "--get", "submodule.relative.url",
    ])
    |> add_test_trim_trailing_newline
  let sub_origin = submodule_wbtest_git_stdout(super_dir + "/relative", [
      "config", "--get", "remote.origin.url",
    ])
    |> add_test_trim_trailing_newline
  let expected = normalize_path(root + "/repo")
  assert_eq(config_url, expected)
  assert_eq(sub_origin, expected)

  cleanup_tree(fs, root)
}

///|
async test "submodule sync: relative url stays relative in config when origin exists" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-submodule-sync-origin-relative-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let super_dir = root + "/super"

  submodule_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  submodule_wbtest_run_git(repo_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(repo_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(repo_dir + "/a", "a\n")
  submodule_wbtest_run_git(repo_dir, ["add", "a"])
  submodule_wbtest_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  submodule_wbtest_run_git(root, ["init", "--bare", "-q", "parent.git"])
  submodule_wbtest_run_git(root, [
    "init", "--initial-branch=main", "-q", "super",
  ])
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])
  submodule_wbtest_run_git(super_dir, [
    "remote", "add", "origin", "../parent.git",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  submodule_wbtest_run_git(super_dir, [
    "submodule", "add", "../repo", "relative",
  ])
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  submodule_wbtest_run_shim_git(super_dir, [
    "submodule", "sync", "--quiet", "relative",
  ])

  let config_url = submodule_wbtest_git_stdout(super_dir, [
      "config", "--get", "submodule.relative.url",
    ])
    |> add_test_trim_trailing_newline
  let sub_origin = submodule_wbtest_git_stdout(super_dir + "/relative", [
      "config", "--get", "remote.origin.url",
    ])
    |> add_test_trim_trailing_newline
  assert_eq(config_url, "../repo")
  assert_eq(sub_origin, "../../repo")

  cleanup_tree(fs, root)
}
