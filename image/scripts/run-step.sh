#!/usr/bin/env bash
# Runs one build step if it belongs to the selected flavor.
# Usage: run-step.sh <step-file> <flavor>
# Each step declares its flavors in a header line: "# flavors: standard full"
set -Eeuo pipefail

step="$1" flavor="$2"
dir="$(cd "$(dirname "$0")" && pwd)"
file="${dir}/${step}.sh"

[[ -f "$file" ]] || { echo "unknown step: $step" >&2; exit 1; }

flavors="$(sed -n 's/^# flavors:[[:space:]]*//p' "$file" | head -n1)"
if [[ " ${flavors} " != *" ${flavor} "* ]]; then
  echo "skip ${step} (not in flavor '${flavor}')"
  exit 0
fi

echo "### step ${step} (${flavor})"
bash "$file"
rm -rf /var/lib/apt/lists/* /tmp/* /root/.cache
