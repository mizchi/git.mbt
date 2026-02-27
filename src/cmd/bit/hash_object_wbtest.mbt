///|
test "hash-object: storage runtime routing follows parser support" {
  assert_false(hash_object_should_use_storage_runtime(["--stdin"]))
  assert_true(hash_object_should_use_storage_runtime(["-t", "blob", "a.txt"]))
  assert_false(hash_object_should_use_storage_runtime(["-t", "tree", "a.txt"]))

  assert_false(hash_object_should_use_storage_runtime(["--stdin-paths"]))
}
