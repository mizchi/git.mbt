#!/bin/bash
#
# Test git init command

source "$(dirname "$0")/test-lib.sh"

test_expect_success 'git init creates .git directory' '
    git_cmd init &&
    test_dir_exists .git &&
    test_dir_exists .git/objects &&
    test_dir_exists .git/refs
'

test_expect_success 'git init creates HEAD file' '
    git_cmd init &&
    test_file_exists .git/HEAD &&
    grep -q "ref: refs/heads/main\|ref: refs/heads/master" .git/HEAD
'

test_expect_success 'git init creates config file' '
    git_cmd init &&
    test_file_exists .git/config
'

test_expect_success 'git init in existing repo is safe' '
    git_cmd init &&
    git_cmd init &&
    test_dir_exists .git
'

test_expect_success 'git init with directory argument' '
    git_cmd init myrepo &&
    test_dir_exists myrepo/.git
'

test_done
