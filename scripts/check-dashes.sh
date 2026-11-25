#!/bin/sh
# Fails if any tracked or new file contains an em or en dash.
set -eu
cd "$(dirname "$0")/.."
found=$(git ls-files -co --exclude-standard -z | xargs -0 perl -CSD -ne 'if (/[\x{2013}\x{2014}]/) { print "$ARGV:$.: $_" } close ARGV if eof' 2>/dev/null || true)
if [ -n "$found" ]; then
  echo "Em or en dashes found:"
  echo "$found"
  exit 1
fi
echo "No em or en dashes."
