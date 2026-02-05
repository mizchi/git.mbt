///| Repository maintenance: repack + gc

///|
pub struct RepackResult {
  pack_id : @git.ObjectId
  object_count : Int
  pack_bytes : Int
}

///|
pub struct GcResult {
  pack : RepackResult?
  dangling : Array[@git.ObjectId]
}

///|
pub struct PruneResult {
  pruned : Array[@git.ObjectId]
}

///|
/// Repack reachable objects from refs under the repository root.
pub fn repack_repo(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> RepackResult? raise @git.GitError {
  let git_dir = root + "/.git"
  repack_git_dir(fs, rfs, git_dir)
}

///|
/// Run a lightweight gc: repack reachable objects and report unreachable ids.
pub fn gc_repo(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> GcResult raise @git.GitError {
  let git_dir = root + "/.git"
  gc_git_dir(fs, rfs, git_dir)
}

///|
/// Prune unreachable loose objects (skip if there are no refs).
pub fn prune_repo(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> PruneResult raise @git.GitError {
  let git_dir = root + "/.git"
  prune_git_dir(fs, rfs, git_dir)
}

///|
fn repack_git_dir(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> RepackResult? raise @git.GitError {
  let ref_ids = collect_ref_ids(rfs, git_dir)
  if ref_ids.length() == 0 {
    return None
  }
  let db = ObjectDb::load(rfs, git_dir)
  let roots = resolve_commit_roots(db, rfs, ref_ids)
  if roots.length() == 0 {
    return None
  }
  let objects = collect_reachable_objects_from_commits(db, rfs, roots)
  repack_from_objects(fs, git_dir, objects)
}

///|
fn gc_git_dir(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> GcResult raise @git.GitError {
  let ref_ids = collect_ref_ids(rfs, git_dir)
  let db = ObjectDb::load(rfs, git_dir)
  let roots = resolve_commit_roots(db, rfs, ref_ids)
  let prune_enabled = roots.length() > 0
  let reachable = if roots.length() == 0 {
    []
  } else {
    collect_reachable_objects_from_commits(db, rfs, roots)
  }
  let reachable_hex : Map[String, Bool] = {}
  for obj in reachable {
    let id = @git.hash_object_content(obj.obj_type, obj.data)
    reachable_hex[id.to_hex()] = true
  }
  let store = load_object_store_from_fs(rfs, git_dir)
  let unreachable_hex : Array[String] = []
  for item in store.objects.to_array() {
    let (hex, _) = item
    if not(reachable_hex.contains(hex)) {
      unreachable_hex.push(hex)
    }
  }
  unreachable_hex.sort()
  let dangling : Array[@git.ObjectId] = []
  for hex in unreachable_hex {
    dangling.push(@git.ObjectId::from_hex(hex))
  }
  let pack = repack_from_objects(fs, git_dir, reachable)
  if prune_enabled {
    let remove_reachable = match pack {
      Some(_) => true
      None => false
    }
    prune_loose_objects(fs, rfs, git_dir, reachable_hex, remove_reachable)
    match pack {
      Some(info) => prune_packfiles(fs, rfs, git_dir, info.pack_id)
      None => ()
    }
  }
  { pack, dangling }
}

///|
fn prune_git_dir(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> PruneResult raise @git.GitError {
  let ref_ids = collect_ref_ids(rfs, git_dir)
  let db = ObjectDb::load(rfs, git_dir)
  let roots = resolve_commit_roots(db, rfs, ref_ids)
  if roots.length() == 0 {
    return { pruned: [] }
  }
  let reachable = collect_reachable_objects_from_commits(db, rfs, roots)
  let reachable_hex : Map[String, Bool] = {}
  for obj in reachable {
    let id = @git.hash_object_content(obj.obj_type, obj.data)
    reachable_hex[id.to_hex()] = true
  }
  let loose_hex = list_loose_object_hex(rfs, git_dir)
  let pruned : Array[@git.ObjectId] = []
  for hex in loose_hex {
    if not(reachable_hex.contains(hex)) {
      pruned.push(@git.ObjectId::from_hex(hex))
    }
  }
  prune_loose_objects(fs, rfs, git_dir, reachable_hex, false)
  { pruned, }
}

///|
fn repack_from_objects(
  fs : &@git.FileSystem,
  git_dir : String,
  objects : Array[@git.PackObject],
) -> RepackResult? raise @git.GitError {
  if objects.length() == 0 {
    return None
  }
  let pack = @git.create_packfile(objects)
  // Force index rebuild from the newly created pack to avoid stale offsets/CRC
  // carried from source packs.
  let objects_for_index : Array[@git.PackObject] = []
  for obj in objects {
    objects_for_index.push(
      @git.PackObject::with_metadata(obj.obj_type, obj.data, obj.id, -1, 0U),
    )
  }
  @git.write_packfile_with_index(fs, git_dir, pack, objects_for_index)
  let pack_id = pack_trailer_id(pack)
  Some({ pack_id, object_count: objects.length(), pack_bytes: pack.length() })
}

///|
fn pack_trailer_id(pack : Bytes) -> @git.ObjectId raise @git.GitError {
  if pack.length() < 20 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  let start = pack.length() - 20
  let bytes = FixedArray::makei(20, fn(i) { pack[start + i] })
  @git.ObjectId::new(bytes)
}

///|
fn collect_ref_ids(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[@git.ObjectId] raise @git.GitError {
  let refs : Map[String, @git.ObjectId] = {}
  let heads_dir = join_path(git_dir, "refs/heads")
  if fs.is_dir(heads_dir) {
    collect_loose_refs(fs, heads_dir, "refs/heads", refs)
  }
  let tags_dir = join_path(git_dir, "refs/tags")
  if fs.is_dir(tags_dir) {
    collect_loose_refs(fs, tags_dir, "refs/tags", refs)
  }
  let remotes_dir = join_path(git_dir, "refs/remotes")
  if fs.is_dir(remotes_dir) {
    collect_loose_refs(fs, remotes_dir, "refs/remotes", refs)
  }
  let packed_path = join_path(git_dir, "packed-refs")
  if fs.is_file(packed_path) {
    collect_packed_refs(fs, packed_path, refs)
  }
  let (head, _) = list_branches(fs, git_dir)
  match head {
    Detached(id) => refs["HEAD"] = id
    Branch(_) => ()
  }
  let out : Array[@git.ObjectId] = []
  for item in refs.to_array() {
    let (_, id) = item
    out.push(id)
  }
  out
}

///|
fn collect_loose_refs(
  fs : &@git.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Map[String, @git.ObjectId],
) -> Unit raise @git.GitError {
  let entries = fs.readdir(dir)
  for name in entries {
    let path = join_path(dir, name)
    let refname = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      collect_loose_refs(fs, path, refname, out)
    } else if fs.is_file(path) {
      let line = read_ref_line_gc(fs, path)
      out[refname] = @git.ObjectId::from_hex(line)
    }
  }
}

///|
fn collect_packed_refs(
  fs : &@git.RepoFileSystem,
  packed_path : String,
  out : Map[String, @git.ObjectId],
) -> Unit raise @git.GitError {
  let prefixes : Array[String] = ["refs/heads/", "refs/tags/", "refs/remotes/"]
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line_gc(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => ()
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
        let mut matched = false
        for prefix in prefixes {
          if refname.has_prefix(prefix) {
            matched = true
          }
        }
        if matched && not(out.contains(refname)) {
          out[refname] = @git.ObjectId::from_hex(id_hex)
        }
      }
    }
  }
}

///|
fn read_ref_line_gc(
  fs : &@git.RepoFileSystem,
  path : String,
) -> String raise @git.GitError {
  let text = @utf8.decode_lossy(fs.read_file(path)[:])
  for line_view in text.split("\n") {
    let line = trim_line_gc(line_view.to_string())
    if line.length() > 0 {
      return line
    }
  }
  raise @git.GitError::InvalidObject("Empty ref: \{path}")
}

///|
fn trim_line_gc(line : String) -> String {
  let mut s = line
  if s.has_suffix("\r") {
    s = String::unsafe_substring(s, start=0, end=s.length() - 1)
  }
  s
}

///|
fn resolve_commit_roots(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  ref_ids : Array[@git.ObjectId],
) -> Array[@git.ObjectId] raise @git.GitError {
  let seen : Map[String, Bool] = {}
  let roots : Array[@git.ObjectId] = []
  for id in ref_ids {
    let local_seen : Map[String, Bool] = {}
    match resolve_commit_from_ref(db, fs, id, local_seen) {
      None => ()
      Some(commit_id) => {
        let hex = commit_id.to_hex()
        if not(seen.contains(hex)) {
          seen[hex] = true
          roots.push(commit_id)
        }
      }
    }
  }
  roots
}

///|
fn resolve_commit_from_ref(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
  seen : Map[String, Bool],
) -> @git.ObjectId? raise @git.GitError {
  let hex = id.to_hex()
  if seen.contains(hex) {
    return None
  }
  seen[hex] = true
  match db.get(fs, id) {
    None => None
    Some(obj) =>
      match obj.obj_type {
        @git.ObjectType::Commit => Some(id)
        @git.ObjectType::Tag =>
          match parse_tag_target(obj.data) {
            None => None
            Some((target, tag_type)) =>
              if tag_type == "commit" {
                Some(target)
              } else if tag_type == "tag" {
                resolve_commit_from_ref(db, fs, target, seen)
              } else {
                None
              }
          }
        _ => None
      }
  }
}

///|
fn parse_tag_target(
  data : Bytes,
) -> (@git.ObjectId, String)? raise @git.GitError {
  let text = @utf8.decode_lossy(data[:])
  let mut object_hex : String? = None
  let mut object_type : String? = None
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("object ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      object_hex = Some(hex)
    } else if line.has_prefix("type ") {
      let typ = String::unsafe_substring(line, start=5, end=line.length())
      object_type = Some(typ)
    }
  }
  match object_hex {
    None => None
    Some(hex) =>
      match object_type {
        None => None
        Some(typ) => Some((@git.ObjectId::from_hex(hex), typ))
      }
  }
}

///|
fn prune_loose_objects(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  keep : Map[String, Bool],
  remove_reachable : Bool,
) -> Unit raise @git.GitError {
  let objects_dir = join_path(git_dir, "objects")
  if not(rfs.is_dir(objects_dir)) {
    return
  }
  let entries = rfs.readdir(objects_dir)
  for entry in entries {
    if entry == "info" || entry == "pack" {
      continue
    }
    if entry.length() != 2 {
      continue
    }
    let dir = join_path(objects_dir, entry)
    if not(rfs.is_dir(dir)) {
      continue
    }
    let files = rfs.readdir(dir)
    for name in files {
      if name.length() != 38 {
        continue
      }
      let path = join_path(dir, name)
      if not(rfs.is_file(path)) {
        continue
      }
      let hex = entry + name
      if not(remove_reachable) && keep.contains(hex) {
        continue
      }
      fs.remove_file(path)
    }
  }
}

///|
fn list_loose_object_hex(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @git.GitError {
  let out : Array[String] = []
  let objects_dir = join_path(git_dir, "objects")
  if not(fs.is_dir(objects_dir)) {
    return out
  }
  let entries = fs.readdir(objects_dir)
  for entry in entries {
    if entry == "info" || entry == "pack" {
      continue
    }
    if entry.length() != 2 {
      continue
    }
    let dir = join_path(objects_dir, entry)
    if not(fs.is_dir(dir)) {
      continue
    }
    let files = fs.readdir(dir)
    for name in files {
      if name.length() != 38 {
        continue
      }
      let path = join_path(dir, name)
      if not(fs.is_file(path)) {
        continue
      }
      out.push(entry + name)
    }
  }
  out
}

///|
fn prune_packfiles(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  keep_pack_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let pack_dir = join_path(git_dir, "objects/pack")
  if not(rfs.is_dir(pack_dir)) {
    return
  }
  let base = "pack-" + keep_pack_id.to_hex()
  let keep_pack = base + ".pack"
  let keep_idx = base + ".idx"
  let entries = rfs.readdir(pack_dir)
  for entry in entries {
    if entry == keep_pack || entry == keep_idx {
      continue
    }
    if entry.has_suffix(".pack") || entry.has_suffix(".idx") {
      fs.remove_file(join_path(pack_dir, entry))
    }
  }
}
