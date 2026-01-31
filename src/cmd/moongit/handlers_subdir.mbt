///|
/// Subdir command handlers - subdirectory as independent repository

///|
async fn handle_subdir(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_subdir_usage()
    return
  }
  let subcommand = args[0]
  let rest = array_view_to_array(args[1:])
  match subcommand {
    "clone" => handle_subdir_clone(rest) catch { e => raise e }
    "status" => handle_subdir_status(rest) catch { e => raise e }
    "rebase" => handle_subdir_rebase(rest) catch { e => raise e }
    "init" => handle_subdir_init(rest) catch { e => raise e }
    "deinit" => handle_subdir_deinit(rest) catch { e => raise e }
    "list" => handle_subdir_list(rest) catch { e => raise e }
    "sync" => handle_subdir_sync(rest) catch { e => raise e }
    "shell" => handle_subdir_shell(rest) catch { e => raise e }
    "show" => handle_subdir_show(rest) catch { e => raise e }
    "log" => handle_subdir_log(rest) catch { e => raise e }
    "diff" => handle_subdir_diff(rest) catch { e => raise e }
    "commit" => handle_subdir_commit(rest) catch { e => raise e }
    "checkout" => handle_subdir_checkout(rest) catch { e => raise e }
    "push" => handle_subdir_push(rest) catch { e => raise e }
    "pull" => handle_subdir_pull(rest) catch { e => raise e }
    "extract" => handle_subdir_extract(rest) catch { e => raise e }
    "sparse-checkout" =>
      handle_subdir_sparse_checkout(rest) catch {
        e => raise e
      }
    _ => {
      print_line("Unknown subdir subcommand: " + subcommand)
      print_subdir_usage()
    }
  }
}

///|
/// ArrayView を Array に変換
fn array_view_to_array(view : ArrayView[String]) -> Array[String] {
  let arr : Array[String] = []
  for item in view {
    arr.push(item)
  }
  arr
}

///|
async fn print_subdir_usage() -> Unit raise Error {
  print_line("Usage: moongit subdir <command> [options]")
  print_line("")
  print_line("Clone and manage subdirectories as independent git repositories.")
  print_line("")
  print_line("Main commands:")
  print_line("  clone <url> <path> [<dest>]  Clone subdirectory from remote")
  print_line("  status [<path>]              Show status (default: current dir)")
  print_line("  commit <path> -m <msg>       Commit changes")
  print_line("  push <path> [<url>]          Push to remote")
  print_line("  pull <path> [<url>]          Pull from remote")
  print_line("")
  print_line("Example workflow:")
  print_line("  moongit subdir clone https://github.com/user/repo src/lib mylib")
  print_line("  cd mylib")
  print_line("  git status          # or: moongit subdir status")
  print_line("  git add . && git commit -m 'changes'")
  print_line("")
  print_line("Other commands:")
  print_line("  init <path>      Initialize existing subdirectory as git module")
  print_line("  deinit <path>    Remove subdirectory module")
  print_line("  list             List initialized subdirectory modules")
  print_line("  sync <path>      Sync subdirectory with parent repository")
  print_line("  shell <path>     Start a shell with git scoped to subdirectory")
  print_line("  show <path>      Show subdirectory info")
  print_line("  log <path>       Show commits that affected the subdirectory")
  print_line("  diff <path>      Show working changes in subdirectory")
  print_line(
    "  checkout <path> <commit>  Checkout specific commit of subdirectory",
  )
  print_line(
    "  extract <path> <target>  Extract subdirectory to target directory",
  )
}

///|
/// Show status of a subdir clone (works from within the cloned directory)
async fn handle_subdir_status(args : Array[String]) -> Unit raise Error {
  // Determine which directory to use
  // For subdir status, use path as-is (relative to actual cwd, not git work root)
  let target_dir = if args.length() > 0 { args[0] } else { "." }
  let git_dir = target_dir + "/.git"
  let fs = OsFs::new()
  // Check if this is a valid git repository
  if not(fs.is_dir(git_dir)) {
    print_line("Error: not a git repository: " + target_dir)
    print_line("Hint: use absolute path or run from within the repository")
    return
  }
  // Check if this is a subdir clone
  let info_path = git_dir + "/subdir-clone-info"
  let is_subdir_clone = fs.is_file(info_path)
  if is_subdir_clone {
    // Show subdir clone info
    let info = fs.read_file(info_path) catch { _ => b"" }
    let info_text = bytes_to_string_handler(info)
    print_line("Subdir clone repository")
    for line in info_text.split("\n") {
      let l = line.to_string()
      if l.length() > 0 {
        print_line("  " + l)
      }
    }
    print_line("")
  }
  // Show git status using native git (most reliable)
  let exit_code = @process.run("git", ["-C", target_dir, "status"])
  if exit_code != 0 {
    // Fall back to our own status implementation
    show_simple_status(fs, target_dir, git_dir) catch { e => raise e }
  }
}

///|
/// Simple status implementation when git command fails
async fn show_simple_status(
  fs : OsFs,
  worktree : String,
  git_dir : String,
) -> Unit raise Error {
  // Load index
  let index = @gitlib.read_index_entries(fs, git_dir)
  let index_map : Map[String, @gitlib.IndexEntry] = {}
  for entry in index {
    index_map[entry.path] = entry
  }
  // Scan working directory
  let worktree_files = scan_worktree_files(fs, worktree, "")
  // Compare
  let mut changes = false
  // Check for modified/deleted files
  for path, _entry in index_map {
    let full_path = worktree + "/" + path
    if not(fs.is_file(full_path)) {
      print_line("D  " + path)
      changes = true
    }
  }
  // Check for new files
  for path in worktree_files {
    if not(index_map.contains(path)) {
      print_line("?? " + path)
      changes = true
    }
  }
  if not(changes) {
    print_line("nothing to commit, working tree clean")
  }
}

///|
/// Scan working directory for files
fn scan_worktree_files(
  fs : OsFs,
  base : String,
  prefix : String,
) -> Array[String] {
  let files : Array[String] = []
  let dir_path = if prefix.length() == 0 { base } else { base + "/" + prefix }
  let entries = fs.readdir(dir_path) catch { _ => return files }
  for entry in entries {
    // Skip .git directory
    if entry == ".git" {
      continue
    }
    let rel_path = if prefix.length() == 0 { entry } else { prefix + "/" + entry }
    let full_path = base + "/" + rel_path
    if fs.is_dir(full_path) {
      let subfiles = scan_worktree_files(fs, base, rel_path)
      for f in subfiles {
        files.push(f)
      }
    } else {
      files.push(rel_path)
    }
  }
  files
}

///|
/// Rebase a subdir clone onto upstream changes
/// Only applies changes that affect the original subdirectory path
async fn handle_subdir_rebase(args : Array[String]) -> Unit raise Error {
  // Parse arguments: [path] [upstream]
  let target_dir = if args.length() > 0 && not(args[0].has_prefix("-")) {
    args[0]
  } else {
    "."
  }
  let upstream = if args.length() > 1 {
    args[1]
  } else {
    "origin/main"
  }
  let git_dir = target_dir + "/.git"
  let fs = OsFs::new()
  // Check if this is a valid git repository
  if not(fs.is_dir(git_dir)) {
    print_line("Error: not a git repository: " + target_dir)
    print_line("Hint: use absolute path or run from within the repository")
    return
  }
  // Check if this is a subdir clone
  let info_path = git_dir + "/subdir-clone-info"
  if not(fs.is_file(info_path)) {
    print_line("Error: not a subdir clone. Use regular 'git rebase' instead.")
    return
  }
  // Read subdir clone metadata
  let info = fs.read_file(info_path) catch {
    _ => raise @git.GitError::IoError("Failed to read subdir-clone-info")
  }
  let info_text = bytes_to_string_handler(info)
  let mut remote_url = ""
  let mut subdir_path = ""
  let mut base_commit = ""
  for line in info_text.split("\n") {
    let l = line.to_string()
    if l.has_prefix("remote=") {
      remote_url = String::unsafe_substring(l, start=7, end=l.length())
    } else if l.has_prefix("path=") {
      subdir_path = String::unsafe_substring(l, start=5, end=l.length())
    } else if l.has_prefix("commit=") {
      base_commit = String::unsafe_substring(l, start=7, end=l.length())
    }
  }
  if subdir_path.length() == 0 || base_commit.length() == 0 {
    print_line("Error: invalid subdir-clone-info")
    return
  }
  print_line("Rebasing subdir clone onto \{upstream}...")
  print_line("  Subdirectory: \{subdir_path}")
  print_line("  Base commit: \{base_commit}")
  // Step 1: Fetch from origin
  print_line("  Fetching from origin...")
  let fetch_result = @process.run("git", ["-C", target_dir, "fetch", "origin"])
  if fetch_result != 0 {
    print_line("Warning: fetch may have failed")
  }
  // Step 2: Resolve upstream ref
  let upstream_commit_bytes = fs.read_file(
    git_dir + "/refs/remotes/" + upstream,
  ) catch {
    _ => {
      print_line("Error: cannot resolve upstream ref: \{upstream}")
      print_line("Make sure the ref exists (e.g., origin/main)")
      return
    }
  }
  let upstream_hex = bytes_to_string_handler(upstream_commit_bytes)
    .trim(chars=" \n\t")
    .to_string()
  print_line("  Upstream: \{upstream_hex}")
  // Step 3: Find commits between base and upstream that affect the subdirectory
  print_line("  Finding changes to \{subdir_path}...")
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Get list of commits from base to upstream
  let commits_affecting_subdir = find_subdir_commits(
    db,
    fs,
    base_commit,
    upstream_hex,
    subdir_path,
  ) catch { err => raise err }
  if commits_affecting_subdir.length() == 0 {
    print_line("Already up to date. No changes to \{subdir_path}.")
    // Update base commit to upstream
    update_subdir_clone_info(fs, git_dir, remote_url, subdir_path, upstream_hex)
    return
  }
  print_line("  Found \{commits_affecting_subdir.length()} commits affecting \{subdir_path}")
  // Step 4: For each commit, apply the subdirectory changes
  for commit_info in commits_affecting_subdir {
    print_line("  Applying: \{commit_info.message}")
    apply_subdir_commit(
      fs, db, target_dir, git_dir, commit_info, subdir_path,
    ) catch { err => raise err }
  }
  // Step 5: Update metadata
  update_subdir_clone_info(fs, git_dir, remote_url, subdir_path, upstream_hex)
  // Step 6: Reset index to sync with HEAD
  let _ = @process.run("git", ["-C", target_dir, "reset", "HEAD"])
  print_line("done.")
  print_line("")
  print_line("Successfully rebased onto \{upstream}")
}

///|
struct SubdirCommitInfo {
  id : @git.ObjectId
  tree : @git.ObjectId
  subdir_tree : @git.ObjectId
  message : String
  author : String
  timestamp : Int64
}

///|
/// Parse full commit data including message and author
fn parse_full_commit(content : Bytes) -> (
  @git.ObjectId,
  Array[@git.ObjectId],
  String,
  Int64,
  String,
) raise @git.GitError {
  let text = @utf8.decode_lossy(content[:])
  let mut tree_id : @git.ObjectId? = None
  let parents : Array[@git.ObjectId] = []
  let mut author = ""
  let mut author_time : Int64 = 0L
  let mut in_message = false
  let message = StringBuilder::new()
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      message.write_string(line)
      message.write_char('\n')
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("tree ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      tree_id = Some(@git.ObjectId::from_hex(hex) catch {
        _ => raise @git.GitError::InvalidObject("Invalid tree id")
      })
    } else if line.has_prefix("parent ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      parents.push(@git.ObjectId::from_hex(hex) catch {
        _ => raise @git.GitError::InvalidObject("Invalid parent id")
      })
    } else if line.has_prefix("author ") {
      // Format: "author Name <email> timestamp timezone"
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      // Find last space-separated parts for timestamp
      match rest.rev_find(" ") {
        Some(tz_idx) => {
          let before_tz = String::unsafe_substring(rest, start=0, end=tz_idx)
          match before_tz.rev_find(" ") {
            Some(ts_idx) => {
              author = String::unsafe_substring(before_tz, start=0, end=ts_idx)
              let ts_str = String::unsafe_substring(
                before_tz,
                start=ts_idx + 1,
                end=before_tz.length(),
              )
              author_time = @strconv.parse_int64(ts_str) catch { _ => 0L }
            }
            None => author = rest
          }
        }
        None => author = rest
      }
    }
  }
  match tree_id {
    Some(tree) => (tree, parents, author, author_time, message.to_string())
    None => raise @git.GitError::InvalidObject("Missing tree in commit")
  }
}

///|
/// Find commits between base and target that modify the subdirectory
fn find_subdir_commits(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  base_hex : String,
  target_hex : String,
  subdir_path : String,
) -> Array[SubdirCommitInfo] raise @git.GitError {
  let result : Array[SubdirCommitInfo] = []
  // Walk from target back to base, collecting commits that change subdir
  let base_id = @git.ObjectId::from_hex(base_hex) catch {
    _ => raise @git.GitError::InvalidObject("Invalid base commit: " + base_hex)
  }
  let target_id = @git.ObjectId::from_hex(target_hex) catch {
    _ =>
      raise @git.GitError::InvalidObject("Invalid target commit: " + target_hex)
  }
  // Get base subdir tree for comparison
  let base_subdir_tree = get_subdir_tree(db, fs, base_id, subdir_path) catch {
    err => raise err
  }
  // Walk commits from target towards base
  let mut current_id = target_id
  let mut prev_subdir_tree = base_subdir_tree
  let commits_to_check : Array[@git.ObjectId] = []
  // First, collect all commits from target to base
  let visited : Map[String, Bool] = {}
  while true {
    let hex = current_id.to_hex()
    if visited.contains(hex) || hex == base_hex {
      break
    }
    visited[hex] = true
    commits_to_check.push(current_id)
    // Get commit and move to parent
    let commit_obj = db.get(fs, current_id)
    guard commit_obj is Some(obj) else { break }
    let commit_info = @git.parse_commit(obj.data) catch { err => raise err }
    if commit_info.parents.length() == 0 {
      break
    }
    current_id = commit_info.parents[0]
  }
  // Now process in reverse order (oldest first)
  let mut i = commits_to_check.length() - 1
  while i >= 0 {
    let commit_id = commits_to_check[i]
    let commit_obj = db.get(fs, commit_id)
    guard commit_obj is Some(obj) else {
      i -= 1
      continue
    }
    let (tree, _parents, author, author_time, message) = parse_full_commit(
      obj.data,
    ) catch { err => raise err }
    // Get subdir tree for this commit
    let current_subdir_tree = get_subdir_tree(
      db, fs, commit_id, subdir_path,
    ) catch { _ => { i -= 1; continue } }
    // Check if subdir changed from previous
    match (prev_subdir_tree, current_subdir_tree) {
      (Some(prev), Some(curr)) =>
        if prev.to_hex() != curr.to_hex() {
          // Subdir changed - include this commit
          result.push({
            id: commit_id,
            tree,
            subdir_tree: curr,
            message: message.trim(chars=" \n\t").to_string(),
            author,
            timestamp: author_time,
          })
          prev_subdir_tree = Some(curr)
        }
      (None, Some(curr)) => {
        // Subdir was added
        result.push({
          id: commit_id,
          tree,
          subdir_tree: curr,
          message: message.trim(chars=" \n\t").to_string(),
          author,
          timestamp: author_time,
        })
        prev_subdir_tree = Some(curr)
      }
      _ => ()
    }
    i -= 1
  }
  result
}

///|
/// Get the tree ID for a subdirectory within a commit
fn get_subdir_tree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId? raise @git.GitError {
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(obj) else {
    return None
  }
  let commit_info = @git.parse_commit(obj.data) catch { err => raise err }
  find_subtree_clone(db, fs, commit_info.tree, subdir_path) catch {
    err => raise err
  }
}

///|
/// Apply a commit's subdirectory changes to the worktree
fn apply_subdir_commit(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  worktree : String,
  git_dir : String,
  commit_info : SubdirCommitInfo,
  _subdir_path : String,
) -> Unit raise @git.GitError {
  // Write the new subdirectory tree to worktree
  // First, clear existing files (keep .git)
  let entries = fs.readdir(worktree) catch { _ => [] }
  for entry in entries {
    if entry == ".git" {
      continue
    }
    let path = worktree + "/" + entry
    if fs.is_dir(path) {
      subdir_remove_dir_recursive(fs, path)
    } else {
      fs.remove_file(path) catch { _ => () }
    }
  }
  // Write new tree contents
  write_tree_to_worktree_clone(db, fs, commit_info.subdir_tree, worktree) catch {
    err => raise err
  }
  // Create a commit with the new state
  let timestamp = get_current_timestamp()
  let author = commit_info.author
  let message = commit_info.message + "\n\n(rebased from " +
    commit_info.id.to_hex() +
    ")\n"
  // Read current HEAD
  let head_content = fs.read_file(git_dir + "/HEAD") catch {
    _ => raise @git.GitError::IoError("Failed to read HEAD")
  }
  let head_text = bytes_to_string_handler(head_content).trim(chars=" \n\t").to_string()
  let parent_id = if head_text.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(head_text, start=5, end=head_text.length())
    let ref_path = git_dir + "/" + ref_name
    let ref_content = fs.read_file(ref_path) catch {
      _ => raise @git.GitError::IoError("Failed to read ref")
    }
    let ref_hex = bytes_to_string_handler(ref_content).trim(chars=" \n\t").to_string()
    @git.ObjectId::from_hex(ref_hex) catch {
      _ => raise @git.GitError::InvalidObject("Invalid ref")
    }
  } else {
    @git.ObjectId::from_hex(head_text) catch {
      _ => raise @git.GitError::InvalidObject("Invalid HEAD")
    }
  }
  // Create new commit
  let parents : Array[@git.ObjectId] = [parent_id]
  let commit = @git.Commit::new(
    commit_info.subdir_tree,
    parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (new_commit_id, commit_bytes) = @git.create_commit(commit)
  @gitlib.write_object_bytes(fs, git_dir, new_commit_id, commit_bytes) catch {
    _ => raise @git.GitError::IoError("Failed to write commit")
  }
  // Update HEAD
  let ref_path = git_dir + "/refs/heads/main"
  fs.write_file(ref_path, string_to_bytes_subdir(new_commit_id.to_hex() + "\n")) catch {
    _ => ()
  }
  // Clear index to force re-sync on next git command
  let index_path = git_dir + "/index"
  fs.remove_file(index_path) catch { _ => () }
}

///|
/// Update subdir-clone-info with new base commit
fn update_subdir_clone_info(
  fs : OsFs,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  new_commit_hex : String,
) -> Unit {
  let info = StringBuilder::new()
  info.write_string("remote=")
  info.write_string(remote_url)
  info.write_string("\n")
  info.write_string("path=")
  info.write_string(subdir_path)
  info.write_string("\n")
  info.write_string("commit=")
  info.write_string(new_commit_hex)
  info.write_string("\n")
  let info_path = git_dir + "/subdir-clone-info"
  fs.write_file(info_path, string_to_bytes_subdir(info.to_string())) catch {
    _ => ()
  }
}

///|
async fn handle_subdir_show(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir show <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ワーキングディレクトリの変更を読み込む
  subdir.load_workdir(fs, root)
  print_line("Subdirectory: " + subdir.path())
  match subdir.base_commit() {
    Some(id) => print_line("Base commit: " + id.to_hex())
    None => print_line("Base commit: (none)")
  }
  match subdir.tree_id() {
    Some(id) => print_line("Tree ID: " + id.to_hex())
    None => print_line("Tree ID: (none)")
  }
  print_line("Dirty: " + subdir.is_dirty().to_string())
}

///|
async fn handle_subdir_log(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir log <path> [--max-count=N]")
    return
  }
  let subdir_path = args[0]
  let mut max_count = 20
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("--max-count=") {
      max_count = parse_int_simple(subdir_skip_prefix(arg, 12))
    } else if arg == "-n" && i + 1 < args.length() {
      i += 1
      max_count = parse_int_simple(args[i])
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // 履歴を取得
  let history = subdir.log(fs, max_count~) catch {
    err => raise @git.GitError::IoError("Failed to get log: " + err.to_string())
  }
  if history.length() == 0 {
    print_line("No commits found that affected " + subdir_path)
    return
  }
  print_line("Commits affecting " + subdir_path + ":")
  print_line("")
  for commit in history {
    let _short_id = subdir_short_hex(commit.id.to_hex())
    print_line("commit " + commit.id.to_hex())
    if commit.author != "" {
      print_line("Author: " + commit.author)
    }
    if commit.timestamp > 0L {
      print_line("Date:   " + format_timestamp_simple(commit.timestamp))
    }
    print_line("")
    if commit.message != "" {
      print_line("    " + commit.message)
    }
    print_line("")
  }
}

///|
async fn handle_subdir_diff(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir diff <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ワーキングディレクトリの変更を読み込む
  subdir.load_workdir(fs, root)
  let diff = subdir.diff()
  if diff.length() == 0 {
    print_line("No changes in " + subdir_path)
    return
  }
  print_line("Changes in " + subdir_path + ":")
  for entry in diff {
    print_line(entry.to_string())
  }
}

///|
async fn handle_subdir_extract(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line("Usage: moongit subdir extract <path> <target>")
    return
  }
  let subdir_path = args[0]
  let target_dir = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ターゲットディレクトリを作成
  fs.mkdir_p(target_dir) catch {
    _ => ()
  }
  // ファイルを展開
  let gitfs = subdir.fs()
  let files = gitfs.readdir(fs, "/") catch {
    _ => raise @git.GitError::IoError("Failed to read subdirectory")
  }
  let mut count = 0
  for file in files {
    extract_file_recursive(fs, gitfs, "/", file, target_dir) catch {
      e => raise e
    }
    count += 1
  }
  print_line("Extracted " + count.to_string() + " items to " + target_dir)
}

///|
async fn extract_file_recursive(
  fs : OsFs,
  gitfs : @gitfs.GitFs,
  base_path : String,
  name : String,
  target_dir : String,
) -> Unit raise Error {
  let path = if base_path == "/" { "/" + name } else { base_path + "/" + name }
  if gitfs.is_dir(fs, path) {
    // ディレクトリの場合は再帰
    let subdir_target = target_dir + "/" + name
    fs.mkdir_p(subdir_target) catch {
      _ => ()
    }
    let children = gitfs.readdir(fs, path) catch { _ => return () }
    for child in children {
      extract_file_recursive(fs, gitfs, path, child, subdir_target) catch {
        e => raise e
      }
    }
  } else if gitfs.is_file(fs, path) {
    // ファイルの場合は内容を書き出し
    let content = gitfs.read_file(fs, path) catch { _ => return () }
    let target_path = target_dir + "/" + name
    fs.write_file(target_path, content) catch {
      _ => ()
    }
  }
}

///|
/// 文字列の先頭 n 文字をスキップ
fn subdir_skip_prefix(s : String, n : Int) -> String {
  let chars = s.to_array()
  if n >= chars.length() {
    return ""
  }
  let result = StringBuilder::new()
  for i = n; i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// 簡易的な整数パース
fn parse_int_simple(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - 48)
    }
  }
  result
}

///|
/// SHA の短縮表示
fn subdir_short_hex(hex : String) -> String {
  let chars = hex.to_array()
  let result = StringBuilder::new()
  for i = 0; i < 7 && i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// タイムスタンプのフォーマット
fn format_timestamp_simple(timestamp : Int64) -> String {
  // Unix タイムスタンプを簡易的に表示
  timestamp.to_string()
}

///|
/// Clone a subdirectory from remote repository
///
/// Usage: moongit subdir clone <url> <remote-path> [<dest>]
///
/// Creates a new directory with:
///   - Contents of <remote-path> directly in <dest>/
///   - <dest>/.git for independent git management
///
/// Example:
///   moongit subdir clone https://github.com/user/repo src/lib mylib
///   → mylib/ contains contents of repo's src/lib/
///   → mylib/.git exists, git commands work from mylib/
async fn handle_subdir_clone(args : Array[String]) -> Unit raise Error {
  let mut url : String? = None
  let mut subdir : String? = None
  let mut dest : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("-") {
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if subdir is None {
      subdir = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    print_line("Usage: moongit subdir clone <url> <remote-path> [<dest>]")
    print_line("")
    print_line("Clone only a subdirectory from a remote repository.")
    print_line("The subdirectory becomes an independent git repository.")
    print_line("")
    print_line("  <url>         Remote repository URL")
    print_line("  <remote-path> Path within the remote repo (e.g., src/lib)")
    print_line("  <dest>        Local directory name (default: last component of path)")
    print_line("")
    print_line("Examples:")
    print_line("  moongit subdir clone https://github.com/user/repo src")
    print_line("    → Creates src/ with contents of repo's src/")
    print_line("")
    print_line("  moongit subdir clone https://github.com/user/repo src/lib mylib")
    print_line("    → Creates mylib/ with contents of repo's src/lib/")
    print_line("")
    print_line("After cloning, standard git commands work from the directory:")
    print_line("  cd mylib && git status")
    return
  }
  guard subdir is Some(subdir_path) else {
    raise @git.GitError::InvalidObject("subdirectory path required")
  }
  // Derive destination from subdir or explicit dest
  let relative_target = match dest {
    Some(d) => d
    None => {
      // Use last component of subdir path
      match subdir_path.rev_find("/") {
        Some(idx) =>
          String::unsafe_substring(subdir_path, start=idx + 1, end=subdir_path.length())
        None => subdir_path
      }
    }
  }
  let root = get_work_root()
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  let git_dir = target + "/.git"
  print_line(
    "Cloning '\{subdir_path}' from '\{remote_url}' into '\{relative_target}'...",
  )
  let fs = OsFs::new()
  // Step 1: Create target directory and initialize git repo
  fs.mkdir_p(target) catch {
    _ => raise @git.GitError::IoError("Failed to create directory: " + target)
  }
  // Step 2: Clone with blob:none filter to a temp location
  print_line("  Fetching repository metadata...")
  let temp_clone = target + "/.git-temp"
  let refs = @git.clone_http_to_fs(
    remote_url,
    true,
    fs,
    temp_clone,
    filter=@git.FilterSpec::BlobNone,
  )
  if refs.length() == 0 {
    raise @git.GitError::InvalidObject("Clone failed: no refs found")
  }
  // Step 3: Move .git to target location
  let temp_git_dir = temp_clone + "/.git"
  // Read HEAD commit from temp
  let head_ref = fs.read_file(temp_git_dir + "/HEAD") catch {
    _ => raise @git.GitError::IoError("Failed to read HEAD")
  }
  let head_text = @utf8.decode_lossy(head_ref[:]).trim(chars=" \n\r\t").to_string()
  let commit_id = if head_text.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(head_text, start=5, end=head_text.length())
    let ref_path = temp_git_dir + "/" + ref_name
    let ref_content = fs.read_file(ref_path) catch {
      _ => raise @git.GitError::IoError("Failed to read ref: " + ref_name)
    }
    let ref_text = @utf8.decode_lossy(ref_content[:]).trim(chars=" \n\r\t").to_string()
    @git.ObjectId::from_hex(ref_text) catch {
      _ => raise @git.GitError::InvalidObject("Invalid commit ID in ref")
    }
  } else {
    @git.ObjectId::from_hex(head_text) catch {
      _ => raise @git.GitError::InvalidObject("Invalid HEAD")
    }
  }
  // Load object database and get tree
  let db = @gitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(obj) else {
    raise @git.GitError::InvalidObject("Commit not found")
  }
  let commit_info = @git.parse_commit(obj.data)
  // Navigate to subdirectory tree
  print_line("  Finding subdirectory '\{subdir_path}'...")
  let subdir_tree_id = find_subtree_clone(db, fs, commit_info.tree, subdir_path)
  guard subdir_tree_id is Some(tree_id) else {
    // Cleanup temp
    remove_dir_recursive(fs, temp_clone)
    raise @git.GitError::InvalidObject(
      "Subdirectory not found: " + subdir_path,
    )
  }
  // Fetch blobs for the subdirectory (on-demand fetch)
  print_line("  Fetching files...")
  let needed_blobs = collect_tree_blobs_clone(db, fs, tree_id)
  if needed_blobs.length() > 0 {
    // Fetch missing blobs from remote
    let missing : Array[@git.ObjectId] = []
    for blob_id in needed_blobs {
      let exists = db.get(fs, blob_id)
      if exists is None {
        missing.push(blob_id)
      }
    }
    if missing.length() > 0 {
      let pack = @git.fetch_pack_http(remote_url, missing, true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, temp_git_dir, pack, objects)
    }
  }
  // Reload object database to include newly fetched blobs
  let db2 = @gitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  // Step 4: Write files directly to target (not target/subdir_path)
  print_line("  Writing files...")
  write_tree_to_worktree_clone(db2, fs, tree_id, target)
  // Step 5: Move .git to target and set up for subdirectory-only management
  print_line("  Setting up git repository...")
  // Move temp/.git to target/.git
  move_git_directory(fs, temp_git_dir, git_dir)
  // Clean up temp directory
  remove_dir_recursive(fs, temp_clone)
  // Step 6: Create a new orphan commit with subdirectory as root tree
  // This makes HEAD, index, and worktree all consistent
  print_line("  Creating initial commit...")
  let timestamp = get_current_timestamp()
  let author = "subdir-clone <subdir-clone@moongit>"
  let message = "Initial commit (cloned from " + subdir_path + ")\n"
  // Create commit: new(tree, parents, author, author_time, author_tz, committer, commit_time, committer_tz, message)
  let parents : Array[@git.ObjectId] = []
  let commit = @git.Commit::new(
    tree_id,
    parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  // Create commit object and write to object database
  let (new_commit_id, commit_bytes) = @git.create_commit(commit)
  @gitlib.write_object_bytes(fs, git_dir, new_commit_id, commit_bytes) catch {
    _ => raise @git.GitError::IoError("Failed to write commit object")
  }
  // Update HEAD to point to new commit on main branch
  let head_path = git_dir + "/HEAD"
  fs.write_file(head_path, string_to_bytes_subdir("ref: refs/heads/main\n")) catch { _ => () }
  let ref_path = git_dir + "/refs/heads/main"
  fs.mkdir_p(git_dir + "/refs/heads") catch { _ => () }
  fs.write_file(ref_path, string_to_bytes_subdir(new_commit_id.to_hex() + "\n")) catch { _ => () }
  // Step 7: Reset index to match the new HEAD
  // Using git reset is more reliable than writing index manually
  let _ = @process.run("git", ["-C", target, "reset", "HEAD"])
  // Step 8: Store metadata about the original repo and subdir
  save_subdir_clone_metadata(fs, git_dir, remote_url, subdir_path, commit_id)
  print_line("done.")
  print_line("")
  print_line("Cloned '\{subdir_path}' to '\{relative_target}/'")
  print_line("")
  print_line("The directory is a standalone git repository:")
  print_line("  cd \{relative_target}")
  print_line("  git status    # shows changes in this directory")
  print_line("  git log       # shows commit history")
  print_line("  git add/commit/push  # manage independently")
  print_line("")
  print_line("To sync with upstream:")
  print_line("  moongit subdir pull \{relative_target}")
}

///|
/// Move git directory from source to destination
fn move_git_directory(fs : OsFs, src : String, dst : String) -> Unit {
  // Create destination directory
  fs.mkdir_p(dst) catch { _ => () }
  // Copy all contents
  let entries = fs.readdir(src) catch { _ => return () }
  for entry in entries {
    let src_path = src + "/" + entry
    let dst_path = dst + "/" + entry
    if fs.is_dir(src_path) {
      move_git_directory(fs, src_path, dst_path)
    } else {
      let content = fs.read_file(src_path) catch { _ => continue }
      fs.write_file(dst_path, content) catch { _ => () }
    }
  }
}

///|
/// Save metadata about the subdir clone origin
fn save_subdir_clone_metadata(
  fs : OsFs,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  commit_id : @git.ObjectId,
) -> Unit {
  // Store in .git/subdir-clone-info
  let info = StringBuilder::new()
  info.write_string("remote=")
  info.write_string(remote_url)
  info.write_string("\n")
  info.write_string("path=")
  info.write_string(subdir_path)
  info.write_string("\n")
  info.write_string("commit=")
  info.write_string(commit_id.to_hex())
  info.write_string("\n")
  let info_path = git_dir + "/subdir-clone-info"
  fs.write_file(info_path, string_to_bytes_subdir(info.to_string())) catch { _ => () }
}

///|
/// Find a subtree by path (for subdir clone)
fn find_subtree_clone(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? raise @git.GitError {
  let parts : Array[String] = []
  for p in path.split("/") {
    let s = p.to_string()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  let mut current = tree_id
  for part in parts {
    let obj = db.get(rfs, current)
    guard obj is Some(tree_obj) else {
      return None
    }
    let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        current = entry.id
        found = true
        break
      }
    }
    if not(found) {
      return None
    }
  }
  Some(current)
}

///|
/// Collect all blob IDs from a tree (for subdir clone)
fn collect_tree_blobs_clone(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let blobs : Array[@git.ObjectId] = []
  let obj = db.get(rfs, tree_id)
  guard obj is Some(tree_obj) else {
    return blobs
  }
  let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
  for entry in entries {
    if entry.mode == "40000" || entry.mode == "040000" {
      // Directory - recurse
      let sub_blobs = collect_tree_blobs_clone(db, rfs, entry.id) catch {
        err => raise err
      }
      for b in sub_blobs {
        blobs.push(b)
      }
    } else {
      // File - add blob
      blobs.push(entry.id)
    }
  }
  blobs
}

///|
/// Write tree contents to worktree directory (for subdir clone)
fn write_tree_to_worktree_clone(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  dir : String,
) -> Unit raise @git.GitError {
  let obj = db.get(fs, tree_id)
  guard obj is Some(tree_obj) else {
    return
  }
  let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
  for entry in entries {
    let path = dir + "/" + entry.name
    if entry.mode == "40000" || entry.mode == "040000" {
      // Directory
      fs.mkdir_p(path) catch { _ => () }
      write_tree_to_worktree_clone(db, fs, entry.id, path) catch {
        err => raise err
      }
    } else {
      // File
      let blob_obj = db.get(fs, entry.id)
      guard blob_obj is Some(blob) else {
        continue
      }
      fs.write_file(path, blob.data) catch { _ => () }
    }
  }
}

///|
async fn handle_subdir_init(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir init <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // サブディレクトリが存在するか確認
  let subdir_abs = root + "/" + subdir_path
  if not(fs.is_dir(subdir_abs)) {
    print_line("Error: subdirectory does not exist: " + subdir_path)
    return
  }
  // 既に初期化済みか確認
  if @subdir.is_module_initialized(fs, git_dir, subdir_path) {
    print_line("Subdirectory already initialized: " + subdir_path)
    return
  }
  // git modules 構造で初期化
  @subdir.init_module(fs, fs, git_dir, root, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to init: " + err.to_string())
  }
  // pre-commit hook に実行権限を付与
  let hook_path = git_dir + "/hooks/pre-commit"
  if fs.is_file(hook_path) {
    let _ = @process.run("chmod", ["+x", hook_path])

  }
  print_line("Initialized subdirectory as git module: " + subdir_path)
  print_line("")
  print_line("Structure created:")
  print_line("  .git/modules/" + subdir_path_to_safe_name(subdir_path) + "/")
  print_line("  " + subdir_path + "/.git (file)")
  print_line("")
  print_line(
    "You can now use standard git commands from within the subdirectory:",
  )
  print_line("  cd " + subdir_path)
  print_line("  git status    # shows only subdirectory changes")
  print_line("  git log       # shows commits affecting subdirectory")
  print_line("  git add/commit  # commits to parent repository")
}

///|
async fn handle_subdir_deinit(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir deinit <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールとして初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line("Subdirectory is not initialized: " + subdir_path)
    return
  }
  // モジュール構造を削除
  @subdir.deinit_module(fs, fs, git_dir, root, subdir_path)
  print_line("Deinitialized subdirectory: " + subdir_path)
  print_line(
    "Removed .git/modules/" + subdir_path_to_safe_name(subdir_path) + "/",
  )
}

///|
async fn handle_subdir_shell(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir shell <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let subdir_abs = root + "/" + subdir_path
  // サブディレクトリが存在するか確認
  if not(fs.is_dir(subdir_abs)) {
    print_line("Error: subdirectory does not exist: " + subdir_path)
    return
  }
  // 環境変数を取得
  let env_vars = @subdir.generate_shell_env(git_dir, root, subdir_path)
  // RC スクリプトを生成
  let rc_script = @subdir.generate_shell_rc(subdir_path)
  // 一時ファイルに RC を書き込み
  let rc_path = "/tmp/moongit-subdir-rc-" + subdir_path_to_id(subdir_path)
  fs.write_file(rc_path, string_to_bytes_subdir(rc_script)) catch {
    _ => ()
  }
  // シェルを起動
  print_line("Starting subdir shell for: " + subdir_path)
  print_line("git commands will be scoped to this directory.")
  print_line("")
  // 環境変数を設定してシェルを起動
  let shell = get_user_shell()
  let shell_args = build_shell_args(shell, rc_path)
  // 環境変数を設定
  for pair in env_vars {
    @sys.set_env_var(pair.0, pair.1)
  }
  // シェルプロセスを起動（サブディレクトリで）
  // カレントディレクトリを変更してシェルを起動
  @sys.set_env_var("MOONGIT_SUBDIR_RC", rc_path)
  let exit_code = @process.run(shell, shell_args)
  if exit_code != 0 {
    print_line("Shell exited with code: " + exit_code.to_string())
  }
  // 一時ファイルを削除
  fs.remove_file(rc_path) catch {
    _ => ()
  }
  print_line("Exited subdir shell.")
}

///|
fn get_user_shell() -> String {
  match @sys.get_env_var("SHELL") {
    Some(s) => s
    None => "/bin/sh"
  }
}

///|
fn build_shell_args(shell : String, rc_path : String) -> Array[String] {
  // bash/zsh の場合は --rcfile を使用
  if shell.has_suffix("bash") {
    ["--rcfile", rc_path]
  } else if shell.has_suffix("zsh") {
    // zsh は ZDOTDIR を使うのが標準だが、簡易的に -i で対応
    ["-i"]
  } else {
    []
  }
}

///|
fn subdir_path_to_id(path : String) -> String {
  let result = StringBuilder::new()
  for c in path {
    if c == '/' {
      result.write_char('-')
    } else if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') {
      result.write_char(c)
    }
  }
  result.to_string()
}

///|
fn string_to_bytes_subdir(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
async fn handle_subdir_commit(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line(
      "Usage: moongit subdir commit <path> [-m <message>] [--author <author>]",
    )
    return
  }
  let subdir_path = args[0]
  let mut message = ""
  let mut author = "author <author@example.com>"
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "-m" && i + 1 < args.length() {
      i += 1
      message = args[i]
    } else if arg == "--author" && i + 1 < args.length() {
      i += 1
      author = args[i]
    } else if arg.has_prefix("-m") {
      message = subdir_skip_prefix(arg, 2)
    }
    i += 1
  }
  if message == "" {
    print_line("Error: commit message required (-m)")
    return
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ワーキングディレクトリの変更を読み込む
  subdir.load_workdir(fs, root)
  // 変更があるか確認
  if not(subdir.is_dirty()) {
    print_line("Nothing to commit in " + subdir_path)
    return
  }
  // コミット
  let timestamp = get_current_timestamp()
  let commit_id = subdir.commit(fs, fs, message, author~, timestamp~) catch {
    err => raise @git.GitError::IoError("Failed to commit: " + err.to_string())
  }
  print_line("Committed subdirectory changes: " + commit_id.to_hex())
  print_line("  Path: " + subdir_path)
  print_line("  Message: " + message)
}

///|
async fn handle_subdir_checkout(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line("Usage: moongit subdir checkout <path> <commit>")
    return
  }
  let subdir_path = args[0]
  let commit_ref = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // コミットIDを解決
  let commit_id = resolve_commit_ref(fs, git_dir, commit_ref) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to resolve commit: " + err.to_string(),
      )
  }
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_commit(
    fs, git_dir, commit_id, subdir_path,
  ) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // サブディレクトリの絶対パス
  let subdir_abs = root + "/" + subdir_path
  // ワークツリーに展開
  let gitfs = subdir.fs()
  let files = gitfs.readdir(fs, "/") catch {
    _ => raise @git.GitError::IoError("Failed to read subdirectory")
  }
  // 既存のファイルを削除（.gitsubdir と git-subdir は保持）
  clear_subdir_worktree(fs, subdir_abs)
  // ファイルを展開
  let mut count = 0
  for file in files {
    extract_file_recursive(fs, gitfs, "/", file, subdir_abs) catch {
      e => raise e
    }
    count += 1
  }
  print_line("Checked out " + subdir_path + " at " + commit_ref)
  print_line("  Commit: " + commit_id.to_hex())
  print_line("  Files: " + count.to_string() + " items")
}

///|
async fn handle_subdir_push(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line(
      "Usage: moongit subdir push <path> [<remote-url>] [--branch <branch>]",
    )
    print_line("")
    print_line("Push subdirectory to a remote repository.")
    print_line("If remote-url is not specified, uses configured remote.")
    return
  }
  let subdir_path = args[0]
  let mut remote_url : String? = None
  let mut branch = "main"
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--branch" && i + 1 < args.length() {
      i += 1
      branch = args[i]
    } else if not(arg.has_prefix("-")) && remote_url is None {
      remote_url = Some(arg)
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // リモートURLを取得または設定ファイルから読み込み
  let url = match remote_url {
    Some(u) => u
    None => {
      // 設定ファイルからリモートを読み込み
      let config_remote = get_subdir_remote(fs, git_dir, subdir_path)
      match config_remote {
        Some(u) => u
        None => {
          print_line("Error: No remote URL specified and no remote configured.")
          print_line(
            "Use: moongit subdir push " + subdir_path + " <remote-url>",
          )
          return
        }
      }
    }
  }
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // サブディレクトリのコミット履歴を取得
  let history = subdir.log(fs, max_count=1) catch {
    _ => raise @git.GitError::IoError("Failed to get history")
  }
  if history.length() == 0 {
    print_line("No commits in subdirectory")
    return
  }
  let latest = history[0]
  print_line("Pushing " + subdir_path + " to " + url)
  print_line("  Branch: " + branch)
  print_line("  Commit: " + latest.id.to_hex())
  // git push を実行（real git を使用）
  let push_result = @process.run("git", [
    "push",
    url,
    "HEAD:" + branch,
    "--force",
  ])
  if push_result != 0 {
    print_line(
      "Warning: git push may have failed (exit code: " +
      push_result.to_string() +
      ")",
    )
  } else {
    print_line("Push completed.")
    // リモートURLを設定に保存
    save_subdir_remote(fs, git_dir, subdir_path, url)
  }
}

///|
async fn handle_subdir_pull(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line(
      "Usage: moongit subdir pull <path> [<remote-url>] [--branch <branch>]",
    )
    print_line("")
    print_line("Pull subdirectory from a remote repository.")
    print_line("If remote-url is not specified, uses configured remote.")
    return
  }
  let subdir_path = args[0]
  let mut remote_url : String? = None
  let mut branch = "main"
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--branch" && i + 1 < args.length() {
      i += 1
      branch = args[i]
    } else if not(arg.has_prefix("-")) && remote_url is None {
      remote_url = Some(arg)
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // リモートURLを取得
  let url = match remote_url {
    Some(u) => u
    None => {
      let config_remote = get_subdir_remote(fs, git_dir, subdir_path)
      match config_remote {
        Some(u) => u
        None => {
          print_line("Error: No remote URL specified and no remote configured.")
          print_line(
            "Use: moongit subdir pull " + subdir_path + " <remote-url>",
          )
          return
        }
      }
    }
  }
  print_line("Pulling " + subdir_path + " from " + url)
  print_line("  Branch: " + branch)
  // 一時ディレクトリにクローン
  let temp_dir = "/tmp/moongit-subdir-pull-" + subdir_path_to_id(subdir_path)
  fs.mkdir_p(temp_dir) catch {
    _ => ()
  }
  // git clone
  let clone_result = @process.run("git", [
    "clone", "--depth=1", "--branch", branch, url, temp_dir,
  ])
  if clone_result != 0 {
    print_line("Error: Failed to clone from " + url)
    return
  }
  // サブディレクトリにコピー
  let subdir_abs = root + "/" + subdir_path
  // 既存ファイルをクリア
  clear_subdir_worktree(fs, subdir_abs)
  // ファイルをコピー（.git を除く）
  copy_dir_recursive(fs, temp_dir, subdir_abs) catch {
    e => raise e
  }
  // 一時ディレクトリを削除
  remove_dir_recursive(fs, temp_dir)
  print_line("Pull completed.")
  // リモートURLを設定に保存
  save_subdir_remote(fs, git_dir, subdir_path, url)
}

///|
fn resolve_commit_ref(
  fs : OsFs,
  git_dir : String,
  ref_str : String,
) -> @git.ObjectId raise @git.GitError {
  // まず HEAD かブランチ名として解決を試みる
  if ref_str == "HEAD" {
    let head_id = @gitlib.resolve_head_commit(fs, git_dir) catch {
      _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
    }
    return match head_id {
      Some(id) => id
      None => raise @git.GitError::InvalidObject("HEAD not found")
    }
  }
  // ブランチとして試す
  let ref_path = git_dir + "/refs/heads/" + ref_str
  if fs.is_file(ref_path) {
    let content = fs.read_file(ref_path) catch {
      _ => raise @git.GitError::InvalidObject("Cannot read ref")
    }
    let hex = bytes_to_string_handler(content).trim(chars=" \n\t").to_string()
    return @git.ObjectId::from_hex(hex) catch {
      _ => raise @git.GitError::InvalidObject("Invalid ref content")
    }
  }
  // 直接SHA-1として解釈
  @git.ObjectId::from_hex(ref_str) catch {
    _ =>
      raise @git.GitError::InvalidObject("Invalid commit reference: " + ref_str)
  }
}

///|
fn clear_subdir_worktree(fs : OsFs, subdir_abs : String) -> Unit {
  // ディレクトリ内のファイルを削除（.gitsubdir と git-subdir は保持）
  let entries = fs.readdir(subdir_abs) catch { _ => return () }
  for entry in entries {
    if entry == ".gitsubdir" || entry == "git-subdir" {
      continue
    }
    let path = subdir_abs + "/" + entry
    if fs.is_dir(path) {
      subdir_remove_dir_recursive(fs, path)
    } else {
      fs.remove_file(path) catch {
        _ => ()
      }
    }
  }
}

///|
fn subdir_remove_dir_recursive(fs : OsFs, path : String) -> Unit {
  let entries = fs.readdir(path) catch { _ => return () }
  for entry in entries {
    let child_path = path + "/" + entry
    if fs.is_dir(child_path) {
      subdir_remove_dir_recursive(fs, child_path)
    } else {
      fs.remove_file(child_path) catch {
        _ => ()
      }
    }
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn copy_dir_recursive(
  fs : OsFs,
  src : String,
  dst : String,
) -> Unit raise Error {
  fs.mkdir_p(dst) catch {
    _ => ()
  }
  let entries = fs.readdir(src) catch { _ => return () }
  for entry in entries {
    // .git ディレクトリはスキップ
    if entry == ".git" {
      continue
    }
    let src_path = src + "/" + entry
    let dst_path = dst + "/" + entry
    if fs.is_dir(src_path) {
      copy_dir_recursive(fs, src_path, dst_path) catch {
        e => raise e
      }
    } else {
      let content = fs.read_file(src_path) catch { _ => continue }
      fs.write_file(dst_path, content) catch {
        _ => ()
      }
    }
  }
}

///|
fn get_subdir_remote(
  fs : OsFs,
  git_dir : String,
  subdir_path : String,
) -> String? {
  let safe_name = subdir_path_to_safe_name(subdir_path)
  let config_path = git_dir + "/subdir/" + safe_name + "/remote"
  let content = fs.read_file(config_path) catch { _ => return None }
  Some(bytes_to_string_handler(content).trim(chars=" \n\t").to_string())
}

///|
fn save_subdir_remote(
  fs : OsFs,
  git_dir : String,
  subdir_path : String,
  url : String,
) -> Unit {
  let safe_name = subdir_path_to_safe_name(subdir_path)
  let config_dir = git_dir + "/subdir/" + safe_name
  fs.mkdir_p(config_dir) catch {
    _ => ()
  }
  let config_path = config_dir + "/remote"
  fs.write_file(config_path, string_to_bytes_subdir(url)) catch {
    _ => ()
  }
}

///|
fn subdir_path_to_safe_name(path : String) -> String {
  let result = StringBuilder::new()
  for c in path {
    if c == '/' {
      result.write_char('_')
    } else {
      result.write_char(c)
    }
  }
  result.to_string()
}

///|
fn bytes_to_string_handler(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
async fn handle_subdir_list(_args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let modules = @subdir.list_modules(fs, git_dir)
  if modules.length() == 0 {
    print_line("No subdirectory modules initialized.")
    print_line("Use 'moongit subdir init <path>' to initialize a subdirectory.")
    return
  }
  print_line("Initialized subdirectory modules:")
  print_line("")
  for path in modules {
    print_line("  " + path)
  }
}

///|
async fn handle_subdir_sync(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sync <path>")
    print_line("       moongit subdir sync --all")
    return
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args[0] == "--all" {
    // 全モジュールを同期
    let modules = @subdir.list_modules(fs, git_dir)
    if modules.length() == 0 {
      print_line("No subdirectory modules to sync.")
      return
    }
    for path in modules {
      @subdir.sync_module(fs, fs, git_dir, path) catch {
        _ => ()
      }
      print_line("Synced: " + path)
    }
  } else {
    let subdir_path = args[0]
    if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
      print_line("Subdirectory is not initialized: " + subdir_path)
      return
    }
    @subdir.sync_module(fs, fs, git_dir, subdir_path) catch {
      err => raise @git.GitError::IoError("Failed to sync: " + err.to_string())
    }
    print_line("Synced: " + subdir_path)
  }
}

///|
/// sparse-checkout サブコマンドのハンドラ
async fn handle_subdir_sparse_checkout(
  args : Array[String],
) -> Unit raise Error {
  if args.length() < 1 {
    print_sparse_checkout_usage()
    return
  }
  let cmd = args[0]
  let rest = array_view_to_array(args[1:])
  match cmd {
    "init" => handle_sparse_init(rest) catch { e => raise e }
    "set" => handle_sparse_set(rest) catch { e => raise e }
    "add" => handle_sparse_add(rest) catch { e => raise e }
    "list" => handle_sparse_list(rest) catch { e => raise e }
    "disable" => handle_sparse_disable(rest) catch { e => raise e }
    _ => {
      print_line("Unknown sparse-checkout command: " + cmd)
      print_sparse_checkout_usage()
    }
  }
}

///|
async fn print_sparse_checkout_usage() -> Unit raise Error {
  print_line("Usage: moongit subdir sparse-checkout <command> [options]")
  print_line("")
  print_line("Commands:")
  print_line(
    "  init <path> [--cone]     Enable sparse checkout for subdirectory",
  )
  print_line(
    "  set <path> <patterns>    Set sparse checkout patterns (replaces existing)",
  )
  print_line("  add <path> <patterns>    Add patterns to sparse checkout")
  print_line("  list <path>              List current sparse checkout patterns")
  print_line("  disable <path>           Disable sparse checkout")
  print_line("")
  print_line("Patterns:")
  print_line("  *.mbt        Match files with .mbt extension")
  print_line("  src/         Include src directory and its contents")
  print_line("  !tests/      Exclude tests directory")
  print_line("  **/test*.mbt Match test files in any directory")
}

///|
async fn handle_sparse_init(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sparse-checkout init <path> [--cone]")
    return
  }
  let subdir_path = args[0]
  let mut cone = false
  for i = 1; i < args.length(); i = i + 1 {
    if args[i] == "--cone" {
      cone = true
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line(
      "Error: subdirectory not initialized. Run 'moongit subdir init " +
      subdir_path +
      "' first.",
    )
    return
  }
  // sparse checkout を初期化
  @subdir.init_module_sparse(fs, fs, git_dir, subdir_path, cone~) catch {
    err =>
      raise @git.GitError::IoError("Failed to init sparse: " + err.to_string())
  }
  print_line("Sparse checkout enabled for: " + subdir_path)
  if cone {
    print_line("  Mode: cone (directory-based)")
  } else {
    print_line("  Mode: pattern-based")
  }
  print_line("")
  print_line(
    "Use 'moongit subdir sparse-checkout set " +
    subdir_path +
    " <patterns>' to specify files.",
  )
}

///|
async fn handle_sparse_set(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line(
      "Usage: moongit subdir sparse-checkout set <path> <pattern1> [pattern2] ...",
    )
    return
  }
  let subdir_path = args[0]
  let patterns : Array[String] = []
  for i = 1; i < args.length(); i = i + 1 {
    patterns.push(args[i])
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line(
      "Error: subdirectory not initialized. Run 'moongit subdir init " +
      subdir_path +
      "' first.",
    )
    return
  }
  // パターンを設定
  @subdir.set_module_sparse_patterns(fs, fs, git_dir, subdir_path, patterns) catch {
    err =>
      raise @git.GitError::IoError("Failed to set patterns: " + err.to_string())
  }
  print_line("Sparse checkout patterns set for: " + subdir_path)
  print_line("")
  for p in patterns {
    print_line("  " + p)
  }
  print_line("")
  print_line(
    "Use 'moongit subdir checkout " + subdir_path + " HEAD' to apply patterns.",
  )
}

///|
async fn handle_sparse_add(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line(
      "Usage: moongit subdir sparse-checkout add <path> <pattern1> [pattern2] ...",
    )
    return
  }
  let subdir_path = args[0]
  let patterns : Array[String] = []
  for i = 1; i < args.length(); i = i + 1 {
    patterns.push(args[i])
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line(
      "Error: subdirectory not initialized. Run 'moongit subdir init " +
      subdir_path +
      "' first.",
    )
    return
  }
  // パターンを追加
  @subdir.add_module_sparse_patterns(fs, fs, git_dir, subdir_path, patterns) catch {
    err =>
      raise @git.GitError::IoError("Failed to add patterns: " + err.to_string())
  }
  print_line("Patterns added to sparse checkout for: " + subdir_path)
  // 現在のパターンを表示
  let all_patterns = @subdir.read_module_sparse_patterns(
    fs, git_dir, subdir_path,
  )
  print_line("")
  print_line("Current patterns:")
  for p in all_patterns {
    print_line("  " + p)
  }
}

///|
async fn handle_sparse_list(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sparse-checkout list <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line("Error: subdirectory not initialized.")
    return
  }
  // sparse checkout が有効かチェック
  if not(@subdir.is_module_sparse_enabled(fs, git_dir, subdir_path)) {
    print_line("Sparse checkout is not enabled for: " + subdir_path)
    print_line(
      "Use 'moongit subdir sparse-checkout init " + subdir_path + "' to enable.",
    )
    return
  }
  // パターンを表示
  let patterns = @subdir.read_module_sparse_patterns(
    fs, git_dir, subdir_path,
  )
  if patterns.length() == 0 {
    print_line("No sparse checkout patterns set for: " + subdir_path)
    return
  }
  print_line("Sparse checkout patterns for: " + subdir_path)
  print_line("")
  for p in patterns {
    print_line("  " + p)
  }
}

///|
async fn handle_sparse_disable(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sparse-checkout disable <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line("Error: subdirectory not initialized.")
    return
  }
  // sparse checkout を無効化
  @subdir.disable_module_sparse(fs, fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to disable sparse: " + err.to_string(),
      )
  }
  print_line("Sparse checkout disabled for: " + subdir_path)
  print_line("All files will now be checked out.")
}
