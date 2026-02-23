///|
fn print_hub_pr_usage() -> Unit {
  println("Usage: bit pr <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  list [--state <open|closed|merged> | --open | --closed | --merged] [--limit <n>]",
  )
  println("  status")
  println(
    "  import [--repo <owner/repo>] [--state <open|closed|merged|all>] [--limit <n>]",
  )
  println("  get <id>")
  println("  view <id>                             (alias: get)")
  println(
    "  propose --title <title> [--body <body>] (--source|--head) <branch> (--target|--base) <branch> [--source-repo <owner/repo>] [--source-ref <ref>]",
  )
  println("  proposals [--state <open|closed|merged>] [--limit <n>]")
  println("  proposal ...                          (alias: proposals)")
  println("  import-proposal <id>")
  println(
    "  create --title <title> [--body <body>] (--source|--head) <branch> (--target|--base) <branch> [--source-repo <owner/repo>] [--source-ref <ref>]",
  )
  println(
    "  update <id> [--title <title>] [--body <body>] [--label <label>...]",
  )
  println("  edit <id> ...                         (alias: update)")
  println("  close <id>")
  println("  reopen <id>")
  println("  merge <id> [--strategy <merge|squash|ff>] [--merge|--squash|--ff]")
  println(
    "  comment add <pr-id> --body <body> [--reply-to <id>] [--file <path>] [--line <n>] [--commit <hex>]",
  )
  println(
    "  comment <pr-id> --body <body> ...    (gh-style alias: comment add)",
  )
  println("  comment list <pr-id>")
  println(
    "  review submit <pr-id> --verdict <approved|comment|request-changes> --commit <hex> [--body <body>]",
  )
  println(
    "  review <pr-id> (--approve|--comment|--request-changes|--verdict <v>) --commit <hex> [--body <body>]",
  )
  println("  review list <pr-id>")
  println(
    "  workflow submit <pr-id> --task <task> --status <pending|running|success|failed> [--fingerprint <value>] [--txn <id>] [--author <name>] [--summary <text>]",
  )
  println("  workflow list <pr-id>")
  println("  search [<query>...] [<options>]")
  println("  note <subcommand> [<args>]")
  println("  init")
}

///|
async fn handle_hub_pr(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let subcmd = normalize_hub_pr_subcommand(args[0])
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_hub_pr_list(rest)
    "proposals" => handle_hub_pr_proposals(rest)
    "status" => handle_hub_pr_status(rest)
    "get" => handle_hub_pr_get(rest)
    "import" => handle_hub_pr_import(rest)
    "import-proposal" => handle_hub_pr_import_proposal(rest)
    "propose" => handle_hub_pr_propose(rest)
    "create" => handle_hub_pr_create(rest)
    "update" => handle_hub_pr_update(rest)
    "close" => handle_hub_pr_close(rest)
    "reopen" => handle_hub_pr_reopen(rest)
    "merge" => handle_hub_pr_merge(rest)
    "comment" => handle_hub_pr_comment(rest)
    "review" => handle_hub_pr_review(rest)
    "workflow" => handle_hub_pr_workflow(rest)
    "search" => handle_hub_pr_search(rest)
    "note" => handle_hub_note(rest)
    "init" => handle_hub_pr_init(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit pr: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
fn parse_hub_pr_list_options(
  args : Array[String],
) -> HubWorkItemListOptions raise @bitcore.GitError {
  parse_hub_list_options(args, "bit pr list", "PR", true, true)
}

///|
async fn handle_hub_pr_list(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_list_options(args)
  if options.kind is Some(_) {
    handle_hub_work_item_list(args)
    return ()
  }
  let state = match options.state {
    None => None
    Some(work_item_state) => Some(work_item_state.to_pr_state())
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let prs = hub.list_prs(objects, state~)
  let raw_limit = options.limit.unwrap_or(prs.length())
  let limit = if raw_limit < prs.length() { raw_limit } else { prs.length() }
  if limit == 0 {
    print_line("No pull requests")
    return ()
  }
  let mut i = 0
  while i < limit {
    prs[i] |> format_pr_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_pr_proposals(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_list_options(args)
  let pr_state = match options.state {
    None => None
    Some(work_item_state) => Some(work_item_state.to_pr_state())
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let candidates = hub.list_pr_proposals(objects)
  let prs : Array[@hub.PullRequest] = []
  for pr in candidates {
    match pr_state {
      None => prs.push(pr)
      Some(s) => if pr.state() == s { prs.push(pr) }
    }
  }
  let raw_limit = options.limit.unwrap_or(prs.length())
  let limit = if raw_limit < prs.length() { raw_limit } else { prs.length() }
  if limit == 0 {
    print_line("No pull request proposals")
    return ()
  }
  let mut i = 0
  while i < limit {
    prs[i] |> format_pr_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_pr_status(args : Array[String]) -> Unit raise Error {
  for arg in args {
    match arg {
      "help" | "-h" | "--help" => {
        print_hub_pr_usage()
        return ()
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("pr status", arg)
      _ => warn_unimplemented_arg("pr status", arg)
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let open_prs = hub.list_prs(objects, state=Some(@hub.PrState::Open))
  if open_prs.length() == 0 {
    print_line("No open pull requests")
    return ()
  }
  let branch_ids : Array[String] = []
  match detect_current_branch_name(git_dir) {
    Some(branch) => {
      print_line("Current branch: \{branch}")
      let mut branch_count = 0
      for pr in open_prs {
        if pr_matches_branch(pr, branch) {
          branch_ids.push(pr.id())
          branch_count += 1
          pr |> format_pr_summary |> print_line
        }
      }
      if branch_count == 0 {
        print_line("No open pull request for current branch")
      }
    }
    None => print_line("Current branch: (detached HEAD)")
  }
  let author = get_author_string()
  let mut mine_count = 0
  for pr in open_prs {
    if pr.author() == author && not(branch_ids.contains(pr.id())) {
      if mine_count == 0 {
        print_line("Open pull requests authored by \{author}:")
      }
      mine_count += 1
      pr |> format_pr_summary |> print_line
    }
  }
  if mine_count == 0 {
    print_line("No open pull requests authored by \{author}")
  }
}

///|
async fn handle_hub_pr_import(args : Array[String]) -> Unit raise Error {
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
        print_hub_pr_usage()
        return ()
      }
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --repo requires a value",
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
          "hub pr import: --state requires a value",
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
          "hub pr import: --limit requires a value",
        )
      "--provider" if i + 1 < args.length() => {
        provider = parse_github_import_provider_option(args[i + 1])
        i += 2
        continue
      }
      "--provider" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --provider requires a value",
        )
      "--input" if i + 1 < args.length() => {
        input_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--input" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --input requires a value",
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("pr import", arg)
      _ => warn_unimplemented_arg("pr import", arg)
    }
    i += 1
  }
  let state_value = state.to_lower()
  match state_value {
    "open" | "closed" | "merged" | "all" => ()
    _ => raise @bitcore.GitError::InvalidObject("Unknown PR state: \{state}")
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
      gh_pr_list(repo_name, state_value, limit)
    }
    GitHubImportProvider::JsonFile =>
      read_import_json_from_file(fs, "hub pr import", input_path)
  }
  let prs = parse_gh_prs(stdout)
  if prs.length() == 0 {
    print_line("No pull requests to import")
    return ()
  }
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let stats = hub.import_prs(objects, refs, clock, prs)
  print_line(
    "Imported PRs: created \{stats.created()}, updated \{stats.updated()}",
  )
}

///|
async fn handle_hub_pr_import_proposal(
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_hub_pr_usage()
    return ()
  }
  let mut proposal_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr import-proposal", arg)
      continue
    }
    if proposal_id is None {
      proposal_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr import-proposal", arg)
    }
  }
  guard proposal_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Proposal id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let proposals = hub.list_pr_proposals(objects)
  let mut selected : @hub.PullRequest? = None
  for proposal in proposals {
    if proposal.id() == id {
      selected = Some(proposal)
      break
    }
  }
  guard selected is Some(pr) else {
    raise @bitcore.GitError::InvalidObject("PR proposal not found: \{id}")
  }
  let stats = hub.import_prs(objects, refs, clock, [pr])
  print_line(
    "Imported proposal as PR: created \{stats.created()}, updated \{stats.updated()}",
  )
}

///|
async fn handle_hub_pr_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr get", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr get", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let pr = hub.get_pr(objects, id)
  guard pr is Some(val) else {
    raise @bitcore.GitError::InvalidObject("PR not found: \{id}")
  }
  print_line(val.serialize())
}

///|
fn normalize_branch_ref(ref_name : String) -> String {
  if ref_name.has_prefix("refs/") {
    ref_name
  } else {
    "refs/heads/" + ref_name
  }
}

///|
fn infer_source_repo_name(fs : OsFs, git_dir : String) -> String? {
  let remote_url = get_effective_remote_url(fs, git_dir)
  guard remote_url is Some(url) else { return None }
  match @hq.parse_repo_url(url) {
    Some(parsed) => {
      let full_name = parsed.full_name()
      if full_name.length() == 0 {
        None
      } else {
        Some(full_name)
      }
    }
    None => None
  }
}

///|
struct HubPrCreateOptions {
  title : String
  body : String
  source_branch : String
  target_branch : String
  source_repo : String?
  source_ref : String?
}

///|
async fn parse_hub_pr_create_options(
  args : Array[String],
  warn_context : String,
) -> HubPrCreateOptions raise Error {
  let mut title : String? = None
  let mut body : String? = None
  let mut source_branch : String? = None
  let mut target_branch : String? = None
  let mut source_repo : String? = None
  let mut source_ref : String? = None
  let positionals : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-t" | "--title" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --title requires a value",
        )
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --body requires a value",
        )
      "--source" | "--head" if i + 1 < args.length() => {
        source_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--source" | "--head" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --source requires a value",
        )
      "--target" | "--base" if i + 1 < args.length() => {
        target_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--target" | "--base" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --target requires a value",
        )
      "--source-repo" if i + 1 < args.length() => {
        source_repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--source-repo" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --source-repo requires a value",
        )
      "--source-ref" if i + 1 < args.length() => {
        source_ref = Some(args[i + 1])
        i += 2
        continue
      }
      "--source-ref" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --source-ref requires a value",
        )
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
      _ if arg.has_prefix("--source=") => {
        source_branch = Some(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--head=") => {
        source_branch = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--target=") => {
        target_branch = Some(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--base=") => {
        target_branch = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--source-repo=") => {
        source_repo = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--source-ref=") => {
        source_ref = Some(
          String::unsafe_substring(arg, start=13, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg(warn_context, arg)
        i += 1
        continue
      }
      _ => {
        positionals.push(arg)
        i += 1
        continue
      }
    }
  }
  if source_branch is None && positionals.length() > 0 {
    source_branch = Some(positionals[0])
  }
  if target_branch is None && positionals.length() > 1 {
    target_branch = Some(positionals[1])
  }
  guard title is Some(t) else {
    raise @bitcore.GitError::InvalidObject("Missing --title")
  }
  guard source_branch is Some(src) else {
    raise @bitcore.GitError::InvalidObject("Missing --source")
  }
  guard target_branch is Some(tgt) else {
    raise @bitcore.GitError::InvalidObject("Missing --target")
  }
  {
    title: t,
    body: body.unwrap_or(""),
    source_branch: src,
    target_branch: tgt,
    source_repo,
    source_ref,
  }
}

///|
async fn handle_hub_pr_create(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_create_options(args, "hub pr create")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let fs = OsFs::new()
  let source_repo_value = match options.source_repo {
    Some(repo) => if repo.length() == 0 { None } else { Some(repo) }
    None => infer_source_repo_name(fs, git_dir)
  }
  let source_ref_value = match options.source_ref {
    Some(ref_name) =>
      if ref_name.length() == 0 {
        Some(normalize_branch_ref(options.source_branch))
      } else {
        Some(normalize_branch_ref(ref_name))
      }
    None => Some(normalize_branch_ref(options.source_branch))
  }
  let hub = init_hub_store(objects, refs)
  let pr = hub.create_pr(
    objects,
    refs,
    clock,
    options.title,
    options.body,
    options.source_branch,
    options.target_branch,
    get_author_string(),
    source_repo=source_repo_value,
    source_ref=source_ref_value,
  )
  print_line(pr.serialize())
}

///|
async fn handle_hub_pr_propose(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_create_options(args, "hub pr propose")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let fs = OsFs::new()
  let source_repo_value = match options.source_repo {
    Some(repo) => if repo.length() == 0 { None } else { Some(repo) }
    None => infer_source_repo_name(fs, git_dir)
  }
  let source_ref_value = match options.source_ref {
    Some(ref_name) =>
      if ref_name.length() == 0 {
        Some(normalize_branch_ref(options.source_branch))
      } else {
        Some(normalize_branch_ref(ref_name))
      }
    None => Some(normalize_branch_ref(options.source_branch))
  }
  let hub = init_hub_store(objects, refs)
  let proposal = hub.propose_pr(
    objects,
    refs,
    clock,
    options.title,
    options.body,
    options.source_branch,
    options.target_branch,
    get_author_string(),
    source_repo=source_repo_value,
    source_ref=source_ref_value,
  )
  print_line(proposal.serialize())
}

///|
async fn handle_hub_pr_update(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  let mut title : String? = None
  let mut body : String? = None
  let labels : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-t" | "--title" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr update: --title requires a value",
        )
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr update: --body requires a value",
        )
      "--label" | "-l" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--label" | "-l" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr update: --label requires a value",
        )
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
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pr update", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("pr update", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let label_option = if labels.length() > 0 { Some(labels) } else { None }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let pr = hub.update_pr(
    objects,
    refs,
    clock,
    id,
    title~,
    body~,
    labels=label_option,
  )
  print_line(pr.serialize())
}

///|
async fn handle_hub_pr_close(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr close", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr close", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.close_pr(objects, refs, clock, id)
  print_line("Closed PR #\{id}")
}

///|
async fn handle_hub_pr_reopen(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr reopen", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr reopen", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.reopen_pr(objects, refs, clock, id)
  print_line("Reopened PR #\{id}")
}

///|
async fn handle_hub_pr_merge(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  let mut strategy : @hub.PrMergeStrategy? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if parse_merge_strategy_flag(arg) is Some(flag_strategy) {
      strategy = Some(flag_strategy)
      i += 1
      continue
    }
    match arg {
      "--rebase" =>
        raise @bitcore.GitError::InvalidObject(
          "Merge strategy 'rebase' is not supported",
        )
      "--strategy" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_merge_strategy(value) {
          Some(s) => strategy = Some(s)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown merge strategy: \{value}",
            )
        }
        i += 2
        continue
      }
      _ if arg.has_prefix("--strategy=") => {
        let value = String::unsafe_substring(arg, start=11, end=arg.length())
        match parse_merge_strategy(value) {
          Some(s) => strategy = Some(s)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown merge strategy: \{value}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pr merge", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("pr merge", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let merge_policy = load_hub_merge_policy(fs, git_dir)
  hub.check_merge_policy(
    objects,
    refs,
    id,
    merge_policy,
    signing_key=get_hub_signing_key(),
  )
  let result = match strategy {
    Some(s) =>
      hub.merge_pr(objects, refs, clock, id, get_author_string(), strategy=s)
    None => hub.merge_pr(objects, refs, clock, id, get_author_string())
  }
  if result.success() {
    print_line(result.message())
    match result.commit_id() {
      Some(cid) => print_line("Merge commit: \{cid.to_hex()}")
      None => ()
    }
  } else {
    eprint_line(result.message())
    for conflict in result.conflicts() {
      eprint_line("conflict: \{conflict}")
    }
    @sys.exit(1)
  }
}

///|
async fn handle_hub_pr_comment(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  let subcmd = resolve_hub_comment_subcommand(first)
  let rest = if subcmd == first { collect_args(args, 1) } else { args }
  match subcmd {
    "add" => handle_hub_pr_comment_add(rest)
    "list" => handle_hub_pr_comment_list(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit pr comment: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_pr_comment_add(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut body : String? = None
  let mut reply_to : String? = None
  let mut file_path : String? = None
  let mut line_number : Int? = None
  let mut commit_id : @bitcore.ObjectId? = None
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
      "--file" if i + 1 < args.length() => {
        file_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--line" if i + 1 < args.length() => {
        line_number = args[i + 1] |> @strconv.parse_int |> Some
        i += 2
        continue
      }
      "--commit" if i + 1 < args.length() => {
        commit_id = args[i + 1] |> @bitcore.ObjectId::from_hex |> Some
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
      _ if arg.has_prefix("--file=") => {
        file_path = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--line=") => {
        let value = String::unsafe_substring(arg, start=7, end=arg.length())
        line_number = value |> @strconv.parse_int |> Some
        i += 1
        continue
      }
      _ if arg.has_prefix("--commit=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        commit_id = value |> @bitcore.ObjectId::from_hex |> Some
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pr comment add", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("pr comment add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  guard body is Some(msg) else {
    raise @bitcore.GitError::InvalidObject("Missing --body")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let comment = hub.add_comment(
    objects,
    refs,
    clock,
    id,
    get_author_string(),
    msg,
    reply_to~,
    file_path~,
    line_number~,
    commit_id~,
  )
  print_line(comment.serialize())
}

///|
async fn handle_hub_pr_comment_list(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr comment list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr comment list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let comments = hub.list_comments(objects, id)
  if comments.length() == 0 {
    print_line("No comments")
    return ()
  }
  for comment in comments {
    print_line(comment.serialize())
  }
}

///|
async fn handle_hub_pr_review(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  let subcmd = resolve_hub_review_subcommand(first)
  let rest = if subcmd == first { collect_args(args, 1) } else { args }
  match subcmd {
    "submit" => handle_hub_pr_review_submit(rest)
    "list" => handle_hub_pr_review_list(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit pr review: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_pr_review_submit(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut verdict : @hub.ReviewVerdict? = None
  let mut body : String? = None
  let mut commit_id : @bitcore.ObjectId? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if parse_review_verdict_flag(arg) is Some(flag_verdict) {
      verdict = Some(flag_verdict)
      i += 1
      continue
    }
    match arg {
      "--verdict" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_review_verdict(value) {
          Some(v) => verdict = Some(v)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown review verdict: \{value}",
            )
        }
        i += 2
        continue
      }
      "--verdict" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr review submit: --verdict requires a value",
        )
      "--commit" if i + 1 < args.length() => {
        commit_id = args[i + 1] |> @bitcore.ObjectId::from_hex |> Some
        i += 2
        continue
      }
      "--commit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr review submit: --commit requires a value",
        )
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr review submit: --body requires a value",
        )
      _ if arg.has_prefix("--verdict=") => {
        let value = String::unsafe_substring(arg, start=10, end=arg.length())
        match parse_review_verdict(value) {
          Some(v) => verdict = Some(v)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown review verdict: \{value}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--commit=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        commit_id = value |> @bitcore.ObjectId::from_hex |> Some
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
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pr review submit", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("pr review submit", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  guard verdict is Some(v) else {
    raise @bitcore.GitError::InvalidObject("Missing --verdict")
  }
  guard commit_id is Some(cid) else {
    raise @bitcore.GitError::InvalidObject("Missing --commit")
  }
  let review_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let review = hub.submit_review(
    objects,
    refs,
    clock,
    id,
    get_author_string(),
    v,
    review_body,
    cid,
  )
  print_line(review.serialize())
}

///|
async fn handle_hub_pr_review_list(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr review list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr review list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let reviews = hub.list_reviews(objects, id)
  if reviews.length() == 0 {
    print_line("No reviews")
    return ()
  }
  for review in reviews {
    print_line(review.serialize())
  }
}

///|
async fn handle_hub_pr_workflow(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "submit" => handle_hub_pr_workflow_submit(rest)
    "list" => handle_hub_pr_workflow_list(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit pr workflow: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_pr_workflow_submit(
  args : Array[String],
) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut task : String? = None
  let mut status : @hub.PrWorkflowStatus? = None
  let mut workspace_fingerprint = ""
  let mut txn_id : String? = None
  let mut author : String? = None
  let mut summary = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--task" if i + 1 < args.length() => {
        task = Some(args[i + 1])
        i += 2
        continue
      }
      "--status" if i + 1 < args.length() => {
        let raw = args[i + 1]
        match @hub.parse_pr_workflow_status(raw) {
          Some(value) => status = Some(value)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown workflow status: \{raw}",
            )
        }
        i += 2
        continue
      }
      "--fingerprint" if i + 1 < args.length() => {
        workspace_fingerprint = args[i + 1]
        i += 2
        continue
      }
      "--txn" if i + 1 < args.length() => {
        txn_id = Some(args[i + 1])
        i += 2
        continue
      }
      "--author" if i + 1 < args.length() => {
        author = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "--summary" | "--body" if i + 1 < args.length() => {
        summary = args[i + 1]
        i += 2
        continue
      }
      _ if arg.has_prefix("--task=") => {
        task = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--status=") => {
        let raw = String::unsafe_substring(arg, start=9, end=arg.length())
        match @hub.parse_pr_workflow_status(raw) {
          Some(value) => status = Some(value)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown workflow status: \{raw}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--fingerprint=") => {
        workspace_fingerprint = String::unsafe_substring(
          arg,
          start=14,
          end=arg.length(),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--txn=") => {
        txn_id = Some(String::unsafe_substring(arg, start=6, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--author=") => {
        author = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--summary=") => {
        summary = String::unsafe_substring(arg, start=10, end=arg.length())
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        summary = String::unsafe_substring(arg, start=7, end=arg.length())
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pr workflow submit", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("pr workflow submit", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  guard task is Some(task_name) else {
    raise @bitcore.GitError::InvalidObject("Missing --task")
  }
  guard status is Some(workflow_status) else {
    raise @bitcore.GitError::InvalidObject("Missing --status")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let workflow = hub.record_pr_workflow(
    objects,
    refs,
    clock,
    id,
    task_name,
    workflow_status,
    workspace_fingerprint,
    author.unwrap_or(get_author_string()),
    txn_id~,
    summary~,
  )
  let txn_text = workflow.txn_id().unwrap_or("")
  print_line(
    "pr workflow \{id} task=\{workflow.task()} status=\{workflow.status().to_string()} fingerprint=\{workflow.workspace_fingerprint()} txn=\{txn_text}",
  )
}

///|
async fn handle_hub_pr_workflow_list(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("pr workflow list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("pr workflow list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let workflows = hub.list_pr_workflows(objects, id)
  if workflows.length() == 0 {
    print_line("No workflows")
    return ()
  }
  for workflow in workflows {
    let txn_text = workflow.txn_id().unwrap_or("")
    print_line(
      "pr=\{id} task=\{workflow.task()} status=\{workflow.status().to_string()} fingerprint=\{workflow.workspace_fingerprint()} txn=\{txn_text} updated=\{workflow.updated_at().to_string()} author=\{workflow.author()}",
    )
  }
}

///|
async fn handle_hub_pr_search(args : Array[String]) -> Unit raise Error {
  let default_types = [
    HubSearchType::Pr,
    HubSearchType::PrComment,
    HubSearchType::PrReview,
  ]
  handle_hub_search_with_defaults(args, default_types, print_hub_pr_usage)
}

///|
async fn handle_hub_pr_init(_args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  ensure_hub_initialized(git_dir)
  print_line("Initialized hub metadata")
}
