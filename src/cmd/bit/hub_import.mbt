///|
enum GitHubImportProvider {
  GhCli
  JsonFile
}

///|
fn parse_github_import_provider(value : String) -> GitHubImportProvider? {
  match value.to_lower() {
    "gh" | "gh-cli" => Some(GitHubImportProvider::GhCli)
    "json-file" | "file" => Some(GitHubImportProvider::JsonFile)
    _ => None
  }
}

///|
fn parse_github_import_provider_option(
  value : String,
) -> GitHubImportProvider raise @bitcore.GitError {
  match parse_github_import_provider(value) {
    Some(provider) => provider
    None =>
      raise @bitcore.GitError::InvalidObject(
        "Unknown GitHub import provider: \{value}",
      )
  }
}

///|
fn read_import_json_from_file(
  fs : OsFs,
  context : String,
  input_path : String?,
) -> (String, String) raise @bitcore.GitError {
  guard input_path is Some(path) else {
    raise @bitcore.GitError::InvalidObject(
      "\{context}: --input requires a file path when --provider=json-file",
    )
  }
  let bytes = fs.read_file(path) catch {
    err =>
      raise @bitcore.GitError::IoError(
        "\{context}: failed to read --input file '\{path}': \{err}",
      )
  }
  (decode_bytes(bytes), "")
}

///|
fn resolve_github_repo(
  fs : OsFs,
  git_dir : String,
  repo : String?,
) -> String raise @bitcore.GitError {
  match repo {
    Some(name) => name
    None => {
      let remote_url = get_effective_remote_url(fs, git_dir)
      guard remote_url is Some(url) else {
        raise @bitcore.GitError::InvalidObject(
          "No remote configured; use --repo",
        )
      }
      match @hq.parse_repo_url(url) {
        Some(parsed) => {
          let host = parsed.host_name()
          if host != "github.com" {
            raise @bitcore.GitError::InvalidObject(
              "Only github.com is supported for gh import",
            )
          }
          parsed.full_name()
        }
        None =>
          raise @bitcore.GitError::InvalidObject(
            "Cannot parse remote URL: \{url}",
          )
      }
    }
  }
}

///|
async fn gh_pr_list(
  repo : String,
  state : String,
  limit : Int,
) -> (String, String) raise @bitcore.GitError {
  let fields = "number,title,body,headRefName,headRefOid,headRepository,baseRefName,baseRefOid,author,createdAt,updatedAt,state,labels"
  let jq = "[.[] | {id:(.number|tostring), title:.title, body:(.body // \"\"), source_branch:.headRefName, source_ref:(if (.headRefName // \"\") == \"\" then \"\" else (\"refs/heads/\" + .headRefName) end), source_repo:((.headRepository // {}) | .nameWithOwner // \"\"), source_commit:.headRefOid, target_branch:.baseRefName, target_commit:.baseRefOid, author:(.author.login // \"unknown\"), created_at:(.createdAt|fromdateiso8601), updated_at:(.updatedAt|fromdateiso8601), state:(.state|ascii_downcase), labels:(.labels|map(.name))}]"
  let args = [
    "pr",
    "list",
    "--state",
    state,
    "--limit",
    limit.to_string(),
    "--json",
    fields,
    "--jq",
    jq,
    "--repo",
    repo,
  ]
  gh_collect_output(args)
}

///|
async fn gh_issue_list(
  repo : String,
  state : String,
  limit : Int,
) -> (String, String) raise @bitcore.GitError {
  let fields = "number,title,body,author,createdAt,updatedAt,state,labels,assignees"
  let jq = "[.[] | {id:(.number|tostring), title:.title, body:(.body // \"\"), author:(.author.login // \"unknown\"), created_at:(.createdAt|fromdateiso8601), updated_at:(.updatedAt|fromdateiso8601), state:(.state|ascii_downcase), labels:(.labels|map(.name)), assignees:(.assignees|map(.login))}]"
  let args = [
    "issue",
    "list",
    "--state",
    state,
    "--limit",
    limit.to_string(),
    "--json",
    fields,
    "--jq",
    jq,
    "--repo",
    repo,
  ]
  gh_collect_output(args)
}

///|
async fn gh_collect_output(
  args : Array[String],
) -> (String, String) raise @bitcore.GitError {
  let (code, stdout, stderr) = @process.collect_output(
    "gh",
    args,
    inherit_env=true,
  ) catch {
    err => raise @bitcore.GitError::IoError("gh failed: \{err}")
  }
  let out = stdout.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @bitcore.GitError::IoError(err.to_string())
    _ => ""
  }
  let err_text = stderr.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @bitcore.GitError::IoError(err.to_string())
    _ => ""
  }
  if code != 0 {
    let message = trim_string(err_text)
    raise @bitcore.GitError::InvalidObject("gh failed (\{code}): \{message}")
  }
  (out, err_text)
}

///|
fn parse_json_array(text : String) -> Array[Json] raise @bitcore.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @bitcore.GitError::InvalidObject(
        "Invalid JSON from gh: \{err.to_string()}",
      )
  }
  match parsed {
    Json::Array(items) => items
    _ => raise @bitcore.GitError::InvalidObject("Expected JSON array from gh")
  }
}

///|
fn json_get_string(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(Json::String(value)) => value
    Some(Json::Number(value, ..)) => value.to_string()
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    _ => fallback
  }
}

///|
fn json_get_int64(
  obj : Map[String, Json],
  key : String,
  fallback : Int64,
) -> Int64 {
  match obj.get(key) {
    Some(Json::Number(value, ..)) => value.to_int64()
    Some(Json::String(value)) =>
      @strconv.parse_int64(value) catch {
        _ => fallback
      }
    _ => fallback
  }
}

///|
fn json_get_string_array(
  obj : Map[String, Json],
  key : String,
) -> Array[String] {
  match obj.get(key) {
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => out.push(value)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
fn parse_gh_prs(
  text : String,
) -> Array[@hub.PullRequest] raise @bitcore.GitError {
  let items = parse_json_array(text)
  let out : Array[@hub.PullRequest] = []
  for item in items {
    match item {
      Json::Object(obj) => {
        let id = json_get_string(obj, "id", "")
        if id.length() == 0 {
          continue
        }
        let title = json_get_string(obj, "title", "")
        let body = json_get_string(obj, "body", "")
        let source_branch = json_get_string(obj, "source_branch", "")
        let source_ref_raw = json_get_string(obj, "source_ref", "")
        let source_repo_raw = json_get_string(obj, "source_repo", "")
        let target_branch = json_get_string(obj, "target_branch", "")
        let source_hex = json_get_string(obj, "source_commit", "")
        let target_hex = json_get_string(obj, "target_commit", "")
        if source_branch.length() == 0 || target_branch.length() == 0 {
          raise @bitcore.GitError::InvalidObject(
            "Missing branch name for PR \{id}",
          )
        }
        let source_commit = @bitcore.ObjectId::from_hex(source_hex) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "Invalid source commit for PR \{id}",
            )
        }
        let target_commit = @bitcore.ObjectId::from_hex(target_hex) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "Invalid target commit for PR \{id}",
            )
        }
        let author = json_get_string(obj, "author", "unknown")
        let created_at = json_get_int64(obj, "created_at", 0L)
        let updated_at = json_get_int64(obj, "updated_at", created_at)
        let labels = json_get_string_array(obj, "labels")
        let state_raw = json_get_string(obj, "state", "open").to_lower()
        let state = match parse_pr_state(state_raw) {
          Some(s) => s
          None => @hub.PrState::Open
        }
        let source_repo = if source_repo_raw.length() == 0 {
          None
        } else {
          Some(source_repo_raw)
        }
        let source_ref = if source_ref_raw.length() == 0 {
          None
        } else {
          Some(source_ref_raw)
        }
        let pr = @hub.PullRequest::new(
          id,
          title,
          body,
          source_branch,
          source_commit,
          target_branch,
          target_commit,
          author,
          created_at,
          updated_at,
          state,
          labels,
          source_repo~,
          source_ref~,
        )
        out.push(pr)
      }
      _ => ()
    }
  }
  out
}

///|
fn parse_gh_issues(text : String) -> Array[@hub.Issue] raise @bitcore.GitError {
  let items = parse_json_array(text)
  let out : Array[@hub.Issue] = []
  for item in items {
    match item {
      Json::Object(obj) => {
        let id = json_get_string(obj, "id", "")
        if id.length() == 0 {
          continue
        }
        let title = json_get_string(obj, "title", "")
        let body = json_get_string(obj, "body", "")
        let author = json_get_string(obj, "author", "unknown")
        let created_at = json_get_int64(obj, "created_at", 0L)
        let updated_at = json_get_int64(obj, "updated_at", created_at)
        let labels = json_get_string_array(obj, "labels")
        let assignees = json_get_string_array(obj, "assignees")
        let state_raw = json_get_string(obj, "state", "open").to_lower()
        let state = match parse_issue_state(state_raw) {
          Some(s) => s
          None => @hub.IssueState::Open
        }
        let issue = @hub.Issue::new(
          id,
          title,
          body,
          author,
          created_at,
          updated_at,
          state,
          labels~,
          assignees~,
        )
        out.push(issue)
      }
      _ => ()
    }
  }
  out
}

///|
fn parse_head_branch_name(head_content : String) -> String? {
  let text = trim_string(head_content)
  if text.has_prefix("ref: refs/heads/") {
    Some(String::unsafe_substring(text, start=16, end=text.length()))
  } else {
    None
  }
}

///|
fn detect_current_branch_name(git_dir : String) -> String? {
  let fs = OsFs::new()
  let head_bytes = fs.read_file(git_dir + "/HEAD") catch { _ => return None }
  parse_head_branch_name(decode_bytes(head_bytes))
}

///|
fn pr_matches_branch(pr : @hub.PullRequest, branch : String) -> Bool {
  let source_branch = pr.source_branch()
  let branch_ref = "refs/heads/" + branch
  if source_branch == branch || source_branch == branch_ref {
    return true
  }
  match pr.source_ref() {
    Some(source_ref) => source_ref == branch || source_ref == branch_ref
    None => false
  }
}
