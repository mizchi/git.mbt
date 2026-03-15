///|
async fn grep_test_run_git(
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
async fn grep_test_git_stdout(
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
async fn grep_test_git_stderr(
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
async fn grep_test_git_collect_stdout(
  root : String,
  args : Array[String],
) -> (Int, String) raise Error {
  let (code, stdout, _) = @process.collect_output(
    "git",
    args[:],
    inherit_env=true,
    cwd=root,
  )
  let text = stdout.text() catch { _ => "" }
  (code, text)
}

///|
fn grep_trim_trailing_newline(s : String) -> String {
  if s.has_suffix("\n") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
async fn grep_wbtest_case_tracked_files_only() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-tracked-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello\nworld\n")
  fs.mkdir_p(repo_dir + "/dir")
  fs.write_string(repo_dir + "/dir/b.txt", "HELLO\n")
  fs.write_string(repo_dir + "/untracked.txt", "hello\n")
  grep_test_run_git(repo_dir, ["add", "a.txt", "dir/b.txt"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "-n", "hello"])
  assert_eq(grep_trim_trailing_newline(stdout), "a.txt:1:hello")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_path_filter_and_ignore_case() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-path-filter-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello\n")
  fs.mkdir_p(repo_dir + "/dir")
  fs.write_string(repo_dir + "/dir/b.txt", "HELLO\n")
  grep_test_run_git(repo_dir, ["add", "a.txt", "dir/b.txt"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-c", "-i", "hello", "dir",
  ])
  assert_eq(grep_trim_trailing_newline(stdout), "dir/b.txt:1")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_dash_e_and_basic_pattern_type() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-pattern-type-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "grep.patternType", "basic"])
  fs.write_string(repo_dir + "/a.txt", "abc\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "-n", "-e", "a.c"])
  assert_eq(grep_trim_trailing_newline(stdout), "a.txt:1:abc")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_pattern_file() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-pattern-file-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello world\n")
  fs.write_string(repo_dir + "/patterns", "world\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "-n", "-f", "patterns"])
  assert_eq(grep_trim_trailing_newline(stdout), "a.txt:1:hello world")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_multiline_pattern_argument() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-multiline-pattern-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/file", "foo mmap bar\n")
  fs.write_string(repo_dir + "/v", "vvv\n")
  grep_test_run_git(repo_dir, ["add", "file", "v"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "mmap\nvvv"])
  assert_eq(grep_trim_trailing_newline(stdout), "file:foo mmap bar\nv:vvv")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_pattern_file_ignores_empty_lines() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-pattern-file-empty-lines-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/file", "foo mmap bar\n")
  fs.write_string(repo_dir + "/v", "vvv\n")
  fs.write_string(repo_dir + "/patterns", "mmap\n\nvvv\n")
  grep_test_run_git(repo_dir, ["add", "file", "v"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "-f", "patterns"])
  assert_eq(grep_trim_trailing_newline(stdout), "file:foo mmap bar\nv:vvv")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_pattern_file_uses_cwd_relative_path() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-pattern-file-cwd-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.mkdir_p(repo_dir + "/sub/dir")
  fs.write_string(repo_dir + "/sub/dir/file", "hit\n")
  fs.write_string(repo_dir + "/sub/dir/pattern", "hit\n")
  fs.write_string(repo_dir + "/pattern", "miss\n")
  grep_test_run_git(repo_dir, ["add", "sub/dir/file"])

  let stdout = grep_test_git_stdout(repo_dir + "/sub/dir", [
    "grep", "-f", "pattern", "file",
  ])
  assert_eq(grep_trim_trailing_newline(stdout), "file:hit")

  let dash_c_stdout = grep_test_git_stdout(repo_dir, [
    "-C", "sub/dir", "grep", "-f", "pattern", "file",
  ])
  assert_eq(grep_trim_trailing_newline(dash_c_stdout), "file:hit")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_subdir_paths_are_relative() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-subdir-relative-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.mkdir_p(repo_dir + "/t")
  fs.write_string(repo_dir + "/root.txt", "test\n")
  fs.write_string(repo_dir + "/t/t", "test\n")
  grep_test_run_git(repo_dir, ["add", "root.txt", "t/t"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let tree_stdout = grep_test_git_stdout(repo_dir + "/t", [
    "grep", "-n", "-e", "test", "HEAD",
  ])
  assert_eq(grep_trim_trailing_newline(tree_stdout), "HEAD:t:1:test")

  let worktree_stdout = grep_test_git_stdout(repo_dir + "/t", [
    "grep", "-n", "-e", "test",
  ])
  assert_eq(grep_trim_trailing_newline(worktree_stdout), "t:1:test")

  let full_name_stdout = grep_test_git_stdout(repo_dir + "/t", [
    "grep", "--full-name", "-n", "-e", "test", "HEAD",
  ])
  assert_eq(grep_trim_trailing_newline(full_name_stdout), "HEAD:t/t:1:test")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_quotes_unusual_paths() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-quote-paths-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.mkdir_p(repo_dir + "/t")
  fs.write_string(repo_dir + "/\"unusual\" pathname", "unusual\n")
  fs.write_string(repo_dir + "/t/nested \"unusual\" pathname", "unusual\n")
  grep_test_run_git(repo_dir, [
    "add", "\"unusual\" pathname", "t/nested \"unusual\" pathname",
  ])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let tree_stdout = grep_test_git_stdout(repo_dir, ["grep", "unusual", "HEAD"])
  assert_eq(
    grep_trim_trailing_newline(tree_stdout),
    "HEAD:\"\\\"unusual\\\" pathname\":unusual\n" +
    "HEAD:\"t/nested \\\"unusual\\\" pathname\":unusual",
  )

  let subdir_stdout = grep_test_git_stdout(repo_dir + "/t", [
    "grep", "unusual", "HEAD",
  ])
  assert_eq(
    grep_trim_trailing_newline(subdir_stdout),
    "HEAD:\"nested \\\"unusual\\\" pathname\":unusual",
  )

  let worktree_stdout = grep_test_git_stdout(repo_dir, ["grep", "unusual"])
  assert_eq(
    grep_trim_trailing_newline(worktree_stdout),
    "\"\\\"unusual\\\" pathname\":unusual\n" +
    "\"t/nested \\\"unusual\\\" pathname\":unusual",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_fixed_ignore_case_short_bundle() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-fixed-ignore-case-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "int main(int argc, const char **argv)\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "-Fi", "CHAR **"])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "hello.c:int main(int argc, const char **argv)",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_threads_option_is_accepted() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-threads-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])

  let baseline = grep_test_git_stdout(repo_dir, ["grep", "."])
  let threaded = grep_test_git_stdout(repo_dir, ["grep", "--threads=4", "."])
  assert_eq(threaded, baseline)

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_cached_reads_index() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-cached-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "cached\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])
  fs.write_string(repo_dir + "/a.txt", "worktree\n")

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "--cached", "cached"])
  assert_eq(grep_trim_trailing_newline(stdout), "a.txt:cached")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_head_reads_treeish() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-head-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/a.txt", "head\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  fs.write_string(repo_dir + "/a.txt", "worktree\n")

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "-n", "head", "HEAD"])
  assert_eq(grep_trim_trailing_newline(stdout), "HEAD:a.txt:1:head")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_invalid_regex_fails() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-invalid-regex-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])

  let (code, stderr) = grep_test_git_stderr(repo_dir, ["grep", "("])
  assert_true(code != 0)
  assert_true(stderr != "")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_max_depth_limits_treeish_search() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-max-depth-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/v", "vvv\n")
  fs.mkdir_p(repo_dir + "/t/a")
  fs.write_string(repo_dir + "/t/v", "vvv\n")
  fs.write_string(repo_dir + "/t/a/v", "vvv\n")
  grep_test_run_git(repo_dir, ["add", "v", "t/v", "t/a/v"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let max_depth_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--max-depth", "0", "-n", "vvv", "HEAD", "--", "t",
  ])
  assert_eq(grep_trim_trailing_newline(max_depth_stdout), "HEAD:t/v:1:vvv")

  let no_recursive_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--no-recursive", "-n", "vvv", "HEAD", "--", "t",
  ])
  assert_eq(grep_trim_trailing_newline(no_recursive_stdout), "HEAD:t/v:1:vvv")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_word_regexp_and_column() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-word-column-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(
    repo_dir + "/file",
    "foo mmap bar\nfoo_mmap bar\nfoo_mmap bar mmap\nfoo mmap bar_mmap\n",
  )
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "-w", "-e", "mmap", "HEAD", "--", "file",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "HEAD:file:5:foo mmap bar\n" +
    "HEAD:file:14:foo_mmap bar mmap\n" +
    "HEAD:file:5:foo mmap bar_mmap",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_line_number_and_column() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-line-column-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "foo mmap bar\nfoo_mmap bar mmap\n")
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-n", "--column", "-w", "-e", "mmap", "HEAD", "--", "file",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "HEAD:file:1:5:foo mmap bar\nHEAD:file:2:14:foo_mmap bar mmap",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_boolean_expression_and_column() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-bool-expr-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(
    repo_dir + "/file",
    "foo mmap bar\n" +
    "foo_mmap bar\n" +
    "foo_mmap bar mmap\n" +
    "foo mmap bar_mmap\n" +
    "foo_mmap bar mmap baz\n",
  )
  fs.write_string(
    repo_dir + "/hello_world",
    "Hello world\nHeLLo world\nHello_world\nHeLLo_world\n",
  )
  grep_test_run_git(repo_dir, ["add", "file", "hello_world"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let or_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "-w", "-e", "mmap$", "--or", "-e", "baz", "HEAD", "--", "file",
  ])
  assert_eq(
    grep_trim_trailing_newline(or_stdout),
    "HEAD:file:14:foo_mmap bar mmap\nHEAD:file:19:foo_mmap bar mmap baz",
  )

  let invert_or_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "--invert-match", "-e", "ll", "--or", "--not", "-e", "_",
    "HEAD", "--", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(invert_or_stdout),
    "HEAD:hello_world:6:HeLLo_world",
  )

  let invert_and_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "--invert-match", "--not", "-e", "_", "--and", "--not", "-e",
    "ll", "HEAD", "--", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(invert_and_stdout),
    "HEAD:hello_world:3:Hello world\n" +
    "HEAD:hello_world:3:Hello_world\n" +
    "HEAD:hello_world:6:HeLLo_world",
  )

  let grouped_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "--not", "(", "--not", "-e", "foo", "--or", "--not", "-e",
    "baz", ")", "HEAD", "--", "file",
  ])
  assert_eq(
    grep_trim_trailing_newline(grouped_stdout),
    "HEAD:file:1:foo_mmap bar mmap baz",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_context_with_column() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-context-column-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(
    repo_dir + "/file",
    "foo mmap bar\n" +
    "foo_mmap bar\n" +
    "foo_mmap bar mmap\n" +
    "foo mmap bar_mmap\n" +
    "foo_mmap bar mmap baz\n",
  )
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "-w", "-C1", "-e", "mmap", "HEAD",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "HEAD:file:5:foo mmap bar\n" +
    "HEAD:file-foo_mmap bar\n" +
    "HEAD:file:14:foo_mmap bar mmap\n" +
    "HEAD:file:5:foo mmap bar_mmap\n" +
    "HEAD:file:14:foo_mmap bar mmap baz",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_only_matching_with_column() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-only-matching-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(
    repo_dir + "/file",
    "foo mmap bar\n" +
    "foo_mmap bar\n" +
    "foo_mmap bar mmap\n" +
    "foo mmap bar_mmap\n" +
    "foo_mmap bar mmap baz\n",
  )
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--column", "-n", "-o", "-e", "mmap", "HEAD",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "HEAD:file:1:5:mmap\n" +
    "HEAD:file:2:5:mmap\n" +
    "HEAD:file:3:5:mmap\n" +
    "HEAD:file:3:13:mmap\n" +
    "HEAD:file:4:5:mmap\n" +
    "HEAD:file:4:13:mmap\n" +
    "HEAD:file:5:5:mmap\n" +
    "HEAD:file:5:13:mmap",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_quiet_suppresses_output() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-quiet-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello\n")
  grep_test_run_git(repo_dir, ["add", "a.txt"])

  let (hit_code, hit_stdout) = grep_test_git_collect_stdout(repo_dir, [
    "grep", "--quiet", "hello",
  ])
  assert_eq(hit_code, 0)
  assert_eq(hit_stdout, "")

  let (miss_code, miss_stdout) = grep_test_git_collect_stdout(repo_dir, [
    "grep", "--quiet", "goodbye",
  ])
  assert_eq(miss_code, 1)
  assert_eq(miss_stdout, "")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_files_without_match_respects_intent_to_add_modes() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-files-without-match-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/a.txt", "hello\n")
  fs.write_string(repo_dir + "/b.txt", "goodbye\n")
  fs.write_string(repo_dir + "/intend.txt", "intent only\n")
  grep_test_run_git(repo_dir, ["add", "a.txt", "b.txt"])
  grep_test_run_git(repo_dir, ["add", "-N", "intend.txt"])

  let worktree_stdout = grep_test_git_stdout(repo_dir, ["grep", "-L", "hello"])
  assert_eq(grep_trim_trailing_newline(worktree_stdout), "b.txt\nintend.txt")

  let cached_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-L", "--cached", "hello",
  ])
  assert_eq(grep_trim_trailing_newline(cached_stdout), "b.txt")

  grep_test_run_git(repo_dir, [
    "update-index", "--assume-unchanged", "intend.txt",
  ])
  let assume_stdout = grep_test_git_stdout(repo_dir, ["grep", "-L", "hello"])
  assert_eq(grep_trim_trailing_newline(assume_stdout), "b.txt")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_assume_unchanged_uses_index_blob() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-assume-unchanged-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "index blob\n")
  grep_test_run_git(repo_dir, ["add", "file"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  grep_test_run_git(repo_dir, ["update-index", "--assume-unchanged", "file"])
  fs.write_string(repo_dir + "/file", "worktree only\n")

  let hit_stdout = grep_test_git_stdout(repo_dir, ["grep", "index blob"])
  assert_eq(grep_trim_trailing_newline(hit_stdout), "file:index blob")

  let (miss_code, miss_stdout) = grep_test_git_collect_stdout(repo_dir, [
    "grep", "worktree only",
  ])
  assert_eq(miss_code, 1)
  assert_eq(miss_stdout, "")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_sparse_checkout_skips_missing_worktree_paths() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-sparse-skip-worktree-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/a", "text\n")
  fs.write_string(repo_dir + "/b", "text\n")
  fs.mkdir_p(repo_dir + "/dir")
  fs.write_string(repo_dir + "/dir/c", "text\n")
  grep_test_run_git(repo_dir, ["add", "a", "b", "dir/c"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  grep_test_run_git(repo_dir, ["sparse-checkout", "init", "--no-cone"])
  grep_test_run_git(repo_dir, ["sparse-checkout", "set", "/*", "!b", "!/*/"])
  assert_false(fs.is_file(repo_dir + "/b"))
  assert_false(fs.is_dir(repo_dir + "/dir"))

  grep_test_run_git(repo_dir, ["sparse-checkout", "disable"])
  assert_true(fs.is_file(repo_dir + "/b"))
  assert_true(fs.is_dir(repo_dir + "/dir"))
  grep_test_run_git(repo_dir, ["sparse-checkout", "init"])
  assert_false(fs.is_file(repo_dir + "/b"))
  assert_false(fs.is_dir(repo_dir + "/dir"))

  grep_test_run_git(repo_dir, ["update-index", "--assume-unchanged", "b"])
  let stdout = grep_test_git_stdout(repo_dir, ["grep", "text"])
  assert_eq(grep_trim_trailing_newline(stdout), "a:text")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_break_heading_and_after_context() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-break-heading-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "\t/* char ?? */\n" +
    "}\n",
  )
  fs.write_string(
    repo_dir + "/hello_world",
    "Hello world\nHeLLo world\nHello_world\nHeLLo_world\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c", "hello_world"])

  let break_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--break", "-e", "char", "-e", "lo_w", "hello.c", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(break_stdout),
    "hello.c:int main(int argc, const char **argv)\n" +
    "hello.c:\t/* char ?? */\n" +
    "\n" +
    "hello_world:Hello_world",
  )

  let heading_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--heading", "-e", "char", "-e", "lo_w", "hello.c", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(heading_stdout),
    "hello.c\n" +
    "int main(int argc, const char **argv)\n" +
    "\t/* char ?? */\n" +
    "hello_world\n" +
    "Hello_world",
  )

  let context_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--break", "-A1", "-e", "char", "-e", "lo_w", "hello.c", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(context_stdout),
    "hello.c:int main(int argc, const char **argv)\n" +
    "hello.c-{\n" +
    "--\n" +
    "hello.c:\t/* char ?? */\n" +
    "hello.c-}\n" +
    "\n" +
    "hello_world:Hello_world\n" +
    "hello_world-HeLLo_world",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_color_output() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-color-" + get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "color.grep.context", "normal"])
  grep_test_run_git(repo_dir, ["config", "color.grep.filename", "bold green"])
  grep_test_run_git(repo_dir, ["config", "color.grep.function", "normal"])
  grep_test_run_git(repo_dir, ["config", "color.grep.linenumber", "normal"])
  grep_test_run_git(repo_dir, ["config", "color.grep.match", "black yellow"])
  grep_test_run_git(repo_dir, ["config", "color.grep.selected", "normal"])
  grep_test_run_git(repo_dir, ["config", "color.grep.separator", "red"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "\t/* char ?? */\n" +
    "}\n",
  )
  fs.write_string(
    repo_dir + "/hello_world",
    "Hello world\nHeLLo world\nHello_world\nHeLLo_world\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c", "hello_world"])

  let separator_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--color=always", "-A1", "-e", "char", "-e", "lo_w", "hello.c", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(separator_stdout),
    "\u001b[1;32mhello.c\u001b[m\u001b[31m:\u001b[mint main(int argc, const \u001b[30;43mchar\u001b[m **argv)\n" +
    "\u001b[1;32mhello.c\u001b[m\u001b[31m-\u001b[m{\n" +
    "\u001b[31m--\u001b[m\n" +
    "\u001b[1;32mhello.c\u001b[m\u001b[31m:\u001b[m\t/* \u001b[30;43mchar\u001b[m ?? */\n" +
    "\u001b[1;32mhello.c\u001b[m\u001b[31m-\u001b[m}\n" +
    "\u001b[31m--\u001b[m\n" +
    "\u001b[1;32mhello_world\u001b[m\u001b[31m:\u001b[mHel\u001b[30;43mlo_w\u001b[morld\n" +
    "\u001b[1;32mhello_world\u001b[m\u001b[31m-\u001b[mHeLLo_world",
  )

  grep_test_run_git(repo_dir, ["config", "color.grep.separator", "normal"])
  let group_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--break", "--heading", "-n", "--color", "-e", "char", "-e", "lo_w",
    "hello.c", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(group_stdout),
    "\u001b[1;32mhello.c\u001b[m\n" +
    "4:int main(int argc, const \u001b[30;43mchar\u001b[m **argv)\n" +
    "8:\t/* \u001b[30;43mchar\u001b[m ?? */\n" +
    "\n" +
    "\u001b[1;32mhello_world\u001b[m\n" +
    "3:Hel\u001b[30;43mlo_w\u001b[morld",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_context_separator_between_files() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-context-separator-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "\t/* char ?? */\n" +
    "}\n",
  )
  fs.write_string(
    repo_dir + "/hello_world",
    "Hello world\nHeLLo world\nHello_world\nHeLLo_world\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c", "hello_world"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-A1", "-e", "char", "-e", "lo_w", "hello.c", "hello_world",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "hello.c:int main(int argc, const char **argv)\n" +
    "hello.c-{\n" +
    "--\n" +
    "hello.c:\t/* char ?? */\n" +
    "hello.c-}\n" +
    "--\n" +
    "hello_world:Hello_world\n" +
    "hello_world-HeLLo_world",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_show_function_context() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-show-function-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "\t/* char ?? */\n" +
    "}\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-p", "-C3", "-e", "int", "--and", "-e", "Hello", "--no-index", "hello.c",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "hello.c-\n" +
    "hello.c=int main(int argc, const char **argv)\n" +
    "hello.c-{\n" +
    "hello.c:\tprintf(\"Hello world.\\n\");\n" +
    "hello.c-\treturn 0;\n" +
    "hello.c-\t/* char ?? */\n" +
    "hello.c-}",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_show_function_context_uses_custom_funcname() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-show-function-custom-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "diff.custom.funcname", "^#"])
  fs.write_string(repo_dir + "/.gitattributes", "hello.c diff=custom\n")
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "\t/* char ?? */\n" +
    "}\n",
  )
  grep_test_run_git(repo_dir, ["add", ".gitattributes", "hello.c"])
  let lines = grep_split_content_lines(
    @utf8.decode_lossy(fs.read_file(repo_dir + "/hello.c")[:]),
  )
  let function_spec = grep_resolve_function_context_spec(
    fs,
    repo_dir,
    repo_dir + "/.git",
    "hello.c",
  )
  assert_eq(function_spec.header_pattern, Some("^#"))
  assert_false(function_spec.include_leading_comments)
  assert_eq(
    grep_find_function_context_line(lines, 1, 6, function_spec.header_pattern),
    Some(2),
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_function_context_whole_function() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-function-context-whole-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "\t/* char ?? */\n" +
    "}\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c"])
  let lines = grep_split_content_lines(
    @utf8.decode_lossy(fs.read_file(repo_dir + "/hello.c")[:]),
  )
  let function_spec = grep_resolve_function_context_spec(
    fs,
    repo_dir,
    repo_dir + "/.git",
    "hello.c",
  )
  assert_eq(grep_compute_whole_function_range(lines, 6, function_spec), (4, 9))
  assert_eq(grep_compute_whole_function_range(lines, 2, function_spec), (1, 2))

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_function_context_whole_function_uses_xfuncname() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-function-context-xfuncname-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, [
    "config", "diff.custom.xfuncname", "^function .*$",
  ])
  fs.write_string(repo_dir + "/.gitattributes", "hello.ps1 diff=custom\n")
  fs.write_string(
    repo_dir + "/hello.ps1",
    "# No-op.\n" +
    "function dummy() {}\n\n" +
    "# Say hello.\n" +
    "function hello() {\n" +
    "  echo \"Hello world.\"\n" +
    "  echo \"Hello again.\"\n" +
    "} # hello\n\n" +
    "# Still a no-op.\n" +
    "function dummy() {}\n",
  )
  grep_test_run_git(repo_dir, ["add", ".gitattributes", "hello.ps1"])
  let lines = grep_split_content_lines(
    @utf8.decode_lossy(fs.read_file(repo_dir + "/hello.ps1")[:]),
  )
  let function_spec = grep_resolve_function_context_spec(
    fs,
    repo_dir,
    repo_dir + "/.git",
    "hello.ps1",
  )
  assert_eq(function_spec.header_pattern, Some("^function .*$"))
  assert_true(function_spec.include_leading_comments)
  assert_eq(grep_compute_whole_function_range(lines, 6, function_spec), (4, 8))

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_max_count_limits_matches_per_file() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-max-count-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "}\n",
  )
  fs.write_string(
    repo_dir + "/hello.ps1",
    "# No-op.\n" +
    "function dummy() {}\n\n" +
    "# Say hello.\n" +
    "function hello() {\n" +
    "  echo \"Hello world.\"\n" +
    "  echo \"Hello again.\"\n" +
    "} # hello\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c", "hello.ps1"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--max-count", "1", "-e", "o", "--", "hello.*",
  ])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    "hello.c:#include <stdio.h>\n" + "hello.ps1:# No-op.",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_max_count_respects_context_and_count() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-max-count-context-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(
    repo_dir + "/hello.c",
    "#include <assert.h>\n" +
    "#include <stdio.h>\n\n" +
    "int main(int argc, const char **argv)\n" +
    "{\n" +
    "\tprintf(\"Hello world.\\n\");\n" +
    "\treturn 0;\n" +
    "}\n",
  )
  fs.write_string(
    repo_dir + "/hello.ps1",
    "# No-op.\n" +
    "function dummy() {}\n\n" +
    "# Say hello.\n" +
    "function hello() {\n" +
    "  echo \"Hello world.\"\n" +
    "  echo \"Hello again.\"\n" +
    "} # hello\n",
  )
  grep_test_run_git(repo_dir, ["add", "hello.c", "hello.ps1"])

  let context_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--max-count", "1", "--context", "1", "-e", "o", "--", "hello.*",
  ])
  assert_eq(
    grep_trim_trailing_newline(context_stdout),
    "hello.c-#include <assert.h>\n" +
    "hello.c:#include <stdio.h>\n" +
    "hello.c-\n" +
    "--\n" +
    "hello.ps1:# No-op.\n" +
    "hello.ps1-function dummy() {}",
  )

  let count_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--max-count", "1", "--count", "Hello", "hello.ps1",
  ])
  assert_eq(grep_trim_trailing_newline(count_stdout), "hello.ps1:1")

  let show_function_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--max-count", "1", "--show-function", "Hello", "hello.ps1",
  ])
  assert_eq(
    grep_trim_trailing_newline(show_function_stdout),
    "hello.ps1=function hello() {\n" + "hello.ps1:  echo \"Hello world.\"",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_pattern_type_short_flags_last_wins() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-pattern-type-short-flags-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/ab", "a+b*c\na+bc\nabc\n")
  grep_test_run_git(repo_dir, ["add", "ab"])

  let basic_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-E", "-F", "-G", "a+b*c", "ab",
  ])
  assert_eq(grep_trim_trailing_newline(basic_stdout), "ab:a+bc")

  let extended_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-F", "-G", "-E", "a+b*c", "ab",
  ])
  assert_eq(grep_trim_trailing_newline(extended_stdout), "ab:abc")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_dashdash_can_introduce_pattern() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-dashdash-pattern-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/double-dash", "a -> b\n")
  grep_test_run_git(repo_dir, ["add", "double-dash"])

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "--", "->"])
  assert_eq(grep_trim_trailing_newline(stdout), "double-dash:a -> b")

  let scoped_stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--", "->", "--", "double-dash",
  ])
  assert_eq(grep_trim_trailing_newline(scoped_stdout), "double-dash:a -> b")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_dashdash_prefers_rev_before_separator() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-dashdash-rev-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/hello.c", "hello world\n")
  grep_test_run_git(repo_dir, ["add", "hello.c"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  fs.write_string(repo_dir + "/main", "content\n")

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "-l", "o", "main", "--", "hello.c",
  ])
  assert_eq(grep_trim_trailing_newline(stdout), "main:hello.c")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_dashdash_reports_invalid_rev() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-dashdash-invalid-rev-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.write_string(repo_dir + "/hello.c", "hello world\n")
  grep_test_run_git(repo_dir, ["add", "hello.c"])

  let (code, _) = grep_test_git_collect_stdout(repo_dir, [
    "grep", "o", "hello.c", "--",
  ])
  assert_true(code != 0)

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_no_index_outside_repo() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-no-index-outside-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  let work_dir = root + "/non/git"
  fs.mkdir_p(work_dir + "/sub")
  fs.write_string(work_dir + "/file1", "hello\n")
  fs.write_string(work_dir + "/sub/file2", "world\n")
  fs.write_string(work_dir + "/.gitignore", ".*o*\n")

  let stdout = grep_test_git_stdout(work_dir, ["grep", "--no-index", "o"])
  assert_eq(
    grep_trim_trailing_newline(stdout),
    ".gitignore:.*o*\nfile1:hello\nsub/file2:world",
  )

  let excluded = grep_test_git_stdout(work_dir, [
    "grep", "--no-index", "--exclude-standard", "o",
  ])
  assert_eq(
    grep_trim_trailing_newline(excluded),
    "file1:hello\nsub/file2:world",
  )

  let restored = grep_test_git_stdout(work_dir, [
    "grep", "--no-index", "--exclude-standard", "--no-exclude-standard", "o",
  ])
  assert_eq(
    grep_trim_trailing_newline(restored),
    ".gitignore:.*o*\nfile1:hello\nsub/file2:world",
  )

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_untracked_search_respects_ignore() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-untracked-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  fs.mkdir_p(repo_dir + "/sub")
  fs.write_string(repo_dir + "/file1", "hello\n")
  fs.write_string(repo_dir + "/sub/file2", "world\n")
  fs.write_string(repo_dir + "/.gitignore", ".*o*\n")

  let stdout = grep_test_git_stdout(repo_dir, ["grep", "--untracked", "o"])
  assert_eq(grep_trim_trailing_newline(stdout), "file1:hello\nsub/file2:world")

  cleanup_tree(fs, root)
}

///|
async fn grep_wbtest_case_no_index_prefers_paths_to_revs() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-grep-no-index-rev-disambiguation-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/tracked.txt", "seed\n")
  grep_test_run_git(repo_dir, ["add", "tracked.txt"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  grep_test_run_git(repo_dir, ["branch", "-M", "main"])
  fs.write_string(repo_dir + "/main", "content\n")

  let stdout = grep_test_git_stdout(repo_dir, [
    "grep", "--no-index", "o", "main",
  ])
  assert_eq(grep_trim_trailing_newline(stdout), "main:content")

  let (code, stderr) = grep_test_git_stderr(repo_dir, [
    "grep", "--no-index", "o", "main", "--",
  ])
  assert_eq(code, 128)
  assert_true(stderr.contains("cannot be used with revs"))

  cleanup_tree(fs, root)
}

///|
async test "grep: command path cases stay compatible" {
  grep_wbtest_case_tracked_files_only()
  grep_wbtest_case_path_filter_and_ignore_case()
  grep_wbtest_case_dash_e_and_basic_pattern_type()
  grep_wbtest_case_pattern_file()
  grep_wbtest_case_multiline_pattern_argument()
  grep_wbtest_case_pattern_file_ignores_empty_lines()
  grep_wbtest_case_pattern_file_uses_cwd_relative_path()
  grep_wbtest_case_subdir_paths_are_relative()
  grep_wbtest_case_quotes_unusual_paths()
  grep_wbtest_case_fixed_ignore_case_short_bundle()
  grep_wbtest_case_threads_option_is_accepted()
  grep_wbtest_case_cached_reads_index()
  grep_wbtest_case_head_reads_treeish()
  grep_wbtest_case_invalid_regex_fails()
  grep_wbtest_case_max_depth_limits_treeish_search()
  grep_wbtest_case_word_regexp_and_column()
  grep_wbtest_case_line_number_and_column()
  grep_wbtest_case_boolean_expression_and_column()
  grep_wbtest_case_context_with_column()
  grep_wbtest_case_only_matching_with_column()
  grep_wbtest_case_quiet_suppresses_output()
  grep_wbtest_case_files_without_match_respects_intent_to_add_modes()
  grep_wbtest_case_assume_unchanged_uses_index_blob()
  grep_wbtest_case_sparse_checkout_skips_missing_worktree_paths()
  grep_wbtest_case_break_heading_and_after_context()
  grep_wbtest_case_color_output()
  grep_wbtest_case_context_separator_between_files()
  grep_wbtest_case_show_function_context()
  grep_wbtest_case_show_function_context_uses_custom_funcname()
  grep_wbtest_case_function_context_whole_function()
  grep_wbtest_case_function_context_whole_function_uses_xfuncname()
  grep_wbtest_case_max_count_limits_matches_per_file()
  grep_wbtest_case_max_count_respects_context_and_count()
  grep_wbtest_case_pattern_type_short_flags_last_wins()
  grep_wbtest_case_dashdash_can_introduce_pattern()
  grep_wbtest_case_dashdash_prefers_rev_before_separator()
  grep_wbtest_case_dashdash_reports_invalid_rev()
  grep_wbtest_case_no_index_outside_repo()
  grep_wbtest_case_untracked_search_respects_ignore()
  grep_wbtest_case_no_index_prefers_paths_to_revs()
}
