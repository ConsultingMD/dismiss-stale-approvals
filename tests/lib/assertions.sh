#!/usr/bin/env bash

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equals() {
  local expected=$1
  local actual=$2
  local message=$3
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_file_contains() {
  local pattern=$1
  local file=$2
  local message=$3
  if ! grep -q "$pattern" "$file"; then
    fail "$message"
  fi
}

assert_file_not_contains() {
  local pattern=$1
  local file=$2
  local message=$3
  if grep -q "$pattern" "$file"; then
    fail "$message"
  fi
}
