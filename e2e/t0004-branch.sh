#!/bin/bash
#
# Test git branch operations: branch, checkout, switch

source "$(dirname "$0")/test-lib.sh"

test_expect_success 'git branch lists branches' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd branch | grep -q "main\|master"
'

test_expect_success 'git branch creates new branch' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd branch feature &&
    git_cmd branch | grep -q "feature"
'

test_expect_success 'git checkout switches branch' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd branch feature &&
    git_cmd checkout feature &&
    git_cmd branch | grep -q "\\* feature"
'

test_expect_success 'git checkout -b creates and switches' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd checkout -b feature &&
    git_cmd branch | grep -q "\\* feature"
'

test_expect_success 'git switch changes branch' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd branch feature &&
    git_cmd switch feature &&
    git_cmd branch | grep -q "\\* feature"
'

test_expect_success 'git switch -c creates and switches' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd switch -c feature &&
    git_cmd branch | grep -q "\\* feature"
'

test_expect_success 'git branch -d deletes branch' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    git_cmd branch feature &&
    git_cmd branch -d feature &&
    ! git_cmd branch | grep -q "feature"
'

test_done
