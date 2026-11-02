#!/usr/bin/env bash
# Runs a command in CI and, when it fails, repeats the end of its output as an error annotation, so the
# reason shows on the check run itself (the full log needs a GitHub login to read).
#   tools/ci-run.sh "Build the receiver" cmake --build native/linux/build
title="$1"
shift
log="$(mktemp)"
set -o pipefail
"$@" 2>&1 | tee "$log"
code=$?
if [ "$code" -ne 0 ]; then
  tail_text="$(tail -c 3800 "$log" | tr -d '\r' | sed -e ':a' -e 'N' -e '$!ba' -e 's/%/%25/g' -e 's/\n/%0A/g')"
  echo "::error title=${title} failed (exit ${code})::${tail_text}"
fi
exit "$code"
