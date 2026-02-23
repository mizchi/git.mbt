///|
fn print_hub_issue_usage() -> Unit {
  println("Usage: bit issue <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  list [--state <open|closed> | --open | --closed] [--limit <n>]")
  println(
    "  import [--repo <owner/repo>] [--state <open|closed|all>] [--limit <n>]",
  )
  println("  get <id>")
  println("  view <id>                             (alias: get)")
  println(
    "  create --title <title> [--body <body>] [--label <label>...] [--assignee <user>...]",
  )
  println(
    "  update <id> [--title <title>] [--body <body>] [--label <label>...] [--assignee <user>...]",
  )
  println("  edit <id> ...                         (alias: update)")
  println("  close <id>")
  println("  reopen <id>")
  println("  comment add <issue-id> --body <body> [--reply-to <id>]")
  println(
    "  comment <issue-id> --body <body> ...  (gh-style alias: comment add)",
  )
  println("  comment list <issue-id>")
  println("  link <issue-id> <pr-id>")
  println("  claim <issue-id> [--remote <url>] [--auth-token <token>]")
  println("  unclaim <issue-id> [--remote <url>] [--auth-token <token>]")
  println(
    "  claims [--stale-hours <n>] [--remote <url>] [--auth-token <token>]",
  )
  println("  watch [--stale-hours <n>] [--remote <url>] [--auth-token <token>]")
  println("  search [<query>...] [<options>]")
  println("  note <subcommand> [<args>]")
  println("  init")
}

///|
fn print_hub_work_item_usage() -> Unit {
  println("Usage: bit pr|issue list --kind=all [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  list [--state <open|closed|merged> | --open | --closed | --merged] [--kind <issue|pr|pull-request> | --issue | --pr] [--limit <n>]",
  )
  println("  get <id>")
  println("  view <id>                             (alias: get)")
}

///|
async fn handle_hub_issue(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let subcmd = normalize_hub_issue_subcommand(args[0])
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_hub_issue_list(rest)
    "get" => handle_hub_issue_get(rest)
    "import" => handle_hub_issue_import(rest)
    "create" => handle_hub_issue_create(rest)
    "update" => handle_hub_issue_update(rest)
    "close" => handle_hub_issue_close(rest)
    "reopen" => handle_hub_issue_reopen(rest)
    "comment" => handle_hub_issue_comment(rest)
    "link" => handle_hub_issue_link(rest)
    "claim" => handle_hub_issue_claim(rest)
    "unclaim" => handle_hub_issue_unclaim(rest)
    "claims" => handle_hub_issue_claims(rest)
    "watch" => handle_hub_issue_watch(rest)
    "search" => handle_hub_issue_search(rest)
    "note" => handle_hub_note(rest)
    "init" => handle_hub_issue_init(rest)
    "help" | "-h" | "--help" => print_hub_issue_usage()
    _ => {
      eprint_line("bit issue: unknown subcommand '\{subcmd}'")
      print_hub_issue_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_work_item(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_work_item_usage()
    return ()
  }
  let subcmd = normalize_hub_work_item_subcommand(args[0])
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_hub_work_item_list(rest)
    "get" => handle_hub_work_item_get(rest)
    "help" | "-h" | "--help" => print_hub_work_item_usage()
    _ => {
      eprint_line("bit work-item: unknown subcommand '\{subcmd}'")
      print_hub_work_item_usage()
      @sys.exit(1)
    }
  }
}

///|
struct HubWorkItemListOptions {
  state : @hub.WorkItemState?
  kind : @hub.WorkItemKind?
  limit : Int?
}

///|
fn parse_work_item_state_for_list(
  value : String,
  unknown_state_label : String,
  allow_merged : Bool,
) -> @hub.WorkItemState raise @bitcore.GitError {
  let state = parse_work_item_state(value)
  guard state is Some(parsed) else {
    raise @bitcore.GitError::InvalidObject(
      "Unknown \{unknown_state_label} state: \{value}",
    )
  }
  if not(allow_merged) && parsed == @hub.WorkItemState::Merged {
    raise @bitcore.GitError::InvalidObject(
      "Unknown \{unknown_state_label} state: \{value}",
    )
  }
  parsed
}

///|
fn parse_hub_list_options(
  args : Array[String],
  context : String,
  unknown_state_label : String,
  allow_merged : Bool,
  allow_kind : Bool,
) -> HubWorkItemListOptions raise @bitcore.GitError {
  let mut state : @hub.WorkItemState? = None
  let mut kind : @hub.WorkItemKind? = None
  let mut limit : Int? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if allow_kind {
      if parse_work_item_state_flag(arg) is Some(flag_state) {
        state = Some(flag_state)
        i += 1
        continue
      }
    } else if allow_merged {
      if parse_pr_state_flag(arg) is Some(flag_state) {
        state = Some(flag_state.to_work_item_state())
        i += 1
        continue
      }
    } else if parse_issue_state_flag(arg) is Some(flag_state) {
      state = Some(flag_state.to_work_item_state())
      i += 1
      continue
    }
    if allow_kind {
      if parse_work_item_kind_flag(arg) is Some(flag_kind) {
        kind = Some(flag_kind)
        i += 1
        continue
      }
    }
    match arg {
      "--state" if i + 1 < args.length() => {
        state = Some(
          parse_work_item_state_for_list(
            args[i + 1],
            unknown_state_label,
            allow_merged,
          ),
        )
        i += 2
        continue
      }
      "--state" =>
        raise @bitcore.GitError::InvalidObject(
          "\{context}: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        state = Some(
          parse_work_item_state_for_list(
            value, unknown_state_label, allow_merged,
          ),
        )
        i += 1
        continue
      }
      "--kind" if allow_kind && i + 1 < args.length() => {
        let value = args[i + 1]
        if parse_work_item_kind(value) is Some(k) {
          kind = Some(k)
        } else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown work item kind: \{value}",
          )
        }
        i += 2
        continue
      }
      "--kind" if allow_kind =>
        raise @bitcore.GitError::InvalidObject(
          "\{context}: --kind requires a value",
        )
      _ if allow_kind && arg.has_prefix("--kind=") => {
        let value = String::unsafe_substring(arg, start=7, end=arg.length())
        if parse_work_item_kind(value) is Some(k) {
          kind = Some(k)
        } else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown work item kind: \{value}",
          )
        }
        i += 1
        continue
      }
      "--limit" | "-L" if i + 1 < args.length() => {
        limit = Some(parse_positive_list_limit(args[i + 1]))
        i += 2
        continue
      }
      "--limit" | "-L" =>
        raise @bitcore.GitError::InvalidObject(
          "\{context}: --limit requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = Some(parse_positive_list_limit(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => ()
      _ => ()
    }
    i += 1
  }
  { state, kind, limit }
}

///|
fn parse_hub_issue_list_options(
  args : Array[String],
) -> HubWorkItemListOptions raise @bitcore.GitError {
  parse_hub_list_options(args, "bit issue list", "issue", false, true)
}

///|
fn parse_hub_work_item_list_options(
  args : Array[String],
) -> HubWorkItemListOptions raise @bitcore.GitError {
  parse_hub_list_options(args, "bit work-item list", "work item", true, true)
}

///|
async fn handle_hub_issue_list(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_issue_list_options(args)
  if options.kind is Some(_) {
    handle_hub_work_item_list(args)
    return ()
  }
  let state = match options.state {
    None => None
    Some(work_item_state) => work_item_state.to_issue_state()
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let issues = hub.list_issues(objects, state~)
  let raw_limit = options.limit.unwrap_or(issues.length())
  let limit = if raw_limit < issues.length() {
    raw_limit
  } else {
    issues.length()
  }
  if limit == 0 {
    print_line("No issues")
    return ()
  }
  let mut i = 0
  while i < limit {
    issues[i] |> format_issue_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_work_item_list(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_work_item_list_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let items = hub.list_work_items(
    objects,
    state=options.state,
    kind=options.kind,
  )
  let raw_limit = options.limit.unwrap_or(items.length())
  let limit = if raw_limit < items.length() {
    raw_limit
  } else {
    items.length()
  }
  if limit == 0 {
    print_line("No work items")
    return ()
  }
  let mut i = 0
  while i < limit {
    items[i] |> format_work_item_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_issue_import(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut state = "all"
  let mut limit = 100
  let mut provider = GitHubImportProvider::GhCli
  let mut input_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" | "help" => {
        print_hub_issue_usage()
        return ()
      }
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --repo requires a value",
        )
      _ if arg.has_prefix("--repo=") => {
        repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      "--state" if i + 1 < args.length() => {
        state = args[i + 1]
        i += 2
        continue
      }
      "--state" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        state = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = @strconv.parse_int(args[i + 1]) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "Invalid limit: \{args[i + 1]}",
            )
        }
        i += 2
        continue
      }
      "--limit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --limit requires a value",
        )
      "--provider" if i + 1 < args.length() => {
        provider = parse_github_import_provider_option(args[i + 1])
        i += 2
        continue
      }
      "--provider" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --provider requires a value",
        )
      "--input" if i + 1 < args.length() => {
        input_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--input" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --input requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = @strconv.parse_int(value) catch {
          _ => raise @bitcore.GitError::InvalidObject("Invalid limit: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--provider=") => {
        let value = String::unsafe_substring(arg, start=11, end=arg.length())
        provider = parse_github_import_provider_option(value)
        i += 1
        continue
      }
      _ if arg.has_prefix("--input=") => {
        input_path = Some(
          String::unsafe_substring(arg, start=8, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("issue import", arg)
      _ => warn_unimplemented_arg("issue import", arg)
    }
    i += 1
  }
  let state_value = state.to_lower()
  match state_value {
    "open" | "closed" | "all" => ()
    _ => raise @bitcore.GitError::InvalidObject("Unknown issue state: \{state}")
  }
  if limit <= 0 {
    raise @bitcore.GitError::InvalidObject("Limit must be positive")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (stdout, _stderr) = match provider {
    GitHubImportProvider::GhCli => {
      let repo_name = resolve_github_repo(fs, git_dir, repo)
      gh_issue_list(repo_name, state_value, limit)
    }
    GitHubImportProvider::JsonFile =>
      read_import_json_from_file(fs, "hub issue import", input_path)
  }
  let issues = parse_gh_issues(stdout)
  if issues.length() == 0 {
    print_line("No issues to import")
    return ()
  }
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let stats = hub.import_issues(objects, refs, clock, issues)
  print_line(
    "Imported issues: created \{stats.created()}, updated \{stats.updated()}",
  )
}

///|
async fn handle_hub_issue_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("issue get", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("issue get", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let issue = hub.get_issue(objects, id)
  guard issue is Some(val) else {
    raise @bitcore.GitError::InvalidObject("Issue not found: \{id}")
  }
  print_line(val.serialize())
}

///|
async fn handle_hub_work_item_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_work_item_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_hub_work_item_usage()
    return ()
  }
  let mut work_item_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("work-item get", arg)
      continue
    }
    if work_item_id is None {
      work_item_id = Some(arg)
    } else {
      warn_unimplemented_arg("work-item get", arg)
    }
  }
  guard work_item_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Work item id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let work_item = hub.get_work_item(objects, id)
  guard work_item is Some(val) else {
    raise @bitcore.GitError::InvalidObject("Work item not found: \{id}")
  }
  print_line(format_work_item_detail(val))
}

///|
async fn handle_hub_issue_create(args : Array[String]) -> Unit raise Error {
  let mut title : String? = None
  let mut body : String? = None
  let labels : Array[String] = []
  let assignees : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" | "-l" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--assignee" | "-a" if i + 1 < args.length() => {
        assignees.push(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--title=") => {
        title = Some(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--assignee=") => {
        assignees.push(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("issue create", arg)
        i += 1
        continue
      }
      _ => {
        warn_unimplemented_arg("issue create", arg)
        i += 1
        continue
      }
    }
  }
  guard title is Some(t) else {
    raise @bitcore.GitError::InvalidObject("Missing --title")
  }
  let issue_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let issue = hub.create_issue(
    objects,
    refs,
    clock,
    t,
    issue_body,
    get_author_string(),
    labels~,
    assignees~,
  )
  print_line(issue.serialize())
}

///|
async fn handle_hub_issue_update(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  let mut title : String? = None
  let mut body : String? = None
  let labels : Array[String] = []
  let assignees : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" | "-l" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--assignee" | "-a" if i + 1 < args.length() => {
        assignees.push(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--title=") => {
        title = Some(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--assignee=") => {
        assignees.push(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("issue update", arg)
        i += 1
        continue
      }
      _ => {
        if issue_id is None {
          issue_id = Some(arg)
        } else {
          warn_unimplemented_arg("issue update", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let label_option = if labels.length() > 0 { Some(labels) } else { None }
  let assignee_option = if assignees.length() > 0 {
    Some(assignees)
  } else {
    None
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let issue = hub.update_issue(
    objects,
    refs,
    clock,
    id,
    title~,
    body~,
    labels=label_option,
    assignees=assignee_option,
  )
  print_line(issue.serialize())
}

///|
async fn handle_hub_issue_close(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("issue close", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("issue close", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.close_issue(objects, refs, clock, id)
  print_line("Closed issue #\{id}")
}

///|
async fn handle_hub_issue_reopen(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("issue reopen", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("issue reopen", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.reopen_issue(objects, refs, clock, id)
  print_line("Reopened issue #\{id}")
}

///|
async fn handle_hub_issue_comment(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let first = args[0]
  let subcmd = resolve_hub_comment_subcommand(first)
  let rest = if subcmd == first { collect_args(args, 1) } else { args }
  match subcmd {
    "add" => handle_hub_issue_comment_add(rest)
    "list" => handle_hub_issue_comment_list(rest)
    "help" | "-h" | "--help" => print_hub_issue_usage()
    _ => {
      eprint_line("bit issue comment: unknown subcommand '\{subcmd}'")
      print_hub_issue_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_issue_comment_add(args : Array[String]) -> Unit raise Error {
  let mut issue_id : String? = None
  let mut body : String? = None
  let mut reply_to : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--reply-to" if i + 1 < args.length() => {
        reply_to = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--reply-to=") => {
        reply_to = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("issue comment add", arg)
        i += 1
        continue
      }
      _ => {
        if issue_id is None {
          issue_id = Some(arg)
        } else {
          warn_unimplemented_arg("issue comment add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  guard body is Some(msg) else {
    raise @bitcore.GitError::InvalidObject("Missing --body")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let comment = hub.add_issue_comment(
    objects,
    refs,
    clock,
    id,
    get_author_string(),
    msg,
    reply_to~,
  )
  print_line(comment.serialize())
}

///|
async fn handle_hub_issue_comment_list(
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("issue comment list", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("issue comment list", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let comments = hub.list_issue_comments(objects, id)
  if comments.length() == 0 {
    print_line("No comments")
    return ()
  }
  for comment in comments {
    print_line(comment.serialize())
  }
}

///|
async fn handle_hub_issue_link(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_hub_issue_usage()
    return ()
  }
  let issue_id = args[0]
  let pr_id = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.link_pr_to_issue(objects, refs, clock, issue_id, pr_id)
  print_line("Linked PR #\{pr_id} to issue #\{issue_id}")
}

///|
async fn handle_hub_issue_claim(args : Array[String]) -> Unit raise Error {
  let mut issue_id : String? = None
  let mut remote_url : String? = None
  let mut auth_token : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--remote" if i + 1 < args.length() => {
        remote_url = Some(args[i + 1])
        i += 2
        continue
      }
      "--auth-token" if i + 1 < args.length() => {
        auth_token = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-") => {
        eprint_line("bit issue claim: unknown option '\{arg}'")
        print_hub_issue_usage()
        @sys.exit(1)
      }
      _ => {
        issue_id = Some(arg)
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    eprint_line("bit issue claim: missing <issue-id>")
    print_hub_issue_usage()
    @sys.exit(1)
  }
  let url = resolve_claim_remote_url(remote_url)
  let sender = @hub_native.relay_sender_name()
  let timestamp = get_current_timestamp()
  let claim = @hub.ClaimMessage::new(
    id,
    @hub.ClaimAction::Claim,
    sender,
    timestamp,
  )
  let accepted = @hub_native.relay_publish_claim(url, claim, auth_token~)
  if accepted {
    print_line("Published claim for \{id}")
  } else {
    print_line("Claim for \{id} already published (duplicate)")
  }
}

///|
async fn handle_hub_issue_unclaim(args : Array[String]) -> Unit raise Error {
  let mut issue_id : String? = None
  let mut remote_url : String? = None
  let mut auth_token : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--remote" if i + 1 < args.length() => {
        remote_url = Some(args[i + 1])
        i += 2
        continue
      }
      "--auth-token" if i + 1 < args.length() => {
        auth_token = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-") => {
        eprint_line("bit issue unclaim: unknown option '\{arg}'")
        print_hub_issue_usage()
        @sys.exit(1)
      }
      _ => {
        issue_id = Some(arg)
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    eprint_line("bit issue unclaim: missing <issue-id>")
    print_hub_issue_usage()
    @sys.exit(1)
  }
  let url = resolve_claim_remote_url(remote_url)
  let sender = @hub_native.relay_sender_name()
  let timestamp = get_current_timestamp()
  let claim = @hub.ClaimMessage::new(
    id,
    @hub.ClaimAction::Unclaim,
    sender,
    timestamp,
  )
  let accepted = @hub_native.relay_publish_claim(url, claim, auth_token~)
  if accepted {
    print_line("Published unclaim for \{id}")
  } else {
    print_line("Unclaim for \{id} already published (duplicate)")
  }
}

///|
async fn handle_hub_issue_claims(args : Array[String]) -> Unit raise Error {
  let mut remote_url : String? = None
  let mut auth_token : String? = None
  let mut stale_hours : Int = 24
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--remote" if i + 1 < args.length() => {
        remote_url = Some(args[i + 1])
        i += 2
        continue
      }
      "--auth-token" if i + 1 < args.length() => {
        auth_token = Some(args[i + 1])
        i += 2
        continue
      }
      "--stale-hours" if i + 1 < args.length() => {
        stale_hours = @strconv.parse_int(args[i + 1]) catch { _ => 24 }
        i += 2
        continue
      }
      _ if arg.has_prefix("-") => {
        eprint_line("bit issue claims: unknown option '\{arg}'")
        print_hub_issue_usage()
        @sys.exit(1)
      }
      _ => {
        i += 1
        continue
      }
    }
  }
  let url = resolve_claim_remote_url(remote_url)
  let all_claims = @hub_native.relay_poll_claims(url, auth_token~)
  let active = @hub.resolve_active_claims(all_claims)
  if active.length() == 0 {
    print_line("No active claims")
    return ()
  }
  let now = get_current_timestamp()
  print_line("ISSUE\tCLAIMER\tCLAIMED_AT\tSTATUS")
  for claim in active {
    let ts = claim.timestamp()
    let status = if claim.is_stale(now, threshold_hours=stale_hours) {
      let hours_ago = (now - ts) / 3600L
      "stale (\{hours_ago}h ago)"
    } else {
      "active"
    }
    print_line("\{claim.issue_id()}\t\{claim.claimer()}\t\{ts}\t\{status}")
  }
}

///|
fn resolve_claim_remote_url(
  explicit : String?,
) -> String raise @bitcore.GitError {
  match explicit {
    Some(url) => url
    None => {
      let root = get_work_root()
      let git_dir = root + "/.git"
      let fs = OsFs::new()
      match get_effective_remote_url(fs, git_dir) {
        Some(url) => url
        None =>
          raise @bitcore.GitError::InvalidObject(
            "No remote configured. Use --remote <url>",
          )
      }
    }
  }
}

///|
fn format_claim_timestamp(ts : Int64) -> String {
  let secs = ts % 60L
  let mins = ts / 60L % 60L
  let hours = ts / 3600L % 24L
  let s = secs.to_int()
  let m = mins.to_int()
  let h = hours.to_int()
  let s_str = if s < 10 { "0\{s}" } else { "\{s}" }
  let m_str = if m < 10 { "0\{m}" } else { "\{m}" }
  let h_str = if h < 10 { "0\{h}" } else { "\{h}" }
  "\{h_str}:\{m_str}:\{s_str}"
}

///|
async fn handle_hub_issue_watch(args : Array[String]) -> Unit raise Error {
  let mut remote_url : String? = None
  let mut auth_token : String? = None
  let mut stale_hours : Int = 24
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--remote" if i + 1 < args.length() => {
        remote_url = Some(args[i + 1])
        i += 2
        continue
      }
      "--auth-token" if i + 1 < args.length() => {
        auth_token = Some(args[i + 1])
        i += 2
        continue
      }
      "--stale-hours" if i + 1 < args.length() => {
        stale_hours = @strconv.parse_int(args[i + 1]) catch { _ => 24 }
        i += 2
        continue
      }
      _ if arg.has_prefix("-") => {
        eprint_line("bit issue watch: unknown option '\{arg}'")
        print_hub_issue_usage()
        @sys.exit(1)
      }
      _ => {
        i += 1
        continue
      }
    }
  }
  let url = resolve_claim_remote_url(remote_url)
  let now = get_current_timestamp()
  // Initial poll: fetch all existing claims
  let initial_result = @hub_native.relay_poll_claims_after(
    url,
    0,
    1000,
    auth_token~,
  )
  let mut cursor = initial_result.0
  let active = @hub.resolve_active_claims(initial_result.1)
  print_line("Watching claims...")
  for claim in active {
    let ts = claim.timestamp()
    let status = if claim.is_stale(now, threshold_hours=stale_hours) {
      let hours_ago = (now - ts) / 3600L
      "stale (\{hours_ago}h ago)"
    } else {
      "active"
    }
    print_line("[initial] \{claim.issue_id()}\t\{claim.claimer()}\t\{status}")
  }
  print_line("---")
  // Try WebSocket first, fall back to poll
  let ws_ok = try {
    print_line("Connecting via WebSocket...")
    @hub_native.relay_watch_claims_ws(
      url,
      fn(claim) {
        let action_str = claim.action().to_string()
        let ts_str = format_claim_timestamp(claim.timestamp())
        println(
          "[new] \{action_str}\t\{claim.issue_id()}\t\{claim.claimer()}\t\{ts_str}",
        )
      },
      auth_token~,
    )
    true
  } catch {
    err => {
      eprint_line("WebSocket failed: \{err.to_string()}, falling back to poll")
      false
    }
  }
  if ws_ok {
    return ()
  }
  // Poll fallback
  print_line("Polling every 5s...")
  while true {
    @async.sleep(5000)
    let (next_cursor, new_claims) = @hub_native.relay_poll_claims_after(
      url,
      cursor,
      100,
      auth_token~,
    ) catch {
      _ => continue
    }
    cursor = next_cursor
    for claim in new_claims {
      let action_str = claim.action().to_string()
      let ts_str = format_claim_timestamp(claim.timestamp())
      print_line(
        "[new] \{action_str}\t\{claim.issue_id()}\t\{claim.claimer()}\t\{ts_str}",
      )
    }
  }
}

///|
async fn handle_hub_issue_search(args : Array[String]) -> Unit raise Error {
  let default_types = [HubSearchType::Issue, HubSearchType::IssueComment]
  handle_hub_search_with_defaults(args, default_types, print_hub_issue_usage)
}

///|
async fn handle_hub_issue_init(_args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  ensure_hub_initialized(git_dir)
  print_line("Initialized hub metadata")
}
