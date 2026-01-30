///| Tests for worktree administration

///|
fn setup_worktree_admin_fs() -> @git.TestFs {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.mkdir_p("/repo/.git/refs/heads")
  fs.mkdir_p("/repo/.git/objects")
  fs.mkdir_p("/repo/.git/objects/pack")
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(
    "/repo/.git/refs/heads/main",
    "1111111111111111111111111111111111111111\n",
  )
  fs
}

///|
test "worktree admin: list main worktree only" {
  let fs = setup_worktree_admin_fs()
  let worktrees = list_worktrees(fs, "/repo")
  assert_eq(worktrees.length(), 1)
  assert_eq(worktrees[0].path, "/repo")
  assert_eq(worktrees[0].branch, Some("main"))
  assert_true(worktrees[0].is_main)
  assert_false(worktrees[0].locked)
}

///|
test "worktree admin: list with linked worktree" {
  let fs = setup_worktree_admin_fs()
  // Create a linked worktree admin dir
  fs.mkdir_p("/repo/.git/worktrees/wt1")
  fs.write_string("/repo/.git/worktrees/wt1/gitdir", "/worktree1/.git\n")
  fs.write_string("/repo/.git/worktrees/wt1/HEAD", "ref: refs/heads/feature\n")
  fs.write_string("/repo/.git/worktrees/wt1/commondir", "../..\n")
  fs.write_string(
    "/repo/.git/refs/heads/feature",
    "2222222222222222222222222222222222222222\n",
  )
  let worktrees = list_worktrees(fs, "/repo")
  assert_eq(worktrees.length(), 2)
  // Main worktree
  assert_eq(worktrees[0].path, "/repo")
  assert_eq(worktrees[0].branch, Some("main"))
  // Linked worktree
  assert_eq(worktrees[1].path, "/worktree1")
  assert_eq(worktrees[1].branch, Some("feature"))
  assert_false(worktrees[1].is_main)
}

///|
test "worktree admin: list detached head worktree" {
  let fs = setup_worktree_admin_fs()
  fs.mkdir_p("/repo/.git/worktrees/wt-detached")
  fs.write_string("/repo/.git/worktrees/wt-detached/gitdir", "/detached-wt/.git\n")
  fs.write_string(
    "/repo/.git/worktrees/wt-detached/HEAD",
    "3333333333333333333333333333333333333333\n",
  )
  fs.write_string("/repo/.git/worktrees/wt-detached/commondir", "../..\n")
  let worktrees = list_worktrees(fs, "/repo")
  assert_eq(worktrees.length(), 2)
  assert_eq(worktrees[1].path, "/detached-wt")
  assert_eq(worktrees[1].branch, None)
}

///|
test "worktree admin: list locked worktree" {
  let fs = setup_worktree_admin_fs()
  fs.mkdir_p("/repo/.git/worktrees/locked-wt")
  fs.write_string("/repo/.git/worktrees/locked-wt/gitdir", "/locked-path/.git\n")
  fs.write_string(
    "/repo/.git/worktrees/locked-wt/HEAD",
    "4444444444444444444444444444444444444444\n",
  )
  fs.write_string("/repo/.git/worktrees/locked-wt/commondir", "../..\n")
  fs.write_string("/repo/.git/worktrees/locked-wt/locked", "")
  let worktrees = list_worktrees(fs, "/repo")
  assert_eq(worktrees.length(), 2)
  assert_true(worktrees[1].locked)
}

///|
test "worktree admin: is_branch_checked_out main" {
  let fs = setup_worktree_admin_fs()
  let result = is_branch_checked_out(fs, "/repo", "main")
  assert_eq(result, Some("/repo"))
}

///|
test "worktree admin: is_branch_checked_out untracked" {
  let fs = setup_worktree_admin_fs()
  let result = is_branch_checked_out(fs, "/repo", "nonexistent")
  assert_eq(result, None)
}

///|
test "worktree admin: is_branch_checked_out in linked worktree" {
  let fs = setup_worktree_admin_fs()
  fs.mkdir_p("/repo/.git/worktrees/wt1")
  fs.write_string("/repo/.git/worktrees/wt1/gitdir", "/worktree1/.git\n")
  fs.write_string("/repo/.git/worktrees/wt1/HEAD", "ref: refs/heads/feature\n")
  fs.write_string("/repo/.git/worktrees/wt1/commondir", "../..\n")
  fs.write_string(
    "/repo/.git/refs/heads/feature",
    "2222222222222222222222222222222222222222\n",
  )
  let result = is_branch_checked_out(fs, "/repo", "feature")
  assert_eq(result, Some("/worktree1"))
}

///|
test "worktree admin: prune missing worktree" {
  let fs = setup_worktree_admin_fs()
  // Create admin dir for a worktree that doesn't exist
  fs.mkdir_p("/repo/.git/worktrees/missing")
  fs.write_string("/repo/.git/worktrees/missing/gitdir", "/nonexistent/.git\n")
  fs.write_string(
    "/repo/.git/worktrees/missing/HEAD",
    "5555555555555555555555555555555555555555\n",
  )
  fs.write_string("/repo/.git/worktrees/missing/commondir", "../..\n")
  // Prune should remove it
  let pruned = prune_worktrees(fs, fs, "/repo")
  assert_eq(pruned.length(), 1)
  assert_eq(pruned[0], "missing")
  // Admin dir should be removed
  assert_false(fs.is_dir("/repo/.git/worktrees/missing"))
}

///|
test "worktree admin: prune dry run" {
  let fs = setup_worktree_admin_fs()
  fs.mkdir_p("/repo/.git/worktrees/missing")
  fs.write_string("/repo/.git/worktrees/missing/gitdir", "/nonexistent/.git\n")
  fs.write_string(
    "/repo/.git/worktrees/missing/HEAD",
    "5555555555555555555555555555555555555555\n",
  )
  fs.write_string("/repo/.git/worktrees/missing/commondir", "../..\n")
  // Dry run should not remove
  let pruned = prune_worktrees(fs, fs, "/repo", dry_run=true)
  assert_eq(pruned.length(), 1)
  // Admin dir should still exist
  assert_true(fs.is_dir("/repo/.git/worktrees/missing"))
}

///|
test "worktree admin: prune locked worktree not pruned" {
  let fs = setup_worktree_admin_fs()
  fs.mkdir_p("/repo/.git/worktrees/locked-missing")
  fs.write_string(
    "/repo/.git/worktrees/locked-missing/gitdir",
    "/nonexistent-locked/.git\n",
  )
  fs.write_string(
    "/repo/.git/worktrees/locked-missing/HEAD",
    "6666666666666666666666666666666666666666\n",
  )
  fs.write_string("/repo/.git/worktrees/locked-missing/commondir", "../..\n")
  fs.write_string("/repo/.git/worktrees/locked-missing/locked", "")
  // Locked worktrees should not be pruned even if missing
  let pruned = prune_worktrees(fs, fs, "/repo")
  assert_eq(pruned.length(), 0)
  assert_true(fs.is_dir("/repo/.git/worktrees/locked-missing"))
}

