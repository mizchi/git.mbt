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
    @runtime.StorageCommand::HashObject(hash_args) =>
      if hash_args.stdin_mode || hash_args.obj_type != @bitcore.ObjectType::Blob {
        None
      } else {
        Some(hash_args)
      }
    _ => None
  }
}

///|
fn hash_object_need_real_git(_args : Array[String]) -> Bool {
  let root = get_work_root()
  need_real_git_for_filtering(root)
}

///|
fn hash_object_should_use_storage_runtime(args : Array[String]) -> Bool {
  hash_object_storage_runtime_delegate_args(args) is Some(_)
}

///|
async fn handle_hash_object(args : Array[String]) -> Unit raise Error {
  if hash_object_should_use_storage_runtime(args) {
    match hash_object_storage_runtime_delegate_args(args) {
      Some(hash_args) => {
        let root = get_work_root()
        let fs = OsFs::new()
        @runtime.run_storage_command(
          fs,
          fs,
          root,
          @runtime.StorageCommand::HashObject(hash_args),
        )
        return
      }
      None => ()
    }
  }
  ignore(run_real_git("hash-object", args))
}
