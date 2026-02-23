///|
fn print_hub_dump_usage() -> Unit {
  println("Usage: bit debug dump [<prefix>] [<options>]")
  println("")
  println("Options:")
  println("  --prefix <prefix>       Filter by key prefix (default: hub/)")
  println("  --raw                   Print full serialized HubRecord bodies")
  println("  --include-deleted       Include tombstoned records")
  println("  -h, --help              Show this help")
}

///|
struct HubDumpOptions {
  prefix : String
  raw : Bool
  include_deleted : Bool
}

///|
fn parse_hub_dump_options(
  args : Array[String],
) -> HubDumpOptions raise @bitcore.GitError {
  let mut prefix = "hub/"
  let mut raw = false
  let mut include_deleted = false
  let mut i = 0
  let mut used_positional_prefix = false
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--prefix" if i + 1 < args.length() => {
        prefix = args[i + 1]
        i += 2
        continue
      }
      "--prefix" =>
        raise @bitcore.GitError::InvalidObject(
          "hub dump: --prefix requires a value",
        )
      _ if arg.has_prefix("--prefix=") => {
        prefix = String::unsafe_substring(arg, start=9, end=arg.length())
        i += 1
        continue
      }
      "--raw" => {
        raw = true
        i += 1
        continue
      }
      "--include-deleted" => {
        include_deleted = true
        i += 1
        continue
      }
      "-h" | "--help" | "help" => {
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub dump option: \{arg}",
        )
      _ => {
        if used_positional_prefix {
          raise @bitcore.GitError::InvalidObject(
            "hub dump: unexpected positional argument: \{arg}",
          )
        }
        prefix = arg
        used_positional_prefix = true
        i += 1
        continue
      }
    }
  }
  { prefix, raw, include_deleted }
}

///|
fn format_hub_record_summary(record : @hub.HubRecord) -> String {
  let deleted_text = if record.deleted { "1" } else { "0" }
  "kind=\{record.kind} key=\{record.key} node=\{record.node} ts=\{record.timestamp} deleted=\{deleted_text}"
}

///|
async fn handle_hub_dump(args : Array[String]) -> Unit raise Error {
  if args.length() > 0 {
    let first = args[0]
    if first == "help" || first == "-h" || first == "--help" {
      print_hub_dump_usage()
      return ()
    }
  }
  let options = parse_hub_dump_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let store = @hub.HubStore::load(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
  let records = store.list_records(
    objects,
    options.prefix,
    include_deleted=options.include_deleted,
  )
  if records.length() == 0 {
    print_line("No hub records for prefix: \{options.prefix}")
    return ()
  }
  records.sort_by(fn(a, b) {
    if a.key < b.key {
      -1
    } else if a.key > b.key {
      1
    } else {
      0
    }
  })
  for rec in records {
    if options.raw {
      print_line("---")
      print_line(format_hub_record_summary(rec))
      print_line(rec.serialize())
    } else {
      print_line(format_hub_record_summary(rec))
    }
  }
}
