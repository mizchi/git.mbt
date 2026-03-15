///|
test "log: storage runtime routing only for oneline subset" {
  assert_true(log_should_use_storage_runtime(["--oneline", "-n", "3"]))
  assert_true(log_should_use_storage_runtime(["--oneline", "--max-count=2"]))
  assert_true(log_should_use_storage_runtime(["--oneline", "-3"]))

  assert_false(log_should_use_storage_runtime(["--oneline"]))
  assert_false(log_should_use_storage_runtime(["-n", "3"]))
  assert_false(log_should_use_storage_runtime(["--graph", "--oneline"]))
  assert_false(log_should_use_storage_runtime(["HEAD"]))
  assert_false(log_should_use_storage_runtime(["--oneline", "HEAD"]))
  assert_false(log_should_use_storage_runtime(["--oneline", "--source", "v1"]))
}

///|
test "log: storage runtime not used for --all, --decorate, ranges" {
  // --all is not --oneline alone, so storage runtime should be false
  assert_false(log_should_use_storage_runtime(["--all"]))
  assert_false(log_should_use_storage_runtime(["--all", "--oneline"]))
  assert_false(log_should_use_storage_runtime(["--decorate"]))
  assert_false(log_should_use_storage_runtime(["--decorate", "--oneline"]))
  // positional args (including ranges) are not pure --oneline
  assert_false(log_should_use_storage_runtime(["main..develop"]))
  assert_false(log_should_use_storage_runtime(["HEAD~3"]))
  assert_false(log_should_use_storage_runtime(["main"]))
}

///|
test "log: storage runtime disabled by repo config overrides" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  let base_config = fs.read_string("/repo/.git/config")

  assert_true(
    log_should_use_storage_runtime_in_repo(fs, "/repo/.git", [
      "--oneline", "-n", "3",
    ]),
  )

  fs.write_string("/repo/.git/config", base_config + "\n[log]\n\tdecorate\n")
  assert_false(
    log_should_use_storage_runtime_in_repo(fs, "/repo/.git", [
      "--oneline", "-n", "3",
    ]),
  )

  fs.write_string(
    "/repo/.git/config",
    base_config + "\n[core]\n\tabbrev = 12\n",
  )
  assert_false(
    log_should_use_storage_runtime_in_repo(fs, "/repo/.git", [
      "--oneline", "-n", "3",
    ]),
  )
}

///|
test "log: config reader handles inline section key" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  let base_config = fs.read_string("/repo/.git/config")
  fs.write_string("/repo/.git/config", base_config + "\n[log] decorate\n")

  let entries = log_read_config_entries(fs, "/repo/.git", "log", "decorate")
  assert_eq(entries.length(), 1)
  assert_false(entries[0].has_value)
}

///|
test "log: log_find_dotdot parses A..B ranges" {
  // Normal range
  assert_eq(log_find_dotdot("main..develop"), 4)
  // Range with no left side
  assert_eq(log_find_dotdot("..develop"), 0)
  // Range with no right side
  assert_eq(log_find_dotdot("main.."), 4)
  // Triple dot is NOT a range
  assert_eq(log_find_dotdot("main...develop"), -1)
  // No dots
  assert_eq(log_find_dotdot("HEAD"), -1)
  assert_eq(log_find_dotdot("HEAD~3"), -1)
  // Single dot
  assert_eq(log_find_dotdot("a.b"), -1)
}

///|
test "log: log_find_tripledot parses A...B ranges" {
  assert_eq(log_find_tripledot("main...topic"), 4)
  assert_eq(log_find_tripledot("...topic"), 0)
  assert_eq(log_find_tripledot("main..."), 4)
  assert_eq(log_find_tripledot("main..topic"), -1)
  assert_eq(log_find_tripledot("HEAD"), -1)
}

///|
test "log: revision input handles caret and not-mode excludes" {
  let revs : Array[String] = []
  let excludes : Array[String] = []
  let symmetric : Array[(String, String)] = []
  log_push_revision_input("^topic", revs, excludes, symmetric, false)
  log_push_revision_input("main", revs, excludes, symmetric, true)

  assert_eq(revs.length(), 0)
  assert_eq(excludes, ["topic", "main"])
}

///|
test "log: ancestry and simplify options fall back to real git" {
  assert_true(log_need_real_git(["--stat"]))
  assert_true(log_need_real_git(["--stdin"]))
  assert_true(log_need_real_git(["--graph"]))
  assert_true(log_need_real_git(["--boundary"]))
  assert_true(log_need_real_git(["--ancestry-path"]))
  assert_true(log_need_real_git(["--ancestry-path=topic"]))
  assert_true(log_need_real_git(["--simplify-by-decoration"]))
  assert_true(log_need_real_git(["--simplify-merges"]))
  assert_true(log_need_real_git(["--parents"]))
  assert_true(log_need_real_git(["--full-history"]))
  assert_true(log_need_real_git(["--show-pulls"]))
  assert_true(log_need_real_git(["--exclude-first-parent-only"]))
  assert_true(log_need_real_git(["--", "file"]))
  assert_false(log_need_real_git(["--oneline", "HEAD"]))
}

///|
test "log: ref glob normalization expands bare namespaces" {
  assert_eq(log_normalize_ref_glob_pattern("refs/heads"), "refs/heads/*")
  assert_eq(
    log_normalize_ref_glob_pattern("heads/topic/*"),
    "refs/heads/topic/*",
  )
}

///|
test "log: branch pattern matching handles exact and nested names" {
  assert_true(log_branch_pattern_matches("main", "main"))
  assert_true(log_branch_pattern_matches("topic/sub", "topic"))
  assert_true(log_branch_pattern_matches("topic/sub", "topic/*"))
  assert_false(log_branch_pattern_matches("main", "does-not-exist"))
}

///|
async test "log: command path supports excludes and pathspec separator" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-log-exclude-pathspec-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  grep_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  grep_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  grep_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])

  fs.write_string(repo_dir + "/file-1", "base\n")
  fs.write_string(repo_dir + "/file-2", "base\n")
  grep_test_run_git(repo_dir, ["add", "file-1", "file-2"])
  grep_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])

  fs.write_string(repo_dir + "/file-1", "touch-1\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "touch-1"])

  fs.write_string(repo_dir + "/file-2", "touch-2\n")
  grep_test_run_git(repo_dir, ["commit", "-q", "-am", "touch-2"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "log", "--format=%s", "HEAD", "^HEAD~1", "--", "file-2",
  ])
  assert_eq(trim_string(stdout), "touch-2")

  cleanup_tree(fs, root)
}

///|
async test "log: command path supports --all with --not" {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-log-all-not-" + get_current_timestamp().to_string()
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
  grep_test_run_git(repo_dir, ["checkout", "-q", "main"])

  let stdout = grep_test_git_stdout(repo_dir, [
    "log", "--format=%s", "--all", "--not", "main",
  ])
  assert_eq(trim_string(stdout), "side")

  cleanup_tree(fs, root)
}

///|
test "log: reflog target selection prefers branch patterns over HEAD" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git/refs/heads/root1")
  fs.mkdir_p("/repo/.git/refs/heads/root2")
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(
    "/repo/.git/refs/heads/root1/branch1", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
  )
  fs.write_string(
    "/repo/.git/refs/heads/root1/branch2", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
  )
  fs.write_string(
    "/repo/.git/refs/heads/root2/branch1", "cccccccccccccccccccccccccccccccccccccccc\n",
  )

  let targets = log_collect_reflog_targets(fs, "/repo/.git", [], ["root*"])
  assert_eq(targets, ["root1/branch1", "root1/branch2", "root2/branch1"])
  assert_eq(log_collect_reflog_targets(fs, "/repo/.git", [], []), ["HEAD"])
}

///|
test "log: reflog selector helpers split and format explicit selectors" {
  assert_eq(log_split_reflog_target("HEAD@{0}"), ("HEAD", Some("0")))
  assert_eq(log_split_reflog_target("HEAD@{now}"), ("HEAD", Some("now")))
  assert_eq(
    log_format_reflog_selector("HEAD", 0, 1112911993L, "-0700", None, "raw"),
    "HEAD@{1112911993 -0700}",
  )
  assert_eq(
    log_format_reflog_selector(
      "HEAD",
      0,
      1112911993L,
      "-0700",
      Some("0"),
      "raw",
    ),
    "HEAD@{0}",
  )
}

///|
test "log: format_reflog_entry keeps %gD selector without message" {
  assert_eq(
    format_reflog_entry(
      Some("%gD"),
      "root1/branch1@{0}",
      "branch: Created from main",
    ),
    "root1/branch1@{0}",
  )
  assert_eq(
    format_reflog_entry(
      Some("%gD %gs"),
      "root1/branch1@{0}",
      "branch: Created from main",
    ),
    "root1/branch1@{0} branch: Created from main",
  )
}

///|
fn log_test_format_data(
  subject : String,
  body? : String = "",
  message? : String = subject,
  encoding? : String = "",
  pretty_color_enabled? : Bool = false,
) -> CommitFormatData {
  let id = @bitcore.ObjectId::new(FixedArray::make(20, b'\xaa'))
  let tree = @bitcore.ObjectId::new(FixedArray::make(20, b'\xbb'))
  {
    id,
    tree,
    parents: [],
    abbrev_len: 7,
    encoding,
    author_name: "Test User",
    author_email: "test@example.com",
    author_timestamp: 1700000000L,
    author_tz: "+0000",
    committer_name: "Test User",
    committer_email: "test@example.com",
    committer_timestamp: 1700000000L,
    committer_tz: "+0000",
    subject,
    body,
    message,
    ref_names: {},
    date_format: "",
    left_right_marker: "",
    reflog_selector_short: Some("HEAD@{0}"),
    reflog_selector: Some("HEAD@{0}"),
    reflog_message: Some("commit: " + subject),
    reflog_author_name: Some("C O Mitter"),
    reflog_author_email: Some("committer@example.com"),
    pretty_color_enabled,
    pretty_auto_color: "\u001b[33m",
  }
}

///|
test "log: format_commit_string honors reflog placeholders" {
  let data = log_test_format_data("sixth")

  assert_eq(
    format_commit_string("%gD %gs %H", data),
    "HEAD@{0} commit: sixth aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  assert_eq(
    format_commit_string("%gn:%ge", data),
    "C O Mitter:committer@example.com",
  )
}

///|
test "log: format_commit_string honors left-right marker" {
  let id = @bitcore.ObjectId::from_hex(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let tree = @bitcore.ObjectId::from_hex(
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  let data : CommitFormatData = {
    id,
    tree,
    parents: [],
    abbrev_len: 7,
    encoding: "",
    author_name: "Test User",
    author_email: "test@example.com",
    author_timestamp: 1700000000L,
    author_tz: "+0000",
    committer_name: "Test User",
    committer_email: "test@example.com",
    committer_timestamp: 1700000000L,
    committer_tz: "+0000",
    subject: "sixth",
    body: "",
    message: "sixth",
    ref_names: {},
    date_format: "",
    left_right_marker: ">",
    reflog_selector_short: None,
    reflog_selector: None,
    reflog_message: None,
    reflog_author_name: None,
    reflog_author_email: None,
    pretty_color_enabled: false,
    pretty_auto_color: "\u001b[33m",
  }

  assert_eq(format_commit_string("%m %s", data), "> sixth")
}

///|
test "log: format_commit_string honors line and space modifiers" {
  let without_body = log_test_format_data("subject")
  let with_body = log_test_format_data(
    "subject",
    body="body line",
    message="subject\n\nbody line",
  )

  assert_eq(format_commit_string("x%n%-b", without_body), "x")
  assert_eq(format_commit_string("x%+b", without_body), "x")
  assert_eq(format_commit_string("x% b", without_body), "x")
  assert_eq(format_commit_string("x%n%-b", with_body), "x\nbody line")
  assert_eq(format_commit_string("x%+b", with_body), "x\nbody line")
  assert_eq(format_commit_string("x% b", with_body), "x body line")
  assert_eq(format_commit_string("x% s", without_body), "x subject")
  assert_eq(
    format_commit_string(
      "%e",
      log_test_format_data("subject", encoding="ISO-8859-1"),
    ),
    "ISO-8859-1",
  )
}

///|
test "log: format_commit_string honors truncation and width padding" {
  let long_subject = log_test_format_data("abcdefghijklmnopqrstuvwxyz")
  let short_subject = log_test_format_data("short")

  assert_eq(
    format_commit_string("%<(20,trunc)%s", long_subject),
    "abcdefghijklmnopqr..",
  )
  assert_eq(
    format_commit_string("%<(20,mtrunc)%s", long_subject),
    "abcdefghi..rstuvwxyz",
  )
  assert_eq(
    format_commit_string("%<(20,ltrunc)%s", long_subject),
    "..ijklmnopqrstuvwxyz",
  )
  assert_eq(
    format_commit_string("%<(20,trunc)%s", short_subject),
    "short               ",
  )
}

///|
test "log: format_commit_string honors pretty color directives" {
  let data = log_test_format_data("subject", pretty_color_enabled=true)

  assert_eq(
    format_commit_string("%C(always,red)foo%C(always,reset)", data),
    "\u001b[31mfoo\u001b[m",
  )
  assert_eq(
    format_commit_string("%Credfoo%Creset", data),
    "\u001b[31mfoo\u001b[m",
  )
  assert_eq(
    format_commit_string("%C(auto)%H", data),
    "\u001b[33maaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u001b[m",
  )
  assert_eq(
    format_commit_string("%Credfoo%Creset", log_test_format_data("subject")),
    "foo",
  )
}

///|
test "log: pretty color mode honors cli and config precedence" {
  assert_false(
    log_resolve_pretty_color_enabled_from_values(None, None, None, false),
  )
  assert_true(
    log_resolve_pretty_color_enabled_from_values(
      Some("always"),
      None,
      None,
      false,
    ),
  )
  assert_true(
    log_resolve_pretty_color_enabled_from_values(
      None,
      Some("always"),
      None,
      false,
    ),
  )
  assert_false(
    log_resolve_pretty_color_enabled_from_values(
      Some("always"),
      None,
      Some("never"),
      false,
    ),
  )
  assert_true(
    log_resolve_pretty_color_enabled_from_values(None, None, Some("auto"), true),
  )
  assert_false(
    log_resolve_pretty_color_enabled_from_values(
      None,
      None,
      Some("auto"),
      false,
    ),
  )
}

///|
test "log: identity patterns use union semantics" {
  assert_true(
    log_identity_patterns_match(
      "Thor <thor@example.com>",
      ["Thor", "Aster"],
      GrepPatternType::Basic,
      false,
    ),
  )
  assert_true(
    log_identity_patterns_match(
      "Thor <thor@example.com>",
      ["Aster", "thor@example\\.com>$"],
      GrepPatternType::Basic,
      false,
    ),
  )
  assert_false(
    log_identity_patterns_match(
      "Thor <thor@example.com>",
      ["Aster", "-0700"],
      GrepPatternType::Basic,
      false,
    ),
  )
}

///|
test "log: grep reflog requires walk_reflogs" {
  let raised = try {
    log_validate_reflog_grep_options(false, ["commit: third"])
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  let ok = try {
    log_validate_reflog_grep_options(true, ["commit: third"])
    true
  } catch {
    _ => false
  }
  assert_true(ok)
}

///|
test "log: format_decoration" {
  let ref_names : Map[String, Array[String]] = {}
  // No decoration
  assert_eq(format_decoration(ref_names, "abc1234"), "")
  // Single decoration
  ref_names["abc1234"] = ["HEAD -> main"]
  assert_eq(format_decoration(ref_names, "abc1234"), " (HEAD -> main)")
  // Multiple decorations
  ref_names["def5678"] = ["HEAD -> main", "origin/main"]
  assert_eq(
    format_decoration(ref_names, "def5678"),
    " (HEAD -> main, origin/main)",
  )
}

///|
test "log: decoration pattern matching handles HEAD and trailing slash" {
  assert_true(log_decoration_pattern_matches("HEAD", "HEAD"))
  assert_false(log_decoration_pattern_matches("refs/heads/main", "HEAD"))
  assert_true(log_decoration_pattern_matches("refs/tags/reach", "tags/"))
  assert_true(
    log_decoration_pattern_matches("refs/heads/topic/sub", "heads/topic"),
  )
  assert_false(
    log_decoration_pattern_matches("refs/heads/topic-2", "heads/topic"),
  )
}

///|
test "log: decoration ref visibility respects defaults and clear mode" {
  assert_false(
    log_should_include_decoration_ref("refs/hidden/tangle", [], [], false),
  )
  assert_true(
    log_should_include_decoration_ref("refs/hidden/tangle", [], [], true),
  )
  assert_false(
    log_should_include_decoration_ref(
      "refs/heads/octopus-a",
      ["heads/*"],
      ["heads/octopus*"],
      true,
    ),
  )
}

///|
test "log: log_extract_author_timestamp" {
  // Simulate a commit object data
  let commit_data = "tree 0000000000000000000000000000000000000000\nauthor Test User <test@example.com> 1700000000 +0000\ncommitter Test User <test@example.com> 1700000000 +0000\n\nTest commit message\n"
  let data = @utf8.encode(commit_data[:])
  let ts = log_extract_author_timestamp(data)
  assert_eq(ts, 1700000000L)
}

///|
test "log: log_parse_entry_from_obj" {
  let commit_data = "tree 0000000000000000000000000000000000000000\nauthor Test User <test@example.com> 1700000000 +0000\ncommitter Test User <test@example.com> 1700000000 +0000\n\nTest commit message\n"
  let data = @utf8.encode(commit_data[:])
  let id = @bitcore.ObjectId::from_hex(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let tree = @bitcore.ObjectId::from_hex(
    "0000000000000000000000000000000000000000",
  )
  let entry = log_parse_entry_from_obj(id, data, tree, 0)
  assert_eq(entry.message, "Test commit message")
  assert_eq(entry.author, "Test User <test@example.com>")
  assert_eq(entry.timestamp, 1700000000L)
  assert_eq(entry.parent_count, 0)
}

///|
test "log: is_short_count_flag" {
  assert_true(is_short_count_flag("-5"))
  assert_true(is_short_count_flag("-10"))
  assert_false(is_short_count_flag("-n"))
  assert_false(is_short_count_flag("--oneline"))
  assert_false(is_short_count_flag("5"))
}

///|
test "log: log_queue_insert maintains descending order" {
  let queue : Array[(Int64, @bitcore.ObjectId)] = []
  let id1 = @bitcore.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let id2 = @bitcore.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  let id3 = @bitcore.ObjectId::from_hex(
    "3333333333333333333333333333333333333333",
  )
  log_queue_insert(queue, (100L, id1))
  log_queue_insert(queue, (300L, id3))
  log_queue_insert(queue, (200L, id2))
  assert_eq(queue[0].0, 300L)
  assert_eq(queue[1].0, 200L)
  assert_eq(queue[2].0, 100L)
}

///|
fn log_test_commit(
  fs : @bitcore.TestFs,
  root : String,
  path : String,
  content : String,
  message : String,
  ts : Int64,
) -> @bitcore.ObjectId raise Error {
  fs.write_string(root + "/" + path, content)
  @bitlib.add_paths(fs, fs, root, [path])
  @bitlib.commit(
    fs,
    fs,
    root,
    message + "\n",
    "Test User <test@example.com>",
    ts,
  )
}

///|
test "log: build ref names peels nested annotated tags" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  ignore(try? log_test_commit(fs, "/repo", "file.txt", "one\n", "one", 1L))
  let head = log_test_commit(fs, "/repo", "file.txt", "two\n", "two", 2L) catch {
    err => fail("unexpected commit error: \{err}")
  }

  ignore(
    try? @bitlib.create_lightweight_tag(
      fs, fs, "/repo/.git", "lightweight", head,
    ),
  )
  ignore(
    try? @bitlib.create_annotated_tag(
      fs, fs, "/repo/.git", "annotated", head, "annotated", "Test User <test@example.com>",
      3L,
    ),
  )
  ignore(try? @bitlib.create_branch_at(fs, fs, "/repo", "reach", head))
  ignore(
    try? @bitlib.create_annotated_tag(
      fs, fs, "/repo/.git", "double-0", head, "double-0", "Test User <test@example.com>",
      4L,
    ),
  )
  let double_0 = @bitrepo.rev_parse(fs, "/repo/.git", "refs/tags/double-0").unwrap_or(
    @bitcore.ObjectId::from_hex("0000000000000000000000000000000000000000"),
  )
  ignore(
    try? @bitlib.create_annotated_tag(
      fs, fs, "/repo/.git", "double-1", double_0, "double-1", "Test User <test@example.com>",
      5L,
    ),
  )

  let ref_names = log_build_ref_names(fs, "/repo/.git", {
    mode: LogDecorationDisplayMode::Short,
    include_patterns: [],
    exclude_patterns: [],
    include_all_refs: false,
  }) catch {
    _ => {}
  }
  match ref_names.get(head.to_hex()) {
    Some(names) =>
      assert_eq(names, [
        "HEAD -> main", "tag: lightweight", "tag: double-1", "tag: double-0", "tag: annotated",
        "reach",
      ])
    None => fail("expected decorations for HEAD commit")
  }

  let full_ref_names = log_build_ref_names(fs, "/repo/.git", {
    mode: LogDecorationDisplayMode::Full,
    include_patterns: [],
    exclude_patterns: [],
    include_all_refs: false,
  }) catch {
    _ => {}
  }
  match full_ref_names.get(head.to_hex()) {
    Some(names) =>
      assert_eq(names, [
        "HEAD -> refs/heads/main", "tag: refs/tags/lightweight", "tag: refs/tags/double-1",
        "tag: refs/tags/double-0", "tag: refs/tags/annotated", "refs/heads/reach",
      ])
    None => fail("expected full decorations for HEAD commit")
  }
}

///|
test "log: resolve targets preserves tag revision names" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  let head = log_test_commit(fs, "/repo", "file.txt", "one\n", "one", 1L) catch {
    err => fail("unexpected commit error: \{err}")
  }
  ignore(try? @bitlib.create_branch_at(fs, fs, "/repo", "source-a", head))
  ignore(
    try? @bitlib.create_annotated_tag(
      fs, fs, "/repo/.git", "source-tag", head, "source-tag", "Test User <test@example.com>",
      2L,
    ),
  )

  let targets = log_resolve_targets(
    fs,
    "/repo/.git",
    ["source-tag", "source-a"],
    [],
    false,
    default_head=false,
  ) catch {
    err => fail("unexpected resolve error: \{err}")
  }
  assert_eq(targets.length(), 2)
  assert_eq(targets[0].0, "source-tag")
  assert_eq(targets[1].0, "source-a")
}

///|
test "log: grafts affect fast-path history in main and linked worktrees" {
  let fs = @bitcore.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, "/repo"))
  let abc = log_test_commit(fs, "/repo", "file.txt", "abc\n", "abc", 1L) catch {
    err => fail("unexpected commit error: \{err}")
  }
  ignore(
    log_test_commit(fs, "/repo", "file.txt", "def\n", "def", 2L) catch {
      err => fail("unexpected commit error: \{err}")
    },
  )
  let xyz = log_test_commit(fs, "/repo", "file.txt", "xyz\n", "xyz", 3L) catch {
    err => fail("unexpected commit error: \{err}")
  }
  fs.write_string(
    "/repo/.git/info/grafts",
    xyz.to_hex() + " " + abc.to_hex() + "\n",
  )

  let main_lines = @bitlib.log_head_oneline(fs, "/repo/.git", max_count=2) catch {
    err => fail("unexpected log error: \{err}")
  }
  assert_eq(main_lines.length(), 2)
  assert_true(main_lines[0].has_suffix(" xyz"))
  assert_true(main_lines[1].has_suffix(" abc"))

  ignore(
    try? @bitlib.create_worktree(
      fs,
      fs,
      "/repo",
      "/grafted",
      Some("main"),
      detach=true,
      new_branch=None,
    ),
  )
  let linked_lines = @bitlib.log_head_oneline(
    fs,
    "/repo/.git/worktrees/grafted",
    max_count=2,
  ) catch {
    err => fail("unexpected linked log error: \{err}")
  }
  assert_eq(linked_lines.length(), 2)
  assert_true(linked_lines[0].has_suffix(" xyz"))
  assert_true(linked_lines[1].has_suffix(" abc"))
}

///|
test "log: apply wrap spec indents and wraps subject text" {
  let wrapped = log_apply_wrap("This is the sixth commit.", {
    width: 11,
    indent1: 1,
    indent2: 2,
  })
  assert_eq(wrapped, " This is\n  the sixth\n  commit.")
}

///|
test "log: format_commit_string honors %w prefix" {
  let id = @bitcore.ObjectId::from_hex(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let tree = @bitcore.ObjectId::from_hex(
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  let data : CommitFormatData = {
    id,
    tree,
    parents: [],
    abbrev_len: 7,
    encoding: "",
    author_name: "Test User",
    author_email: "test@example.com",
    author_timestamp: 1700000000L,
    author_tz: "+0000",
    committer_name: "Test User",
    committer_email: "test@example.com",
    committer_timestamp: 1700000000L,
    committer_tz: "+0000",
    subject: "sixth",
    body: "",
    message: "sixth",
    ref_names: {},
    date_format: "",
    left_right_marker: "",
    reflog_selector_short: None,
    reflog_selector: None,
    reflog_message: None,
    reflog_author_name: None,
    reflog_author_email: None,
    pretty_color_enabled: false,
    pretty_auto_color: "\u001b[33m",
  }
  let wrapped = format_commit_string("%w(11,1,2)This is the %s commit.", data)
  assert_eq(wrapped, " This is\n  the sixth\n  commit.")

  let explicit_breaks = format_commit_string(
    "%w(,1,2)This is%nthe %s%ncommit.", data,
  )
  assert_eq(explicit_breaks, " This is\n  the sixth\n  commit.")

  let sanitized_data : CommitFormatData = {
    id,
    tree,
    parents: [],
    abbrev_len: 7,
    encoding: "",
    author_name: "Test User",
    author_email: "test@example.com",
    author_timestamp: 1700000000L,
    author_tz: "+0000",
    committer_name: "Test User",
    committer_email: "test@example.com",
    committer_timestamp: 1700000000L,
    committer_tz: "+0000",
    subject: "Merge tag 'reach'",
    body: "",
    message: "Merge tag 'reach'",
    ref_names: {},
    date_format: "",
    left_right_marker: "",
    reflog_selector_short: None,
    reflog_selector: None,
    reflog_message: None,
    reflog_author_name: None,
    reflog_author_email: None,
    pretty_color_enabled: false,
    pretty_auto_color: "\u001b[33m",
  }
  let sanitized = format_commit_string("%f", sanitized_data)
  assert_eq(sanitized, "Merge-tag-reach")
}

///|
test "log: abbrev helpers respect bool and numeric config" {
  assert_eq(log_parse_abbrev_length_value("false"), Some(40))
  assert_eq(log_parse_abbrev_length_value("9000"), Some(40))
  assert_eq(log_parse_abbrev_length_value("3"), Some(4))
  assert_eq(log_parse_abbrev_length_value("12"), Some(12))
  assert_eq(log_abbrev_hex("0123456789abcdef", 7), "0123456")
  assert_eq(log_abbrev_hex("012345", 40), "012345")
}

///|
test "log: diff-filter parser splits include and exclude bits" {
  let include_bits : Map[String, Bool] = {}
  let exclude : Map[String, Bool] = {}
  log_add_diff_filter_chars("Ra", include_bits, exclude)
  log_add_diff_filter_chars("d", include_bits, exclude)
  assert_true(include_bits.contains("R"))
  assert_true(exclude.contains("A"))
  assert_true(exclude.contains("D"))
  assert_false(include_bits.contains("D"))
}

///|
test "log: diff-filter matching respects positive and negative bits" {
  let statuses : Map[String, Bool] = { "R": true }
  let include_bits : Map[String, Bool] = { "R": true }
  let exclude : Map[String, Bool] = { "A": true }
  assert_true(log_has_diff_filter(include_bits, exclude))
  assert_true(
    log_commit_matches_diff_filter_with_statuses(
      statuses, include_bits, exclude,
    ),
  )

  statuses["A"] = true
  assert_false(
    log_commit_matches_diff_filter_with_statuses(
      statuses, include_bits, exclude,
    ),
  )

  let negative_only_statuses : Map[String, Bool] = { "A": true, "D": true }
  let negative_only_include : Map[String, Bool] = {}
  let negative_only_exclude : Map[String, Bool] = { "D": true }
  assert_true(
    log_commit_matches_diff_filter_with_statuses(
      negative_only_statuses, negative_only_include, negative_only_exclude,
    ),
  )

  let deleted_only_statuses : Map[String, Bool] = { "D": true }
  assert_false(
    log_commit_matches_diff_filter_with_statuses(
      deleted_only_statuses, negative_only_include, negative_only_exclude,
    ),
  )
}

///|
test "log: grep helper supports any-match and all-match" {
  let patterns = ["second", "initial"]
  assert_true(
    log_grep_patterns_match(
      "second commit message",
      patterns,
      GrepPatternType::Fixed,
      false,
      false,
    ),
  )
  assert_false(
    log_grep_patterns_match(
      "second commit message",
      patterns,
      GrepPatternType::Fixed,
      false,
      true,
    ),
  )
  assert_true(
    log_grep_patterns_match(
      "second initial",
      patterns,
      GrepPatternType::Fixed,
      false,
      true,
    ),
  )
}
