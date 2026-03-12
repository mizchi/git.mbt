///|
test "sparse: cone encoding adds ancestor file patterns for deep paths" {
  assert_eq(sparse_encode_cone_patterns(["folder2/2/3"]), [
    "/*", "!/*/", "/folder2/", "!/folder2/*/", "/folder2/2/", "!/folder2/2/*/", "/folder2/2/3/",
  ])
}

///|
test "sparse: deep cone pattern includes ancestor files but excludes sibling subtrees" {
  let patterns = sparse_encode_cone_patterns(["folder2/2/3"])
  assert_true(matches_sparse_pattern("a", patterns))
  assert_true(matches_sparse_pattern("folder2/a", patterns))
  assert_true(matches_sparse_pattern("folder2/2/a", patterns))
  assert_true(matches_sparse_pattern("folder2/2/3/a", patterns))
  assert_false(matches_sparse_pattern("folder2/0/1", patterns))
  assert_false(matches_sparse_pattern("folder2/2/4/a", patterns))
}
