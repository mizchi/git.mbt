///| Sparse checkout implementation

///|
pub fn sparse_default_patterns() -> Array[String] {
  ["/*", "!/*/"]
}

///|
fn sparse_read_or_default_config(
  rfs : &@bit.RepoFileSystem,
  path : String,
) -> String {
  if rfs.is_file(path) {
    @utf8.decode_lossy(
      (rfs.read_file(path) catch { _ => return "[core]\n" })[:],
    )
  } else {
    "[core]\n"
  }
}

///|
fn sparse_upsert_section_value(
  config : String,
  section : String,
  name : String,
  value_text : String,
) -> String {
  let header = "[\{section}]"
  let lines : Array[String] = []
  let mut in_section = false
  let mut found_section = false
  let mut key_set = false
  for line_view in config.split("\n") {
    let line = line_view.to_string()
    let trimmed = sparse_trim(line)
    if trimmed == header {
      in_section = true
      found_section = true
      lines.push(line)
      continue
    }
    if in_section && trimmed.has_prefix("[") {
      if not(key_set) {
        lines.push("\t\{name} = \{value_text}")
        key_set = true
      }
      in_section = false
    }
    if in_section && trimmed.has_prefix("\{name} = ") {
      lines.push("\t\{name} = \{value_text}")
      key_set = true
      continue
    }
    lines.push(line)
  }
  if found_section {
    if in_section && not(key_set) {
      lines.push("\t\{name} = \{value_text}")
    }
  } else {
    if lines.length() > 0 && sparse_trim(lines[lines.length() - 1]) != "" {
      lines.push("")
    }
    lines.push(header)
    lines.push("\t\{name} = \{value_text}")
  }
  lines
  .iter()
  .fold(init="", fn(acc, line) {
    if acc == "" {
      line
    } else {
      acc + "\n" + line
    }
  })
}

///|
fn sparse_upsert_section_bool(
  config : String,
  section : String,
  name : String,
  value : Bool,
) -> String {
  let value_text = if value { "true" } else { "false" }
  sparse_upsert_section_value(config, section, name, value_text)
}

///|
fn sparse_upsert_core_bool(
  config : String,
  name : String,
  value : Bool,
) -> String {
  sparse_upsert_section_bool(config, "core", name, value)
}

///|
fn sparse_is_section_bool_enabled(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  section : String,
  name : String,
) -> Bool {
  let header = "[\{section}]"
  let config_paths = [
    join_path(git_dir, "config"),
    join_path(git_dir, "config.worktree"),
  ]
  for config_path in config_paths {
    if not(rfs.is_file(config_path)) {
      continue
    }
    let content = @utf8.decode_lossy(
      (rfs.read_file(config_path) catch { _ => continue })[:],
    )
    let mut in_section = false
    for line_view in content.split("\n") {
      let trimmed = sparse_trim(line_view.to_string())
      if trimmed == header {
        in_section = true
        continue
      }
      if trimmed.has_prefix("[") {
        in_section = false
        continue
      }
      if in_section && trimmed.has_prefix(name) {
        if trimmed.contains("true") || trimmed.contains("= true") {
          return true
        }
      }
    }
  }
  false
}

///|
fn sparse_enable_worktree_config(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Unit raise @bit.GitError {
  let config_path = join_path(git_dir, "config")
  let config = sparse_read_or_default_config(rfs, config_path)
  let config_with_extension = sparse_upsert_section_bool(
    sparse_upsert_section_value(config, "core", "repositoryformatversion", "1"),
    "extensions",
    "worktreeConfig",
    true,
  )
  fs.write_string(config_path, config_with_extension)

  let worktree_config_path = join_path(git_dir, "config.worktree")
  let worktree_config = sparse_read_or_default_config(rfs, worktree_config_path)
  fs.write_string(
    worktree_config_path,
    sparse_upsert_core_bool(worktree_config, "sparseCheckout", true),
  )
}

///|
pub fn sparse_set_index_sparse_config(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  value : Bool,
) -> Unit raise @bit.GitError {
  sparse_enable_worktree_config(fs, rfs, git_dir)
  let worktree_config_path = join_path(git_dir, "config.worktree")
  let worktree_config = sparse_read_or_default_config(rfs, worktree_config_path)
  fs.write_string(
    worktree_config_path,
    sparse_upsert_section_bool(worktree_config, "index", "sparse", value),
  )
}

///|
fn sparse_is_core_bool_enabled(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Bool {
  sparse_is_section_bool_enabled(rfs, git_dir, "core", name)
}

///|
pub fn is_sparse_checkout_cone_enabled(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  sparse_is_core_bool_enabled(rfs, git_dir, "sparseCheckoutCone")
}

///|
pub fn sparse_set_cone_config(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  value : Bool,
) -> Unit raise @bit.GitError {
  sparse_enable_worktree_config(fs, rfs, git_dir)
  let worktree_config_path = join_path(git_dir, "config.worktree")
  let worktree_config = sparse_read_or_default_config(rfs, worktree_config_path)
  let updated = sparse_upsert_core_bool(
    sparse_upsert_core_bool(worktree_config, "sparseCheckout", true),
    "sparseCheckoutCone",
    value,
  )
  fs.write_string(worktree_config_path, updated)
}

///|
fn sparse_normalize_cone_pattern(pattern : String) -> String? {
  let trimmed = sparse_trim(pattern)
  if trimmed.length() == 0 || trimmed == "/*" || trimmed == "!/*/" {
    return None
  }
  let without_bang = if trimmed.has_prefix("!") {
    trimmed[1:].to_string()
  } else {
    trimmed
  }
  let without_leading = if without_bang.has_prefix("/") {
    without_bang[1:].to_string()
  } else {
    without_bang
  }
  let normalized = if without_leading.has_suffix("/") && without_leading.length() > 1 {
    without_leading[:without_leading.length() - 1].to_string()
  } else {
    without_leading
  }
  if normalized.length() == 0 {
    None
  } else {
    Some(normalized)
  }
}

///|
fn sparse_cone_is_descendant(path : String, parent : String) -> Bool {
  path.length() > parent.length() && path.has_prefix(parent + "/")
}

///|
fn sparse_canonicalize_cone_patterns(patterns : Array[String]) -> Array[String] {
  let canonical : Array[String] = []
  for pattern in patterns {
    match sparse_normalize_cone_pattern(pattern) {
      None => ()
      Some(normalized) => {
        let mut covered = false
        let kept : Array[String] = []
        for existing in canonical {
          if existing == normalized || sparse_cone_is_descendant(normalized, existing) {
            covered = true
          }
          if existing != normalized &&
            !sparse_cone_is_descendant(existing, normalized) {
            kept.push(existing)
          }
        }
        canonical.clear()
        for existing in kept {
          canonical.push(existing)
        }
        if not(covered) {
          canonical.push(normalized)
        }
      }
    }
  }
  canonical
}

///|
fn sparse_patterns_use_cone_mode(patterns : Array[String]) -> Bool {
  if patterns.length() == 0 {
    return true
  }
  if !patterns.contains("/*") || !patterns.contains("!/*/") {
    return false
  }
  for pattern in patterns {
    if pattern == "/*" || pattern == "!/*/" {
      continue
    }
    if pattern.has_prefix("!") {
      if !pattern.has_prefix("!/") || !pattern.has_suffix("/*/") {
        return false
      }
      continue
    }
    if sparse_normalize_cone_pattern(pattern) == None {
      return false
    }
  }
  true
}

///|
fn sparse_encode_cone_patterns(patterns : Array[String]) -> Array[String] {
  let out = sparse_default_patterns()
  for relative in sparse_canonicalize_cone_patterns(patterns) {
    let parts : Array[String] = []
    for part_view in relative.split("/") {
      let part = part_view.to_string()
      if part.length() > 0 {
        parts.push(part)
      }
    }
    let mut current = ""
    if parts.length() > 1 {
      for i in 0..<(parts.length() - 1) {
        current = if current == "" {
          parts[i]
        } else {
          current + "/" + parts[i]
        }
        let parent = "/" + current + "/"
        if not(out.contains(parent)) {
          out.push(parent)
        }
        let exclude_children = "!/" + current + "/*/"
        if not(out.contains(exclude_children)) {
          out.push(exclude_children)
        }
      }
    }
    let stored = "/" + relative + "/"
    if not(out.contains(stored)) {
      out.push(stored)
    }
  }
  out
}

///|
/// Check if sparse checkout is enabled.
pub fn is_sparse_checkout_enabled(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  sparse_is_core_bool_enabled(rfs, git_dir, "sparseCheckout")
}

///|
fn sparse_is_index_sparse_enabled(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  sparse_is_section_bool_enabled(rfs, git_dir, "index", "sparse")
}

///|
/// Read sparse checkout patterns from .git/info/sparse-checkout.
pub fn read_sparse_patterns(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @bit.GitError {
  let sparse_path = join_path(git_dir, "info/sparse-checkout")
  if not(rfs.is_file(sparse_path)) {
    return []
  }
  let content = rfs.read_file(sparse_path)
  let text = @utf8.decode_lossy(content[:])
  let patterns : Array[String] = []
  for line_view in text.split("\n") {
    let line = sparse_trim(line_view.to_string())
    if line.length() > 0 && not(line.has_prefix("#")) {
      patterns.push(line)
    }
  }
  patterns
}

///|
pub fn read_sparse_display_patterns(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @bit.GitError {
  let patterns = read_sparse_patterns(rfs, git_dir)
  if not(is_sparse_checkout_cone_enabled(rfs, git_dir)) {
    return patterns
  }
  let positive : Array[String] = []
  let exclude_children : Map[String, Bool] = {}
  for pattern in patterns {
    if pattern == "/*" || pattern == "!/*/" {
      continue
    }
    if pattern.has_prefix("!/") && pattern.has_suffix("/*/") {
      let normalized = pattern[2:pattern.length() - 3].to_string()
      if normalized.length() > 0 {
        exclude_children[normalized] = true
      }
      continue
    }
    if pattern.has_prefix("!") {
      continue
    }
    match sparse_normalize_cone_pattern(pattern) {
      Some(normalized) if not(positive.contains(normalized)) =>
        positive.push(normalized)
      _ => ()
    }
  }
  let display : Array[String] = []
  for candidate in positive {
    let mut intermediate = false
    if exclude_children.contains(candidate) {
      for other in positive {
        if sparse_cone_is_descendant(other, candidate) {
          intermediate = true
          break
        }
      }
    }
    if not(intermediate) {
      display.push(candidate)
    }
  }
  display
}

///|
/// Write sparse checkout patterns to .git/info/sparse-checkout.
pub fn write_sparse_patterns(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  patterns : Array[String],
) -> Unit raise @bit.GitError {
  let info_dir = join_path(git_dir, "info")
  fs.mkdir_p(info_dir)
  let sparse_path = join_path(git_dir, "info/sparse-checkout")
  let lock_path = sparse_path + ".lock"
  if rfs.is_file(lock_path) {
    raise @bit.GitError::InvalidObject(
      "Unable to create '\{lock_path}': File exists.",
    )
  }
  let content = patterns
    .iter()
    .fold(init="", fn(acc, p) {
      if acc.length() == 0 {
        p + "\n"
      } else {
        acc + p + "\n"
      }
    })
  fs.write_string(sparse_path, content)
}

///|
/// Initialize sparse checkout.
pub fn sparse_checkout_init(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  cone? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let config_path = join_path(git_dir, "config")
  let config = sparse_read_or_default_config(rfs, config_path)
  let updated = sparse_upsert_section_bool(
    sparse_upsert_section_value(config, "core", "repositoryformatversion", "1"),
    "extensions",
    "worktreeConfig",
    true,
  )
  fs.write_string(config_path, updated)
  sparse_set_cone_config(fs, rfs, git_dir, cone)
  let sparse_path = join_path(git_dir, "info/sparse-checkout")
  if not(rfs.is_file(sparse_path)) {
    write_sparse_patterns(fs, rfs, git_dir, sparse_default_patterns())
  }
  sparse_update_worktree(fs, rfs, root)
}

///|
/// Set sparse checkout patterns (replaces existing patterns).
pub fn sparse_checkout_set(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  patterns : Array[String],
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Ensure sparse checkout is initialized
  if not(is_sparse_checkout_enabled(rfs, git_dir)) {
    sparse_checkout_init(fs, rfs, root)
  }
  sparse_enable_worktree_config(fs, rfs, git_dir)
  let stored_patterns = if is_sparse_checkout_cone_enabled(rfs, git_dir) {
    sparse_encode_cone_patterns(patterns)
  } else {
    patterns
  }
  write_sparse_patterns(fs, rfs, git_dir, stored_patterns)
  // Update worktree
  sparse_update_worktree(fs, rfs, root)
}

///|
/// Add patterns to sparse checkout.
pub fn sparse_checkout_add(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  new_patterns : Array[String],
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Ensure sparse checkout is initialized
  if not(is_sparse_checkout_enabled(rfs, git_dir)) {
    sparse_checkout_init(fs, rfs, root)
  }
  sparse_enable_worktree_config(fs, rfs, git_dir)
  let cone_mode = is_sparse_checkout_cone_enabled(rfs, git_dir)
  let existing = read_sparse_patterns(rfs, git_dir)
  if cone_mode && not(sparse_patterns_use_cone_mode(existing)) {
    raise @bit.GitError::InvalidObject(
      "existing sparse-checkout patterns do not use cone mode",
    )
  }
  let next_patterns = if cone_mode {
    let display = read_sparse_display_patterns(rfs, git_dir)
    for p in new_patterns {
      if not(display.contains(p)) {
        display.push(p)
      }
    }
    sparse_encode_cone_patterns(display)
  } else {
    for p in new_patterns {
      if not(existing.contains(p)) {
        existing.push(p)
      }
    }
    existing
  }
  write_sparse_patterns(fs, rfs, git_dir, next_patterns)
  // Update worktree
  sparse_update_worktree(fs, rfs, root)
}

///|
/// Disable sparse checkout.
pub fn sparse_checkout_disable(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Update config to disable
  let config_path = join_path(git_dir, "config")
  if rfs.is_file(config_path) {
    let config = @utf8.decode_lossy(rfs.read_file(config_path)[:])
    let new_config = config
      .replace(old="sparseCheckout = true", new="sparseCheckout = false")
      .replace(
        old="sparseCheckoutCone = true",
        new="sparseCheckoutCone = false",
      )
    fs.write_string(config_path, new_config)
  }
  let worktree_config_path = join_path(git_dir, "config.worktree")
  if rfs.is_file(worktree_config_path) {
    let worktree_config = sparse_read_or_default_config(
      rfs, worktree_config_path,
    )
    fs.write_string(
      worktree_config_path,
      sparse_upsert_core_bool(
        sparse_upsert_core_bool(worktree_config, "sparseCheckout", false),
        "sparseCheckoutCone",
        false,
      ),
    )
  }
  // Checkout all files
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => ()
    Some(commit_id) => {
      let db = ObjectDb::load(rfs, git_dir)
      let files = collect_tree_files_from_commit(db, rfs, commit_id)
      write_worktree_from_files(db, fs, rfs, root, git_dir, files)
      let entries = tree_files_to_index(db, rfs, files)
      write_skip_worktree_paths(fs, git_dir, [])
      write_index_entries(fs, git_dir, entries)
    }
  }
}

///|
pub fn sparse_checkout_reapply(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  if not(is_sparse_checkout_enabled(rfs, git_dir)) {
    sparse_checkout_init(fs, rfs, root)
  }
  sparse_enable_worktree_config(fs, rfs, git_dir)
  sparse_update_worktree(fs, rfs, root, preserve_index=true)
}

///|
/// Check if a path matches any of the sparse checkout patterns.
pub fn matches_sparse_pattern(path : String, patterns : Array[String]) -> Bool {
  if patterns.length() == 0 {
    return true // No patterns means include everything
  }
  let mut included = false
  for pattern in patterns {
    if pattern.has_prefix("!") {
      // Negation pattern
      let neg_pattern = String::unsafe_substring(
        pattern,
        start=1,
        end=pattern.length(),
      )
      if sparse_path_matches(path, neg_pattern) {
        included = false
      }
    } else if sparse_path_matches(path, pattern) {
      included = true
    }
  }
  included
}

///|
/// Simple glob-like pattern matching for sparse checkout.
fn sparse_path_matches(path : String, pattern : String) -> Bool {
  let anchored = pattern.has_prefix("/")
  let normalized_pattern = if pattern.has_prefix("/") &&
    pattern != "/*" &&
    pattern != "!/*/" {
    String::unsafe_substring(pattern, start=1, end=pattern.length())
  } else {
    pattern
  }
  // Handle common patterns:
  // "/*" - match all files in root
  // "!/*/  " - exclude all directories in root
  // "dir/" - match directory and contents
  // "dir/*" - match files in directory
  // "*.txt" - match files ending in .txt
  if normalized_pattern == "/*" {
    // Match files in root (no slash in path)
    return not(path.contains("/"))
  }
  if normalized_pattern == "/*/" {
    // Used by the default negation pattern "!/*/" to exclude root directories.
    return path.contains("/")
  }
  if normalized_pattern.has_prefix("*") &&
    normalized_pattern.has_suffix("*") &&
    normalized_pattern.length() > 1 {
    let needle = String::unsafe_substring(
      normalized_pattern,
      start=1,
      end=normalized_pattern.length() - 1,
    )
    return needle.length() == 0 || path.contains(needle)
  }
  if normalized_pattern.has_suffix("/*/") {
    let dir = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 3,
    )
    if path.has_prefix(dir + "/") {
      let rest = String::unsafe_substring(
        path,
        start=dir.length() + 1,
        end=path.length(),
      )
      return rest.contains("/")
    }
    return false
  }
  if normalized_pattern.has_suffix("/") {
    // Directory pattern - match if path starts with this directory
    let dir = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 1,
    )
    return sparse_path_matches_unanchored_prefix(path, dir, anchored)
  }
  if normalized_pattern.has_suffix("/*") {
    // Match files directly in directory
    let dir = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 2,
    )
    if path.has_prefix(dir + "/") {
      let rest = String::unsafe_substring(
        path,
        start=dir.length() + 1,
        end=path.length(),
      )
      return not(rest.contains("/"))
    }
    return false
  }
  if normalized_pattern.has_prefix("*") {
    // Wildcard at start
    let suffix = String::unsafe_substring(
      normalized_pattern,
      start=1,
      end=normalized_pattern.length(),
    )
    return path.has_suffix(suffix)
  }
  if normalized_pattern.has_suffix("*") {
    // Wildcard at end
    let prefix = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 1,
    )
    return path.has_prefix(prefix)
  }
  if normalized_pattern.contains("**") {
    // Double star matches any path
    let parts = normalized_pattern.split("**")
    let parts_arr : Array[String] = []
    for p in parts {
      parts_arr.push(p.to_string())
    }
    if parts_arr.length() == 2 {
      let prefix = parts_arr[0]
      let suffix = parts_arr[1]
      return (prefix.length() == 0 || path.has_prefix(prefix)) &&
        (suffix.length() == 0 || path.has_suffix(suffix))
    }
  }
  // Exact match or path prefix
  sparse_path_matches_unanchored_prefix(path, normalized_pattern, anchored)
}

///|
fn sparse_path_matches_unanchored_prefix(
  path : String,
  pattern : String,
  anchored : Bool,
) -> Bool {
  if anchored {
    return path == pattern || path.has_prefix(pattern + "/")
  }
  path == pattern ||
  path.has_prefix(pattern + "/") ||
  path.has_suffix("/" + pattern) ||
  path.contains("/" + pattern + "/")
}

///|
fn sparse_collect_tree_ids(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  out : Map[String, @bit.ObjectId],
) -> Unit raise @bit.GitError {
  let tree_obj = db.get(rfs, tree_id)
  match tree_obj {
    None =>
      raise @bit.GitError::InvalidObject(
        "Missing tree object: " + tree_id.to_hex(),
      )
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @bit.parse_tree(obj.data)
      for entry in entries {
        if entry.mode != "40000" {
          continue
        }
        let path = if prefix == "" {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        out[path] = entry.id
        sparse_collect_tree_ids(db, rfs, entry.id, path, out)
      }
    }
  }
}

///|
fn sparse_parent_dirs(path : String) -> Array[String] {
  let out : Array[String] = []
  let mut current = path
  while current.contains("/") {
    let mut slash = -1
    for i = current.length() - 1; i >= 0; i = i - 1 {
      if current.unsafe_get(i) == '/' {
        slash = i
        break
      }
    }
    if slash <= 0 {
      break
    }
    current = current[:slash].to_string()
    if current.length() > 0 && not(out.contains(current)) {
      out.push(current)
    }
  }
  out
}

///|
fn sparse_path_depth(path : String) -> Int {
  let mut depth = 0
  for i = 0; i < path.length(); i = i + 1 {
    if path.unsafe_get(i) == '/' {
      depth = depth + 1
    }
  }
  depth
}

///|
fn sparse_is_under_dir(path : String, dir : String) -> Bool {
  path.has_prefix(dir + "/")
}

///|
fn sparse_build_sparse_index_entries(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
  all_files : Map[String, TreeFileEntry],
  skip_paths : Array[String],
) -> (Array[IndexEntry], Map[String, Bool]) raise @bit.GitError {
  let tree_ids : Map[String, @bit.ObjectId] = {}
  let commit_obj = db.get(rfs, commit_id)
  match commit_obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      let info = @bit.parse_commit(obj.data)
      sparse_collect_tree_ids(db, rfs, info.tree, "", tree_ids)
    }
  }

  let candidate_dirs : Array[String] = []
  for path in skip_paths {
    for dir in sparse_parent_dirs(path) {
      if not(candidate_dirs.contains(dir)) {
        candidate_dirs.push(dir)
      }
    }
  }
  candidate_dirs.sort_by(fn(left, right) {
    let left_depth = sparse_path_depth(left)
    let right_depth = sparse_path_depth(right)
    if left_depth == right_depth {
      String::compare(left, right)
    } else {
      left_depth - right_depth
    }
  })

  let sparse_dirs : Array[String] = []
  for dir in candidate_dirs {
    let mut has_files = false
    let mut fully_skipped = true
    for item in all_files.to_array() {
      let (path, _) = item
      if not(sparse_is_under_dir(path, dir)) {
        continue
      }
      has_files = true
      if not(skip_paths.contains(path)) {
        fully_skipped = false
        break
      }
    }
    if not(has_files) || not(fully_skipped) {
      continue
    }
    let mut shadowed = false
    for existing in sparse_dirs {
      if sparse_is_under_dir(dir, existing) {
        shadowed = true
        break
      }
    }
    if not(shadowed) {
      sparse_dirs.push(dir)
    }
  }

  let sparse_dir_set : Map[String, Bool] = {}
  for dir in sparse_dirs {
    sparse_dir_set[dir] = true
  }

  let kept_files : Map[String, TreeFileEntry] = {}
  let skip_set : Map[String, Bool] = {}
  for item in all_files.to_array() {
    let (path, entry) = item
    let mut collapsed = false
    for dir in sparse_dirs {
      if sparse_is_under_dir(path, dir) {
        collapsed = true
        break
      }
    }
    if collapsed {
      continue
    }
    kept_files[path] = entry
    if skip_paths.contains(path) {
      skip_set[path] = true
    }
  }

  let entries = tree_files_to_index(db, rfs, kept_files)
  for dir in sparse_dirs {
    match tree_ids.get(dir) {
      Some(tree_id) =>
        entries.push(IndexEntry::new(dir + "/", tree_id, 0o040000, 0))
      None => ()
    }
    skip_set[dir + "/"] = true
  }
  entries.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  (entries, skip_set)
}

///|
/// Update worktree based on sparse checkout patterns.
fn sparse_update_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  preserve_index? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  if not(rfs.is_file(join_path(git_dir, "index"))) {
    return
  }
  let patterns = read_sparse_patterns(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => ()
    Some(commit_id) => {
      let db = ObjectDb::load(rfs, git_dir)
      let autocrlf = read_autocrlf_setting(rfs, git_dir)
      let current_raw_entries = read_index_entries(rfs, git_dir)
      let current_entries = expand_sparse_index_entries(
        rfs, git_dir, current_raw_entries,
      )
      let protected_skip_paths : Map[String, Bool] = {}
      for entry in current_entries {
        if matches_sparse_pattern(entry.path, patterns) {
          continue
        }
        if sparse_worktree_matches_index_entry(
          rfs,
          root,
          entry.path,
          entry,
          autocrlf,
        ) {
          continue
        }
        protected_skip_paths[entry.path] = true
      }
      let all_files : Map[String, TreeFileEntry] = if preserve_index {
        let files : Map[String, TreeFileEntry] = {}
        for entry in current_entries {
          files[entry.path] = { id: entry.id, mode: entry.mode }
        }
        files
      } else {
        collect_tree_files_from_commit(db, rfs, commit_id)
      }
      // Filter files based on sparse patterns
      let sparse_files : Map[String, TreeFileEntry] = {}
      let skip_paths : Array[String] = []
      for item in all_files.to_array() {
        let (path, entry) = item
        if matches_sparse_pattern(path, patterns) {
          sparse_files[path] = entry
        } else {
          skip_paths.push(path)
        }
      }
      // Remove files not in sparse set
      for item in all_files.to_array() {
        let (path, _) = item
        if not(matches_sparse_pattern(path, patterns)) {
          if protected_skip_paths.contains(path) {
            continue
          }
          let file_path = join_path(root, path)
          if rfs.is_file(file_path) {
            fs.remove_file(file_path)
          }
        }
      }
      // Write sparse files
      write_worktree_from_files(db, fs, rfs, root, git_dir, sparse_files)
      ignore(sparse_prune_empty_dirs(fs, rfs, root, root))
      write_skip_worktree_paths(fs, git_dir, skip_paths)
      let use_sparse_index = sparse_is_index_sparse_enabled(rfs, git_dir) &&
        is_sparse_checkout_cone_enabled(rfs, git_dir)
      if use_sparse_index {
        let (entries, skip_set) = sparse_build_sparse_index_entries(
          db, rfs, commit_id, all_files, skip_paths,
        )
        write_index_entries_with_flags(fs, git_dir, entries, skip_set, {})
      } else {
        // Update index with sparse skip-worktree entries.
        let skip_set : Map[String, Bool] = {}
        for path in skip_paths {
          skip_set[path] = true
        }
        let all_entries = tree_files_to_index(db, rfs, all_files)
        write_index_entries_with_skip_worktree(
          fs, git_dir, all_entries, skip_set,
        )
      }
    }
  }
}

///|
fn sparse_worktree_matches_index_entry(
  rfs : &@bit.RepoFileSystem,
  root : String,
  path : String,
  entry : IndexEntry,
  autocrlf : AutoCrlf,
) -> Bool raise @bit.GitError {
  let abs = join_path(root, path)
  match @bitio.worktree_entry_meta_sync(rfs, abs) {
    None => false
    Some(info) =>
      match info.kind {
        @bitio.WorktreeKindMeta::Regular => {
          if info.mode != entry.mode {
            return false
          }
          let content = rfs.read_file(abs)
          let attrs = resolve_eol_attrs(rfs, root, path)
          let normalized = clean_for_storage(content, attrs, autocrlf)
          @bit.hash_blob(normalized) == entry.id
        }
        @bitio.WorktreeKindMeta::Symlink => {
          if info.mode != entry.mode {
            return false
          }
          match @bitio.read_symlink_target_path(abs) {
            Some(target) => @bit.hash_blob(@utf8.encode(target)) == entry.id
            None => false
          }
        }
      }
  }
}

///|
fn sparse_prune_empty_dirs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  path : String,
) -> Bool {
  if path != root && path.has_prefix(join_path(root, ".git")) {
    return false
  }
  if not(rfs.is_dir(path)) {
    return false
  }
  let entries = rfs.readdir(path) catch { _ => return false }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let child = join_path(path, entry)
    if rfs.is_dir(child) {
      ignore(sparse_prune_empty_dirs(fs, rfs, root, child))
    }
  }
  let remaining = rfs.readdir(path) catch { _ => return false }
  let mut has_entries = false
  for entry in remaining {
    if entry != "." && entry != ".." {
      has_entries = true
      break
    }
  }
  if path != root && not(has_entries) {
    fs.remove_dir(path) catch {
      _ => ()
    }
    return true
  }
  false
}

///|
fn sparse_trim(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}
