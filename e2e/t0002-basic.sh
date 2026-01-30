#!/bin/bash
#
# Test basic git operations: status, add, commit

source "$(dirname "$0")/test-lib.sh"

test_expect_success 'git status in empty repo' '
    git_cmd init &&
    git_cmd status
'

test_expect_success 'git status shows untracked file' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd status | grep -q "test.txt"
'

test_expect_success 'git add adds file to index' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd ls-files | grep -q "test.txt"
'

test_expect_success 'git commit creates commit' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd log | grep -q "first commit"
'

test_expect_success 'git status shows clean after commit' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd status | grep -q "nothing to commit"
'

test_expect_success 'git status shows modified file' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    echo "world" >> test.txt &&
    git_cmd status | grep -q "modified"
'

test_done
