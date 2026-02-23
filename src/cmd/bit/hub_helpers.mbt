///|
fn default_hub_merge_policy() -> @hub.PrMergePolicy {
  @hub.PrMergePolicy::default()
}

///|
fn default_hub_merge_policy_toml() -> String {
  let template =
    #|# Hub merge policy
    #|# required_approvals: minimum number of latest approved reviews
    #|# allow_request_changes: allow merge while latest review requests changes
    #|# require_signed_records: require PR metadata and reviews to be signed
    #|# required_workflows: workflow task names that must be latest-success
    #|[merge]
    #|required_approvals = 0
    #|allow_request_changes = true
    #|require_signed_records = false
    #|required_workflows = []
  template
}

///|
fn parse_merge_policy_bool(
  value : String,
  key : String,
) -> Bool raise @bitcore.GitError {
  let normalized = value.to_lower()
  match normalized {
    "true" | "1" | "yes" => true
    "false" | "0" | "no" => false
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: '\{key}' must be true or false: \{value}",
      )
  }
}

///|
fn parse_merge_policy_string_array(
  value : String,
  key : String,
) -> Array[String] raise @bitcore.GitError {
  let parsed = @json.parse(value) catch {
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: '\{key}' must be JSON string array: \{value}",
      )
  }
  match parsed {
    Json::Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(text) => out.push(text)
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "hub merge policy: '\{key}' must contain only strings",
            )
        }
      }
      out
    }
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: '\{key}' must be string array",
      )
  }
}

///|
fn parse_hub_merge_policy_toml(
  content : String,
) -> @hub.PrMergePolicy raise @bitcore.GitError {
  let mut required_approvals = 0
  let mut allow_request_changes = true
  let mut require_signed_records = false
  let mut required_workflows : Array[String] = []
  let mut in_merge_section = false
  for line_view in content.split("\n") {
    let raw_line = line_view.to_string()
    let line = trim_string(raw_line)
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let section_name = trim_string(
        String::unsafe_substring(line, start=1, end=line.length() - 1),
      )
      in_merge_section = section_name == "merge"
      continue
    }
    if not(in_merge_section) {
      continue
    }
    let eq_idx = line.find("=")
    guard eq_idx is Some(i) else {
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: expected key=value in [merge]: \{line}",
      )
    }
    let key = trim_string(String::unsafe_substring(line, start=0, end=i))
    let value_part = trim_string(
      String::unsafe_substring(line, start=i + 1, end=line.length()),
    )
    let value = match value_part.find("#") {
      Some(comment_start) =>
        trim_string(
          String::unsafe_substring(value_part, start=0, end=comment_start),
        )
      None => value_part
    }
    match key {
      "required_approvals" => {
        let parsed = @strconv.parse_int(value) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "hub merge policy: required_approvals must be int: \{value}",
            )
        }
        if parsed < 0 {
          raise @bitcore.GitError::InvalidObject(
            "hub merge policy: required_approvals must be >= 0",
          )
        }
        required_approvals = parsed
      }
      "allow_request_changes" =>
        allow_request_changes = parse_merge_policy_bool(value, key)
      "require_signed_records" =>
        require_signed_records = parse_merge_policy_bool(value, key)
      "required_workflows" =>
        required_workflows = parse_merge_policy_string_array(value, key)
      _ =>
        raise @bitcore.GitError::InvalidObject(
          "hub merge policy: unknown key in [merge]: \{key}",
        )
    }
  }
  @hub.PrMergePolicy::new(
    required_approvals,
    allow_request_changes,
    require_signed_records,
    required_workflows~,
  )
}

///|
fn hub_merge_policy_path(git_dir : String) -> String {
  git_dir + "/hub/policy.toml"
}

///|
fn ensure_hub_merge_policy_file(
  fs : OsFs,
  git_dir : String,
) -> Unit raise @bitcore.GitError {
  let policy_path = hub_merge_policy_path(git_dir)
  if fs.is_file(policy_path) {
    return ()
  }
  fs.mkdir_p(git_dir + "/hub")
  fs.write_string(policy_path, default_hub_merge_policy_toml())
}

///|
fn load_hub_merge_policy(
  fs : OsFs,
  git_dir : String,
) -> @hub.PrMergePolicy raise @bitcore.GitError {
  let policy_path = hub_merge_policy_path(git_dir)
  if not(fs.is_file(policy_path)) {
    return default_hub_merge_policy()
  }
  let content = decode_bytes(fs.read_file(policy_path))
  parse_hub_merge_policy_toml(content)
}

///|
fn parse_positive_list_limit(value : String) -> Int raise @bitcore.GitError {
  let parsed = @strconv.parse_int(value) catch {
    _ => raise @bitcore.GitError::InvalidObject("Invalid limit: \{value}")
  }
  if parsed <= 0 {
    raise @bitcore.GitError::InvalidObject("Limit must be positive")
  }
  parsed
}

///|
fn parse_pr_state_flag(value : String) -> @hub.PrState? {
  match parse_work_item_state_flag(value) {
    Some(work_item_state) => Some(work_item_state.to_pr_state())
    None => None
  }
}

///|
fn parse_issue_state_flag(value : String) -> @hub.IssueState? {
  match parse_work_item_state_flag(value) {
    Some(work_item_state) => work_item_state.to_issue_state()
    None => None
  }
}

///|
fn parse_work_item_state_flag(value : String) -> @hub.WorkItemState? {
  match value {
    "--open" => Some(@hub.WorkItemState::Open)
    "--closed" => Some(@hub.WorkItemState::Closed)
    "--merged" => Some(@hub.WorkItemState::Merged)
    _ => None
  }
}

///|
fn parse_work_item_kind_flag(value : String) -> @hub.WorkItemKind? {
  match value {
    "--issue" => Some(@hub.WorkItemKind::Issue)
    "--pr" | "--pull-request" => Some(@hub.WorkItemKind::PullRequest)
    _ => None
  }
}

///|
fn normalize_hub_pr_subcommand(subcmd : String) -> String {
  match subcmd {
    "view" => "get"
    "edit" => "update"
    "proposal" => "proposals"
    _ => subcmd
  }
}

///|
fn normalize_hub_issue_subcommand(subcmd : String) -> String {
  match subcmd {
    "view" => "get"
    "edit" => "update"
    _ => subcmd
  }
}

///|
fn normalize_hub_work_item_subcommand(subcmd : String) -> String {
  match subcmd {
    "view" => "get"
    _ => subcmd
  }
}

///|
fn resolve_hub_comment_subcommand(subcmd : String) -> String {
  match subcmd {
    "add" | "list" | "help" | "-h" | "--help" => subcmd
    _ => "add"
  }
}

///|
fn resolve_hub_review_subcommand(subcmd : String) -> String {
  match subcmd {
    "submit" | "list" | "help" | "-h" | "--help" => subcmd
    _ => "submit"
  }
}

///|
fn parse_review_verdict_flag(value : String) -> @hub.ReviewVerdict? {
  match value {
    "--approve" | "--approved" => Some(@hub.ReviewVerdict::Approved)
    "--comment" => Some(@hub.ReviewVerdict::Comment)
    "--request-changes" => Some(@hub.ReviewVerdict::RequestChanges)
    _ => None
  }
}

///|
fn parse_merge_strategy_flag(value : String) -> @hub.PrMergeStrategy? {
  match value {
    "--merge" => Some(@hub.PrMergeStrategy::Merge)
    "--squash" => Some(@hub.PrMergeStrategy::Squash)
    "--ff" | "--fast-forward" => Some(@hub.PrMergeStrategy::FastForward)
    _ => None
  }
}

///|
fn parse_pr_state(value : String) -> @hub.PrState? {
  match parse_work_item_state(value) {
    Some(work_item_state) => Some(work_item_state.to_pr_state())
    None => None
  }
}

///|
fn parse_issue_state(value : String) -> @hub.IssueState? {
  match parse_work_item_state(value) {
    Some(work_item_state) => work_item_state.to_issue_state()
    None => None
  }
}

///|
fn parse_work_item_state(value : String) -> @hub.WorkItemState? {
  match value {
    "open" => Some(@hub.WorkItemState::Open)
    "closed" => Some(@hub.WorkItemState::Closed)
    "merged" => Some(@hub.WorkItemState::Merged)
    _ => None
  }
}

///|
fn parse_work_item_kind(value : String) -> @hub.WorkItemKind? {
  match value {
    "issue" => Some(@hub.WorkItemKind::Issue)
    "pr" | "pull-request" | "pullrequest" =>
      Some(@hub.WorkItemKind::PullRequest)
    _ => None
  }
}

///|
fn parse_review_verdict(value : String) -> @hub.ReviewVerdict? {
  match value {
    "approved" | "approve" => Some(@hub.ReviewVerdict::Approved)
    "comment" => Some(@hub.ReviewVerdict::Comment)
    "request-changes" | "request_changes" =>
      Some(@hub.ReviewVerdict::RequestChanges)
    _ => None
  }
}

///|
fn parse_merge_strategy(value : String) -> @hub.PrMergeStrategy? {
  match value {
    "merge" => Some(@hub.PrMergeStrategy::Merge)
    "squash" => Some(@hub.PrMergeStrategy::Squash)
    "ff" | "fast-forward" | "fastforward" =>
      Some(@hub.PrMergeStrategy::FastForward)
    _ => None
  }
}

///|
fn format_pr_summary(pr : @hub.PullRequest) -> String {
  let id = pr.id()
  let title = pr.title()
  let state = pr.state().to_string()
  "#\{id} [\{state}] \{title}"
}

///|
fn format_issue_summary(issue : @hub.Issue) -> String {
  let id = issue.id()
  let title = issue.title()
  let state = issue.state().to_string()
  "#\{id} [\{state}] \{title}"
}

///|
fn format_work_item_summary(item : @hub.WorkItem) -> String {
  let id = item.id()
  let title = item.title()
  let kind = item.kind().to_string()
  let state = item.state().to_string()
  "#\{id} [\{kind}/\{state}] \{title}"
}

///|
fn format_work_item_detail(item : @hub.WorkItem) -> String {
  let sb = StringBuilder::new()
  sb.write_string("id ")
  sb.write_string(item.id())
  sb.write_char('\n')
  sb.write_string("kind ")
  sb.write_string(item.kind().to_string())
  sb.write_char('\n')
  sb.write_string("state ")
  sb.write_string(item.state().to_string())
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(item.author())
  sb.write_char('\n')
  sb.write_string("created-at ")
  sb.write_string(item.created_at().to_string())
  sb.write_char('\n')
  sb.write_string("updated-at ")
  sb.write_string(item.updated_at().to_string())
  sb.write_char('\n')
  for label in item.labels() {
    sb.write_string("label ")
    sb.write_string(label)
    sb.write_char('\n')
  }
  for assignee in item.assignees() {
    sb.write_string("assignee ")
    sb.write_string(assignee)
    sb.write_char('\n')
  }
  for linked_pr in item.linked_prs() {
    sb.write_string("linked-pr ")
    sb.write_string(linked_pr)
    sb.write_char('\n')
  }
  match item.patch() {
    None => ()
    Some(patch) => {
      sb.write_string("source-branch ")
      sb.write_string(patch.source_branch())
      sb.write_char('\n')
      match patch.source_repo() {
        Some(source_repo) => {
          sb.write_string("source-repo ")
          sb.write_string(source_repo)
          sb.write_char('\n')
        }
        None => ()
      }
      match patch.source_ref() {
        Some(source_ref) => {
          sb.write_string("source-ref ")
          sb.write_string(source_ref)
          sb.write_char('\n')
        }
        None => ()
      }
      sb.write_string("source-commit ")
      sb.write_string(patch.source_commit().to_hex())
      sb.write_char('\n')
      sb.write_string("target-branch ")
      sb.write_string(patch.target_branch())
      sb.write_char('\n')
      sb.write_string("target-commit ")
      sb.write_string(patch.target_commit().to_hex())
      sb.write_char('\n')
      for closes_issue in patch.closes_issues() {
        sb.write_string("closes-issue ")
        sb.write_string(closes_issue)
        sb.write_char('\n')
      }
      match patch.merge_commit() {
        Some(merge_commit) => {
          sb.write_string("merge-commit ")
          sb.write_string(merge_commit.to_hex())
          sb.write_char('\n')
        }
        None => ()
      }
    }
  }
  sb.write_string("title ")
  sb.write_string(item.title())
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(item.body())
  sb.to_string()
}

///|
fn note_ns(ns : String?) -> String {
  ns.unwrap_or("commits")
}
