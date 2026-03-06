///|
fn hash_object_storage_runtime_delegate_args(
  args : Array[String],
) -> @runtime.StorageHashObjectArgs? {
  if hash_object_need_real_git(args) {
    return None
  }
  let parsed = storage_runtime_parse_command("hash-object", args) catch {
    _ => return None
  }
  match parsed {
    @runtime.StorageCommand::HashObject(hash_args) => Some(hash_args)
    _ => None
  }
}

///|
fn hash_object_need_real_git(_args : Array[String]) -> Bool {
  false
}

///|
async fn handle_hash_object(args : Array[String]) -> Unit raise Error {
  match hash_object_storage_runtime_delegate_args(args) {
    Some(hash_args) => {
      let root = get_work_root()
      let fs = OsFs::new()
      if hash_args.stdin_mode {
        let content = read_all_stdin()
        let git_dir = resolve_git_dir(fs, root)
        let id = @bitcore.hash_object_content(hash_args.obj_type, content)
        if hash_args.write_object {
          ignore(
            @bitlib.write_loose_object(fs, git_dir, hash_args.obj_type, content),
          )
        }
        print_line(id.to_hex())
      } else {
        @runtime.run_storage_command(
          fs,
          fs,
          root,
          @runtime.StorageCommand::HashObject(hash_args),
        )
      }
      return
    }
    None => ()
  }
  eprint_line(
    "fatal: hash-object with unsupported arguments is not available in standalone mode",
  )
  @sys.exit(128)
}
