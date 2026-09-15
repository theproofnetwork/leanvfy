#!/usr/bin/env bash
# Write comparator's configuration and the list of declarations the exports
# must contain.
#
# Usage: write-comparator-config.sh <config_out.json> <targets_out>
#
# Required environment:
#   THEOREM           Fully-qualified name of the theorem to verify
#   CHALLENGE_MODULE  Module of the challenge package declaring it
#   SOLUTION_MODULE   Module of the solution package proving it
#   ALLOWED_AXIOMS    Comma-separated axiom whitelist
# Optional:
#   VERIFIER_BIN_DIR  Directory holding comparator (default: /opt/bin)
#
# comparator is configured through this JSON file only. In the mode used here
# (patches/comparator/supply-exports.patch) it receives two ready-made exports
# at the fixed jail paths below and neither builds nor exports anything itself.
# It also knows which declarations those exports must contain (the theorem,
# the permitted axioms, the kernel's built-in constants); asking it with
# --print-export-targets rather than repeating the list keeps the two in step.
# comparator is statically linked and needs no Lean for this.
#
# `external_kernels` lists every kernel besides Lean's own that judges the
# solution export, each run by comparator under landrun. Kernel names
# containing "noda" receive nanoda's JSON config instead of the export path;
# everything else gets the path as its last argument. comparator rejects the
# solution if the theorem depends on any axiom outside `permitted_axioms` (or
# on sorry) and passes the same list to nanoda, which treats an unlisted axiom
# anywhere in the export as a hard error. eink0rn takes no axiom list; it only
# judges well-typedness.
set -euo pipefail

config_out="${1:-}"
targets_out="${2:-}"
if [ -z "$config_out" ] || [ -z "$targets_out" ] || [ $# -ne 2 ]; then
    echo "Usage: $(basename "$0") <config_out.json> <targets_out>" >&2
    exit 1
fi
for var in THEOREM CHALLENGE_MODULE SOLUTION_MODULE ALLOWED_AXIOMS; do
    if [ -z "${!var:-}" ]; then
        echo "Error: required environment variable $var is not set" >&2
        exit 1
    fi
done
VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"

mkdir -p "$(dirname "$config_out")" "$(dirname "$targets_out")"
jq -n \
    --arg challenge "$CHALLENGE_MODULE" \
    --arg solution "$SOLUTION_MODULE" \
    --arg theorem "$THEOREM" \
    --arg axioms "$ALLOWED_AXIOMS" \
    '{
      challenge_module: $challenge,
      solution_module: $solution,
      challenge_export: "/exports/challenge.export",
      solution_export: "/exports/solution.export",
      theorem_names: [$theorem],
      permitted_axioms: ($axioms | split(",") | map(select(length > 0))),
      external_kernels: {
        nanoda: ["nanoda_bin"],
        eink0rn: ["eink0rn", "--enforce-mutual-univ", "-j"]
      }
    }' >"$config_out"
cat "$config_out"
"$VERIFIER_BIN_DIR/comparator" --print-export-targets "$config_out" >"$targets_out"
if [ ! -s "$targets_out" ]; then
    echo "Error: comparator printed no export targets" >&2
    exit 1
fi
echo "Export targets: $(tr '\n' ' ' <"$targets_out")"
