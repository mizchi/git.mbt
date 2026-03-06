///|
test "hash-object: storage runtime routing follows parser support" {
  assert_true(hash_object_storage_runtime_delegate_args(["--stdin"]) is Some(_))
  assert_true(
    hash_object_storage_runtime_delegate_args(["-t", "blob", "a.txt"])
    is Some(_),
  )
  assert_true(
    hash_object_storage_runtime_delegate_args(["-t", "tree", "a.txt"])
    is Some(_),
  )
  assert_true(
    hash_object_storage_runtime_delegate_args(["-t", "tag", "--stdin"])
    is Some(_),
  )
  assert_true(
    hash_object_storage_runtime_delegate_args(["--stdin-paths"]) is None,
  )
}
