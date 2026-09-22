#!/usr/bin/env bash

set -euo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for test_file in "$tests_dir"/test_*.sh; do
  printf '\n==> %s\n' "$(basename "$test_file")"
  "$test_file"
done

printf '\nAll tests passed.\n'
