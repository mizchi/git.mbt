///| Tree helpers for checkout/reset/merge

///|
pub struct TreeFileEntry {
  id : @bit.ObjectId
  mode : Int
}

///|
fn worktree_is_case_insensitive(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool raise @bit.GitError {
  let lower_path = join_path(git_dir, "bit-case-probe-9fcb2c2d")
  let upper_path = join_path(git_dir, "BIT-CASE-PROBE-9FCB2C2D")
  if rfs.is_file(lower_path) ||
    rfs.is_dir(lower_path) ||
    rfs.is_file(upper_path) ||
    rfs.is_dir(upper_path) {
    return false
  }
  fs.write_string(lower_path, "1")
  let insensitive = rfs.is_file(upper_path)
  if rfs.is_file(lower_path) {
    fs.remove_file(lower_path)
  }
  insensitive
}

///|
fn detect_case_insensitive_collision_skips(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  paths : Array[String],
) -> Map[String, Bool] raise @bit.GitError {
  let skip : Map[String, Bool] = {}
  if not(worktree_is_case_insensitive(fs, rfs, git_dir)) {
    return skip
  }
  let mut i = 0
  while i < paths.length() {
    let left = paths[i]
    let left_fold = left.to_lower()
    let mut j = i + 1
    while j < paths.length() {
      let right = paths[j]
      let right_fold = right.to_lower()
      if left_fold == right_fold {
        skip[right] = true
      } else {
        let right_prefix = right_fold + "/"
        let left_prefix = left_fold + "/"
        if left_fold.has_prefix(right_prefix) {
          skip[right] = true
        } else if right_fold.has_prefix(left_prefix) {
          skip[left] = true
        }
      }
      j += 1
    }
    i += 1
  }
  skip
}

///|
fn remove_worktree_path_recursive(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  path : String,
) -> Unit raise @bit.GitError {
  if rfs.is_file(path) {
    fs.remove_file(path)
    return ()
  }
  if not(rfs.is_dir(path)) {
    return ()
  }
  let entries = rfs.readdir(path)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    remove_worktree_path_recursive(fs, rfs, join_path(path, entry))
  }
  fs.remove_dir(path)
}

///|
fn tree_ops_get_rel_path(from : String, to : String) -> String {
  let from_parts : Array[String] = from
    .split("/")
    .filter(s => s.to_string().length() > 0)
    .map(s => s.to_string())
    .collect()
  let to_parts : Array[String] = to
    .split("/")
    .filter(s => s.to_string().length() > 0)
    .map(s => s.to_string())
    .collect()
  let mut common = 0
  while common < from_parts.length() && common < to_parts.length() {
    if from_parts[common] == to_parts[common] {
      common += 1
    } else {
      break
    }
  }
  let mut result = ""
  for _ in 0..<(from_parts.length() - common) {
    result = result + "../"
  }
  for i in common..<to_parts.length() {
    if result.length() > 0 && not(result.has_suffix("/")) {
      result = result + "/"
    }
    result = result + to_parts[i]
  }
  result
}

///|
fn tree_ops_find_submodule_name_in_content(
  content : String,
  path : String,
) -> String? {
  let mut current_name : String? = None
  let mut current_path : String? = None
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = line.trim(chars=" \t").to_string()
    if trimmed.has_prefix("[submodule \"") && trimmed.has_suffix("\"]") {
      match (current_name, current_path) {
        (Some(name), Some(current)) if current == path => return Some(name)
        _ => ()
      }
      let name = String::unsafe_substring(
        trimmed,
        start=12,
        end=trimmed.length() - 2,
      )
      current_name = Some(name)
      current_path = None
      continue
    }
    if trimmed.has_prefix("[") {
      match (current_name, current_path) {
        (Some(name), Some(current)) if current == path => return Some(name)
        _ => ()
      }
      current_name = None
      current_path = None
      continue
    }
    if current_name is Some(_) && trimmed.has_prefix("path = ") {
      current_path = Some(
        String::unsafe_substring(trimmed, start=7, end=trimmed.length()),
      )
    }
  }
  match (current_name, current_path) {
    (Some(name), Some(current)) if current == path => Some(name)
    _ => None
  }
}

///|
fn tree_ops_find_submodule_name_by_path(
  rfs : &@bit.RepoFileSystem,
  root : String,
  path : String,
  gitmodules_content? : String? = None,
) -> String {
  match gitmodules_content {
    Some(content) =>
      tree_ops_find_submodule_name_in_content(content, path).unwrap_or(path)
    None => {
      let gitmodules_path = join_path(root, ".gitmodules")
      if not(rfs.is_file(gitmodules_path)) {
        return path
      }
      let content = decode_bytes_lossy(
        rfs.read_file(gitmodules_path) catch {
          _ => return path
        },
      )
      tree_ops_find_submodule_name_in_content(content, path).unwrap_or(path)
    }
  }
}

///|
fn tree_ops_set_core_config_value(
  content : String,
  key : String,
  value : String,
) -> String {
  let lines : Array[String] = []
  let mut in_core = false
  let mut found_section = false
  let mut key_set = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = line.trim(chars=" \t").to_string()
    if trimmed == "[core]" {
      in_core = true
      found_section = true
      lines.push(line)
      continue
    }
    if in_core && trimmed.has_prefix("[") {
      if not(key_set) {
        lines.push("\t\{key} = \{value}")
        key_set = true
      }
      in_core = false
    }
    if in_core &&
      (
        trimmed == key ||
        trimmed.has_prefix(key + " =") ||
        trimmed.has_prefix(key + "=")
      ) {
      lines.push("\t\{key} = \{value}")
      key_set = true
      continue
    }
    lines.push(line)
  }
  if found_section {
    if in_core && not(key_set) {
      lines.push("\t\{key} = \{value}")
    }
  } else {
    if lines.length() > 0 &&
      lines[lines.length() - 1].trim(chars=" \t").length() > 0 {
      lines.push("")
    }
    lines.push("[core]")
    lines.push("\t\{key} = \{value}")
  }
  lines.join("\n")
}

///|
fn tree_ops_read_target_gitmodules_content(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  files : Map[String, TreeFileEntry],
) -> String? {
  match files.get(".gitmodules") {
    Some(info) => {
      let obj = db.get(rfs, info.id) catch { _ => return None }
      match obj {
        Some(obj) if obj.obj_type == @bit.ObjectType::Blob =>
          Some(decode_bytes_lossy(obj.data))
        _ => None
      }
    }
    None => None
  }
}

///|
fn restore_gitlink_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  path : String,
  commit_id : @bit.ObjectId,
  gitmodules_content? : String? = None,
) -> Unit raise @bit.GitError {
  let full_path = join_path(root, path)
  let worktree_git_path = join_path(full_path, ".git")
  if rfs.is_file(full_path) {
    fs.remove_file(full_path)
  }
  let has_existing_worktree = rfs.is_file(worktree_git_path) ||
    rfs.is_dir(worktree_git_path)
  let submodule_name = tree_ops_find_submodule_name_by_path(
    rfs,
    root,
    path,
    gitmodules_content~,
  )
  let modules_dir = join_path(join_path(git_dir, "modules"), submodule_name)
  fs.mkdir_p(full_path)
  if not(rfs.is_dir(modules_dir)) {
    return ()
  }
  let rel_path = tree_ops_get_rel_path(full_path, modules_dir)
  let config_path = join_path(modules_dir, "config")
  let config_content = if rfs.is_file(config_path) {
    decode_bytes_lossy(rfs.read_file(config_path))
  } else {
    ""
  }
  let with_worktree = tree_ops_set_core_config_value(
    config_content,
    "worktree",
    tree_ops_get_rel_path(modules_dir, full_path),
  )
  let with_bare = tree_ops_set_core_config_value(with_worktree, "bare", "false")
  fs.write_string(config_path, with_bare)
  if rfs.is_file(worktree_git_path) {
    fs.write_string(worktree_git_path, "gitdir: \{rel_path}\n")
  } else if not(has_existing_worktree) {
    fs.write_string(worktree_git_path, "gitdir: \{rel_path}\n")
  }
  if has_existing_worktree {
    return ()
  }
  fs.write_string(join_path(modules_dir, "HEAD"), commit_id.to_hex() + "\n")
  let db = ObjectDb::load_lazy(rfs, modules_dir)
  db.set_skip_verify(true)
  let files = collect_tree_files_from_commit(db, rfs, commit_id)
  let entries = write_worktree_and_build_index(
    db,
    fs,
    rfs,
    full_path,
    modules_dir,
    files,
    remove_missing=true,
  )
  write_index_entries(fs, modules_dir, entries)
}

///|
pub fn collect_tree_files(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
) -> Map[String, TreeFileEntry] raise @bit.GitError {
  let out : Map[String, TreeFileEntry] = {}
  collect_tree_files_inner(db, fs, tree_id, "", out)
  out
}

///|
pub fn collect_tree_files_from_commit(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> Map[String, TreeFileEntry] raise @bit.GitError {
  let commit_obj = db.get(fs, commit_id)
  match commit_obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      let info = @bit.parse_commit(obj.data)
      collect_tree_files(db, fs, info.tree)
    }
  }
}

///|
pub fn tree_files_to_index(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  files : Map[String, TreeFileEntry],
) -> Array[IndexEntry] raise @bit.GitError {
  let entries : Array[IndexEntry] = []
  for item in files.to_array() {
    let (path, info) = item
    if is_gitlink_mode_int(info.mode) {
      entries.push({
        path,
        id: info.id,
        mode: info.mode,
        size: 0,
        mtime_sec: 0,
        mtime_nsec: 0,
        intent_to_add: false,
        dev: 0,
        ino: 0,
        uid: 0,
        gid: 0,
      })
      continue
    }
    let obj = db.get(fs, info.id)
    match obj {
      None =>
        raise @bit.GitError::InvalidObject(
          "Missing blob object: " + info.id.to_hex(),
        )
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Blob {
          raise @bit.GitError::InvalidObject("Object is not a blob")
        }
        entries.push({
          path,
          id: info.id,
          mode: info.mode,
          size: o.data.length(),
          mtime_sec: 0,
          mtime_nsec: 0,
          intent_to_add: false,
          dev: 0,
          ino: 0,
          uid: 0,
          gid: 0,
        })
      }
    }
  }
  entries.sort_by((a, b) => String::compare(a.path, b.path))
  entries
}

///|
fn tree_ops_remove_missing_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  files : Map[String, TreeFileEntry],
  preserve_removed_gitlinks : Bool,
) -> Unit raise @bit.GitError {
  let entries = read_index_entries(rfs, git_dir)
  for entry in entries {
    if files.contains(entry.path) {
      continue
    }
    let path = join_path(root, entry.path)
    if rfs.is_file(path) {
      fs.remove_file(path)
    } else if is_gitlink_mode_int(entry.mode) && rfs.is_dir(path) {
      let bit_marker = join_path(path, ".git")
      if preserve_removed_gitlinks &&
        (rfs.is_file(bit_marker) || rfs.is_dir(bit_marker)) {
        continue
      }
      remove_worktree_path_recursive(fs, rfs, path)
    }
  }
}

///|
fn tree_ops_prepare_blob_path(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  full_path : String,
  path : String,
) -> Unit raise @bit.GitError {
  if not(rfs.is_dir(full_path)) {
    return
  }
  let bit_marker = join_path(full_path, ".git")
  if rfs.is_file(bit_marker) || rfs.is_dir(bit_marker) {
    raise @bit.GitError::InvalidObject(
      "Refusing to overwrite submodule: \{path}",
    )
  }
  remove_worktree_path_recursive(fs, rfs, full_path)
}

///|
pub fn write_worktree_from_files(
  db : ObjectDb,
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  files : Map[String, TreeFileEntry],
  remove_missing? : Bool = false,
  preserve_removed_gitlinks? : Bool = false,
) -> Unit raise @bit.GitError {
  if remove_missing {
    tree_ops_remove_missing_paths(
      fs, rfs, root, git_dir, files, preserve_removed_gitlinks,
    )
  }
  let autocrlf = read_autocrlf_setting(rfs, git_dir)
  let core_eol = read_core_eol_setting(rfs, git_dir)
  let items = files.to_array()
  items.sort_by((left, right) => {
    let (left_path, _) = left
    let (right_path, _) = right
    String::compare(left_path, right_path)
  })
  let gitmodules_content = tree_ops_read_target_gitmodules_content(
    db, rfs, files,
  )
  let paths : Array[String] = []
  for item in items {
    let (path, _) = item
    paths.push(path)
  }
  let skip_paths = detect_case_insensitive_collision_skips(
    fs, rfs, git_dir, paths,
  )
  for item in items {
    let (path, info) = item
    let skip_write = skip_paths.contains(path)
    if skip_write {
      continue
    }
    if is_gitlink_mode_int(info.mode) {
      restore_gitlink_worktree(
        fs,
        rfs,
        root,
        git_dir,
        path,
        info.id,
        gitmodules_content~,
      )
      continue
    }
    let full_path = join_path(root, path)
    tree_ops_prepare_blob_path(fs, rfs, full_path, path)
    let obj = db.get(rfs, info.id)
    match obj {
      None =>
        raise @bit.GitError::InvalidObject(
          "Missing blob object: " + info.id.to_hex(),
        )
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Blob {
          raise @bit.GitError::InvalidObject("Object is not a blob")
        }
        let full_path = join_path(root, path)
        let dir = parent_dir(full_path)
        fs.mkdir_p(dir)
        let attrs = resolve_eol_attrs(rfs, root, path)
        let output = smudge_for_checkout(o.data, attrs, autocrlf, core_eol~)
        fs.write_file(full_path, output)
      }
    }
  }
}

///|
/// Combined worktree write + index build — reads each blob only once.
pub fn write_worktree_and_build_index(
  db : ObjectDb,
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  files : Map[String, TreeFileEntry],
  remove_missing? : Bool = false,
  preserve_removed_gitlinks? : Bool = false,
) -> Array[IndexEntry] raise @bit.GitError {
  if remove_missing {
    tree_ops_remove_missing_paths(
      fs, rfs, root, git_dir, files, preserve_removed_gitlinks,
    )
  }
  let autocrlf = read_autocrlf_setting(rfs, git_dir)
  let core_eol = read_core_eol_setting(rfs, git_dir)
  let items = files.to_array()
  items.sort_by((left, right) => {
    let (left_path, _) = left
    let (right_path, _) = right
    String::compare(left_path, right_path)
  })
  let gitmodules_content = tree_ops_read_target_gitmodules_content(
    db, rfs, files,
  )
  let paths : Array[String] = []
  for item in items {
    let (path, _) = item
    paths.push(path)
  }
  let skip_paths = detect_case_insensitive_collision_skips(
    fs, rfs, git_dir, paths,
  )
  let index_entries : Array[IndexEntry] = []
  for item in items {
    let (path, info) = item
    let skip_write = skip_paths.contains(path)
    if is_gitlink_mode_int(info.mode) {
      if not(skip_write) {
        restore_gitlink_worktree(
          fs,
          rfs,
          root,
          git_dir,
          path,
          info.id,
          gitmodules_content~,
        )
      }
      index_entries.push({
        path,
        id: info.id,
        mode: info.mode,
        size: 0,
        mtime_sec: 0,
        mtime_nsec: 0,
        intent_to_add: false,
        dev: 0,
        ino: 0,
        uid: 0,
        gid: 0,
      })
      continue
    }
    if not(skip_write) {
      let full_path = join_path(root, path)
      tree_ops_prepare_blob_path(fs, rfs, full_path, path)
    }
    let obj = db.get(rfs, info.id)
    match obj {
      None =>
        raise @bit.GitError::InvalidObject(
          "Missing blob object: " + info.id.to_hex(),
        )
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Blob {
          raise @bit.GitError::InvalidObject("Object is not a blob")
        }
        let full_path = join_path(root, path)
        if not(skip_write) {
          let dir = parent_dir(full_path)
          fs.mkdir_p(dir)
          let attrs = resolve_eol_attrs(rfs, root, path)
          let output = smudge_for_checkout(o.data, attrs, autocrlf, core_eol~)
          fs.write_file(full_path, output)
        }
        // Get actual mtime from the file we just wrote
        let (mtime_sec, mtime_nsec) = match
          @bitio.worktree_entry_meta_sync(rfs, full_path) {
          Some(meta) => meta.mtime()
          None => (0, 0)
        }
        index_entries.push({
          path,
          id: info.id,
          mode: info.mode,
          size: o.data.length(),
          mtime_sec,
          mtime_nsec,
          intent_to_add: false,
          dev: 0,
          ino: 0,
          uid: 0,
          gid: 0,
        })
      }
    }
  }
  index_entries
}

///|
fn collect_tree_files_inner(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  out : Map[String, TreeFileEntry],
) -> Unit raise @bit.GitError {
  let tree_obj = db.get(fs, tree_id)
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
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if is_tree_mode(entry.mode) {
          collect_tree_files_inner(db, fs, entry.id, path, out)
        } else {
          let mode = worktree_parse_octal(entry.mode)
          out[path] = { id: entry.id, mode }
        }
      }
    }
  }
}
