///| Ignore integration for git worktree operations (async, all targets)

///|
/// List files under root, excluding ignored paths and .git.
pub async fn list_working_files_async(
  fs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] raise @bit.GitError {
  let matcher = Matcher::new()
  let out : Array[String] = []
  walk_dir_async(fs, root, "", matcher, out)
  out
}

///|
pub fn working_files_cache(root : String) -> Array[String]? noraise {
  ignore(root)
  None
}

///|
async fn walk_dir_async(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  matcher : Matcher,
  out : Array[String],
) -> Unit raise @bit.GitError {
  let dir = if rel == "" { root } else { @bit.join_path(root, rel) }
  // Skip submodules (directories containing .git/.bit file or directory)
  if rel != "" {
    let dot_git_marker = @bit.join_path(dir, ".git")
    let bit_marker = @bit.join_path(dir, ".bit")
    if fs.is_file(dot_git_marker) || fs.is_file(bit_marker) {
      return ()
    }
  }
  // Use native readdir_typed if available to avoid per-entry stat syscalls
  let typed = @bitio.readdir_typed(dir)
  match typed {
    Some(typed_entries) =>
      walk_dir_async_typed(fs, root, rel, dir, matcher, out, typed_entries)
    None => walk_dir_async_fallback(fs, root, rel, dir, matcher, out)
  }
}

///|
async fn walk_dir_async_typed(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  dir : String,
  matcher : Matcher,
  out : Array[String],
  typed_entries : Array[(String, Int)],
) -> Unit raise @bit.GitError {
  let mut has_git = false
  let mut has_gitignore = false
  for entry in typed_entries {
    let name = entry.0
    if name == ".git" || name == ".bit" {
      has_git = true
    }
    if name == ".gitignore" {
      has_gitignore = true
    }
    if has_git && has_gitignore {
      break
    }
  }
  if rel != "" && has_git {
    return ()
  }
  let prev_len = matcher.len()
  if has_gitignore {
    let ignore_path = @bit.join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for entry in typed_entries {
    let name = entry.0
    let d_type = entry.1
    if name == ".git" || name == ".bit" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    // d_type: 4=DT_DIR, 8=DT_REG, 10=DT_LNK, 0=DT_UNKNOWN
    let is_dir = if d_type == 4 {
      true
    } else if d_type == 10 {
      // Symlink: check if it points to a directory
      let child_path = @bit.join_path(root, child_rel)
      fs.is_dir(child_path) &&
      not(@bitio.read_symlink_target_path(child_path) is Some(_))
    } else if d_type == 0 {
      // DT_UNKNOWN: fall back to stat
      let child_path = @bit.join_path(root, child_rel)
      if fs.is_dir(child_path) {
        not(@bitio.read_symlink_target_path(child_path) is Some(_))
      } else {
        false
      }
    } else {
      false
    }
    if matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        walk_dir_async(fs, root, child_rel, matcher, out)
      }
      continue
    }
    if is_dir {
      walk_dir_async(fs, root, child_rel, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

///|
async fn walk_dir_async_fallback(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  dir : String,
  matcher : Matcher,
  out : Array[String],
) -> Unit raise @bit.GitError {
  let entries = fs.readdir(dir)
  let mut has_git = false
  let mut has_gitignore = false
  for name in entries {
    if name == ".git" || name == ".bit" {
      has_git = true
    }
    if name == ".gitignore" {
      has_gitignore = true
    }
    if has_git && has_gitignore {
      break
    }
  }
  if rel != "" && has_git {
    return ()
  }
  let prev_len = matcher.len()
  if has_gitignore {
    let ignore_path = @bit.join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for name in entries {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = @bit.join_path(root, child_rel)
    let is_dir = if fs.is_dir(child_path) {
      not(@bitio.read_symlink_target_path(child_path) is Some(_))
    } else {
      false
    }
    if matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        walk_dir_async(fs, root, child_rel, matcher, out)
      }
      continue
    }
    if is_dir {
      walk_dir_async(fs, root, child_rel, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}
