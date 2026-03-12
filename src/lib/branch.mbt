///| Git branch listing (refs/heads + packed-refs)

///|
pub enum HeadRef {
  Branch(String)
  Detached(@bit.ObjectId)
}

///|
pub struct BranchInfo {
  name : String
  id : @bit.ObjectId
  current : Bool
}

///|
fn resolve_worktree_git_dir(
  fs : &@bit.RepoFileSystem,
  root : String,
) -> String raise @bit.GitError {
  let bit_path = join_path(root, ".git")
  if fs.is_dir(bit_path) {
    bit_path
  } else if fs.is_file(bit_path) {
    resolve_commondir(fs, resolve_gitdir(fs, bit_path))
  } else if fs.is_file(join_path(root, "HEAD")) &&
    fs.is_dir(join_path(root, "objects")) {
    root
  } else {
    bit_path
  }
}

///|
/// Read HEAD and return its reference.
pub fn read_head_ref(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> HeadRef raise @bit.GitError {
  let head_path = join_path(git_dir, "HEAD")
  match @bitio.read_symlink_target_path(head_path) {
    Some(target) if target.has_prefix("refs/") => {
      let name = if target.has_prefix("refs/heads/") {
        String::unsafe_substring(target, start=11, end=target.length())
      } else {
        target
      }
      return HeadRef::Branch(name)
    }
    _ => ()
  }
  let line = read_ref_line(fs, head_path)
  if line.has_prefix("ref: ") {
    let refname = String::unsafe_substring(line, start=5, end=line.length())
    let name = if refname.has_prefix("refs/heads/") {
      String::unsafe_substring(refname, start=11, end=refname.length())
    } else {
      refname
    }
    HeadRef::Branch(name)
  } else {
    let id = @bit.ObjectId::from_hex(line)
    HeadRef::Detached(id)
  }
}

///|
/// List local branches with current flag.
pub fn list_branches(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> (HeadRef, Array[BranchInfo]) raise @bit.GitError {
  let head = read_head_ref(fs, git_dir)
  let map : Map[String, @bit.ObjectId] = {}
  let heads_dir = join_path(git_dir, "refs/heads")
  if fs.is_dir(heads_dir) {
    collect_loose_heads(fs, heads_dir, "", map)
  }
  let packed_path = join_path(git_dir, "packed-refs")
  if fs.is_file(packed_path) {
    collect_packed_heads(fs, packed_path, map)
  }
  let branches : Array[BranchInfo] = []
  for item in map.to_array() {
    let (name, id) = item
    let current = match head {
      Branch(n) => n == name
      Detached(_) => false
    }
    branches.push({ name, id, current })
  }
  branches.sort_by((a, b) => String::compare(a.name, b.name))
  (head, branches)
}

///|
/// Format like `git branch` output.
pub fn list_branches_text(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @bit.GitError {
  let (head, branches) = list_branches(fs, git_dir)
  let lines : Array[String] = []
  match head {
    Detached(id) => {
      let short = @bithash.short_hex(id.to_hex(), 7)
      lines.push("* (HEAD detached at \{short})")
    }
    Branch(_) => ()
  }
  for b in branches {
    let mark = if b.current { "*" } else { " " }
    lines.push("\{mark} \{b.name}")
  }
  lines
}

///|
/// List branches with commit hash and subject (verbose mode).
pub fn list_branches_verbose(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @bit.GitError {
  let lines : Array[String] = []
  let (head, branches) = list_branches(fs, git_dir)
  let db = try! ObjectDb::load(fs, git_dir)
  // Find max branch name length for padding
  let mut max_len = 0
  for b in branches {
    if b.name.length() > max_len {
      max_len = b.name.length()
    }
  }
  for b in branches {
    let marker = match head {
      Branch(name) => if name == b.name { "* " } else { "  " }
      Detached(_) => "  "
    }
    let short_hash = (try! b.id.to_hex()[:7]).to_string()
    let subject = branch_get_commit_subject(db, fs, b.id)
    let padded_name = pad_right(b.name, max_len)
    lines.push("\{marker}\{padded_name} \{short_hash} \{subject}")
  }
  lines
}

///|
fn branch_get_commit_subject(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> String {
  let obj = db.get(fs, id) catch { _ => return "" }
  match obj {
    None => ""
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        return ""
      }
      extract_commit_subject(o.data)
    }
  }
}

///|
fn extract_commit_subject(data : Bytes) -> String {
  let text = @utf8.decode_lossy(data[:])
  let mut in_header = true
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_header {
      if line.length() == 0 {
        in_header = false
      }
      continue
    }
    // First non-empty line after blank line is the subject
    if line.length() > 0 {
      return line
    }
  }
  ""
}

///|
fn pad_right(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let buf = StringBuilder::new()
  buf.write_string(s)
  for i = s.length(); i < width; i = i + 1 {
    buf.write_char(' ')
  }
  buf.to_string()
}

///|
/// List remote tracking branches.
pub fn list_remote_branches(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] {
  let lines : Array[String] = []
  let refs_dir = join_path(git_dir, "refs/remotes")
  if not(fs.is_dir(refs_dir)) {
    return lines
  }
  // Walk refs/remotes directory
  collect_remote_refs(fs, refs_dir, "", lines)
  lines.sort()
  lines
}

///|
fn collect_remote_refs(
  fs : &@bit.RepoFileSystem,
  base_dir : String,
  prefix : String,
  out : Array[String],
) -> Unit {
  let entries = fs.readdir(base_dir) catch { _ => return () }
  for entry in entries {
    let path = join_path(base_dir, entry)
    let name = if prefix.length() > 0 { prefix + "/" + entry } else { entry }
    if fs.is_dir(path) {
      collect_remote_refs(fs, path, name, out)
    } else if fs.is_file(path) {
      out.push("  remotes/" + name)
    }
  }
}

///|
fn branch_is_bare_repo(
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
) -> Bool {
  normalize_path(root) == normalize_path(git_dir) &&
  rfs.is_file(join_path(root, "HEAD")) &&
  rfs.is_dir(join_path(root, "objects"))
}

///|
fn branch_creation_source_label(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  start_point : String?,
) -> String raise @bit.GitError {
  match start_point {
    Some(source) => source
    None =>
      match read_head_ref(rfs, git_dir) {
        Branch(name) => name
        Detached(_) => "HEAD"
      }
  }
}

///|
fn append_branch_creation_reflog(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  refname : String,
  new_id : @bit.ObjectId,
  start_point : String?,
  author : String,
  email : String,
  timestamp : Int64,
  timezone : String,
) -> Unit raise @bit.GitError {
  let is_bare = branch_is_bare_repo(rfs, root, git_dir)
  let (should_log, _) = should_log_ref(rfs, git_dir, refname, is_bare)
  if not(should_log) {
    return
  }
  let source_label = branch_creation_source_label(rfs, git_dir, start_point)
  append_reflog(
    fs,
    rfs,
    git_dir,
    refname,
    @bit.ObjectId::zero(),
    new_id,
    author,
    email,
    timestamp,
    timezone,
    "branch: Created from " + source_label,
  )
}

///|
/// Create a local branch pointing at current HEAD.
pub fn create_branch(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  name : String,
  start_point? : String? = None,
  author? : String = "unknown",
  email? : String = "unknown",
  timestamp? : Int64 = 0L,
  timezone? : String = "+0000",
) -> Unit raise @bit.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let refname = branch_ref_name(name)
  if resolve_ref(rfs, git_dir, refname) is Some(_) {
    match branch_checked_out_path(rfs, root, name) {
      Some(path) =>
        raise @bit.GitError::InvalidObject(
          "branch '\{name}' is checked out at '\{path}'",
        )
      None => ()
    }
  }
  let ref_path = join_path(git_dir, refname)
  let dir = parent_dir(ref_path)
  fs.mkdir_p(dir)
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None =>
      if rfs.is_file(ref_path) {
        fs.remove_file(ref_path) catch {
          _ => ()
        }
      }
    Some(id) => {
      fs.write_string(ref_path, id.to_hex() + "\n")
      append_branch_creation_reflog(
        fs, rfs, root, git_dir, refname, id, start_point, author, email, timestamp,
        timezone,
      )
    }
  }
}

///|
/// Create a local branch pointing at a specific commit.
pub fn create_branch_at(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  name : String,
  commit_id : @bit.ObjectId,
  start_point? : String? = None,
  author? : String = "unknown",
  email? : String = "unknown",
  timestamp? : Int64 = 0L,
  timezone? : String = "+0000",
) -> Unit raise @bit.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let refname = branch_ref_name(name)
  if resolve_ref(rfs, git_dir, refname) is Some(_) {
    match branch_checked_out_path(rfs, root, name) {
      Some(path) =>
        raise @bit.GitError::InvalidObject(
          "branch '\{name}' is checked out at '\{path}'",
        )
      None => ()
    }
  }
  let ref_path = join_path(git_dir, refname)
  let dir = parent_dir(ref_path)
  fs.mkdir_p(dir)
  fs.write_string(ref_path, commit_id.to_hex() + "\n")
  append_branch_creation_reflog(
    fs, rfs, root, git_dir, refname, commit_id, start_point, author, email, timestamp,
    timezone,
  )
}

///|
fn is_directory_empty(rfs : &@bit.RepoFileSystem, path : String) -> Bool {
  let entries = rfs.readdir(path) catch { _ => return false }
  for entry in entries {
    if entry != "." && entry != ".." {
      return false
    }
  }
  true
}

///|
fn prune_empty_ref_parent_dirs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  ref_path : String,
  stop_dir : String,
) -> Unit {
  let mut current = parent_dir(ref_path)
  while current.length() > 0 &&
        current != stop_dir &&
        current.has_prefix(stop_dir + "/") {
    if not(rfs.is_dir(current)) {
      break
    }
    if not(is_directory_empty(rfs, current)) {
      break
    }
    fs.remove_dir(current) catch {
      _ => break
    }
    current = parent_dir(current)
  }
}

///|
/// Delete a local branch. Fails if it's the current branch.
pub fn delete_branch(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  name : String,
  force? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  match branch_checked_out_path(rfs, root, name) {
    Some(path) =>
      raise @bit.GitError::InvalidObject(
        "Cannot delete branch '\{name}' checked out at '\{path}'",
      )
    None => ()
  }
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  // Check if branch exists
  let exists = rfs.is_file(ref_path) ||
    resolve_packed_ref(rfs, join_path(git_dir, "packed-refs"), refname)
    is Some(_)
  if not(exists) {
    raise @bit.GitError::InvalidObject("branch '\{name}' not found")
  }
  // Check if branch is fully merged (unless force)
  if not(force) {
    let head_commit = resolve_head_commit(rfs, git_dir)
    let branch_id = match resolve_ref(rfs, git_dir, refname) {
      Some(id) => id
      None => raise @bit.GitError::InvalidObject("branch '\{name}' not found")
    }
    match head_commit {
      Some(head_id) =>
        if not(is_ancestor_of(rfs, git_dir, branch_id, head_id)) {
          raise @bit.GitError::InvalidObject(
            "The branch '\{name}' is not fully merged.\nIf you are sure you want to delete it, run 'git branch -D \{name}'.",
          )
        }
      None => ()
    }
  }
  // Delete loose ref if it exists
  if rfs.is_file(ref_path) {
    fs.remove_file(ref_path)
    prune_empty_ref_parent_dirs(
      fs,
      rfs,
      ref_path,
      join_path(git_dir, "refs/heads"),
    )
  }
  // Remove from packed-refs if present
  let packed_path = join_path(git_dir, "packed-refs")
  if rfs.is_file(packed_path) {
    remove_from_packed_refs(fs, rfs, packed_path, refname)
  }
  delete_reflog(fs, rfs, git_dir, refname)
  prune_empty_ref_parent_dirs(
    fs,
    rfs,
    join_path(git_dir, "logs/" + refname),
    join_path(git_dir, "logs/refs/heads"),
  )
}

///|
/// Rename a local branch.
pub fn rename_branch(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  old_name : String,
  new_name : String,
  force? : Bool = false,
  author? : String = "Unknown",
  email? : String = "unknown@localhost",
  timestamp? : Int64 = 0L,
  timezone? : String = "+0000",
) -> Unit raise @bit.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let old_ref = branch_ref_name(old_name)
  let new_ref = branch_ref_name(new_name)
  let old_path = join_path(git_dir, old_ref)
  let new_path = join_path(git_dir, new_ref)
  if old_name != new_name {
    match branch_checked_out_path(rfs, root, new_name) {
      Some(path) =>
        raise @bit.GitError::InvalidObject(
          "branch '\{new_name}' is checked out at '\{path}'",
        )
      None => ()
    }
  }
  let checked_out_head_paths = branch_checked_out_head_paths(
    rfs, root, git_dir, old_name,
  )
  let old_id = match resolve_ref(rfs, git_dir, old_ref) {
    Some(id) => id
    None => raise @bit.GitError::InvalidObject("branch '\{old_name}' not found")
  }
  let old_log = join_path(git_dir, "logs/" + old_ref)
  let old_log_data = if rfs.is_file(old_log) {
    Some(rfs.read_file(old_log))
  } else {
    None
  }
  let packed_path = join_path(git_dir, "packed-refs")
  validate_branch_rename_target_path(rfs, git_dir, old_path, old_ref, new_ref)
  let new_packed_exists = if rfs.is_file(packed_path) {
    resolve_packed_ref(rfs, packed_path, new_ref) is Some(_)
  } else {
    false
  }
  let new_exists = (
      rfs.is_file(new_path) &&
      not(branch_is_dangling_symref(rfs, git_dir, new_ref, new_path))
    ) ||
    new_packed_exists
  if new_exists {
    if not(force) {
      raise @bit.GitError::InvalidObject("branch '\{new_name}' already exists")
    }
    if rfs.is_file(new_path) {
      fs.remove_file(new_path)
    }
    if rfs.is_file(packed_path) {
      remove_from_packed_refs(fs, rfs, packed_path, new_ref)
    }
  }
  if rfs.is_file(old_path) {
    fs.remove_file(old_path)
    prune_empty_ref_parent_dirs(
      fs,
      rfs,
      old_path,
      join_path(git_dir, "refs/heads"),
    )
  }
  if rfs.is_file(packed_path) {
    remove_from_packed_refs(fs, rfs, packed_path, old_ref)
  }
  if rfs.is_file(old_log) {
    fs.remove_file(old_log)
    prune_empty_ref_parent_dirs(
      fs,
      rfs,
      old_log,
      join_path(git_dir, "logs/refs/heads"),
    )
  }
  let dir = parent_dir(new_path)
  fs.mkdir_p(dir)
  fs.write_string(new_path, old_id.to_hex() + "\n")
  let rename_message = "Branch: renamed \{old_ref} to \{new_ref}"
  match old_log_data {
    Some(data) => {
      let new_log = join_path(git_dir, "logs/" + new_ref)
      let parent = parent_dir(new_log)
      fs.mkdir_p(parent)
      fs.write_file(new_log, data)
    }
    None => ()
  }
  append_reflog(
    fs, rfs, git_dir, new_ref, old_id, old_id, author, email, timestamp, timezone,
    rename_message,
  )
  let main_head_path = join_path(git_dir, "HEAD")
  let mut had_locked_worktree_head = false
  for head_path in checked_out_head_paths {
    let lock_path = head_path + ".lock"
    if rfs.is_file(lock_path) {
      had_locked_worktree_head = true
      continue
    }
    fs.write_string(head_path, "ref: \{new_ref}\n")
    if head_path == main_head_path {
      append_reflog(
        fs, rfs, git_dir, "HEAD", old_id, old_id, author, email, timestamp, timezone,
        rename_message,
      )
    }
  }
  if had_locked_worktree_head {
    raise @bit.GitError::InvalidObject(
      "failed to update HEAD for one or more worktrees",
    )
  }
}

///|
fn branch_checked_out_path(
  rfs : &@bit.RepoFileSystem,
  root : String,
  branch : String,
) -> String? raise @bit.GitError {
  is_branch_checked_out(rfs, root, branch)
}

///|
fn branch_checked_out_head_paths(
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  branch : String,
) -> Array[String] raise @bit.GitError {
  let head_paths : Array[String] = []
  let worktrees = list_worktrees(rfs, root)
  for wt in worktrees {
    match wt.branch {
      Some(b) if b == branch =>
        if wt.is_main {
          head_paths.push(join_path(git_dir, "HEAD"))
        } else {
          match find_worktree_admin_dir(rfs, git_dir, wt.path) {
            Some(admin_dir) => head_paths.push(join_path(admin_dir, "HEAD"))
            None => ()
          }
        }
      _ => ()
    }
  }
  head_paths
}

///|
fn branch_is_dangling_symref(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
  ref_path : String,
) -> Bool raise @bit.GitError {
  if not(rfs.is_file(ref_path)) {
    return false
  }
  let line = read_ref_line(rfs, ref_path)
  if not(line.has_prefix("ref: ")) {
    return false
  }
  resolve_ref(rfs, git_dir, refname) is None
}

///|
fn validate_branch_rename_target_path(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  old_path : String,
  old_ref : String,
  new_ref : String,
) -> Unit raise @bit.GitError {
  let parts : Array[String] = []
  for part_view in new_ref.split("/") {
    parts.push(part_view.to_string())
  }
  let mut current = git_dir
  for i in 0..<(parts.length() - 1) {
    current = join_path(current, parts[i])
    if rfs.is_file(current) && current != old_path {
      raise @bit.GitError::InvalidObject("branch '\{new_ref}' already exists")
    }
  }
  let new_path = join_path(git_dir, new_ref)
  if rfs.is_dir(new_path) && not(old_ref.has_prefix(new_ref + "/")) {
    raise @bit.GitError::InvalidObject("branch '\{new_ref}' already exists")
  }
}

///|
fn remove_from_packed_refs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  packed_path : String,
  refname : String,
) -> Unit raise @bit.GitError {
  let text = @utf8.decode_lossy(rfs.read_file(packed_path)[:])
  let lines : Array[String] = []
  let mut found = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      continue
    }
    // Check if this line is for the ref we want to remove
    let space = line.find(" ")
    match space {
      None => lines.push(line)
      Some(idx) => {
        if idx + 1 >= line.length() {
          lines.push(line)
          continue
        }
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == refname {
          found = true
        } else {
          lines.push(line)
        }
      }
    }
  }
  if found {
    let new_content = lines.join("\n") + "\n"
    fs.write_string(packed_path, new_content)
  }
}

///|
/// Switch HEAD to a branch, optionally creating it and checking out files.
pub fn switch_branch(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  name : String,
  create? : Bool = false,
  checkout_files? : Bool = true,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  if create {
    create_branch(fs, rfs, root, name)
  } else if not(rfs.is_file(ref_path)) {
    match resolve_ref(rfs, git_dir, refname) {
      None => raise @bit.GitError::InvalidObject("Invalid ref: \{name}")
      Some(_) => ()
    }
  }
  if checkout_files {
    ignore(checkout(fs, rfs, root, name))
    if is_sparse_checkout_enabled(rfs, git_dir) {
      sparse_checkout_reapply(fs, rfs, root)
    }
  } else {
    let head_path = join_path(git_dir, "HEAD")
    fs.write_string(head_path, "ref: \{refname}\n")
  }
}

///|
/// Resolve a ref to an object id.
pub fn resolve_ref(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @bit.ObjectId? raise @bit.GitError {
  // Try reftable first if the repo uses reftable ref storage
  if fs.is_dir(join_path(git_dir, "reftable")) {
    match @reftable.resolve_ref_reftable(fs, git_dir, refname) {
      Some(oid) => return Some(oid)
      None => ()
    }
  }
  let normalized = normalize_repo_path(refname) catch { _ => return None }
  resolve_ref_inner(fs, git_dir, normalized, 0)
}

///|
fn resolve_ref_commondir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String? {
  let commondir_path = join_path(git_dir, "commondir")
  if not(fs.is_file(commondir_path)) {
    return None
  }
  let rel = read_ref_line(fs, commondir_path) catch { _ => "" }
  if rel.length() == 0 {
    return None
  }
  if rel.has_prefix("/") {
    return Some(normalize_path(rel))
  }
  Some(normalize_path(join_path(git_dir, rel)))
}

///|
fn resolve_ref_inner(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> @bit.ObjectId? raise @bit.GitError {
  let refname = normalize_repo_path(refname) catch { _ => return None }
  if depth > 8 {
    return None
  }
  let path = join_path(git_dir, refname)
  if fs.is_file(path) {
    let line = read_ref_line(fs, path)
    if line.has_prefix("ref: ") {
      let target = String::unsafe_substring(line, start=5, end=line.length())
      return resolve_ref_inner(fs, git_dir, target, depth + 1)
    }
    return parse_ref_object_id(line)
  }
  match resolve_ref_commondir(fs, git_dir) {
    Some(common_git_dir) =>
      if common_git_dir != git_dir {
        match resolve_ref_inner(fs, common_git_dir, refname, depth + 1) {
          Some(id) => return Some(id)
          None => ()
        }
      }
    None => ()
  }
  let packed = join_path(git_dir, "packed-refs")
  if fs.is_file(packed) {
    return resolve_packed_ref(fs, packed, refname)
  }
  None
}

///|
fn collect_loose_heads(
  fs : &@bit.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Map[String, @bit.ObjectId],
) -> Unit raise @bit.GitError {
  let entries = fs.readdir(dir)
  for name in entries {
    let path = join_path(dir, name)
    let rel = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      collect_loose_heads(fs, path, rel, out)
    } else if fs.is_file(path) {
      let line = read_ref_line(fs, path)
      match parse_ref_object_id(line) {
        Some(id) => out[rel] = id
        None => ()
      }
    }
  }
}

///|
fn collect_packed_heads(
  fs : &@bit.RepoFileSystem,
  packed_path : String,
  out : Map[String, @bit.ObjectId],
) -> Unit raise @bit.GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if not(refname.has_prefix("refs/heads/")) {
          continue
        }
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        if not(out.contains(name)) {
          match parse_ref_object_id(id_hex) {
            Some(id) => out[name] = id
            None => ()
          }
        }
      }
    }
  }
}

///|
fn branch_ref_name(name : String) -> String raise @bit.GitError {
  let normalized = normalize_repo_path(name) catch {
    _ => raise @bit.GitError::InvalidObject("invalid branch name: " + name)
  }
  if normalized.has_prefix("refs/heads/") {
    normalized
  } else {
    "refs/heads/" + normalized
  }
}

///|
fn normalize_tag_ref(name : String) -> String raise @bit.GitError {
  let normalized = normalize_repo_path(name) catch {
    _ => raise @bit.GitError::InvalidObject("invalid tag name: " + name)
  }
  if normalized.has_prefix("refs/tags/") {
    normalized
  } else {
    "refs/tags/" + normalized
  }
}

///|
fn resolve_packed_ref(
  fs : &@bit.RepoFileSystem,
  packed_path : String,
  refname : String,
) -> @bit.ObjectId? raise @bit.GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == refname {
          return parse_ref_object_id(id_hex)
        }
      }
    }
  }
  None
}

///|
fn parse_ref_object_id(hex : String) -> @bit.ObjectId? raise @bit.GitError {
  // lib/object currently represents only SHA-1 ObjectId values.
  // Treat SHA-256 refs as unresolved so callers can degrade gracefully.
  if hex.length() == 64 {
    return None
  }
  Some(@bit.ObjectId::from_hex(hex))
}

///|
fn read_ref_line(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> String raise @bit.GitError {
  let text = @utf8.decode_lossy(fs.read_file(path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() > 0 {
      return line
    }
  }
  raise @bit.GitError::InvalidObject("Empty ref: \{path}")
}

///|
fn trim_line(line : String) -> String {
  let mut s = line
  if s.has_suffix("\r") {
    s = String::unsafe_substring(s, start=0, end=s.length() - 1)
  }
  s
}

///|
/// List all tags.
pub fn list_tags(fs : &@bit.RepoFileSystem, git_dir : String) -> Array[String] {
  let tags : Array[String] = []
  let refs_dir = join_path(git_dir, "refs/tags")
  if fs.is_dir(refs_dir) {
    collect_tag_names(fs, refs_dir, "", tags)
  }
  // Also check packed-refs
  let packed_path = join_path(git_dir, "packed-refs")
  if fs.is_file(packed_path) {
    collect_packed_tags(fs, packed_path, tags)
  }
  tags.sort()
  tags
}

///|
fn collect_tag_names(
  fs : &@bit.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Array[String],
) -> Unit {
  let entries = fs.readdir(dir) catch { _ => return () }
  for entry in entries {
    let path = join_path(dir, entry)
    let name = if prefix.length() > 0 { prefix + "/" + entry } else { entry }
    if fs.is_dir(path) {
      collect_tag_names(fs, path, name, out)
    } else if fs.is_file(path) {
      if not(out.contains(name)) {
        out.push(name)
      }
    }
  }
}

///|
fn collect_packed_tags(
  fs : &@bit.RepoFileSystem,
  packed_path : String,
  out : Array[String],
) -> Unit {
  let text = @utf8.decode_lossy(
    (fs.read_file(packed_path) catch { _ => return () })[:],
  )
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if refname.has_prefix("refs/tags/") {
          let name = String::unsafe_substring(
            refname,
            start=10,
            end=refname.length(),
          )
          if not(out.contains(name)) {
            out.push(name)
          }
        }
      }
    }
  }
}

///|
/// Delete a tag.
pub fn delete_tag(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit raise @bit.GitError {
  let refname = normalize_tag_ref(name)
  let ref_path = join_path(git_dir, refname)
  if rfs.is_file(ref_path) {
    fs.remove_file(ref_path)
    prune_empty_ref_parent_dirs(
      fs,
      rfs,
      ref_path,
      join_path(git_dir, "refs/tags"),
    )
  }
  delete_reflog(fs, rfs, git_dir, refname)
  prune_empty_ref_parent_dirs(
    fs,
    rfs,
    join_path(git_dir, "logs/" + refname),
    join_path(git_dir, "logs/refs/tags"),
  )
}

///|
/// Create a lightweight tag.
pub fn create_lightweight_tag(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  name : String,
  target : @bit.ObjectId,
) -> Unit raise @bit.GitError {
  let refname = normalize_tag_ref(name)
  validate_tag_ref_path(rfs, git_dir, refname)
  let ref_path = join_path(git_dir, refname)
  fs.mkdir_p(parent_dir(ref_path))
  fs.write_string(ref_path, target.to_hex() + "\n")
}

///|
/// Create an annotated tag.
pub fn create_annotated_tag(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  name : String,
  target : @bit.ObjectId,
  message : String,
  tagger : String,
  timestamp : Int64,
  timezone? : String = "+0000",
) -> Unit raise @bit.GitError {
  let db = ObjectDb::load(rfs, git_dir)
  let target_obj = db.get(rfs, target)
  guard target_obj is Some(obj) else {
    raise @bit.GitError::InvalidObject("unknown object: \{target.to_hex()}")
  }
  let refname = normalize_tag_ref(name)
  validate_tag_ref_path(rfs, git_dir, refname)
  let target_type = match obj.obj_type {
    @bit.ObjectType::Blob => "blob"
    @bit.ObjectType::Tree => "tree"
    @bit.ObjectType::Commit => "commit"
    @bit.ObjectType::Tag => "tag"
  }
  // Create tag object
  let tag_content = if message.length() == 0 {
    "object \{target.to_hex()}\ntype \{target_type}\ntag \{name}\ntagger \{tagger} \{timestamp} \{timezone}\n\n"
  } else {
    "object \{target.to_hex()}\ntype \{target_type}\ntag \{name}\ntagger \{tagger} \{timestamp} \{timezone}\n\n\{message}\n"
  }
  let tag_bytes = @utf8.encode(tag_content)
  let (tag_id, compressed) = @bit.create_object(@bit.ObjectType::Tag, tag_bytes)
  write_object_bytes(fs, git_dir, tag_id, compressed)
  // Create ref pointing to tag object
  let ref_path = join_path(git_dir, refname)
  fs.mkdir_p(parent_dir(ref_path))
  fs.write_string(ref_path, tag_id.to_hex() + "\n")
}

///|
fn validate_tag_ref_path(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Unit raise @bit.GitError {
  let parts : Array[String] = []
  for part_view in refname.split("/") {
    parts.push(part_view.to_string())
  }
  let mut current = git_dir
  for i in 0..<(parts.length() - 1) {
    current = join_path(current, parts[i])
    if rfs.is_file(current) {
      raise @bit.GitError::InvalidObject(
        "cannot create ref due to path conflict: \{refname}",
      )
    }
  }
  let ref_path = join_path(git_dir, refname)
  if rfs.is_dir(ref_path) {
    raise @bit.GitError::InvalidObject(
      "cannot create ref due to path conflict: \{refname}",
    )
  }
  let packed_path = join_path(git_dir, "packed-refs")
  if has_packed_ref_path_conflict(rfs, packed_path, refname) {
    raise @bit.GitError::InvalidObject(
      "cannot create ref due to path conflict: \{refname}",
    )
  }
}

///|
fn has_packed_ref_path_conflict(
  fs : &@bit.RepoFileSystem,
  packed_path : String,
  refname : String,
) -> Bool {
  if not(fs.is_file(packed_path)) {
    return false
  }
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:]) catch {
    _ => return false
  }
  let refname_prefix = refname + "/"
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    guard space is Some(idx) else { continue }
    if idx + 1 >= line.length() {
      continue
    }
    let name = String::unsafe_substring(line, start=idx + 1, end=line.length())
    if name.has_prefix(refname_prefix) || refname.has_prefix(name + "/") {
      return true
    }
  }
  false
}

///|
/// Check if `ancestor` is an ancestor of `descendant` via BFS.
pub fn is_ancestor_of(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  ancestor : @bit.ObjectId,
  descendant : @bit.ObjectId,
) -> Bool {
  if ancestor == descendant {
    return true
  }
  let db = ObjectDb::load(fs, git_dir) catch { _ => return false }
  let ancestor_hex = ancestor.to_hex()
  let visited : Map[String, Bool] = {}
  let queue : Array[@bit.ObjectId] = [descendant]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if hex == ancestor_hex {
      return true
    }
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    let obj = db.get(fs, cid) catch { _ => continue }
    match obj {
      Some(o) => {
        let info = @bit.parse_commit(o.data) catch { _ => continue }
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  false
}
