///|
test "pack-objects parser tracks repack flags" {
  match
    parse_pack_objects_args([
      "--stdout", "--non-empty", "--reflog", "--indexed-objects", "--unpack-unreachable",
    ]) {
    PackObjectsParse::Ok(cfg) => {
      assert_true(cfg.stdout)
      assert_true(cfg.non_empty)
      assert_true(cfg.reflog)
      assert_true(cfg.indexed_objects)
      assert_true(cfg.unpack_unreachable)
      assert_eq(cfg.unpack_unreachable_expiration, 0L)
    }
    _ => fail("expected pack-objects parse ok")
  }
}

///|
test "index-pack parser handles options natively" {
  // --strict is handled natively
  match parse_index_pack_args(["--stdin", "--strict"]) {
    IndexPackParse::Ok(cfg) => {
      assert_true(cfg.stdin)
      assert_true(cfg.strict)
    }
    _ => fail("expected index-pack parse ok")
  }
  // --rev-index is handled natively (sets write_rev_index flag)
  match parse_index_pack_args(["--stdin", "--rev-index"]) {
    IndexPackParse::Ok(cfg) => {
      assert_true(cfg.stdin)
      assert_eq(cfg.write_rev_index, Some(true))
    }
    _ => fail("expected index-pack parse ok")
  }
  // --threads is accepted with warning flag
  match parse_index_pack_args(["--stdin", "--threads=4"]) {
    IndexPackParse::Ok(cfg) => {
      assert_true(cfg.stdin)
      assert_true(cfg.threads_warning)
    }
    _ => fail("expected index-pack parse ok")
  }
}
