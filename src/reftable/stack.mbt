///|
/// Reftable stack management: tables.list, loading, adding, compacting.

///|
/// Read the tables.list file and return table filenames.
pub fn read_tables_list(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @object.GitError {
  let path = git_dir + "/reftable/tables.list"
  if not(fs.is_file(path)) {
    return []
  }
  let data = fs.read_file(path)
  let content = bytes_to_string(data, 0, data.length())
  split_lines(content)
}

///|
fn split_lines(s : String) -> Array[String] {
  let lines : Array[String] = []
  let buf = StringBuilder::new()
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i].to_int()
    if ch == 0x0a {
      // '\n'
      let line = buf.to_string()
      if line.length() > 0 {
        lines.push(line)
      }
      buf.reset()
    } else {
      buf.write_char(Int::unsafe_to_char(ch))
    }
  }
  let last = buf.to_string()
  if last.length() > 0 {
    lines.push(last)
  }
  lines
}

///|
/// Load all reftable files referenced by tables.list.
pub fn load_tables(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[Bytes] raise @object.GitError {
  let names = read_tables_list(fs, git_dir)
  let tables : Array[Bytes] = []
  let reftable_dir = git_dir + "/reftable"
  for name in names {
    let path = reftable_dir + "/" + name
    if fs.is_file(path) {
      tables.push(fs.read_file(path))
    }
  }
  tables
}

///|
/// Resolve a ref through stacked reftable tables, following symrefs.
pub fn resolve_ref_reftable(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @object.ObjectId? raise @object.GitError {
  let tables = load_tables(fs, git_dir)
  resolve_ref_from_tables(tables, refname, 0)
}

///|
/// Internal resolve with depth limit (max 8 for symref chains).
fn resolve_ref_from_tables(
  tables : Array[Bytes],
  refname : String,
  depth : Int,
) -> @object.ObjectId? {
  if depth > 8 {
    return None
  }
  match lookup_ref_in_stack(tables, refname) {
    Some(rec) =>
      match rec.value {
        Val1(oid) => Some(oid)
        Val2(oid, _) => Some(oid)
        Symref(target) => resolve_ref_from_tables(tables, target, depth + 1)
        Deletion => None
      }
    None => None
  }
}

///|
/// Collect all refs from reftable (for show-ref, list-refs).
pub fn collect_reftable_refs(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[(String, @object.ObjectId)] raise @object.GitError {
  let tables = load_tables(fs, git_dir)
  let refs = iter_refs(tables, "refs/")
  let result : Array[(String, @object.ObjectId)] = []
  for r in refs {
    match r.value {
      Val1(oid) => result.push((r.refname, oid))
      Val2(oid, _) => result.push((r.refname, oid))
      Symref(target) =>
        match resolve_ref_from_tables(tables, target, 0) {
          Some(oid) => result.push((r.refname, oid))
          None => ()
        }
      Deletion => ()
    }
  }
  result
}
