///|
test "rev-list: short max-count helpers detect numeric forms" {
  assert_true(rev_list_is_short_max_count_arg("-1"))
  assert_true(rev_list_is_short_max_count_arg("-123"))
  assert_false(rev_list_is_short_max_count_arg("-n1"))
  assert_false(rev_list_is_short_max_count_arg("-q"))
}

///|
test "rev-list: window honors skip and max-count" {
  assert_eq(rev_list_window(5, 0, None), (0, 5))
  assert_eq(rev_list_window(5, 3, None), (3, 5))
  assert_eq(rev_list_window(5, 3, Some(0)), (3, 3))
  assert_eq(rev_list_window(5, 3, Some(2)), (3, 5))
  assert_eq(rev_list_window(5, 10, Some(2)), (5, 5))
}

///|
test "rev-list: negative max-count is treated as unlimited" {
  assert_eq(rev_list_normalize_max_count(Some(-1)), None)
  assert_eq(rev_list_collection_limit(3, Some(-1)), 2147483647)
  assert_eq(rev_list_window(5, 0, Some(-1)), (0, 5))
}

///|
test "rev-list: cherry options require real git fallback" {
  assert_true(rev_list_requires_real_git(["--cherry-pick", "A...B"]))
  assert_true(rev_list_requires_real_git(["--cherry-mark", "A...B"]))
  assert_true(rev_list_requires_real_git(["--cherry", "A...B"]))
  assert_false(rev_list_requires_real_git(["--left-right", "A...B"]))
}

///|
async fn rev_list_test_init_repo(
  root : String,
  repo_dir : String,
) -> Unit raise Error {
  rev_list_test_run_git(root, ["init", "-q", "repo"])
  rev_list_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  rev_list_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
}

///|
async fn rev_list_test_run_git(
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
async fn rev_list_test_git_stdout(
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
async fn rev_list_test_run_shim_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": wbtest_resolve_real_git(repo_root),
    "SHIM_REAL_GIT_FALLBACK": "",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": repo_root + "/_build/native/release/build/cmd/bit/bit.exe",
    "SHIM_CMDS": "init status add commit log show branch checkout switch reset rebase stash cherry-pick diff diff-files diff-index merge tag rm mv config sparse-checkout restore rev-parse cat-file ls-files hash-object ls-tree write-tree show-ref update-ref update-index symbolic-ref reflog worktree gc clean grep submodule revert notes bisect describe blame format-patch shortlog remote clone fetch pull push receive-pack upload-pack pack-objects index-pack shell",
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
  assert_eq(code, 0)
  assert_eq(text, "")
}

///|
async fn rev_list_test_shim_git_stdout(
  cwd : String,
  args : Array[String],
) -> String raise Error {
  let repo_root = @env.current_dir().unwrap_or(".")
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": wbtest_resolve_real_git(repo_root),
    "SHIM_REAL_GIT_FALLBACK": "",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": repo_root + "/_build/native/release/build/cmd/bit/bit.exe",
    "SHIM_CMDS": "init status add commit log show branch checkout switch reset rebase stash cherry-pick diff diff-files diff-index merge tag rm mv config sparse-checkout restore rev-parse cat-file ls-files hash-object ls-tree write-tree show-ref update-ref update-index symbolic-ref reflog worktree gc clean grep submodule revert notes bisect describe blame format-patch shortlog remote clone fetch pull push receive-pack upload-pack pack-objects index-pack shell",
    "SHIM_STRICT": "1",
  }
  let git_args : Array[String] = ["-C", cwd]
  for arg in args {
    git_args.push(arg)
  }
  let (code, stdout, _) = @process.collect_output(
    shim_git,
    git_args[:],
    extra_env=env,
    inherit_env=true,
  )
  assert_eq(code, 0)
  stdout.text() catch {
    _ => ""
  }
}

///|
fn rev_list_trim_trailing_newline(s : String) -> String {
  if s.has_suffix("\n") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
async test "rev-list: indexed-objects includes staged blobs and cached subtree" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-indexed-objects-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])

  let one_blob = rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:one"])
  let two_tree = rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:two"])

  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_git(repo_dir, ["add", "only-in-index"])
  let only_blob = rev_list_test_git_stdout(repo_dir, [
    "hash-object", "only-in-index",
  ])
  let actual = rev_list_test_git_stdout(repo_dir, [
    "rev-list", "--objects", "--indexed-objects",
  ])
  let expected = rev_list_trim_trailing_newline(one_blob) +
    " one\n" +
    rev_list_trim_trailing_newline(only_blob) +
    " only-in-index\n" +
    rev_list_trim_trailing_newline(two_tree) +
    " two"
  assert_eq(rev_list_trim_trailing_newline(actual), expected)

  cleanup_tree(fs, root)
}

///|
async test "rev-list: not indexed-objects suppresses tree and blob output" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-negate-indexed-objects-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])

  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_git(repo_dir, ["add", "only-in-index"])

  let head = rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD"])
  let root_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD^{tree}"]),
  )
  let actual = rev_list_test_git_stdout(repo_dir, [
    "rev-list", "-1", "--objects", "HEAD", "--not", "--indexed-objects",
  ])
  assert_eq(
    rev_list_trim_trailing_newline(actual),
    rev_list_trim_trailing_newline(head) + "\n" + root_tree + " ",
  )

  cleanup_tree(fs, root)
}

///|
async test "rev-list: indexed-objects tracks head tree ids even with extra staged paths" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-index-tree-coverage-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])
  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_git(repo_dir, ["add", "only-in-index"])
  let two_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:two"]),
  )

  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let result = rev_list_collect_index_objects(db, fs, git_dir, index_entries)
  let head_id = @bitrepo.rev_parse(fs, git_dir, "HEAD")
  guard head_id is Some(commit_id) else { fail("expected HEAD commit") }
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(obj) else { fail("expected commit object") }
  let info = @bitcore.parse_commit(obj.data)
  match result.1.get("") {
    Some(root_tree_hex) => assert_eq(root_tree_hex, info.tree.to_hex())
    None => fail("expected root tree entry")
  }
  assert_true(
    result.0.any(fn(item) { item.1 == "two" && item.0.to_hex() == two_tree }),
  )

  cleanup_tree(fs, root)
}

///|
async test "rev-list: indexed-objects keeps cached subtree after empty head commit" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-index-tree-empty-head-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])
  rev_list_test_run_git(repo_dir, ["commit", "--allow-empty", "-qm", "another"])
  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_git(repo_dir, ["add", "only-in-index"])

  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let result = rev_list_collect_index_objects(db, fs, git_dir, index_entries)
  let two_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:two"]),
  )

  assert_true(result.1.contains("two"))
  match result.1.get("two") {
    Some(hex) => assert_eq(hex, two_tree)
    None => fail("expected subtree cache-tree id")
  }
  assert_true(
    result.0.any(fn(item) { item.1 == "two" && item.0.to_hex() == two_tree }),
  )

  cleanup_tree(fs, root)
}

///|
async test "rev-list: shim setup keeps cached subtree after empty head commit" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-shim-index-tree-empty-head-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  rev_list_test_run_shim_git(root, ["init", "-q", "repo"])
  rev_list_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  rev_list_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_shim_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_shim_git(repo_dir, ["commit", "-m", "that"])
  rev_list_test_run_shim_git(repo_dir, [
    "commit", "--allow-empty", "-m", "another",
  ])
  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_shim_git(repo_dir, ["add", "only-in-index"])

  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let result = rev_list_collect_index_objects(db, fs, git_dir, index_entries)
  let two_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:two"]),
  )

  assert_true(result.1.contains("two"))
  match result.1.get("two") {
    Some(hex) => assert_eq(hex, two_tree)
    None => fail("expected subtree cache-tree id")
  }
  assert_true(
    result.0.any(fn(item) { item.1 == "two" && item.0.to_hex() == two_tree }),
  )

  cleanup_tree(fs, root)
}

///|
async test "rev-list: shim setup preserves cached subtree for indexed output" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-shim-indexed-output-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  rev_list_test_run_shim_git(root, ["init", "-q", "repo"])
  rev_list_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  rev_list_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_shim_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_shim_git(repo_dir, ["commit", "-m", "that"])
  rev_list_test_run_shim_git(repo_dir, [
    "commit", "--allow-empty", "-m", "another",
  ])
  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_shim_git(repo_dir, ["add", "only-in-index"])

  let one_blob = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:one"]),
  )
  let two_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:two"]),
  )
  let only_blob = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["hash-object", "only-in-index"]),
  )
  let actual = rev_list_trim_trailing_newline(
    rev_list_test_shim_git_stdout(repo_dir, [
      "rev-list", "--objects", "--indexed-objects",
    ]),
  )
  let expected = one_blob +
    " one\n" +
    only_blob +
    " only-in-index\n" +
    two_tree +
    " two"
  assert_eq(actual, expected)

  cleanup_tree(fs, root)
}

///|
async test "rev-list: shim allow-empty commit preserves indexed tree objects" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-shim-empty-commit-indexed-output-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  rev_list_test_run_shim_git(root, ["init", "-q", "repo"])
  rev_list_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  rev_list_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_shim_git(repo_dir, ["add", "one", "two/three"])
  assert_true(
    rev_list_bytes_contains_ascii(
      fs.read_file(repo_dir + "/.git/index"),
      "TREE",
    ),
  )
  rev_list_test_run_shim_git(repo_dir, ["commit", "-m", "that"])
  assert_true(
    rev_list_bytes_contains_ascii(
      fs.read_file(repo_dir + "/.git/index"),
      "TREE",
    ),
  )
  rev_list_test_run_shim_git(repo_dir, [
    "commit", "--allow-empty", "-m", "another",
  ])
  let index_bytes = fs.read_file(repo_dir + "/.git/index")
  assert_true(rev_list_bytes_contains_ascii(index_bytes, "TREE"))

  let one_blob = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:one"]),
  )
  let root_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD^{tree}"]),
  )
  let two_tree = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD:two"]),
  )
  let actual = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, [
      "rev-list", "--objects", "--indexed-objects",
    ]),
  )
  let expected = one_blob + " one\n" + root_tree + " \n" + two_tree + " two"
  assert_eq(actual, expected)

  cleanup_tree(fs, root)
}

///|
fn rev_list_bytes_contains_ascii(bytes : Bytes, text : String) -> Bool {
  let needle = @utf8.encode(text)
  if needle.length() == 0 {
    return true
  }
  if bytes.length() < needle.length() {
    return false
  }
  for start in 0..<=(bytes.length() - needle.length()) {
    let mut matched = true
    for i in 0..<needle.length() {
      if bytes[start + i] != needle[i] {
        matched = false
        break
      }
    }
    if matched {
      return true
    }
  }
  false
}

///|
async test "rev-list: shim setup negates cached tree objects for real rev-list" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-shim-negated-output-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  rev_list_test_run_shim_git(root, ["init", "-q", "repo"])
  rev_list_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  rev_list_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_shim_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_shim_git(repo_dir, ["commit", "-m", "that"])
  rev_list_test_run_shim_git(repo_dir, [
    "commit", "--allow-empty", "-m", "another",
  ])

  let head = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD"]),
  )
  let actual = rev_list_trim_trailing_newline(
    rev_list_test_shim_git_stdout(repo_dir, [
      "rev-list", "-1", "--objects", "HEAD", "--not", "--indexed-objects",
    ]),
  )
  assert_eq(actual, head)

  cleanup_tree(fs, root)
}

///|
async test "rev-list: negated indexed-objects suppresses clean head tree" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-negate-clean-index-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])

  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let result = rev_list_collect_index_objects(db, fs, git_dir, index_entries)
  let head_id = @bitrepo.rev_parse(fs, git_dir, "HEAD")
  guard head_id is Some(commit_id) else { fail("expected HEAD commit") }
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(obj) else { fail("expected commit object") }
  let info = @bitcore.parse_commit(obj.data)
  let copied_path_ids : Map[String, String] = {}
  for item in result.1.to_array() {
    copied_path_ids[item.0] = item.1
  }
  let out : Array[(@bitcore.ObjectId, String)] = []
  let visited : Map[String, Bool] = {}
  collect_tree_objects_excluding_index(
    db,
    fs,
    info.tree,
    out,
    visited,
    copied_path_ids,
  )
  assert_true(copied_path_ids.contains(""))
  assert_true(copied_path_ids.contains("two"))
  assert_eq(out.length(), 0)

  cleanup_tree(fs, root)
}

///|
async test "rev-list: negated indexed-objects suppresses clean trees after empty head commit" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-negate-empty-head-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let git_dir = repo_dir + "/.git"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])
  rev_list_test_run_git(repo_dir, ["commit", "--allow-empty", "-qm", "another"])
  fs.write_string(repo_dir + "/only-in-index", "only-in-index\n")
  rev_list_test_run_git(repo_dir, ["add", "only-in-index"])

  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let result = rev_list_collect_index_objects(db, fs, git_dir, index_entries)
  let head_id = @bitrepo.rev_parse(fs, git_dir, "HEAD")
  guard head_id is Some(commit_id) else { fail("expected HEAD commit") }
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(obj) else { fail("expected commit object") }
  let info = @bitcore.parse_commit(obj.data)
  let copied_path_ids : Map[String, String] = {}
  for item in result.1.to_array() {
    copied_path_ids[item.0] = item.1
  }
  let out : Array[(@bitcore.ObjectId, String)] = []
  let visited : Map[String, Bool] = {}
  collect_tree_objects_excluding_index(
    db,
    fs,
    info.tree,
    out,
    visited,
    copied_path_ids,
  )

  assert_true(copied_path_ids.contains(""))
  assert_true(copied_path_ids.contains("two"))
  assert_eq(out.length(), 0)

  cleanup_tree(fs, root)
}

///|
async test "rev-list: command path suppresses clean head tree for negated indexed objects" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-rev-list-command-negate-clean-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  rev_list_test_init_repo(root, repo_dir)
  fs.write_string(repo_dir + "/one", "frotz\n")
  fs.mkdir_p(repo_dir + "/two")
  fs.write_string(repo_dir + "/two/three", "frotz\n")
  rev_list_test_run_git(repo_dir, ["add", "one", "two/three"])
  rev_list_test_run_git(repo_dir, ["commit", "-qm", "that"])

  let head = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, ["rev-parse", "HEAD"]),
  )
  let actual = rev_list_trim_trailing_newline(
    rev_list_test_git_stdout(repo_dir, [
      "rev-list", "-1", "--objects", "HEAD", "--not", "--indexed-objects",
    ]),
  )
  assert_eq(actual, head)

  cleanup_tree(fs, root)
}
