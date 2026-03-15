///|
async fn handle_repack(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let git_dir = resolve_git_dir(fs, root)
  let pack_dir = git_dir + "/objects/pack"
  // Parse flags
  let mut all = false
  let mut delete_redundant = false
  let mut quiet = false
  let mut local_only = false
  let mut no_update_server_info = false
  let mut write_bitmap = false
  let mut no_write_bitmap = false
  let mut pack_kept_objects = false
  let mut cruft = false
  let mut write_midx = false
  let keep_packs : Array[String] = []
  let filter_specs : Array[String] = []
  let mut geometric_factor : String = ""
  let mut keep_unreachable = false
  let mut unpack_unreachable_arg : String = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--" {
      break
    }
    if arg == "--local" {
      local_only = true
    } else if arg == "-n" {
      no_update_server_info = true
    } else if arg == "-b" || arg == "--write-bitmap-index" {
      write_bitmap = true
      no_write_bitmap = false
    } else if arg == "--no-write-bitmap-index" {
      no_write_bitmap = true
      write_bitmap = false
    } else if arg == "--pack-kept-objects" {
      pack_kept_objects = true
    } else if arg == "--cruft" {
      cruft = true
    } else if arg == "--write-midx" {
      write_midx = true
    } else if arg == "-k" || arg == "--keep-unreachable" {
      keep_unreachable = true
    } else if arg.has_prefix("--keep-pack=") {
      let val = String::unsafe_substring(arg, start=12, end=arg.length())
      keep_packs.push(val)
    } else if arg == "--keep-pack" {
      i += 1
      if i < args.length() {
        keep_packs.push(args[i])
      }
    } else if arg.has_prefix("--filter=") {
      filter_specs.push(
        String::unsafe_substring(arg, start=9, end=arg.length()),
      )
    } else if arg == "--filter" {
      i += 1
      if i < args.length() {
        filter_specs.push(args[i])
      }
    } else if arg.has_prefix("--unpack-unreachable=") {
      unpack_unreachable_arg = arg
    } else if arg == "--unpack-unreachable" {
      unpack_unreachable_arg = "--unpack-unreachable"
    } else if arg.has_prefix("--geometric=") {
      geometric_factor = String::unsafe_substring(
        arg,
        start=12,
        end=arg.length(),
      )
    } else if arg == "--geometric" {
      i += 1
      if i < args.length() {
        geometric_factor = args[i]
      }
    } else if arg.has_prefix("-") &&
      not(arg.has_prefix("--")) &&
      arg.length() > 1 {
      // Parse combined short flags like -ad, -adq, -Adl, etc.
      for j in 1..<arg.length() {
        let ch = arg[j]
        match ch {
          'a' => all = true
          'A' => {
            all = true
            delete_redundant = true
          }
          'd' => delete_redundant = true
          'q' => quiet = true
          'l' => local_only = true
          'n' => no_update_server_info = true
          'b' => {
            write_bitmap = true
            no_write_bitmap = false
          }
          'k' => keep_unreachable = true
          _ => ()
        }
      }
    }
    i += 1
  }
  ignore(cruft)
  ignore(write_midx)
  // Auto-enable bitmaps for bare repos (matches git behavior) unless
  // explicitly disabled via --no-write-bitmap-index or config.
  let is_bare = root == git_dir || is_bare_repo_dir(root)
  let bitmap_from_cmdline = write_bitmap
  if not(write_bitmap) && not(no_write_bitmap) && all {
    // Check repack.writeBitmaps config, defaulting to true for bare repos
    let config_val = bit_config_get(git_dir, "repack", "writeBitmaps")
    match config_val {
      Some(v) => if parse_bool_value(v).unwrap_or(false) { write_bitmap = true }
      None => if is_bare { write_bitmap = true }
    }
  }
  // When bitmaps were auto-enabled (not explicitly from command line),
  // suppress them if .keep packs exist (git behavior).
  if write_bitmap && not(bitmap_from_cmdline) && not(pack_kept_objects) {
    let entries = fs.readdir(pack_dir) catch { _ => [] }
    let has_keep = entries.iter().any(fn(e) { e.has_suffix(".keep") })
    if has_keep {
      write_bitmap = false
    }
  }
  // When --filter is used, suppress auto-enabled bitmaps (only error
  // if bitmap was explicitly requested on the command line).
  if filter_specs.length() > 0 {
    if bitmap_from_cmdline {
      @stdio.stderr.write(
        "error: cannot use --filter with --write-bitmap-index\n",
      )
      @sys.exit(1)
    }
    write_bitmap = false
  }
  // Build pack-objects arguments
  let po_args : Array[String] = ["pack-objects", "--delta-base-offset"]
  // Always pass --all --reflog to enumerate objects.
  // When -a is not set, also pass --unpacked --incremental to filter
  // so only loose objects are packed (existing packs are kept).
  po_args.push("--all")
  po_args.push("--reflog")
  if not(all) {
    po_args.push("--unpacked")
    po_args.push("--incremental")
  }
  if local_only {
    po_args.push("--local")
  }
  if not(pack_kept_objects) {
    po_args.push("--honor-pack-keep")
  }
  po_args.push("--non-empty")
  if quiet {
    po_args.push("-q")
  }
  if write_bitmap && not(no_write_bitmap) {
    po_args.push("--write-bitmap-index")
  }
  if keep_unreachable {
    po_args.push("--keep-unreachable")
  }
  if unpack_unreachable_arg.length() > 0 {
    po_args.push(unpack_unreachable_arg)
  }
  if filter_specs.length() > 0 {
    for spec in filter_specs {
      po_args.push("--filter=" + spec)
    }
    // Write filtered-out objects to a separate pack in the same directory
    po_args.push("--filter-to=" + pack_dir + "/pack")
  }
  if geometric_factor.length() > 0 {
    po_args.push("--geometric=" + geometric_factor)
  }
  for kp in keep_packs {
    po_args.push("--keep-pack=" + kp)
  }
  // Use the pack directory directly as prefix — pack-objects writes
  // pack-HASH.pack and pack-HASH.idx into the directory.
  ensure_dir(pack_dir)
  let pack_prefix = pack_dir + "/pack"
  po_args.push(pack_prefix)
  // Collect existing packs before repacking (for -d cleanup).
  // When -a is not set (incremental mode), only loose objects are packed,
  // so existing packs are NOT redundant and must be kept.
  let old_packs : Array[String] = []
  if delete_redundant && all {
    let entries = fs.readdir(pack_dir) catch { _ => [] }
    for entry in entries {
      if entry.has_suffix(".pack") {
        old_packs.push(entry)
      }
    }
  }
  // Find the bit executable to run pack-objects
  let bit_exe = repack_find_bit_exe(git_dir)
  // Run pack-objects subprocess.
  // pack-objects with --all --reflog enumerates objects itself (--revs implied).
  // We need to close stdin to signal end of input.
  let (stdin_input, stdin_writer) = @process.write_to_process() catch {
    _ => {
      // Fall back to @bitlib.repack_repo
      repack_fallback(fs, root, all, delete_redundant, quiet)
      return
    }
  }
  // Close stdin writer immediately — pack-objects with --all doesn't read stdin
  stdin_writer.close()
  let dev_null = @process.redirect_to_file("/dev/null")
  // We collect stdout to get the pack hash(es), stderr for errors
  let (code, stdout_data, stderr_data) = @process.collect_output(
    bit_exe,
    po_args[:],
    inherit_env=true,
    stdin=stdin_input,
    cwd=root[:],
  ) catch {
    _ => {
      repack_fallback(fs, root, all, delete_redundant, quiet)
      return
    }
  }
  ignore(dev_null)
  if code != 0 {
    let err_text = stderr_data.text() catch { _ => "" }
    if err_text.length() > 0 && not(quiet) {
      @stdio.stderr.write(err_text)
    }
    // pack-objects returns 1 with --non-empty when nothing to pack — that's ok
    if code != 1 {
      raise @bitcore.GitError::IoError(
        "pack-objects failed with exit code " + code.to_string(),
      )
    }
  }
  // Parse stdout to get new pack hashes (one per line)
  let stdout_text = stdout_data.text() catch { _ => "" }
  let new_packs : Array[String] = []
  for line_view in stdout_text.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() > 0 {
      new_packs.push("pack-" + line + ".pack")
    }
  }
  // Delete old redundant packs if -d
  if delete_redundant {
    for old_pack in old_packs {
      // Skip if this pack is in the new set
      if new_packs.contains(old_pack) {
        continue
      }
      let stem = midx_pack_stem(old_pack)
      // Skip packs with .keep files (unless --pack-kept-objects)
      if not(pack_kept_objects) && fs.is_file(pack_dir + "/" + stem + ".keep") {
        continue
      }
      // Skip packs in --keep-pack list
      if repack_is_kept_pack(old_pack, keep_packs) {
        continue
      }
      // Remove pack and associated files
      fs.remove_file(pack_dir + "/" + old_pack) catch {
        _ => ()
      }
      fs.remove_file(pack_dir + "/" + stem + ".idx") catch {
        _ => ()
      }
      fs.remove_file(pack_dir + "/" + stem + ".rev") catch {
        _ => ()
      }
      fs.remove_file(pack_dir + "/" + stem + ".bitmap") catch {
        _ => ()
      }
    }
  }
  // Update server info (objects/info/packs) unless -n
  if not(no_update_server_info) {
    repack_update_server_info(fs, git_dir, pack_dir)
  }
}

///|
fn repack_find_bit_exe(git_dir : String) -> String {
  // Check GIT_TEST_INSTALLED (used in shim tests)
  match @sys.get_env_var("GIT_TEST_INSTALLED") {
    Some(dir) if dir.length() > 0 => {
      let fs = OsFs::new()
      let candidate = dir + "/git"
      if fs.is_file(candidate) {
        return candidate
      }
    }
    _ => ()
  }
  // Check SHIM_MOON env var (bit binary path for shim tests)
  match @sys.get_env_var("SHIM_MOON") {
    Some(path) if path.length() > 0 => return path
    _ => ()
  }
  // Try relative to git_dir (standard build location)
  let fs = OsFs::new()
  let build_path = git_dir + "/../_build/native/release/build/cmd/bit/bit.exe"
  if fs.is_file(build_path) {
    return build_path
  }
  // Fall back to "git" (real git) which also has pack-objects
  "git"
}

///|
fn repack_is_kept_pack(pack_name : String, keep_packs : Array[String]) -> Bool {
  for kp in keep_packs {
    // keep_packs may contain just the hash or full name
    if pack_name == kp ||
      pack_name == "pack-" + kp + ".pack" ||
      pack_name.contains(kp) {
      return true
    }
  }
  false
}

///|
fn repack_update_server_info(
  fs : OsFs,
  git_dir : String,
  pack_dir : String,
) -> Unit {
  // Write objects/info/packs listing all pack files
  let info_dir = git_dir + "/objects/info"
  ensure_dir(info_dir) catch {
    _ => return
  }
  let packs_path = info_dir + "/packs"
  let entries = fs.readdir(pack_dir) catch { _ => return }
  let buf = StringBuilder::new()
  for entry in entries {
    if entry.has_suffix(".pack") && not(entry.has_prefix(".tmp-")) {
      buf.write_string("P ")
      buf.write_string(entry)
      buf.write_string("\n")
    }
  }
  buf.write_string("\n")
  @fs.write_string_to_file(packs_path, buf.to_string()) catch {
    _ => ()
  }
  // Write info/refs listing all refs
  let refs_info_dir = git_dir + "/info"
  ensure_dir(refs_info_dir) catch {
    _ => return
  }
  let refs_path = refs_info_dir + "/refs"
  let rfs : &@bitcore.RepoFileSystem = fs
  let all_refs = @bitrepo.show_ref(rfs, git_dir) catch { _ => [] }
  let refs_buf = StringBuilder::new()
  for item in all_refs {
    let (name, id) = item
    refs_buf.write_string(id.to_hex())
    refs_buf.write_string("\t")
    refs_buf.write_string(name)
    refs_buf.write_string("\n")
  }
  @fs.write_string_to_file(refs_path, refs_buf.to_string()) catch {
    _ => ()
  }
}

///|
async fn repack_fallback(
  fs : OsFs,
  root : String,
  all : Bool,
  delete_redundant : Bool,
  quiet : Bool,
) -> Unit {
  let result = @bitlib.repack_repo(fs, fs, root) catch { _ => None }
  match result {
    Some(info) => {
      if not(quiet) {
        let hex = info.pack_id.to_hex()
        print_line(
          "Repacked \{info.object_count} objects into pack-\{String::unsafe_substring(hex, start=0, end=8)}",
        )
      }
      if all && delete_redundant {
        let git_dir = root + "/.git"
        let pack_dir = git_dir + "/objects/pack"
        let new_pack_name = "pack-" + info.pack_id.to_hex() + ".pack"
        let entries = fs.readdir(pack_dir) catch { _ => [] }
        for entry in entries {
          if entry.has_suffix(".pack") && entry != new_pack_name {
            let stem = midx_pack_stem(entry)
            fs.remove_file(pack_dir + "/" + entry) catch {
              _ => ()
            }
            fs.remove_file(pack_dir + "/" + stem + ".idx") catch {
              _ => ()
            }
            fs.remove_file(pack_dir + "/" + stem + ".rev") catch {
              _ => ()
            }
            fs.remove_file(pack_dir + "/" + stem + ".bitmap") catch {
              _ => ()
            }
          }
        }
      }
    }
    None => if not(quiet) { print_line("Nothing to repack.") }
  }
}

///|
