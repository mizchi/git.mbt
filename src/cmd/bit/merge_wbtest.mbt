///|
test "merge help is handled by merge command path" {
  assert_true(command_handles_builtin_help("merge"))
}

///|
test "split_cmdline quote validation" {
  assert_true(split_cmdline_has_unclosed_quote("echo \""))
  assert_false(split_cmdline_has_unclosed_quote("echo \\\""))
  assert_false(split_cmdline_has_unclosed_quote("--no-ff -m \"ok\""))
}
