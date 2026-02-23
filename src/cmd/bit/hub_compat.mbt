///|
fn print_hub_deprecation_guide() -> Unit {
  println("'bit hub' is deprecated. Use the following commands instead:")
  println("")
  println("  bit hub pr ...         ->  bit pr ...")
  println("  bit hub issue ...      ->  bit issue ...")
  println("  bit hub init           ->  bit pr init / bit issue init")
  println(
    "  bit hub work-item ...  ->  bit pr list --kind=all / bit issue list --kind=all",
  )
  println(
    "  bit hub search ...     ->  bit pr search ... / bit issue search ...",
  )
  println("  bit hub note ...       ->  bit pr note ... / bit issue note ...")
  println("  bit hub dump ...       ->  bit debug dump ...")
  println("  bit hub sync ...       ->  bit relay sync ...")
  println("  bit hub serve ...      ->  bit relay serve ...")
}

///|
async fn hub_deprecation_warning(old_cmd : String, new_cmd : String) -> Unit {
  eprint_line("warning: '\{old_cmd}' is deprecated. Use '\{new_cmd}' instead.")
}

///|
async fn handle_hub(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_deprecation_guide()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "help" | "-h" | "--help" => print_hub_deprecation_guide()
    "init" => {
      hub_deprecation_warning("bit hub init", "bit pr init")
      handle_hub_init(rest)
    }
    "pr" => {
      hub_deprecation_warning("bit hub pr", "bit pr")
      handle_hub_pr(rest)
    }
    "issue" => {
      hub_deprecation_warning("bit hub issue", "bit issue")
      handle_hub_issue(rest)
    }
    "work-item" | "workitem" | "item" => {
      hub_deprecation_warning("bit hub work-item", "bit pr list --kind=all")
      handle_hub_work_item(rest)
    }
    "note" => {
      hub_deprecation_warning("bit hub note", "bit pr note / bit issue note")
      handle_hub_note(rest)
    }
    "sync" => {
      hub_deprecation_warning("bit hub sync", "bit relay sync")
      handle_hub_sync(rest)
    }
    "dump" => {
      hub_deprecation_warning("bit hub dump", "bit debug dump")
      handle_hub_dump(rest)
    }
    "search" => {
      hub_deprecation_warning(
        "bit hub search", "bit pr search / bit issue search",
      )
      handle_hub_search(rest)
    }
    "serve" => {
      hub_deprecation_warning("bit hub serve", "bit relay serve")
      handle_hub_serve(rest)
    }
    _ => {
      eprint_line("bit hub: unknown subcommand '\{subcmd}'")
      print_hub_deprecation_guide()
      @sys.exit(1)
    }
  }
}
