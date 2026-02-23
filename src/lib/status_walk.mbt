///| Index-guided worktree walk for status

///|
/// Directory index: maps directory relative path to sorted (index_position, filename) pairs.
priv struct DirIndex {
  dir_files : Map[String, Array[(Int, String)]]
  dir_has_descendants : Map[String, Bool]
}

///|
/// Build a directory index from sorted index entries.
/// Groups entries by their parent directory and records which directories
/// have descendants in the index (for guided pruning).
fn build_dir_index(
  entries : Array[IndexEntry],
  skip_worktree : Map[String, Bool],
) -> DirIndex {
  let dir_files : Map[String, Array[(Int, String)]] = {}
  let dir_has_descendants : Map[String, Bool] = {}
  for i, entry in entries {
    if skip_worktree.contains(entry.path) {
      continue
    }
    // Find last '/' to split directory and filename
    let path = entry.path
    let mut slash_pos = -1
    for j = path.length() - 1; j >= 0; j = j - 1 {
      if path.unsafe_get(j) == '/' {
        slash_pos = j
        break
      }
    }
    let (dir, filename) = if slash_pos < 0 {
      ("", path)
    } else {
      (
        String::unsafe_substring(path, start=0, end=slash_pos),
        String::unsafe_substring(path, start=slash_pos + 1, end=path.length()),
      )
    }
    // Add to dir_files
    match dir_files.get(dir) {
      Some(arr) => arr.push((i, filename))
      None => dir_files[dir] = [(i, filename)]
    }
    // Mark all ancestor directories as having descendants
    dir_has_descendants[dir] = true
    // Walk up ancestor chain
    let mut d = dir
    while d.length() > 0 {
      let mut parent_slash = -1
      for j = d.length() - 1; j >= 0; j = j - 1 {
        if d.unsafe_get(j) == '/' {
          parent_slash = j
          break
        }
      }
      let parent = if parent_slash < 0 {
        ""
      } else {
        String::unsafe_substring(d, start=0, end=parent_slash)
      }
      if dir_has_descendants.contains(parent) {
        break
      }
      dir_has_descendants[parent] = true
      d = parent
    }
  }
  { dir_files, dir_has_descendants }
}

///|
/// Perform index-guided status walk.
/// Returns (unstaged_modified, unstaged_deleted, untracked).
async fn index_guided_status_walk(
  fs : &@bit.RepoFileSystem,
  root : String,
  index_entries : Array[IndexEntry],
  skip_worktree : Map[String, Bool],
  autocrlf : AutoCrlf,
  racy_git : Bool,
) -> (Array[String], Array[String], Array[String]) raise @bit.GitError {
  let dir_index = build_dir_index(index_entries, skip_worktree)
  let visited = FixedArray::make(index_entries.length(), false)
  let unstaged_modified : Array[String] = []
  let unstaged_deleted : Array[String] = []
  let untracked : Array[String] = []
  let matcher = @ignore.Matcher::new()
  walk_dir_guided(
    fs, root, "", index_entries, dir_index, visited, matcher, autocrlf, racy_git,
    unstaged_modified, unstaged_deleted, untracked,
  )
  // Post-walk sweep: any unvisited, non-skip-worktree entries are deleted
  for i, entry in index_entries {
    if not(visited[i]) && not(skip_worktree.contains(entry.path)) {
      if not(is_gitlink_mode_int(entry.mode)) {
        unstaged_deleted.push(entry.path)
      }
    }
  }
  (unstaged_modified, unstaged_deleted, untracked)
}

///|
/// Recursive index-guided directory walk.
async fn walk_dir_guided(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  index_entries : Array[IndexEntry],
  dir_index : DirIndex,
  visited : FixedArray[Bool],
  matcher : @ignore.Matcher,
  autocrlf : AutoCrlf,
  racy_git : Bool,
  unstaged_modified : Array[String],
  unstaged_deleted : Array[String],
  untracked : Array[String],
) -> Unit raise @bit.GitError {
  let dir = if rel == "" { root } else { join_path(root, rel) }
  // Try readdir_typed; if directory doesn't exist, all index entries here
  // will be caught as deleted in post-walk sweep
  let typed_result = @bitio.readdir_typed(dir)
  let (disk_files, disk_dirs) = match typed_result {
    Some(typed_entries) =>
      classify_readdir_typed(fs, root, rel, dir, typed_entries)
    None => {
      // Try fallback readdir
      let entries = fs.readdir(dir) catch { _ => return }
      classify_readdir_fallback(fs, root, rel, entries)
    }
  }
  // Check for submodule markers
  if rel != "" {
    let mut has_git = false
    for entry in disk_files {
      if entry.0 == ".git" || entry.0 == ".bit" {
        has_git = true
        break
      }
    }
    if not(has_git) {
      for entry in disk_dirs {
        if entry == ".git" || entry == ".bit" {
          has_git = true
          break
        }
      }
    }
    if has_git {
      // Mark all index entries under this directory as visited (submodule)
      mark_subtree_visited(rel, dir_index, visited)
      return
    }
  }
  // Load .gitignore for this directory
  let prev_len = matcher.len()
  let gitignore_path = join_path(dir, ".gitignore")
  if fs.is_file(gitignore_path) {
    let content = @utf8.decode_lossy(fs.read_file(gitignore_path)[:])
    matcher.add_rules(rel, content)
  }
  // Get index files for this directory (already sorted by index order)
  let idx_files = match dir_index.dir_files.get(rel) {
    Some(arr) => arr
    None => []
  }
  // Sort disk files by name for two-pointer merge
  let sorted_disk = disk_files.copy()
  sorted_disk.sort_by(fn(a, b) { compare_strings_lexicographic(a.0, b.0) })
  // Sort index files by name
  let sorted_idx : Array[(Int, String)] = idx_files.copy()
  sorted_idx.sort_by(fn(a, b) { compare_strings_lexicographic(a.1, b.1) })
  // Two-pointer merge
  let mut di = 0
  let mut ii = 0
  while di < sorted_disk.length() || ii < sorted_idx.length() {
    if di < sorted_disk.length() && ii < sorted_idx.length() {
      let disk_name = sorted_disk[di].0
      let idx_name = sorted_idx[ii].1
      let cmp = compare_strings_lexicographic(disk_name, idx_name)
      if cmp == 0 {
        // File exists in both disk and index
        let idx_pos = sorted_idx[ii].0
        let entry = index_entries[idx_pos]
        visited[idx_pos] = true
        if not(is_gitlink_mode_int(entry.mode)) {
          check_file_against_index(
            fs,
            root,
            entry.path,
            entry,
            autocrlf,
            racy_git,
            unstaged_modified,
          )
        }
        di += 1
        ii += 1
      } else if cmp < 0 {
        // File on disk only (untracked candidate)
        let name = sorted_disk[di].0
        if name != ".git" &&
          name != ".bit" &&
          name != ".jj" &&
          name != ".gitignore" {
          let child_rel = if rel == "" { name } else { rel + "/" + name }
          if not(matcher.is_ignored(child_rel, false)) {
            untracked.push(child_rel)
          }
        }
        di += 1
      } else {
        // File in index only (deleted on disk)
        let idx_pos = sorted_idx[ii].0
        visited[idx_pos] = true
        // Will be caught as deleted in post-walk sweep
        // (visited=true but file missing → worktree_entry_meta returns None)
        // Actually, we should NOT mark visited here since the file is missing.
        // Let the post-walk sweep handle it. But we need to avoid double-counting.
        // Actually: mark visited and add to deleted directly here.
        let entry = index_entries[idx_pos]
        if not(is_gitlink_mode_int(entry.mode)) {
          unstaged_deleted.push(entry.path)
        }
        ii += 1
      }
    } else if di < sorted_disk.length() {
      // Remaining disk files (untracked)
      let name = sorted_disk[di].0
      if name != ".git" &&
        name != ".bit" &&
        name != ".jj" &&
        name != ".gitignore" {
        let child_rel = if rel == "" { name } else { rel + "/" + name }
        if not(matcher.is_ignored(child_rel, false)) {
          untracked.push(child_rel)
        }
      }
      di += 1
    } else {
      // Remaining index files (deleted)
      let idx_pos = sorted_idx[ii].0
      visited[idx_pos] = true
      let entry = index_entries[idx_pos]
      if not(is_gitlink_mode_int(entry.mode)) {
        unstaged_deleted.push(entry.path)
      }
      ii += 1
    }
  }
  // Process directories: sort and recurse
  let sorted_dirs = disk_dirs.copy()
  sorted_dirs.sort()
  for dir_name in sorted_dirs {
    if dir_name == ".git" || dir_name == ".bit" || dir_name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { dir_name } else { rel + "/" + dir_name }
    let has_descendants = dir_index.dir_has_descendants.contains(child_rel)
    let is_ignored = matcher.is_ignored(child_rel, true)
    if is_ignored {
      if has_descendants {
        // Must recurse to detect deleted entries
        walk_dir_guided(
          fs, root, child_rel, index_entries, dir_index, visited, matcher, autocrlf,
          racy_git, unstaged_modified, unstaged_deleted, untracked,
        )
      } else if matcher.could_negate_under(child_rel) {
        // A negation rule could un-ignore children under this directory
        walk_dir_guided(
          fs, root, child_rel, index_entries, dir_index, visited, matcher, autocrlf,
          racy_git, unstaged_modified, unstaged_deleted, untracked,
        )
      }
      // Otherwise: skip entirely (major speedup)
    } else {
      walk_dir_guided(
        fs, root, child_rel, index_entries, dir_index, visited, matcher, autocrlf,
        racy_git, unstaged_modified, unstaged_deleted, untracked,
      )
    }
  }
  matcher.truncate(prev_len)
}

///|
/// Classify readdir_typed results into (files, directories).
/// Files are returned as (name, d_type) for non-directory entries.
/// Symlinks pointing to directories are treated as files (not recursed into).
fn classify_readdir_typed(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  _dir : String,
  typed_entries : Array[(String, Int)],
) -> (Array[(String, Int)], Array[String]) {
  let files : Array[(String, Int)] = []
  let dirs : Array[String] = []
  for entry in typed_entries {
    let name = entry.0
    let d_type = entry.1
    if name == "." || name == ".." {
      continue
    }
    // d_type: 4=DT_DIR, 8=DT_REG, 10=DT_LNK, 0=DT_UNKNOWN
    if d_type == 4 {
      dirs.push(name)
    } else if d_type == 10 {
      // Symlink: check if it points to a directory
      let child_rel = if rel == "" { name } else { rel + "/" + name }
      let child_path = join_path(root, child_rel)
      if fs.is_dir(child_path) &&
        not(@bitio.read_symlink_target_path(child_path) is Some(_)) {
        dirs.push(name)
      } else {
        files.push((name, d_type))
      }
    } else if d_type == 0 {
      // DT_UNKNOWN: fall back to stat
      let child_rel = if rel == "" { name } else { rel + "/" + name }
      let child_path = join_path(root, child_rel)
      if fs.is_dir(child_path) {
        if not(@bitio.read_symlink_target_path(child_path) is Some(_)) {
          dirs.push(name)
        } else {
          files.push((name, d_type))
        }
      } else {
        files.push((name, d_type))
      }
    } else {
      files.push((name, d_type))
    }
  }
  (files, dirs)
}

///|
/// Classify readdir fallback results into (files, directories).
fn classify_readdir_fallback(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  entries : Array[String],
) -> (Array[(String, Int)], Array[String]) {
  let files : Array[(String, Int)] = []
  let dirs : Array[String] = []
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = join_path(root, child_rel)
    if fs.is_dir(child_path) {
      if not(@bitio.read_symlink_target_path(child_path) is Some(_)) {
        dirs.push(name)
      } else {
        files.push((name, 0))
      }
    } else {
      files.push((name, 0))
    }
  }
  (files, dirs)
}

///|
/// Mark all index entries under a directory subtree as visited.
fn mark_subtree_visited(
  rel : String,
  dir_index : DirIndex,
  visited : FixedArray[Bool],
) -> Unit {
  // Mark direct files
  match dir_index.dir_files.get(rel) {
    Some(arr) =>
      for item in arr {
        visited[item.0] = true
      }
    None => ()
  }
  // Mark files in subdirectories (need to scan all dirs with matching prefix)
  let prefix = rel + "/"
  for item in dir_index.dir_files.to_array() {
    let (dir, files) = item
    if dir.has_prefix(prefix) {
      for f in files {
        visited[f.0] = true
      }
    }
  }
}

///|
/// Check a single file against its index entry.
/// Adds to unstaged_modified if the file has changed.
async fn check_file_against_index(
  fs : &@bit.RepoFileSystem,
  root : String,
  path : String,
  entry : IndexEntry,
  autocrlf : AutoCrlf,
  racy_git : Bool,
  unstaged_modified : Array[String],
) -> Unit raise @bit.GitError {
  let abs = join_path(root, path)
  match @bitio.worktree_entry_meta(fs, abs) {
    None => ()
    Some(info) =>
      match info.kind {
        @bitio.WorktreeKindMeta::Regular => {
          let mut stat_matches = false
          let mut size_mismatch = false
          match info.size {
            Some(sz) => {
              size_mismatch = sz != entry.size
              match info.mtime_sec {
                Some(ms) =>
                  match info.mtime_nsec {
                    Some(mn) =>
                      if entry.mtime_sec != 0 || entry.mtime_nsec != 0 {
                        stat_matches = not(size_mismatch) &&
                          ms == entry.mtime_sec &&
                          mn == entry.mtime_nsec
                      }
                    None => ()
                  }
                None => ()
              }
            }
            None => ()
          }
          if info.mode != entry.mode {
            unstaged_modified.push(path)
          } else if size_mismatch {
            unstaged_modified.push(path)
          } else if not(stat_matches) {
            let content = fs.read_file(abs)
            let normalized = normalize_worktree_content(content, autocrlf)
            let id = @bit.hash_blob(normalized)
            if id != entry.id {
              unstaged_modified.push(path)
            }
          } else if racy_git {
            let content = fs.read_file(abs)
            let normalized = normalize_worktree_content(content, autocrlf)
            let id = @bit.hash_blob(normalized)
            if id != entry.id {
              unstaged_modified.push(path)
            }
          }
        }
        @bitio.WorktreeKindMeta::Symlink => {
          let mode_changed = info.mode != entry.mode
          let mut stat_matches = false
          match info.mtime_sec {
            Some(ms) =>
              match info.mtime_nsec {
                Some(mn) =>
                  if entry.mtime_sec != 0 || entry.mtime_nsec != 0 {
                    stat_matches = ms == entry.mtime_sec &&
                      mn == entry.mtime_nsec
                  }
                None => ()
              }
            None => ()
          }
          if mode_changed {
            unstaged_modified.push(path)
          } else if not(stat_matches) {
            match @bitio.read_symlink_target_path(abs) {
              Some(target) => {
                let id = target |> @utf8.encode |> @bit.hash_blob
                if id != entry.id {
                  unstaged_modified.push(path)
                }
              }
              None => ()
            }
          } else if racy_git {
            match @bitio.read_symlink_target_path(abs) {
              Some(target) => {
                let id = target |> @utf8.encode |> @bit.hash_blob
                if id != entry.id {
                  unstaged_modified.push(path)
                }
              }
              None => ()
            }
          }
        }
      }
  }
}
