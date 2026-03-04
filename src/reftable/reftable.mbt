///|
/// Reftable binary format: header, footer, blocks, and record types.
/// See https://git-scm.com/docs/reftable for the specification.

///|
let reftable_magic : FixedArray[Byte] = [b'R', b'E', b'F', b'T']

///|
let reftable_version : Int = 1

///|
let reftable_header_size : Int = 24

///|
let reftable_footer_size : Int = 68

///|
let hash_size : Int = 20

///|
let block_type_ref : Byte = b'r'

///|
let default_block_size : Int = 4096

///|
let default_restart_interval : Int = 16

///|
pub(all) enum RefValue {
  Deletion
  Val1(@object.ObjectId)
  Val2(@object.ObjectId, @object.ObjectId)
  Symref(String)
} derive(Eq, Show)

///|
pub(all) struct RefRecord {
  refname : String
  update_index : UInt64
  value : RefValue
} derive(Eq, Show)

///|
pub struct ReftableHeader {
  version : Int
  block_size : Int
  min_update_index : UInt64
  max_update_index : UInt64
} derive(Eq, Show)

///|
struct ReftableFooter {
  header : ReftableHeader
  ref_index_offset : UInt64
  obj_offset : UInt64
  obj_index_offset : UInt64
  log_offset : UInt64
  log_index_offset : UInt64
  crc32 : UInt
} derive(Eq, Show)

///|
/// Encode a varint (LEB128 variant with zero optimization used by reftable).
pub fn encode_varint(out : Array[Byte], value : UInt64) -> Unit {
  let mut v = value
  let buf : Array[Byte] = []
  buf.push((v & 0x7fUL).to_byte())
  v = v >> 7
  while v > 0UL {
    v -= 1UL
    buf.push(((v & 0x7fUL).to_byte().to_int() | 0x80).to_byte())
    v = v >> 7
  }
  // Reverse the bytes (they were pushed in LSB-first order)
  for i = buf.length() - 1; i >= 0; i = i - 1 {
    out.push(buf[i])
  }
}

///|
/// Decode a varint from bytes at the given position.
/// Returns (value, bytes_consumed).
pub fn decode_varint(data : Bytes, pos : Int) -> (UInt64, Int) {
  let mut val = 0UL
  let mut i = pos
  while true {
    let b = data[i].to_int()
    val = (val << 7) | (b & 0x7f).to_uint64()
    i += 1
    if (b & 0x80) == 0 {
      break
    }
    val += 1UL
  }
  (val, i - pos)
}

///|
/// Read a big-endian u16 from bytes.
fn read_be_u16(data : Bytes, pos : Int) -> Int {
  (data[pos].to_int() << 8) | data[pos + 1].to_int()
}

///|
/// Read a big-endian u24 (3 bytes) from bytes.
fn read_be_u24(data : Bytes, pos : Int) -> Int {
  (data[pos].to_int() << 16) |
  (data[pos + 1].to_int() << 8) |
  data[pos + 2].to_int()
}

///|
/// Read a big-endian u32 from bytes.
fn read_be_u32(data : Bytes, pos : Int) -> UInt {
  ((data[pos].to_int() << 24) |
  (data[pos + 1].to_int() << 16) |
  (data[pos + 2].to_int() << 8) |
  data[pos + 3].to_int()).reinterpret_as_uint()
}

///|
/// Read a big-endian u64 from bytes.
fn read_be_u64(data : Bytes, pos : Int) -> UInt64 {
  let hi = read_be_u32(data, pos).to_uint64()
  let lo = read_be_u32(data, pos + 4).to_uint64()
  (hi << 32) | lo
}

///|
/// Parse a reftable header from the first 24 bytes.
pub fn parse_header(data : Bytes) -> ReftableHeader? {
  if data.length() < reftable_header_size {
    return None
  }
  // Check magic
  for i = 0; i < 4; i = i + 1 {
    if data[i] != reftable_magic[i] {
      return None
    }
  }
  let version = data[4].to_int()
  if version != 1 {
    return None
  }
  let block_size = read_be_u24(data, 5)
  let min_update_index = read_be_u64(data, 8)
  let max_update_index = read_be_u64(data, 16)
  Some({ version, block_size, min_update_index, max_update_index })
}

///|
/// Parse a reftable footer from the last 68 bytes.
pub fn parse_footer(data : Bytes) -> ReftableFooter? {
  let len = data.length()
  if len < reftable_footer_size {
    return None
  }
  let footer_start = len - reftable_footer_size
  let footer = data.blit(footer_start, len)
  let header = match parse_header(footer) {
    Some(h) => h
    None => return None
  }
  let ref_index_offset = read_be_u64(footer, 24)
  let obj_offset_raw = read_be_u64(footer, 32)
  let obj_index_offset = read_be_u64(footer, 40)
  let log_offset = read_be_u64(footer, 48)
  let log_index_offset = read_be_u64(footer, 56)
  let crc32 = read_be_u32(footer, 64)
  // Verify CRC32
  let computed_crc = crc32_bytes(footer, 0, 64)
  if computed_crc != crc32 {
    return None
  }
  Some({
    header,
    ref_index_offset,
    obj_offset: obj_offset_raw,
    obj_index_offset,
    log_offset,
    log_index_offset,
    crc32,
  })
}

///|
/// Extract a UTF-8 string from bytes.
fn bytes_to_string(data : Bytes, start : Int, len : Int) -> String {
  let buf = StringBuilder::new()
  for i = start; i < start + len; i = i + 1 {
    buf.write_char(Int::unsafe_to_char(data[i].to_int()))
  }
  buf.to_string()
}

///|
/// Decode a single ref record from a block's data.
/// `prev_key` is the previous record's refname for prefix decompression.
/// Returns (RefRecord, bytes_consumed).
pub fn decode_ref_record(
  data : Bytes,
  pos : Int,
  prev_key : String,
  header : ReftableHeader,
) -> (RefRecord, Int)? {
  if pos >= data.length() {
    return None
  }
  let mut offset = pos
  // Decode prefix length
  let (prefix_len, n1) = decode_varint(data, offset)
  offset += n1
  // Decode suffix_len << 3 | value_type
  let (suffix_and_type, n2) = decode_varint(data, offset)
  offset += n2
  let value_type = (suffix_and_type & 0x7UL).to_int()
  let suffix_len = (suffix_and_type >> 3).to_int()
  let prefix_len_int = prefix_len.to_int()
  // Reconstruct key
  let key_buf = StringBuilder::new()
  for i = 0; i < prefix_len_int; i = i + 1 {
    if i < prev_key.length() {
      key_buf.write_char(Int::unsafe_to_char(prev_key[i].to_int()))
    }
  }
  for i = 0; i < suffix_len; i = i + 1 {
    key_buf.write_char(Int::unsafe_to_char(data[offset + i].to_int()))
  }
  offset += suffix_len
  let refname = key_buf.to_string()
  // Decode update_index (delta from min_update_index)
  let (update_index_delta, n3) = decode_varint(data, offset)
  offset += n3
  let update_index = header.min_update_index + update_index_delta
  // Decode value based on type
  let value : RefValue = match value_type {
    0 => RefValue::Deletion
    1 => {
      // Single OID
      let oid = @object.ObjectId::from_bytes_at(data, offset)
      offset += hash_size
      RefValue::Val1(oid)
    }
    2 => {
      // Two OIDs (value + target)
      let oid1 = @object.ObjectId::from_bytes_at(data, offset)
      offset += hash_size
      let oid2 = @object.ObjectId::from_bytes_at(data, offset)
      offset += hash_size
      RefValue::Val2(oid1, oid2)
    }
    3 => {
      // Symbolic reference
      let (sym_len, n4) = decode_varint(data, offset)
      offset += n4
      let sym = bytes_to_string(data, offset, sym_len.to_int())
      offset += sym_len.to_int()
      RefValue::Symref(sym)
    }
    _ => return None
  }
  Some(({ refname, update_index, value }, offset - pos))
}

///|
/// Read all ref records from a single reftable file.
/// Iterates through ref blocks ('r' type) and decodes all records.
pub fn read_refs(data : Bytes) -> Array[RefRecord]? {
  let header = match parse_header(data) {
    Some(h) => h
    None => return None
  }
  let block_size = if header.block_size == 0 {
    // If block_size is 0, the entire file is one block
    data.length()
  } else {
    header.block_size
  }
  let records : Array[RefRecord] = []
  let mut block_offset = reftable_header_size
  // Parse footer to know where ref blocks end
  let footer = match parse_footer(data) {
    Some(f) => f
    None => return None
  }
  let ref_end = if footer.log_offset > 0UL {
    footer.log_offset.to_int()
  } else {
    data.length() - reftable_footer_size
  }
  while block_offset < ref_end {
    // Read block header
    if block_offset + 4 > data.length() {
      break
    }
    let block_type = data[block_offset]
    if block_type != block_type_ref {
      // Not a ref block, stop
      break
    }
    let block_len = read_be_u24(data, block_offset + 1)
    if block_len == 0 {
      break
    }
    // Parse records in this block
    // Block data starts at block_offset + 4 (after block header)
    let restart_count = read_be_u16(data, block_offset + block_len - 2)
    let restarts_start = block_offset + block_len - 2 - restart_count * 3
    let records_end = restarts_start
    let mut rec_pos = block_offset + 4
    let mut prev_key = ""
    while rec_pos < records_end {
      match decode_ref_record(data, rec_pos, prev_key, header) {
        Some((rec, consumed)) => {
          prev_key = rec.refname
          records.push(rec)
          rec_pos += consumed
        }
        None => break
      }
    }
    // Move to next block
    if block_size > 0 && header.block_size > 0 {
      block_offset += block_size
    } else {
      break
    }
  }
  Some(records)
}

///|
/// Look up a specific ref in a reftable file.
pub fn lookup_ref(data : Bytes, refname : String) -> RefRecord? {
  match read_refs(data) {
    Some(refs) =>
      for r in refs {
        if r.refname == refname {
          break Some(r)
        }
      } nobreak {
        None
      }
    None => None
  }
}

///|
/// Look up a ref across multiple stacked tables (newest first).
pub fn lookup_ref_in_stack(
  tables : Array[Bytes],
  refname : String,
) -> RefRecord? {
  // Search from newest (last) to oldest (first)
  for i = tables.length() - 1; i >= 0; i = i - 1 {
    match lookup_ref(tables[i], refname) {
      Some(rec) => return Some(rec)
      None => continue
    }
  }
  None
}

///|
/// Iterate all refs with a given prefix across stacked tables.
/// Latest table wins for duplicate refnames.
pub fn iter_refs(tables : Array[Bytes], prefix : String) -> Array[RefRecord] {
  let merged : Map[String, RefRecord] = {}
  // Process oldest to newest so newest wins
  for table in tables {
    match read_refs(table) {
      Some(refs) =>
        for r in refs {
          if r.refname.has_prefix(prefix) {
            match r.value {
              Deletion => merged.remove(r.refname) |> ignore
              _ => merged[r.refname] = r
            }
          }
        }
      None => ()
    }
  }
  let result : Array[RefRecord] = []
  for _k, v in merged {
    result.push(v)
  }
  result.sort_by(fn(a, b) { String::compare(a.refname, b.refname) })
  result
}

///|
/// CRC32 lookup table (standard zlib CRC32)
let crc32_table : FixedArray[UInt] = build_crc32_table()

///|
fn build_crc32_table() -> FixedArray[UInt] {
  let table : FixedArray[UInt] = FixedArray::make(256, 0U)
  for i = 0; i < 256; i = i + 1 {
    let mut crc = i.reinterpret_as_uint()
    for _j = 0; _j < 8; _j = _j + 1 {
      if (crc & 1U) != 0U {
        crc = (crc >> 1) ^ 0xedb88320U
      } else {
        crc = crc >> 1
      }
    }
    table[i] = crc
  }
  table
}

///|
fn crc32_bytes(data : Bytes, start : Int, end : Int) -> UInt {
  let mut crc = (-1).reinterpret_as_uint()
  for i = start; i < end; i = i + 1 {
    let idx = ((crc ^ data[i].to_int().reinterpret_as_uint()) & 255U).reinterpret_as_int()
    crc = (crc >> 8) ^ crc32_table[idx]
  }
  crc ^ (-1).reinterpret_as_uint()
}

///|
fn crc32_array(data : Array[Byte], start : Int, end : Int) -> UInt {
  let mut crc = (-1).reinterpret_as_uint()
  for i = start; i < end; i = i + 1 {
    let idx = ((crc ^ data[i].to_int().reinterpret_as_uint()) & 255U).reinterpret_as_int()
    crc = (crc >> 8) ^ crc32_table[idx]
  }
  crc ^ (-1).reinterpret_as_uint()
}

///|
/// Blit (slice copy) helper for Bytes.
fn Bytes::blit(self : Bytes, start : Int, end : Int) -> Bytes {
  let len = end - start
  Bytes::from_array(FixedArray::makei(len, fn(i) { self[start + i] }))
}
