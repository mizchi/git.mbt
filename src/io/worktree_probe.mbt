///|
pub enum WorktreeKind {
  Regular
  Symlink(target~ : String)
}

///|
pub struct WorktreeEntry {
  kind : WorktreeKind
  mode : Int
  size : Int?
  mtime_sec : Int?
  mtime_nsec : Int?
}

///|
pub enum WorktreeKindMeta {
  Regular
  Symlink
}

///|
pub struct WorktreeEntryMeta {
  kind : WorktreeKindMeta
  mode : Int
  size : Int?
  mtime_sec : Int?
  mtime_nsec : Int?
}

///|
pub fn WorktreeKindMeta::regular() -> WorktreeKindMeta {
  Regular
}

///|
pub fn WorktreeKindMeta::symlink() -> WorktreeKindMeta {
  Symlink
}

///|
pub fn WorktreeEntryMeta::new(
  kind : WorktreeKindMeta,
  mode : Int,
  size : Int?,
  mtime_sec : Int?,
  mtime_nsec : Int?,
) -> WorktreeEntryMeta {
  { kind, mode, size, mtime_sec, mtime_nsec }
}

///|
pub fn WorktreeEntryMeta::mtime(self : WorktreeEntryMeta) -> (Int, Int) {
  (self.mtime_sec.unwrap_or(0), self.mtime_nsec.unwrap_or(0))
}

///|
pub struct WorktreeProbeProvider {
  entry_meta : async (&@types.RepoFileSystem, String) -> WorktreeEntryMeta? noraise
  entry_meta_sync : (&@types.RepoFileSystem, String) -> WorktreeEntryMeta?
  lstat : (String) -> WorktreeEntryMeta?
  symlink_target : (String) -> String?
  readdir_typed : (String) -> Array[(String, Int)]?
}

///|
pub fn WorktreeProbeProvider::new(
  entry_meta : async (&@types.RepoFileSystem, String) -> WorktreeEntryMeta? noraise,
  symlink_target : (String) -> String?,
  entry_meta_sync? : (&@types.RepoFileSystem, String) -> WorktreeEntryMeta?,
  lstat? : (String) -> WorktreeEntryMeta?,
  readdir_typed? : (String) -> Array[(String, Int)]?,
) -> WorktreeProbeProvider {
  let sync_fn = match entry_meta_sync {
    Some(f) => f
    None => fn(_fs, _path) { None }
  }
  let lstat_fn = match lstat {
    Some(f) => f
    None => fn(_path) { None }
  }
  let readdir_fn = match readdir_typed {
    Some(f) => f
    None => fn(_path) { None }
  }
  {
    entry_meta,
    entry_meta_sync: sync_fn,
    lstat: lstat_fn,
    symlink_target,
    readdir_typed: readdir_fn,
  }
}

///|
pub fn WorktreeProbeProvider::none() -> WorktreeProbeProvider {
  let fallback_meta : (&@types.RepoFileSystem, String) -> WorktreeEntryMeta? = fn(
    fs,
    path,
  ) {
    if fs.is_file(path) {
      Some(
        WorktreeEntryMeta::new(
          WorktreeKindMeta::regular(),
          0o100644,
          None,
          None,
          None,
        ),
      )
    } else {
      None
    }
  }
  {
    entry_meta: fn(
      fs : &@types.RepoFileSystem,
      path : String,
    ) -> WorktreeEntryMeta? noraise {
      fallback_meta(fs, path)
    },
    entry_meta_sync: fallback_meta,
    lstat: fn(_path) { None },
    symlink_target: fn(_ : String) { None },
    readdir_typed: fn(_path) { None },
  }
}

///|
priv struct WorktreeProbeBox {
  mut value : WorktreeProbeProvider
}

///|
let worktree_probe_box : WorktreeProbeBox = {
  value: WorktreeProbeProvider::none(),
}

///|
pub fn set_worktree_probe(provider : WorktreeProbeProvider) -> Unit {
  worktree_probe_box.value = provider
}

///|
pub async fn worktree_entry_meta(
  fs : &@types.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntryMeta? noraise {
  (worktree_probe_box.value.entry_meta)(fs, abs_path)
}

///|
pub fn worktree_entry_meta_sync(
  fs : &@types.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntryMeta? {
  (worktree_probe_box.value.entry_meta_sync)(fs, abs_path)
}

///|
/// Stat a file without requiring RepoFileSystem. Uses the native lstat provider
/// when available, otherwise returns None.
pub fn lstat_entry_meta(abs_path : String) -> WorktreeEntryMeta? {
  (worktree_probe_box.value.lstat)(abs_path)
}

///|
pub fn read_symlink_target_path(path : String) -> String? {
  (worktree_probe_box.value.symlink_target)(path)
}

///|
/// Read directory entries with file type info. Returns (name, d_type) pairs.
/// d_type: 4=DT_DIR, 8=DT_REG, 10=DT_LNK, 0=DT_UNKNOWN.
/// Returns None if native readdir is not available (fallback to fs.readdir + is_dir).
pub fn readdir_typed(path : String) -> Array[(String, Int)]? {
  (worktree_probe_box.value.readdir_typed)(path)
}

///|
pub async fn worktree_entry(
  fs : &@types.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntry? noraise {
  let meta = worktree_entry_meta(fs, abs_path)
  match meta {
    None => None
    Some(info) =>
      match info.kind {
        WorktreeKindMeta::Regular =>
          Some({
            kind: WorktreeKind::Regular,
            mode: info.mode,
            size: info.size,
            mtime_sec: info.mtime_sec,
            mtime_nsec: info.mtime_nsec,
          })
        WorktreeKindMeta::Symlink =>
          match read_symlink_target_path(abs_path) {
            Some(target) =>
              Some({
                kind: WorktreeKind::Symlink(target~),
                mode: info.mode,
                size: info.size,
                mtime_sec: info.mtime_sec,
                mtime_nsec: info.mtime_nsec,
              })
            None => None
          }
      }
  }
}
