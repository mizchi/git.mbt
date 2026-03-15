///|
test "diff: apply relative path strips literal prefix" {
  assert_eq(diff_apply_relative_path("subdir/file2", "subdir/"), Some("file2"))
  assert_eq(diff_apply_relative_path("subdir/file2", "subdir"), Some("file2"))
  assert_eq(diff_apply_relative_path("subdir/file2", "sub"), Some("dir/file2"))
  assert_eq(diff_apply_relative_path("file1", "subdir"), None)
}

///|
test "diff: apply relative files filters outside prefix" {
  let files : Array[@bitdiff.DiffFile] = [
    {
      path: "file1",
      kind: @bitdiff.DiffKind::Added,
      old_content: None,
      new_content: Some(@utf8.encode("content\n"[:])),
      old_mode: None,
      new_mode: Some(0o100644),
    },
    {
      path: "subdir/file2",
      kind: @bitdiff.DiffKind::Added,
      old_content: None,
      new_content: Some(@utf8.encode("other content\n"[:])),
      old_mode: None,
      new_mode: Some(0o100644),
    },
  ]
  let display = diff_apply_relative_files(files, Some("subdir"))
  assert_eq(display.length(), 1)
  assert_eq(display[0].path, "file2")
}

///|
async test "diff: resolve relative prefix from cwd and config" {
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string("/repo/.git/config", "[diff]\n\trelative = true\n")
  @sys.set_env_var("GIT_SHIM_CWD", "/repo/subdir")
  @sys.set_env_var("GIT_SHIM_PWD", "/repo/subdir")
  let from_config = diff_resolve_relative_prefix(
    fs,
    "/repo/.git",
    "/repo",
    None,
    false,
  )
  assert_eq(from_config, Some("subdir"))
  let explicit = diff_resolve_relative_prefix(
    fs,
    "/repo/.git",
    "/repo",
    Some("sub"),
    false,
  )
  assert_eq(explicit, Some("sub"))
  let disabled = diff_resolve_relative_prefix(
    fs,
    "/repo/.git",
    "/repo",
    Some("sub"),
    true,
  )
  assert_eq(disabled, None)
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
}

///|
test "diff: format numstat and stat" {
  let files : Array[@bitdiff.DiffFile] = [
    {
      path: "file2",
      kind: @bitdiff.DiffKind::Added,
      old_content: None,
      new_content: Some(@utf8.encode("other content\n"[:])),
      old_mode: None,
      new_mode: Some(0o100644),
    },
  ]
  assert_eq(diff_format_numstat(files), ["1\t0\tfile2"])
  assert_eq(diff_format_stat(files), [
    " file2 | 1 +", " 1 file changed, 1 insertion(+)",
  ])
}

///|
test "diff: format shortstat summary dirstat and compact summary" {
  let base = @utf8.encode("Line 1\nLine 2\nline 3\n"[:])
  let changed = @utf8.encode("Line 1\nLine 2\nLine 3\n"[:])
  let dated = @utf8.encode("0123456789012345678901234567\n"[:])
  let files : Array[@bitdiff.DiffFile] = [
    {
      path: "path0",
      kind: @bitdiff.DiffKind::Modified,
      old_content: Some(base),
      new_content: Some(changed),
      old_mode: Some(0o100644),
      new_mode: Some(0o100755),
    },
    {
      path: "path1",
      kind: @bitdiff.DiffKind::Deleted,
      old_content: Some(base),
      new_content: None,
      old_mode: Some(0o100755),
      new_mode: None,
    },
    {
      path: "path2/path3",
      kind: @bitdiff.DiffKind::Modified,
      old_content: Some(@utf8.encode(""[:])),
      new_content: Some(dated),
      old_mode: Some(0o100644),
      new_mode: Some(0o100644),
    },
  ]
  assert_eq(diff_format_shortstat(files), [
    " 3 files changed, 2 insertions(+), 4 deletions(-)",
  ])
  assert_eq(diff_format_summary(files), [
    " mode change 100644 => 100755 path0", " delete mode 100755 path1",
  ])
  assert_eq(diff_format_dirstat(files), ["  45.3% path2/"])
  assert_eq(diff_format_dirstat(files, by_file=true), ["  33.3% path2/"])
  assert_eq(diff_format_stat(files, compact_summary=true), [
    " path0 (mode +x) | 2 +-", " path1 (gone)    | 3 ---", " path2/path3     | 1 +",
    " 3 files changed, 2 insertions(+), 4 deletions(-)",
  ])
}

///|
test "diff: ignore-all-space drops whitespace-only modifications" {
  let files : Array[@bitdiff.DiffFile] = [
    {
      path: "same.txt",
      kind: @bitdiff.DiffKind::Modified,
      old_content: Some(@utf8.encode("1 \n2\t3\n"[:])),
      new_content: Some(@utf8.encode("1\n2 3\n"[:])),
      old_mode: Some(0o100644),
      new_mode: Some(0o100644),
    },
    {
      path: "mode.txt",
      kind: @bitdiff.DiffKind::Modified,
      old_content: Some(@utf8.encode("keep\n"[:])),
      new_content: Some(@utf8.encode("keep\n"[:])),
      old_mode: Some(0o100644),
      new_mode: Some(0o100755),
    },
    {
      path: "real.txt",
      kind: @bitdiff.DiffKind::Modified,
      old_content: Some(@utf8.encode("before\n"[:])),
      new_content: Some(@utf8.encode("after\n"[:])),
      old_mode: Some(0o100644),
      new_mode: Some(0o100644),
    },
  ]
  let filtered = diff_filter_ignore_all_space(files)
  assert_eq(filtered.map(f => f.path), ["mode.txt", "real.txt"])
}

///|
test "diff: check helper finds trailing whitespace and conflict markers" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo")
  fs.write_string("/repo/.gitattributes", "b conflict-marker-size=8\n")
  let issues_a = diff_collect_check_issues_for_file(fs, "/repo", {
    path: "a",
    kind: @bitdiff.DiffKind::Modified,
    old_content: Some(@utf8.encode("base\n"[:])),
    new_content: Some(@utf8.encode("base\nbad   \n"[:])),
    old_mode: Some(0o100644),
    new_mode: Some(0o100644),
  })
  assert_eq(issues_a.map(issue => "\{issue.line}:\{issue.message}"), [
    "2:trailing whitespace.",
  ])
  let issues_b = diff_collect_check_issues_for_file(fs, "/repo", {
    path: "b",
    kind: @bitdiff.DiffKind::Modified,
    old_content: Some(@utf8.encode("base\n"[:])),
    new_content: Some(@utf8.encode("base\n>>>>>>>> ours\n========\n"[:])),
    old_mode: Some(0o100644),
    new_mode: Some(0o100644),
  })
  assert_eq(issues_b.map(issue => "\{issue.line}:\{issue.message}"), [
    "2:leftover conflict marker", "3:leftover conflict marker",
  ])
}

///|
test "diff: raw formatter uses blob object ids" {
  let content = @utf8.encode("other content\n"[:])
  let file : @bitdiff.DiffFile = {
    path: "file2",
    kind: @bitdiff.DiffKind::Added,
    old_content: None,
    new_content: Some(content),
    old_mode: None,
    new_mode: Some(0o100644),
  }
  let expected_oid = @bitcore.hash_object_content(
    @bitcore.ObjectType::Blob,
    content,
  )
  assert_eq(
    format_diff_index_line_from_diff_file(file),
    ":000000 100644 0000000000000000000000000000000000000000 \{expected_oid.to_hex()} A\tfile2",
  )
  assert_eq(
    format_diff_index_line_from_diff_file(file, worktree_compare=true),
    ":000000 100644 0000000000000000000000000000000000000000 0000000000000000000000000000000000000000 A\tfile2",
  )
}

///|
test "diff: raw worktree change tracks delete typechange and add" {
  let old_id = @bitcore.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let gitlink_id = @bitcore.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  let missing : DiffWorktreeObserved = { mode: None, id: None }
  let submodule : DiffWorktreeObserved = {
    mode: Some(0o160000),
    id: Some(gitlink_id),
  }
  let same_file : DiffWorktreeObserved = {
    mode: Some(0o100644),
    id: Some(old_id),
  }

  let gone = diff_raw_worktree_change(
    "gone",
    Some(0o100644),
    Some(old_id),
    missing,
  ).unwrap()
  assert_eq(gone.path, "gone")
  assert_eq(gone.status, "D")
  assert_eq(gone.old_mode, Some(0o100644))
  assert_eq(gone.old_id.map(id => id.to_hex()), Some(old_id.to_hex()))
  assert_eq(gone.new_mode, None)

  let typed = diff_raw_worktree_change(
    "submodule",
    Some(0o100644),
    Some(old_id),
    submodule,
  ).unwrap()
  assert_eq(typed.path, "submodule")
  assert_eq(typed.status, "T")
  assert_eq(typed.old_mode, Some(0o100644))
  assert_eq(typed.old_id.map(id => id.to_hex()), Some(old_id.to_hex()))
  assert_eq(typed.new_mode, Some(0o160000))

  let added = diff_raw_worktree_change("added", None, None, submodule).unwrap()
  assert_eq(added.path, "added")
  assert_eq(added.status, "A")
  assert_eq(added.old_mode, None)
  assert_eq(added.old_id, None)
  assert_eq(added.new_mode, Some(0o160000))

  assert_true(
    diff_raw_worktree_change("same", Some(0o100644), Some(old_id), same_file)
    is None,
  )
}

///|
test "diff: ignore-submodules filter removes gitlink raw changes" {
  let old_id = @bitcore.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let changes : Array[DiffRawWorktreeChange] = [
    {
      path: "plain",
      status: "M",
      old_mode: Some(0o100644),
      old_id: Some(old_id),
      new_mode: Some(0o100644),
    },
    {
      path: "sub",
      status: "D",
      old_mode: Some(0o160000),
      old_id: Some(old_id),
      new_mode: None,
    },
  ]
  let filtered = diff_filter_raw_submodule_changes(changes, true)
  assert_eq(filtered.length(), 1)
  assert_eq(filtered[0].path, "plain")
  assert_eq(diff_filter_raw_submodule_changes(changes, false).length(), 2)
}

///|
test "diff: extra unmerged names duplicate displayed relative paths" {
  let unmerged : Map[String, Bool] = { "file0": true, "subdir/file0": true }
  let displayed : Array[@bitdiff.DiffFile] = [
    {
      path: "file0",
      kind: @bitdiff.DiffKind::Modified,
      old_content: Some(@utf8.encode("sub3\n"[:])),
      new_content: Some(@utf8.encode("sub1\n"[:])),
      old_mode: Some(0o100644),
      new_mode: Some(0o100644),
    },
  ]
  let extra = diff_extra_unmerged_name_only_paths(
    unmerged,
    displayed,
    [],
    Some("subdir"),
  )
  assert_eq(extra, ["file0"])
}

///|
test "diff: gitlink patch includes subproject commit lines" {
  let rev1 = "0123456789abcdef0123456789abcdef01234567"
  let rev2 = "89abcdef0123456789abcdef0123456789abcdef"
  let file : @bitdiff.DiffFile = {
    path: "init",
    kind: @bitdiff.DiffKind::Modified,
    old_content: Some(@utf8.encode("Subproject commit \{rev1}\n"[:])),
    new_content: Some(@utf8.encode("Subproject commit \{rev2}\n"[:])),
    old_mode: Some(0o160000),
    new_mode: Some(0o160000),
  }
  let lines = diff_collect_output_lines(
    [file],
    diff_default_output_selection(),
    3,
    [],
  )
  assert_true(lines.contains("+Subproject commit " + rev2))
  assert_true(lines.contains("-Subproject commit " + rev1))
}

///|
async test "diff: real fs diff_worktree sees gitlink head change" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-diff-real-fs-gitlink-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let init_dir = root + "/init"
  let super_dir = root + "/super"

  let (code_init, _, _) = @process.collect_output(
    "git",
    ["init", "--initial-branch=main", "-q", init_dir],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code_init, 0)
  submodule_wbtest_run_git(init_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(init_dir, [
    "config", "user.email", "test@example.com",
  ])
  fs.write_string(init_dir + "/a", "a\n")
  submodule_wbtest_run_git(init_dir, ["add", "a"])
  submodule_wbtest_run_git(init_dir, ["commit", "-q", "-m", "initial"])
  let rev1 = submodule_wbtest_git_stdout(init_dir, ["rev-parse", "HEAD"])
    |> add_test_trim_trailing_newline

  let (code_super, _, _) = @process.collect_output(
    "git",
    ["init", "--initial-branch=main", "-q", super_dir],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code_super, 0)
  submodule_wbtest_run_git(super_dir, ["config", "user.name", "Test User"])
  submodule_wbtest_run_git(super_dir, [
    "config", "user.email", "test@example.com",
  ])

  let prev_allow_protocol = @sys.get_env_var("GIT_ALLOW_PROTOCOL")
  @sys.set_env_var("GIT_ALLOW_PROTOCOL", "file")
  let (code_add, _, _) = @process.collect_output(
    "git",
    ["-C", super_dir, "submodule", "add", "./../init", "init"],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code_add, 0)
  let (code_commit, _, _) = @process.collect_output(
    "git",
    ["-C", super_dir, "commit", "-qam", "initial"],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code_commit, 0)
  submodule_wbtest_restore_env("GIT_ALLOW_PROTOCOL", prev_allow_protocol)

  fs.write_string(super_dir + "/init/b", "b\n")
  let (code_sub_add, _, _) = @process.collect_output(
    "git",
    ["-C", super_dir + "/init", "add", "b"],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code_sub_add, 0)
  let (code_sub_commit, _, _) = @process.collect_output(
    "git",
    ["-C", super_dir + "/init", "commit", "-q", "-m", "second"],
    inherit_env=true,
    cwd=root,
  )
  assert_eq(code_sub_commit, 0)
  let rev2 = submodule_wbtest_git_stdout(super_dir + "/init", [
      "rev-parse", "HEAD",
    ])
    |> add_test_trim_trailing_newline

  let entries = @bitlib.read_index_entries(fs, super_dir + "/.git")
  let mut gitlink : @bitlib.IndexEntry? = None
  for entry in entries {
    if entry.path == "init" {
      gitlink = Some(entry)
      break
    }
  }
  let gitlink = gitlink.unwrap()
  assert_eq(gitlink.mode, 0o160000)
  assert_eq(gitlink.id.to_hex(), rev1)
  let sub_git_dir = @bitlib.resolve_gitdir(fs, super_dir + "/init/.git")
  let head = @bitlib.resolve_head_commit(fs, sub_git_dir).unwrap()
  assert_eq(head.to_hex(), rev2)

  let files = @bitdiff.diff_worktree(fs, super_dir)
  assert_eq(files.length(), 1)
  let text = @bitdiff.diff_text(files)
  assert_true(text.contains("-Subproject commit " + rev1))
  assert_true(text.contains("+Subproject commit " + rev2))

  cleanup_tree(fs, root)
}
