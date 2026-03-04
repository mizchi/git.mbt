///|
/// Reftable writer: creates reftable binary files from RefRecords.

///|
/// Write big-endian u16 to output.
fn push_be_u16(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 8) & 0xff).to_byte())
  out.push((value & 0xff).to_byte())
}

///|
/// Write big-endian u24 (3 bytes) to output.
fn push_be_u24(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 16) & 0xff).to_byte())
  out.push(((value >> 8) & 0xff).to_byte())
  out.push((value & 0xff).to_byte())
}

///|
/// Write big-endian u32 to output.
fn push_be_u32(out : Array[Byte], value : UInt) -> Unit {
  out.push(((value >> 24) & 0xffU).reinterpret_as_int().to_byte())
  out.push(((value >> 16) & 0xffU).reinterpret_as_int().to_byte())
  out.push(((value >> 8) & 0xffU).reinterpret_as_int().to_byte())
  out.push((value & 0xffU).reinterpret_as_int().to_byte())
}

///|
/// Write big-endian u64 to output.
fn push_be_u64(out : Array[Byte], value : UInt64) -> Unit {
  push_be_u32(out, (value >> 32).to_uint())
  push_be_u32(out, value.to_uint())
}

///|
/// Encode a single ref record into output bytes.
/// Returns nothing; appends encoded bytes to `out`.
fn encode_ref_record(
  out : Array[Byte],
  rec : RefRecord,
  prev_key : String,
  min_update_index : UInt64,
) -> Unit {
  // Compute shared prefix length
  let mut prefix_len = 0
  let min_len = if prev_key.length() < rec.refname.length() {
    prev_key.length()
  } else {
    rec.refname.length()
  }
  while prefix_len < min_len && prev_key[prefix_len] == rec.refname[prefix_len] {
    prefix_len += 1
  }
  let suffix_len = rec.refname.length() - prefix_len
  // value_type for the lower 3 bits
  let value_type : Int = match rec.value {
    Deletion => 0
    Val1(_) => 1
    Val2(_, _) => 2
    Symref(_) => 3
  }
  // Encode prefix length
  encode_varint(out, prefix_len.to_uint64())
  // Encode (suffix_len << 3) | value_type
  encode_varint(out, ((suffix_len << 3) | value_type).to_uint64())
  // Write suffix bytes
  for i = prefix_len; i < rec.refname.length(); i = i + 1 {
    out.push((rec.refname[i].to_int() & 0xff).to_byte())
  }
  // Write update_index delta
  let update_index_delta = rec.update_index - min_update_index
  encode_varint(out, update_index_delta)
  // Write value
  match rec.value {
    Deletion => ()
    Val1(oid) => {
      let bytes = oid.to_bytes()
      for i = 0; i < hash_size; i = i + 1 {
        out.push(bytes[i])
      }
    }
    Val2(oid1, oid2) => {
      let b1 = oid1.to_bytes()
      let b2 = oid2.to_bytes()
      for i = 0; i < hash_size; i = i + 1 {
        out.push(b1[i])
      }
      for i = 0; i < hash_size; i = i + 1 {
        out.push(b2[i])
      }
    }
    Symref(target) => {
      encode_varint(out, target.length().to_uint64())
      for i = 0; i < target.length(); i = i + 1 {
        out.push((target[i].to_int() & 0xff).to_byte())
      }
    }
  }
}

///|
/// Write a reftable header to output.
fn write_header(
  out : Array[Byte],
  block_size : Int,
  min_update_index : UInt64,
  max_update_index : UInt64,
) -> Unit {
  // Magic "REFT"
  out.push(b'R')
  out.push(b'E')
  out.push(b'F')
  out.push(b'T')
  // Version
  out.push(reftable_version.to_byte())
  // Block size (24-bit BE)
  push_be_u24(out, block_size)
  // Min/max update index
  push_be_u64(out, min_update_index)
  push_be_u64(out, max_update_index)
}

///|
/// Write a reftable footer to output.
fn write_footer(
  out : Array[Byte],
  block_size : Int,
  min_update_index : UInt64,
  max_update_index : UInt64,
) -> Unit {
  // Footer starts with a copy of the header
  write_header(out, block_size, min_update_index, max_update_index)
  // ref_index_offset (0 = none)
  push_be_u64(out, 0UL)
  // obj_offset (0 = none)
  push_be_u64(out, 0UL)
  // obj_index_offset (0 = none)
  push_be_u64(out, 0UL)
  // log_offset (0 = none)
  push_be_u64(out, 0UL)
  // log_index_offset (0 = none)
  push_be_u64(out, 0UL)
  // CRC32 over footer bytes (all except the CRC32 field itself)
  let footer_start = out.length() - 64
  let crc = crc32_array(out, footer_start, out.length())
  push_be_u32(out, crc)
}

///|
/// Write a complete reftable file from sorted ref records.
/// Records MUST be sorted by refname.
/// Returns the file contents as Bytes.
pub fn write_reftable(
  records : Array[RefRecord],
  block_size : Int,
  min_update_index : UInt64,
  max_update_index : UInt64,
) -> Bytes {
  let out : Array[Byte] = []
  let effective_block_size = if block_size == 0 {
    default_block_size
  } else {
    block_size
  }
  // Write file header
  write_header(out, effective_block_size, min_update_index, max_update_index)
  if records.length() > 0 {
    // Build ref blocks
    let mut block_records : Array[Byte] = []
    let mut restart_offsets : Array[Int] = []
    let mut prev_key = ""
    let mut record_count = 0
    let block_header_size = 4
    let restart_overhead_per = 3 // 3 bytes per restart offset
    let restart_count_size = 2 // 2 bytes for count
    for i, rec in records {
      let rec_out : Array[Byte] = []
      let current_prev = if record_count % default_restart_interval == 0 {
        // Restart point: no prefix compression
        ""
      } else {
        prev_key
      }
      if record_count % default_restart_interval == 0 {
        restart_offsets.push(block_records.length())
      }
      encode_ref_record(rec_out, rec, current_prev, min_update_index)
      // Check if adding this record would exceed block size
      let projected_size = block_header_size +
        block_records.length() +
        rec_out.length() +
        restart_offsets.length() * restart_overhead_per +
        restart_count_size
      if projected_size > effective_block_size && block_records.length() > 0 {
        // Flush current block
        flush_ref_block(
          out, block_records, restart_offsets, effective_block_size,
        )
        // Start new block
        block_records = []
        restart_offsets = []
        prev_key = ""
        record_count = 0
        // Re-encode the current record with no prefix compression
        let new_rec_out : Array[Byte] = []
        restart_offsets.push(0)
        encode_ref_record(new_rec_out, rec, "", min_update_index)
        for b in new_rec_out {
          block_records.push(b)
        }
        prev_key = rec.refname
        record_count = 1
      } else {
        for b in rec_out {
          block_records.push(b)
        }
        prev_key = rec.refname
        record_count += 1
      }
      // Flush on last record
      if i == records.length() - 1 && block_records.length() > 0 {
        flush_ref_block(
          out, block_records, restart_offsets, effective_block_size,
        )
      }
    }
  }
  // Write footer
  write_footer(out, effective_block_size, min_update_index, max_update_index)
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
/// Flush a completed ref block to output, padded to block_size.
fn flush_ref_block(
  out : Array[Byte],
  records : Array[Byte],
  restart_offsets : Array[Int],
  block_size : Int,
) -> Unit {
  // Calculate total block content size
  let content_size = 4 + records.length() + restart_offsets.length() * 3 + 2
  // Write block header
  out.push(block_type_ref)
  push_be_u24(out, content_size)
  // Write record data
  for b in records {
    out.push(b)
  }
  // Write restart offsets (3 bytes BE each)
  for offset in restart_offsets {
    push_be_u24(out, offset)
  }
  // Write restart count (2 bytes BE)
  push_be_u16(out, restart_offsets.length())
  // Pad to block_size
  let current_size = content_size
  if current_size < block_size {
    for _i = current_size; _i < block_size; _i = _i + 1 {
      out.push(b'\x00')
    }
  }
}
