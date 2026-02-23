///|
pub fn init_worktree_probe() -> Unit {
  let sync_meta : (&@bit.RepoFileSystem, String) -> @bitio.WorktreeEntryMeta? = fn(
    _fs,
    abs_path,
  ) {
    native_lstat_meta(abs_path)
  }
  let provider = @bitio.WorktreeProbeProvider::new(
    fn(
      _fs : &@bit.RepoFileSystem,
      abs_path : String,
    ) -> @bitio.WorktreeEntryMeta? noraise {
      native_lstat_meta(abs_path)
    },
    fn(path : String) { native_read_symlink_target_path(path) },
    entry_meta_sync=sync_meta,
    lstat=native_lstat_meta,
    readdir_typed=native_readdir_typed,
  )
  @bitio.set_worktree_probe(provider)
}

///|
fn native_lstat_meta(abs_path : String) -> @bitio.WorktreeEntryMeta? {
  let path_buf = native_string_to_cstring(abs_path)
  let buf = Bytes::new(28)
  let ret = bit_lstat(path_buf, buf)
  if ret < 0 {
    return None
  }
  // Read st_mode (uint32 LE at offset 0)
  let raw_mode = buf[0].to_int() |
    (buf[1].to_int() << 8) |
    (buf[2].to_int() << 16) |
    (buf[3].to_int() << 24)
  // File type from st_mode
  let file_type = raw_mode & 0xF000
  // S_IFLNK = 0xA000, S_IFREG = 0x8000, S_IFDIR = 0x4000
  if file_type == 0xA000 {
    // Symlink
    let mtime_sec = native_read_i64_le(buf, 12)
    let mtime_nsec = native_read_i64_le(buf, 20)
    return Some(
      @bitio.WorktreeEntryMeta::new(
        @bitio.WorktreeKindMeta::symlink(),
        0o120000,
        None,
        Some(mtime_sec),
        Some(mtime_nsec),
      ),
    )
  }
  if file_type != 0x8000 {
    // Not a regular file (directory, etc.)
    return None
  }
  // Regular file
  let exec = (raw_mode & 0o111) != 0
  let git_mode = if exec { 0o100755 } else { 0o100644 }
  let size = native_read_i64_le(buf, 4)
  let mtime_sec = native_read_i64_le(buf, 12)
  let mtime_nsec = native_read_i64_le(buf, 20)
  Some(
    @bitio.WorktreeEntryMeta::new(
      @bitio.WorktreeKindMeta::regular(),
      git_mode,
      Some(size),
      Some(mtime_sec),
      Some(mtime_nsec),
    ),
  )
}

///|
fn native_read_i64_le(buf : Bytes, offset : Int) -> Int {
  buf[offset].to_int() |
  (buf[offset + 1].to_int() << 8) |
  (buf[offset + 2].to_int() << 16) |
  (buf[offset + 3].to_int() << 24) |
  (buf[offset + 4].to_int() << 32) |
  (buf[offset + 5].to_int() << 40) |
  (buf[offset + 6].to_int() << 48) |
  (buf[offset + 7].to_int() << 56)
}

///|
fn native_read_symlink_target_path(path : String) -> String? {
  native_try_readlink(path)
}

///|
fn native_try_readlink(path : String) -> String? {
  let path_buf = native_string_to_cstring(path)
  let mut buf_len = 256
  while buf_len <= 131072 {
    let buf = Bytes::new(buf_len)
    let read_len = readlink(path_buf, buf, buf.length())
    if read_len < 0 {
      return None
    }
    if read_len < buf.length() {
      return buf[:read_len] |> @utf8.decode_lossy |> Some
    }
    buf_len *= 2
  }
  let buf = Bytes::new(131072)
  let read_len = readlink(path_buf, buf, buf.length())
  if read_len < 0 {
    None
  } else {
    buf[:read_len] |> @utf8.decode_lossy |> Some
  }
}

///|
fn native_string_to_cstring(path : String) -> Bytes {
  let encoded = @utf8.encode(path.to_string_view())
  Bytes::add(encoded, Bytes::make(1, b'\x00'))
}

///|
#borrow(path_buf, buf)
extern "c" fn readlink(path_buf : Bytes, buf : Bytes, size : Int) -> Int = "readlink"

///|
#borrow(path_buf, buf)
extern "c" fn bit_lstat(path_buf : Bytes, buf : Bytes) -> Int = "bit_lstat"

///|
#borrow(path_buf, buf)
extern "c" fn bit_readdir(path_buf : Bytes, buf : Bytes, buf_size : Int) -> Int = "bit_readdir"

///|
/// Read directory entries with d_type info via native readdir.
/// Returns array of (name, d_type) pairs where d_type: 4=DT_DIR, 8=DT_REG, 10=DT_LNK, 0=DT_UNKNOWN.
pub fn native_readdir_typed(path : String) -> Array[(String, Int)]? {
  let path_buf = native_string_to_cstring(path)
  let buf_size = 65536
  let buf = Bytes::new(buf_size)
  let ret = bit_readdir(path_buf, buf, buf_size)
  if ret < 0 {
    return None
  }
  let total = ret
  let result : Array[(String, Int)] = []
  let mut pos = 0
  while pos + 3 <= total {
    let name_len = buf[pos].to_int() | (buf[pos + 1].to_int() << 8)
    let d_type = buf[pos + 2].to_int()
    if pos + 3 + name_len > total {
      break
    }
    let name = @utf8.decode_lossy(buf[pos + 3:pos + 3 + name_len])
    result.push((name, d_type))
    pos = pos + 3 + name_len
  }
  Some(result)
}
