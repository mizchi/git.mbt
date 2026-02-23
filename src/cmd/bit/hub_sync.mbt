///|
fn print_hub_sync_usage() -> Unit {
  println("Usage: bit relay sync <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  push [<remote-url>] [--auth-token <token>] [--signing-key <key>] [--require-signed|--allow-unsigned]",
  )
  println(
    "  fetch [<remote-url>] [--auth-token <token>] [--signing-key <key>] [--require-signed|--allow-unsigned]",
  )
  println(
    "  clone-announce [<remote-url>] --url <clone-url> [--repo <repo>] [--auth-token <token>]",
  )
  println(
    "  clone-peers [<remote-url>] [--include-self] [--auth-token <token>]",
  )
  println("  issue-url [<remote-url>] [--room <room>] [--room-token <token>]")
  println("")
  println("Remote URL:")
  println("  - Smart HTTP remote: https://host/repo.git")
  println("  - Relay explicit: relay+http(s)://host")
  println("  - Relay fallback: http(s)://host (when info/refs returns 404)")
  println(
    "  - Shared signaling URL: relay+https://host/?room=<room>&room_token=<token>",
  )
  println("")
  println("Relay signing env:")
  println(
    "  BIT_RELAY_SIGN_PRIVATE_KEY_FILE=<path>   Sign relay publish requests with Ed25519",
  )
  println(
    "  BIT_RELAY_SIGN_PUBLIC_KEY=<base64url>    Optional override for x-relay-public-key",
  )
  println(
    "  BIT_RELAY_SENDER=<id>                    Sender id for relay publish (default: bit)",
  )
}

///|
async fn handle_hub_sync(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_sync_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "push" => handle_hub_sync_push(rest)
    "fetch" => handle_hub_sync_fetch(rest)
    "clone-announce" => handle_hub_sync_clone_announce(rest)
    "clone-peers" => handle_hub_sync_clone_peers(rest)
    "issue-url" => handle_hub_sync_issue_url(rest)
    "help" | "-h" | "--help" => print_hub_sync_usage()
    _ => {
      eprint_line("bit relay sync: unknown subcommand '\{subcmd}'")
      print_hub_sync_usage()
      @sys.exit(1)
    }
  }
}

///|
struct HubSyncRuntimeOptions {
  remote_url : String?
  auth_token : String?
  signing_key : String?
  require_signed : Bool?
  conflict_policy : @hub.RecordMergePolicy?
}

///|
fn parse_hub_conflict_policy(
  value : String,
) -> @hub.RecordMergePolicy raise @bitcore.GitError {
  match @hub.parse_record_merge_policy(value) {
    Some(policy) => policy
    None =>
      raise @bitcore.GitError::InvalidObject(
        "Unknown hub conflict policy: \{value}",
      )
  }
}

///|
fn parse_hub_sync_runtime_options(
  args : Array[String],
  default_remote_url? : String? = None,
) -> HubSyncRuntimeOptions raise @bitcore.GitError {
  let mut remote_url = default_remote_url
  let mut auth_token : String? = None
  let mut signing_key : String? = None
  let mut require_signed : Bool? = None
  let mut conflict_policy : @hub.RecordMergePolicy? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--auth-token" if i + 1 < args.length() => {
        auth_token = Some(args[i + 1])
        i += 2
        continue
      }
      "--auth-token" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync: --auth-token requires a value",
        )
      "--signing-key" | "--sign-key" if i + 1 < args.length() => {
        signing_key = Some(args[i + 1])
        i += 2
        continue
      }
      "--signing-key" | "--sign-key" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync: --signing-key requires a value",
        )
      "--require-signed" => {
        require_signed = Some(true)
        i += 1
        continue
      }
      "--allow-unsigned" => {
        require_signed = Some(false)
        i += 1
        continue
      }
      "--conflict-policy" if i + 1 < args.length() => {
        conflict_policy = Some(parse_hub_conflict_policy(args[i + 1]))
        i += 2
        continue
      }
      "--conflict-policy" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync: --conflict-policy requires a value",
        )
      _ if arg.has_prefix("--auth-token=") => {
        auth_token = Some(
          String::unsafe_substring(arg, start=13, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--signing-key=") => {
        signing_key = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--sign-key=") => {
        signing_key = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--conflict-policy=") => {
        let value = String::unsafe_substring(arg, start=18, end=arg.length())
        conflict_policy = Some(parse_hub_conflict_policy(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub sync option: \{arg}",
        )
      _ => {
        remote_url = Some(arg)
        i += 1
        continue
      }
    }
  }
  { remote_url, auth_token, signing_key, require_signed, conflict_policy }
}

///|
struct HubSyncCloneAnnounceOptions {
  runtime : HubSyncRuntimeOptions
  clone_url : String
  repo : String?
}

///|
fn parse_hub_sync_clone_announce_options(
  args : Array[String],
  default_remote_url? : String? = None,
) -> HubSyncCloneAnnounceOptions raise @bitcore.GitError {
  let runtime_args : Array[String] = []
  let mut clone_url : String? = None
  let mut repo : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--url" if i + 1 < args.length() => {
        clone_url = Some(args[i + 1])
        i += 2
        continue
      }
      "--url" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync clone-announce: --url requires a value",
        )
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync clone-announce: --repo requires a value",
        )
      _ if arg.has_prefix("--url=") => {
        clone_url = Some(
          String::unsafe_substring(arg, start=6, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--repo=") => {
        repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ => {
        runtime_args.push(arg)
        i += 1
        continue
      }
    }
  }
  let runtime = parse_hub_sync_runtime_options(
    runtime_args,
    default_remote_url~,
  )
  guard clone_url is Some(raw_clone_url) else {
    raise @bitcore.GitError::InvalidObject(
      "hub sync clone-announce: --url is required",
    )
  }
  let normalized_clone_url = raw_clone_url.trim(chars=" \n\r\t").to_string()
  if normalized_clone_url.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "hub sync clone-announce: --url must not be empty",
    )
  }
  let normalized_repo = match repo {
    Some(raw_repo) => {
      let value = raw_repo.trim(chars=" \n\r\t").to_string()
      if value.length() == 0 {
        None
      } else {
        Some(value)
      }
    }
    None => None
  }
  { runtime, clone_url: normalized_clone_url, repo: normalized_repo }
}

///|
struct HubSyncClonePeersOptions {
  runtime : HubSyncRuntimeOptions
  include_self : Bool
}

///|
fn parse_hub_sync_clone_peers_options(
  args : Array[String],
  default_remote_url? : String? = None,
) -> HubSyncClonePeersOptions raise @bitcore.GitError {
  let runtime_args : Array[String] = []
  let mut include_self = false
  for arg in args {
    if arg == "--include-self" {
      include_self = true
    } else {
      runtime_args.push(arg)
    }
  }
  let runtime = parse_hub_sync_runtime_options(
    runtime_args,
    default_remote_url~,
  )
  { runtime, include_self }
}

///|
struct HubSyncIssueUrlOptions {
  remote_url : String?
  room : String?
  room_token : String?
}

///|
fn parse_hub_sync_issue_url_options(
  args : Array[String],
  default_remote_url? : String? = None,
) -> HubSyncIssueUrlOptions raise @bitcore.GitError {
  let mut remote_url = default_remote_url
  let mut room : String? = None
  let mut room_token : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--room" if i + 1 < args.length() => {
        room = Some(args[i + 1])
        i += 2
        continue
      }
      "--room" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync issue-url: --room requires a value",
        )
      "--room-token" if i + 1 < args.length() => {
        room_token = Some(args[i + 1])
        i += 2
        continue
      }
      "--room-token" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync issue-url: --room-token requires a value",
        )
      _ if arg.has_prefix("--room=") => {
        room = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--room-token=") => {
        room_token = Some(
          String::unsafe_substring(arg, start=13, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub sync issue-url option: \{arg}",
        )
      _ => {
        remote_url = Some(arg)
        i += 1
        continue
      }
    }
  }
  let normalized_room = match room {
    Some(raw) => {
      let value = raw.trim(chars=" \n\r\t").to_string()
      if value.length() == 0 {
        None
      } else {
        Some(value)
      }
    }
    None => None
  }
  let normalized_room_token = match room_token {
    Some(raw) => {
      let value = raw.trim(chars=" \n\r\t").to_string()
      if value.length() == 0 {
        None
      } else {
        Some(value)
      }
    }
    None => None
  }
  { remote_url, room: normalized_room, room_token: normalized_room_token }
}

///|
fn hub_sync_is_http_url(url : String) -> Bool {
  url.has_prefix("http://") || url.has_prefix("https://")
}

///|
fn hub_sync_trim_trailing_slash(url : String) -> String {
  if url.length() > 1 && url.has_suffix("/") {
    String::unsafe_substring(url, start=0, end=url.length() - 1)
  } else {
    url
  }
}

///|
fn hub_sync_parse_relay_base_url(remote_url : String) -> String? {
  if remote_url.has_prefix("relay+http://") ||
    remote_url.has_prefix("relay+https://") {
    Some(
      hub_sync_trim_trailing_slash(
        String::unsafe_substring(remote_url, start=6, end=remote_url.length()),
      ),
    )
  } else if remote_url.has_prefix("relay://") {
    Some(
      hub_sync_trim_trailing_slash(
        "http://" +
        String::unsafe_substring(remote_url, start=8, end=remote_url.length()),
      ),
    )
  } else {
    None
  }
}

///|
fn hub_sync_strip_query(url : String) -> String {
  match url.find("?") {
    Some(idx) => String::unsafe_substring(url, start=0, end=idx)
    None => url
  }
}

///|
fn hub_sync_room_leading_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

///|
fn hub_sync_room_safe_char(c : Char) -> Bool {
  hub_sync_room_leading_char(c) || c == '.' || c == '_' || c == '-'
}

///|
fn hub_sync_is_valid_room_name(room : String) -> Bool {
  if room.length() == 0 || room.length() > 64 {
    return false
  }
  let mut first = true
  for c in room {
    if first {
      if not(hub_sync_room_leading_char(c)) {
        return false
      }
      first = false
    } else if not(hub_sync_room_safe_char(c)) {
      return false
    }
  }
  true
}

///|
fn hub_sync_room_token_safe_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '.' ||
  c == '_' ||
  c == '-'
}

///|
fn hub_sync_is_valid_room_token(room_token : String) -> Bool {
  if room_token.length() == 0 || room_token.length() > 128 {
    return false
  }
  for c in room_token {
    if not(hub_sync_room_token_safe_char(c)) {
      return false
    }
  }
  true
}

///|
fn hub_sync_generate_room(remote_url : String) -> String {
  let seed = "room\n\{remote_url}\n\{@env.now().to_string()}"
  let (id, _) = @bitcore.create_blob_string(seed)
  "room-" + String::unsafe_substring(id.to_hex(), start=0, end=12)
}

///|
fn hub_sync_generate_room_token(remote_url : String, room : String) -> String {
  let seed = "room-token\n\{remote_url}\n\{room}\n\{@env.now().to_string()}"
  let (id, _) = @bitcore.create_blob_string(seed)
  "token-" + String::unsafe_substring(id.to_hex(), start=0, end=24)
}

///|
fn build_hub_sync_issue_url(
  options : HubSyncIssueUrlOptions,
) -> String raise @bitcore.GitError {
  guard options.remote_url is Some(remote_url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let relay_base = match hub_sync_parse_relay_base_url(remote_url) {
    Some(base) => hub_sync_strip_query(base)
    None =>
      if hub_sync_is_http_url(remote_url) {
        hub_sync_strip_query(hub_sync_trim_trailing_slash(remote_url))
      } else {
        raise @bitcore.GitError::InvalidObject(
          "hub sync issue-url: remote must be relay+http(s)://, relay://, or http(s)://",
        )
      }
  }
  let room = match options.room {
    Some(value) => value
    None => hub_sync_generate_room(relay_base)
  }
  if not(hub_sync_is_valid_room_name(room)) {
    raise @bitcore.GitError::InvalidObject(
      "hub sync issue-url: invalid room name: \{room}",
    )
  }
  let room_token = match options.room_token {
    Some(value) => value
    None => hub_sync_generate_room_token(relay_base, room)
  }
  if not(hub_sync_is_valid_room_token(room_token)) {
    raise @bitcore.GitError::InvalidObject(
      "hub sync issue-url: invalid room token",
    )
  }
  let relay_remote_url = if relay_base.has_prefix("http://") ||
    relay_base.has_prefix("https://") {
    "relay+" + relay_base
  } else {
    relay_base
  }
  "\{relay_remote_url}/?room=\{room}&room_token=\{room_token}"
}

///|
async fn handle_hub_sync_issue_url(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_issue_url_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  let invite_url = build_hub_sync_issue_url(options)
  print_line(invite_url)
}

///|
async fn handle_hub_sync_push(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_runtime_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  guard options.remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let result = @hub_native.hub_push(
    hub,
    fs,
    git_dir,
    url,
    signing_key=options.signing_key,
    require_signed=options.require_signed,
    auth_token=options.auth_token,
    conflict_policy=options.conflict_policy,
  )
  if result.success() {
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}

///|
async fn handle_hub_sync_clone_announce(
  args : Array[String],
) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_clone_announce_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  guard options.runtime.remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let accepted = @hub_native.relay_publish_clone_announce(
    url,
    options.clone_url,
    repo=options.repo,
    auth_token=options.runtime.auth_token,
  )
  if accepted {
    print_line("Clone announce published")
  } else {
    print_line("Clone announce already published (duplicate id)")
  }
}

///|
async fn handle_hub_sync_clone_peers(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_clone_peers_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  guard options.runtime.remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let peers = @hub_native.relay_list_clone_peers(
    url,
    auth_token=options.runtime.auth_token,
    include_self=options.include_self,
  )
  if peers.length() == 0 {
    print_line("No clone peers found")
    return ()
  }
  for peer in peers {
    let (sender, clone_url, repo) = peer
    match repo {
      Some(repo_name) => print_line("\{sender}\t\{clone_url}\t\{repo_name}")
      None => print_line("\{sender}\t\{clone_url}")
    }
  }
}

///|
fn load_hub_record_store(
  objects : &@bitlib.ObjectStore,
  refs : &@bitlib.RefStore,
) -> @hub.HubStore raise @bitcore.GitError {
  @hub.HubStore::load(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
}

///|
fn select_notify_records(
  records : Array[@hub.HubRecord],
) -> Map[String, @hub.HubRecord] {
  let selected : Map[String, @hub.HubRecord] = {}
  for record in records {
    if @hub.record_notify_topic(record) is Some(_) {
      selected[record.key] = record
    }
  }
  selected
}

///|
fn collect_notify_records_from_store(
  store : @hub.HubStore,
  objects : &@bitlib.ObjectStore,
) -> Map[String, @hub.HubRecord] {
  let records = store.list_records(objects, "hub/")
  select_notify_records(records)
}

///|
fn collect_changed_notify_records(
  before : Map[String, @hub.HubRecord],
  after : Map[String, @hub.HubRecord],
) -> Array[@hub.HubRecord] {
  let changed : Array[@hub.HubRecord] = []
  for key, record in after {
    match before.get(key) {
      Some(prev) =>
        if prev.serialize() != record.serialize() {
          changed.push(record)
        }
      None => changed.push(record)
    }
  }
  changed.sort_by(fn(a, b) {
    if a.key < b.key {
      -1
    } else if a.key > b.key {
      1
    } else {
      0
    }
  })
  changed
}

///|
fn format_hub_notify_message(topic : String, record : @hub.HubRecord) -> String {
  match topic {
    "hub.pr.proposal" => {
      let proposal = @hub.parse_legacy_pull_request(record.payload) catch {
        _ => return "[hub.notify] hub.pr.proposal key=\{record.key}"
      }
      "[hub.notify] hub.pr.proposal #\{proposal.id()} [\{proposal.state().to_string()}] \{proposal.title()}"
    }
    _ => "[hub.notify] \{topic} key=\{record.key}"
  }
}

///|
async fn run_hub_notify_hook(
  fs : OsFs,
  git_dir : String,
  topic : String,
  record : @hub.HubRecord,
) -> Int {
  let hook_path = git_dir + "/hooks/hub-notify"
  if not(fs.is_file(hook_path)) {
    return -1
  }
  @process.run(
    hook_path,
    [topic, record.kind, record.key, record.node],
    inherit_env=true,
    cwd=os_parent_path(git_dir),
  ) catch {
    _ => 1
  }
}

///|
async fn dispatch_hub_notify_events(
  fs : OsFs,
  git_dir : String,
  changed : Array[@hub.HubRecord],
) -> Unit {
  for record in changed {
    match @hub.record_notify_topic(record) {
      Some(topic) => {
        let code = run_hub_notify_hook(fs, git_dir, topic, record)
        if code > 0 {
          eprint_line("bit relay notify: hook failed (\{code}) for \{topic}")
        }
        if code != 0 {
          eprint_line(format_hub_notify_message(topic, record))
        }
      }
      None => ()
    }
  }
}

///|
async fn handle_hub_sync_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_runtime_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  guard options.remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let before_store = load_hub_record_store(objects, refs)
  let before_notify = collect_notify_records_from_store(before_store, objects)
  let hub = load_hub_store(objects, refs)
  let result = @hub_native.hub_fetch(
    hub,
    fs,
    fs,
    git_dir,
    url,
    signing_key=options.signing_key,
    require_signed=options.require_signed,
    auth_token=options.auth_token,
    conflict_policy=options.conflict_policy,
  )
  if result.success() {
    let after_store = load_hub_record_store(objects, refs)
    let after_notify = collect_notify_records_from_store(after_store, objects)
    let changed_notify = collect_changed_notify_records(
      before_notify, after_notify,
    )
    dispatch_hub_notify_events(fs, git_dir, changed_notify)
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}
