///|
fn print_hub_search_usage() -> Unit {
  println("Usage: bit pr|issue search [<query>...] [<options>]")
  println("")
  println("Options:")
  println(
    "  --type <pr|issue|pr-comment|pr-review|issue-comment|comment|review|all>",
  )
  println("  --state <open|closed|merged|all>")
  println("  --author <author>")
  println("  --label <label>         (repeatable)")
  println("  --limit <n>")
  println("  -h, --help              Show this help")
}

///|
enum HubSearchType {
  Pr
  Issue
  PrComment
  PrReview
  IssueComment
}

///|
struct HubSearchOptions {
  query : String?
  types : Array[HubSearchType]
  state : String?
  author : String?
  labels : Array[String]
  limit : Int?
}

///|
fn all_hub_search_types() -> Array[HubSearchType] {
  [
    HubSearchType::Pr,
    HubSearchType::Issue,
    HubSearchType::PrComment,
    HubSearchType::PrReview,
    HubSearchType::IssueComment,
  ]
}

///|
fn hub_search_type_eq(a : HubSearchType, b : HubSearchType) -> Bool {
  match (a, b) {
    (HubSearchType::Pr, HubSearchType::Pr) => true
    (HubSearchType::Issue, HubSearchType::Issue) => true
    (HubSearchType::PrComment, HubSearchType::PrComment) => true
    (HubSearchType::PrReview, HubSearchType::PrReview) => true
    (HubSearchType::IssueComment, HubSearchType::IssueComment) => true
    _ => false
  }
}

///|
fn hub_search_has_type(types : Array[HubSearchType], t : HubSearchType) -> Bool {
  for existing in types {
    if hub_search_type_eq(existing, t) {
      return true
    }
  }
  false
}

///|
fn push_unique_search_type(
  types : Array[HubSearchType],
  t : HubSearchType,
) -> Unit {
  if not(hub_search_has_type(types, t)) {
    types.push(t)
  }
}

///|
fn append_hub_search_types_by_token(
  out : Array[HubSearchType],
  token : String,
) -> Bool {
  match token {
    "all" => {
      for t in all_hub_search_types() {
        push_unique_search_type(out, t)
      }
      true
    }
    "pr" => {
      push_unique_search_type(out, HubSearchType::Pr)
      true
    }
    "issue" => {
      push_unique_search_type(out, HubSearchType::Issue)
      true
    }
    "pr-comment" => {
      push_unique_search_type(out, HubSearchType::PrComment)
      true
    }
    "pr-review" | "review" => {
      push_unique_search_type(out, HubSearchType::PrReview)
      true
    }
    "issue-comment" => {
      push_unique_search_type(out, HubSearchType::IssueComment)
      true
    }
    "comment" => {
      push_unique_search_type(out, HubSearchType::PrComment)
      push_unique_search_type(out, HubSearchType::IssueComment)
      true
    }
    _ => false
  }
}

///|
fn parse_hub_search_types(value : String) -> Array[HubSearchType]? {
  let out : Array[HubSearchType] = []
  for part_view in value.split(",") {
    let token = trim_string(part_view.to_string()).to_lower()
    if token.length() == 0 {
      continue
    }
    if not(append_hub_search_types_by_token(out, token)) {
      return None
    }
  }
  if out.length() == 0 {
    None
  } else {
    Some(out)
  }
}

///|
fn parse_hub_search_state(value : String) -> String? {
  let normalized = value.to_lower()
  match normalized {
    "open" | "closed" | "merged" | "all" => Some(normalized)
    _ => None
  }
}

///|
fn parse_hub_search_options(
  args : Array[String],
  default_types? : Array[HubSearchType],
) -> HubSearchOptions raise @bitcore.GitError {
  let query_parts : Array[String] = []
  let mut types = match default_types {
    Some(dt) => dt
    None => all_hub_search_types()
  }
  let mut type_filter_set = false
  let mut state : String? = None
  let mut author : String? = None
  let labels : Array[String] = []
  let mut limit : Int? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--type" if i + 1 < args.length() => {
        let value = args[i + 1]
        let parsed = parse_hub_search_types(value)
        guard parsed is Some(parsed_types) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search type: \{value}",
          )
        }
        if not(type_filter_set) {
          types = []
          type_filter_set = true
        }
        for t in parsed_types {
          push_unique_search_type(types, t)
        }
        i += 2
        continue
      }
      "--type" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --type requires a value",
        )
      _ if arg.has_prefix("--type=") => {
        let value = String::unsafe_substring(arg, start=7, end=arg.length())
        let parsed = parse_hub_search_types(value)
        guard parsed is Some(parsed_types) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search type: \{value}",
          )
        }
        if not(type_filter_set) {
          types = []
          type_filter_set = true
        }
        for t in parsed_types {
          push_unique_search_type(types, t)
        }
        i += 1
        continue
      }
      "--state" if i + 1 < args.length() => {
        let value = args[i + 1]
        let parsed = parse_hub_search_state(value)
        guard parsed is Some(s) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search state: \{value}",
          )
        }
        state = Some(s)
        i += 2
        continue
      }
      "--state" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        let parsed = parse_hub_search_state(value)
        guard parsed is Some(s) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search state: \{value}",
          )
        }
        state = Some(s)
        i += 1
        continue
      }
      "--open" | "--closed" | "--merged" => {
        let parsed = parse_hub_search_state(
          String::unsafe_substring(arg, start=2, end=arg.length()),
        )
        guard parsed is Some(s) else { panic() }
        state = Some(s)
        i += 1
        continue
      }
      "--author" if i + 1 < args.length() => {
        author = Some(args[i + 1])
        i += 2
        continue
      }
      "--author" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --author requires a value",
        )
      _ if arg.has_prefix("--author=") => {
        author = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
        i += 1
        continue
      }
      "--label" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--label" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --label requires a value",
        )
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = Some(parse_positive_list_limit(args[i + 1]))
        i += 2
        continue
      }
      "--limit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --limit requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = Some(parse_positive_list_limit(value))
        i += 1
        continue
      }
      "-h" | "--help" | "help" => {
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub search option: \{arg}",
        )
      _ => {
        query_parts.push(arg)
        i += 1
        continue
      }
    }
  }
  let query = if query_parts.length() == 0 {
    None
  } else {
    Some(query_parts.join(" "))
  }
  { query, types, state, author, labels, limit }
}

///|
fn matches_author_filter(author_filter : String?, actual : String) -> Bool {
  match author_filter {
    Some(author) => actual.to_lower().contains(author.to_lower())
    None => true
  }
}

///|
fn matches_labels_filter(
  required_labels : Array[String],
  labels : Array[String],
) -> Bool {
  if required_labels.length() == 0 {
    return true
  }
  let lower_labels : Array[String] = []
  for label in labels {
    lower_labels.push(label.to_lower())
  }
  for required in required_labels {
    if not(lower_labels.contains(required.to_lower())) {
      return false
    }
  }
  true
}

///|
fn matches_query_filter(query : String?, fields : Array[String]) -> Bool {
  match query {
    None => true
    Some(raw_query) => {
      let needle = raw_query.to_lower()
      for field in fields {
        if field.to_lower().contains(needle) {
          return true
        }
      }
      false
    }
  }
}

///|
fn matches_pr_state_filter(
  state_filter : String?,
  state : @hub.PrState,
) -> Bool {
  match state_filter {
    None => true
    Some("all") => true
    Some(value) => state.to_string() == value
  }
}

///|
fn matches_issue_state_filter(
  state_filter : String?,
  state : @hub.IssueState,
) -> Bool {
  match state_filter {
    None => true
    Some("all") => true
    Some("merged") => false
    Some(value) => state.to_string() == value
  }
}

///|
fn search_limit_reached(limit : Int?, current : Int) -> Bool {
  match limit {
    Some(max) => current >= max
    None => false
  }
}

///|
fn preview_text(text : String) -> String {
  match text.find("\n") {
    Some(idx) => String::unsafe_substring(text, start=0, end=idx)
    None => text
  }
}

///|
async fn handle_hub_search(args : Array[String]) -> Unit raise Error {
  if args.length() > 0 {
    match args[0] {
      "-h" | "--help" | "help" => {
        print_hub_search_usage()
        return ()
      }
      _ => ()
    }
  }
  let options = parse_hub_search_options(args)
  let include_pr = hub_search_has_type(options.types, HubSearchType::Pr)
  let include_issue = hub_search_has_type(options.types, HubSearchType::Issue)
  let include_pr_comment = hub_search_has_type(
    options.types,
    HubSearchType::PrComment,
  )
  let include_pr_review = hub_search_has_type(
    options.types,
    HubSearchType::PrReview,
  )
  let include_issue_comment = hub_search_has_type(
    options.types,
    HubSearchType::IssueComment,
  )

  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let results : Array[String] = []

  if include_pr || include_pr_comment || include_pr_review {
    let prs = hub.list_prs(objects)
    for pr in prs {
      if search_limit_reached(options.limit, results.length()) {
        break
      }
      if not(matches_pr_state_filter(options.state, pr.state())) {
        continue
      }
      if not(matches_labels_filter(options.labels, pr.labels())) {
        continue
      }
      if include_pr &&
        matches_author_filter(options.author, pr.author()) &&
        matches_query_filter(options.query, [
          pr.id(),
          pr.title(),
          pr.body(),
          pr.author(),
          pr.labels().join(","),
        ]) {
        results.push("pr #\{pr.id()} [\{pr.state().to_string()}] \{pr.title()}")
      }
      if include_pr_comment {
        let comments = hub.list_comments(objects, pr.id())
        for comment in comments {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, comment.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              comment.id(),
              comment.pr_id(),
              comment.author(),
              comment.body(),
            ]) {
            results.push(
              "pr-comment #\{comment.pr_id()}/\{comment.id()} \{comment.author()}: \{preview_text(comment.body())}",
            )
          }
        }
      }
      if include_pr_review {
        let reviews = hub.list_reviews(objects, pr.id())
        for review in reviews {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, review.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              review.id(),
              review.pr_id(),
              review.author(),
              review.verdict().to_string(),
              review.body(),
            ]) {
            results.push(
              "pr-review #\{review.pr_id()}/\{review.id()} \{review.author()} [\{review.verdict().to_string()}]: \{preview_text(review.body())}",
            )
          }
        }
      }
    }
  }

  if include_issue || include_issue_comment {
    let issues = hub.list_issues(objects)
    for issue in issues {
      if search_limit_reached(options.limit, results.length()) {
        break
      }
      if not(matches_issue_state_filter(options.state, issue.state())) {
        continue
      }
      if not(matches_labels_filter(options.labels, issue.labels())) {
        continue
      }
      if include_issue &&
        matches_author_filter(options.author, issue.author()) &&
        matches_query_filter(options.query, [
          issue.id(),
          issue.title(),
          issue.body(),
          issue.author(),
          issue.labels().join(","),
          issue.assignees().join(","),
        ]) {
        results.push(
          "issue #\{issue.id()} [\{issue.state().to_string()}] \{issue.title()}",
        )
      }
      if include_issue_comment {
        let comments = hub.list_issue_comments(objects, issue.id())
        for comment in comments {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, comment.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              comment.id(),
              comment.issue_id(),
              comment.author(),
              comment.body(),
            ]) {
            results.push(
              "issue-comment #\{comment.issue_id()}/\{comment.id()} \{comment.author()}: \{preview_text(comment.body())}",
            )
          }
        }
      }
    }
  }

  if results.length() == 0 {
    print_line("No matches")
    return ()
  }
  for result in results {
    print_line(result)
  }
}

///|
async fn handle_hub_search_with_defaults(
  args : Array[String],
  default_types : Array[HubSearchType],
  usage_fn : () -> Unit,
) -> Unit raise Error {
  if args.length() > 0 {
    match args[0] {
      "-h" | "--help" | "help" => {
        usage_fn()
        return ()
      }
      _ => ()
    }
  }
  let options = parse_hub_search_options(args, default_types~)
  let include_pr = hub_search_has_type(options.types, HubSearchType::Pr)
  let include_issue = hub_search_has_type(options.types, HubSearchType::Issue)
  let include_pr_comment = hub_search_has_type(
    options.types,
    HubSearchType::PrComment,
  )
  let include_pr_review = hub_search_has_type(
    options.types,
    HubSearchType::PrReview,
  )
  let include_issue_comment = hub_search_has_type(
    options.types,
    HubSearchType::IssueComment,
  )

  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let results : Array[String] = []

  if include_pr || include_pr_comment || include_pr_review {
    let prs = hub.list_prs(objects)
    for pr in prs {
      if search_limit_reached(options.limit, results.length()) {
        break
      }
      if not(matches_pr_state_filter(options.state, pr.state())) {
        continue
      }
      if not(matches_labels_filter(options.labels, pr.labels())) {
        continue
      }
      if include_pr &&
        matches_author_filter(options.author, pr.author()) &&
        matches_query_filter(options.query, [
          pr.id(),
          pr.title(),
          pr.body(),
          pr.author(),
          pr.labels().join(","),
        ]) {
        results.push("pr #\{pr.id()} [\{pr.state().to_string()}] \{pr.title()}")
      }
      if include_pr_comment {
        let comments = hub.list_comments(objects, pr.id())
        for comment in comments {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, comment.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              comment.id(),
              comment.pr_id(),
              comment.author(),
              comment.body(),
            ]) {
            results.push(
              "pr-comment #\{comment.pr_id()}/\{comment.id()} \{comment.author()}: \{preview_text(comment.body())}",
            )
          }
        }
      }
      if include_pr_review {
        let reviews = hub.list_reviews(objects, pr.id())
        for review in reviews {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, review.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              review.id(),
              review.pr_id(),
              review.author(),
              review.verdict().to_string(),
              review.body(),
            ]) {
            results.push(
              "pr-review #\{review.pr_id()}/\{review.id()} \{review.author()} [\{review.verdict().to_string()}]: \{preview_text(review.body())}",
            )
          }
        }
      }
    }
  }

  if include_issue || include_issue_comment {
    let issues = hub.list_issues(objects)
    for issue in issues {
      if search_limit_reached(options.limit, results.length()) {
        break
      }
      if not(matches_issue_state_filter(options.state, issue.state())) {
        continue
      }
      if not(matches_labels_filter(options.labels, issue.labels())) {
        continue
      }
      if include_issue &&
        matches_author_filter(options.author, issue.author()) &&
        matches_query_filter(options.query, [
          issue.id(),
          issue.title(),
          issue.body(),
          issue.author(),
          issue.labels().join(","),
          issue.assignees().join(","),
        ]) {
        results.push(
          "issue #\{issue.id()} [\{issue.state().to_string()}] \{issue.title()}",
        )
      }
      if include_issue_comment {
        let comments = hub.list_issue_comments(objects, issue.id())
        for comment in comments {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, comment.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              comment.id(),
              comment.issue_id(),
              comment.author(),
              comment.body(),
            ]) {
            results.push(
              "issue-comment #\{comment.issue_id()}/\{comment.id()} \{comment.author()}: \{preview_text(comment.body())}",
            )
          }
        }
      }
    }
  }

  if results.length() == 0 {
    print_line("No matches")
    return ()
  }
  for result in results {
    print_line(result)
  }
}
