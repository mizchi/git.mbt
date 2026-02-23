///| Dispatch for `bit relay` top-level command.

///| Delegates to existing serve/sync implementations.

///|
fn print_relay_usage() -> Unit {
  println("Usage: bit relay <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  serve         Serve repository via relay for remote cloning")
  println("  sync          Sync hub refs with relay remotes")
  println("  help          Show this help")
  println("")
  println("Run 'bit relay <subcommand> -h' for details.")
}

///|
async fn handle_relay(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_relay_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "help" | "-h" | "--help" => print_relay_usage()
    "serve" => handle_hub_serve(rest)
    "sync" => handle_hub_sync(rest)
    _ => {
      eprint_line("bit relay: unknown subcommand '\{subcmd}'")
      print_relay_usage()
      @sys.exit(1)
    }
  }
}
