///|
fn print_debug_usage() -> Unit {
  println("Usage: bit debug <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  dump          Dump raw hub records from notes")
  println("  help          Show this help")
  println("")
  println("Run 'bit debug <subcommand> -h' for details.")
}

///|
async fn handle_debug(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_debug_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "help" | "-h" | "--help" => print_debug_usage()
    "dump" => handle_hub_dump(rest)
    _ => {
      eprint_line("bit debug: unknown subcommand '\{subcmd}'")
      print_debug_usage()
      @sys.exit(1)
    }
  }
}
