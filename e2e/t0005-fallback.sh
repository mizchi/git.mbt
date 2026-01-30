#!/bin/bash
#
# Test --no-git-fallback behavior

source "$(dirname "$0")/test-lib.sh"

test_expect_failure 'unsupported command fails with --no-git-fallback' '
    git_cmd init &&
    git_cmd blame README.md
'

test_expect_success 'version command works with --no-git-fallback' '
    git_cmd --version | grep -q "moongit"
'

test_expect_success 'help command works with --no-git-fallback' '
    git_cmd --help | grep -q "moongit"
'

test_done
