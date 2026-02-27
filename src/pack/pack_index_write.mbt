///| Pack index writer (v2)

///|
priv struct PackIndexEntry {
  id : @bit.ObjectId
  offset : Int
  crc : UInt
}

///|
/// Build a pack index (v2) from packfile bytes.
pub fn build_pack_index(pack : Bytes) -> Bytes raise @bit.GitError {
  let objects = parse_packfile(pack)
  build_pack_index_from_objects(pack, objects)
}

///|
/// Build a pack index (v2) from packfile bytes and parsed objects.
/// Uses cached metadata (id, offset, crc32) from PackObject when available.
/// Falls back to re-parsing the pack if metadata is missing.
pub fn build_pack_index_from_objects(
  pack : Bytes,
  objects : Array[@bit.PackObject],
) -> Bytes raise @bit.GitError {
  // Validate that object offsets are plausible for this pack.
  // Objects may carry stale offsets from a different (source) pack,
  // so we check: offset >= 12 (after header) and < pack_data_end.
  let pack_data_end = if pack.length() >= 20 {
    pack.length() - 20
  } else {
    0
  }
  let mut needs_parse = false
  for obj in objects {
    if obj.offset < 12 || obj.offset >= pack_data_end {
      needs_parse = true
      break
    }
  }

  // If objects have stale/invalid offsets, re-parse the pack to get correct values
  if needs_parse {
    return build_pack_index(pack)
  }
  let entries : Array[PackIndexEntry] = []
  for obj in objects {
    entries.push({ id: obj.id, offset: obj.offset, crc: obj.crc32 })
  }
  entries.sort_by((a, b) => compare_object_id(a.id, b.id))
  let counts : Array[Int] = Array::make(256, 0)
  for entry in entries {
    let first = entry.id.bytes[0].to_int()
    counts[first] = counts[first] + 1
  }
  let out : Array[Byte] = []
  // Index header: magic + version
  out.push(b'\xff')
  out.push(b't')
  out.push(b'O')
  out.push(b'c')
  push_u32_be_from_int(out, 2)

  // Fanout table
  let mut sum = 0
  for i in 0..<256 {
    sum = sum + counts[i]
    push_u32_be_from_int(out, sum)
  }

  // Object name table
  for entry in entries {
    for b in entry.id.bytes {
      out.push(b)
    }
  }

  // CRC32 table
  for entry in entries {
    push_u32_be_from_uint(out, entry.crc)
  }

  // Offsets table (no large offsets due to Int range)
  for entry in entries {
    if entry.offset < 0 {
      raise @bit.GitError::PackfileError("Negative pack offset")
    }
    push_u32_be_from_int(out, entry.offset)
  }

  // Packfile checksum (trailer)
  if pack.length() < 20 {
    raise @bit.GitError::PackfileError("Packfile too short")
  }
  let trailer_offset = pack.length() - 20
  let pack_checksum = read_trailer_id(pack, trailer_offset)
  for b in pack_checksum.bytes {
    out.push(b)
  }

  // Index checksum
  let before_checksum = bytes_from_array(out)
  let index_checksum = @bit.sha1(before_checksum)
  for b in index_checksum.bytes {
    out.push(b)
  }
  bytes_from_array(out)
}

///|
/// Write a pack index to the filesystem.
pub fn write_pack_index(
  fs : &@bit.FileSystem,
  idx_path : String,
  pack : Bytes,
) -> Unit raise @bit.GitError {
  let idx = build_pack_index(pack)
  fs.write_file(idx_path, idx)
}

///|
/// Write a pack index using pre-parsed objects.
pub fn write_pack_index_from_objects(
  fs : &@bit.FileSystem,
  idx_path : String,
  pack : Bytes,
  objects : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let idx = build_pack_index_from_objects(pack, objects)
  fs.write_file(idx_path, idx)
}

///|
/// Write a pack index using pre-parsed objects with specific version.
pub fn write_pack_index_from_objects_versioned(
  fs : &@bit.FileSystem,
  idx_path : String,
  pack : Bytes,
  objects : Array[@bit.PackObject],
  version : Int,
) -> Unit raise @bit.GitError {
  let idx = if version == 1 {
    build_pack_index_v1_from_objects(pack, objects)
  } else {
    build_pack_index_from_objects(pack, objects)
  }
  fs.write_file(idx_path, idx)
}

///|
/// Build a pack index (v1) from packfile bytes and parsed objects.
/// Falls back to re-parsing the pack if metadata is missing.
fn build_pack_index_v1_from_objects(
  pack : Bytes,
  objects : Array[@bit.PackObject],
) -> Bytes raise @bit.GitError {
  // Validate that object offsets are plausible for this pack.
  let pack_data_end = if pack.length() >= 20 {
    pack.length() - 20
  } else {
    0
  }
  let mut needs_parse = false
  for obj in objects {
    if obj.offset < 12 || obj.offset >= pack_data_end {
      needs_parse = true
      break
    }
  }

  // If objects have stale/invalid offsets, re-parse the pack to get correct values
  if needs_parse {
    let parsed = parse_packfile(pack)
    return build_pack_index_v1_from_objects(pack, parsed)
  }
  let entries : Array[PackIndexEntry] = []
  for obj in objects {
    entries.push({ id: obj.id, offset: obj.offset, crc: obj.crc32 })
  }
  entries.sort_by((a, b) => compare_object_id(a.id, b.id))

  // Build fanout table (counts per first byte)
  let counts : Array[Int] = Array::make(256, 0)
  for entry in entries {
    let first = entry.id.bytes[0].to_int()
    counts[first] = counts[first] + 1
  }
  let out : Array[Byte] = []

  // v1 format: no header, starts directly with fanout
  // Fanout table (cumulative counts)
  let mut sum = 0
  for i in 0..<256 {
    sum = sum + counts[i]
    push_u32_be_from_int(out, sum)
  }

  // v1 entries: each entry is offset(4) + sha1(20) = 24 bytes
  for entry in entries {
    if entry.offset < 0 {
      raise @bit.GitError::PackfileError("Negative pack offset")
    }
    push_u32_be_from_int(out, entry.offset)
    for b in entry.id.bytes {
      out.push(b)
    }
  }

  // Packfile checksum (trailer)
  if pack.length() < 20 {
    raise @bit.GitError::PackfileError("Packfile too short")
  }
  let trailer_offset = pack.length() - 20
  let pack_checksum = read_trailer_id(pack, trailer_offset)
  for b in pack_checksum.bytes {
    out.push(b)
  }
  bytes_from_array(out)
}

///|
fn _scan_pack_entry_offsets(
  data : Bytes,
) -> (Array[Int], Array[Int]) raise @bit.GitError {
  if data.length() < 32 {
    raise @bit.GitError::PackfileError("Packfile too short")
  }
  if not(
      data[0] == b'P' && data[1] == b'A' && data[2] == b'C' && data[3] == b'K',
    ) {
    raise @bit.GitError::PackfileError("Invalid packfile magic")
  }
  let version = read_u32_be(data, 4)
  if version != 2 {
    raise @bit.GitError::PackfileError(
      "Unsupported packfile version: \{version}",
    )
  }
  let count = read_u32_be(data, 8)
  if count < 0 {
    raise @bit.GitError::PackfileError("Packfile object count out of range")
  }
  let mut offset = 12
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  for _ in 0..<count {
    let start = offset
    let (type_id, size, next_offset) = decode_type_and_size_at(data, offset)
    offset = next_offset
    let after = match type_id {
      1 | 2 | 3 | 4 => {
        let (content, after) = @zlib.zlib_decompress_at(data, offset) catch {
          e => raise @bit.GitError::PackfileError("Zlib error: \{e}")
        }
        if content.length() != size {
          raise @bit.GitError::PackfileError(
            "Object size mismatch: expected=\{size}, got=\{content.length()}",
          )
        }
        after
      }
      6 => {
        let (_, after_ref) = read_ofs_delta_offset(data, offset)
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise @bit.GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise @bit.GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        after
      }
      7 => {
        let (_, after_ref) = read_ref_delta_id(data, offset)
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise @bit.GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise @bit.GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        after
      }
      _ =>
        raise @bit.GitError::PackfileError(
          "Unknown packfile object type: \{type_id}",
        )
    }
    offset = after
    starts.push(start)
    ends.push(after)
  }
  let trailer_offset = data.length() - 20
  if offset != trailer_offset {
    raise @bit.GitError::PackfileError("Packfile length mismatch")
  }
  let pack_bytes = Bytes::from_array(
    FixedArray::makei(trailer_offset, i => data[i]),
  )
  let computed = @bit.sha1(pack_bytes)
  let trailer = read_trailer_id(data, trailer_offset)
  if computed != trailer {
    raise @bit.GitError::HashMismatch(computed.to_hex(), trailer.to_hex())
  }
  (starts, ends)
}

///|
fn compare_object_id(a : @bit.ObjectId, b : @bit.ObjectId) -> Int {
  for i in 0..<20 {
    let av = a.bytes[i].to_int()
    let bv = b.bytes[i].to_int()
    if av != bv {
      return av - bv
    }
  }
  0
}

///|
pub fn crc32_range(
  data : Bytes,
  start : Int,
  end : Int,
) -> UInt raise @bit.GitError {
  if start < 0 || end < start || end > data.length() {
    raise @bit.GitError::PackfileError("Invalid CRC range")
  }
  let slice = Bytes::from_array(
    FixedArray::makei(end - start, i => data[start + i]),
  )
  @zlib.crc32(slice)
}

///|
fn bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), i => arr[i]))
}

///|
fn push_u32_be_from_int(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 24) & 0xff).to_byte())
  out.push(((value >> 16) & 0xff).to_byte())
  out.push(((value >> 8) & 0xff).to_byte())
  out.push((value & 0xff).to_byte())
}

///|
fn push_u32_be_from_uint(out : Array[Byte], value : UInt) -> Unit {
  let mask = Int::reinterpret_as_uint(0xff)
  let b0 = (value >> 24) & mask
  let b1 = (value >> 16) & mask
  let b2 = (value >> 8) & mask
  let b3 = value & mask
  out.push(UInt::reinterpret_as_int(b0).to_byte())
  out.push(UInt::reinterpret_as_int(b1).to_byte())
  out.push(UInt::reinterpret_as_int(b2).to_byte())
  out.push(UInt::reinterpret_as_int(b3).to_byte())
}

///|
/// Write a packfile and its index under .git/objects/pack.
pub fn write_packfile_with_index(
  fs : &@bit.FileSystem,
  git_dir : String,
  pack : Bytes,
  objects : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  if pack.length() < 20 {
    raise @bit.GitError::PackfileError("Packfile too short")
  }
  let pack_dir = @bit.join_path(git_dir, "objects/pack")
  fs.mkdir_p(pack_dir)
  let trailer_offset = pack.length() - 20
  let pack_id = read_trailer_id(pack, trailer_offset)
  let base = "pack-\{pack_id.to_hex()}"
  let pack_path = @bit.join_path(pack_dir, base + ".pack")
  let idx_path = @bit.join_path(pack_dir, base + ".idx")
  fs.write_file(pack_path, pack)
  write_pack_index_from_objects(fs, idx_path, pack, objects)
}
