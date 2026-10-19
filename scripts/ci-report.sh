#!/bin/bash
# Turns CI logs into GitHub annotations, so failures can be read from the
# check-run's annotations (via the API) without downloading the raw logs.
#   scripts/ci-report.sh <level> <title> <log-file> [max-lines]
# level is error, warning or notice. Compiler errors, self-test FAIL lines and
# the summary come first, then the end of the log.
set -uo pipefail
LEVEL="$1"
TITLE="$2"
LOG="$3"
MAX="${4:-150}"
[[ -f "$LOG" ]] || exit 0

{
  grep -E -A3 ": error: |^FAIL |FAILED:|passed, .* failed|fatal error|Fatal error|error: " "$LOG" | head -n "$MAX"
  echo "----- last lines -----"
  tail -n 60 "$LOG"
} > "$LOG.report"

# Annotation messages must escape %, CR and LF, and stay under GitHub's size limit.
body=$(head -c 60000 "$LOG.report" | sed -e 's/%/%25/g' | awk 'BEGIN { ORS = "%0A" } { gsub(/\r/, "%0D"); print }')
echo "::${LEVEL} title=${TITLE}::${body}"
