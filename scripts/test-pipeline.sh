#!/usr/bin/env bash
# End-to-end tests of the evaluate pipeline with the real pinned toolchain:
# fetch-repo.sh -> materialize-deps.sh -> tree-digest.sh ->
# write-comparator-config.sh -> sandboxed-build-export.sh (challenge, solution)
# -> sandboxed-comparator.sh, i.e. the steps of leanvfy.yml's evaluate job in
# order, on Lake packages served from the local https server of test-lib.sh.
#
# Needs the toolchain provisioned by scripts/provision-toolchain.sh
# (LEAN_ROOT, default /opt/lean; VERIFIER_BIN_DIR, default /opt/bin), bubblewrap
# with --disable-userns and sudo (for the throwaway CA). Linux only; run by
# .github/workflows/test-scripts.yml (job `pipeline`).
#
# The challenge depends on a second package and states a theorem about a
# definition of its own; solutions then exercise what comparator must accept
# (an honest proof that imports the challenge's definitions through a `require`,
# and one that restates them) and what it must reject (sorry, an extra axiom,
# a redefined constant, a different statement, a missing theorem), plus what the
# jails must contain: a solution whose module runs shell commands at build time
# and records what it could reach.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/test-lib.sh
source "$here/test-lib.sh"
test_init

export LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"
export VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"
for f in "$LEAN_ROOT/bin/lake" "$LEAN_ROOT/bin/lean4export" "$VERIFIER_BIN_DIR/comparator" \
    "$VERIFIER_BIN_DIR/landrun" "$VERIFIER_BIN_DIR/nanoda_bin" "$VERIFIER_BIN_DIR/eink0rn"; do
    [ -x "$f" ] || {
        echo "$f is missing; run scripts/provision-toolchain.sh toolchain.lock first" >&2
        exit 1
    }
done
command -v curl >/dev/null || {
    echo "curl is required (the escape probe uses it)" >&2
    exit 1
}
https_server

fetch="$here/fetch-repo.sh"
mat="$here/materialize-deps.sh"
digest="$here/tree-digest.sh"
config="$here/write-comparator-config.sh"
build="$here/sandboxed-build-export.sh"
compare="$here/sandboxed-comparator.sh"

# --- fixtures ---------------------------------------------------------------
# Manifests are written by the pinned Lake itself (`lake update` on the host,
# as a prover would run it), so their shape is whatever this Lake version
# produces; .lake is ignored so that the committed trees hold sources only.
lake_update() {
    (cd "$1" && PATH="$LEAN_ROOT/bin:$PATH" lake update >"$work/lake-update.log" 2>&1) || {
        echo "lake update failed in $1:" >&2
        cat "$work/lake-update.log" >&2
        exit 1
    }
}
# package <name> <lib> [<require-name> <require-url> <require-rev>]
package() {
    local d
    d="$(new_repo "$1")"
    {
        printf 'name = "%s"\ndefaultTargets = ["%s"]\n\n' "$1" "$2"
        if [ $# -eq 5 ]; then
            printf '[[require]]\nname = "%s"\ngit = "%s"\nrev = "%s"\n\n' "$3" "$4" "$5"
        fi
        printf '[[lean_lib]]\nname = "%s"\n' "$2"
    } >"$d/lakefile.toml"
    printf '.lake/\n' >"$d/.gitignore"
    echo "$d"
}

d="$(package dep Dep)"
echo 'def Dep.answer : Nat := 42' >"$d/Dep.lean"
lake_update "$d"
dep_commit="$(publish dep "$d")"

d="$(package challenge Challenge dep "$base/dep.git" "$dep_commit")"
mkdir -p "$d/Challenge"
printf 'import Dep\n\ndef Challenge.f (n : Nat) : Nat := Dep.answer + n\n' >"$d/Challenge/Defs.lean"
printf 'import Challenge.Defs\n\ntheorem Challenge.main : Challenge.f 1 = 43 := sorry\n' >"$d/Challenge.lean"
lake_update "$d"
challenge_commit="$(publish challenge "$d")"

# solution <name> <lean source> [norequire]: a solution package whose module
# Solution holds <lean source>; unless norequire, it requires the challenge.
solution() {
    local d
    if [ "${3:-}" = norequire ]; then
        d="$(package "$1" Solution)"
    else
        d="$(package "$1" Solution challenge "$base/challenge.git" "$challenge_commit")"
    fi
    printf '%s\n' "$2" >"$d/Solution.lean"
    lake_update "$d"
    publish "$1" "$d"
}
good_commit="$(solution good 'import Challenge.Defs

theorem Challenge.main : Challenge.f 1 = 43 := rfl')"
restated_commit="$(solution restated 'def Dep.answer : Nat := 42

def Challenge.f (n : Nat) : Nat := Dep.answer + n

theorem Challenge.main : Challenge.f 1 = 43 := rfl' norequire)"
sorry_commit="$(solution sorry 'import Challenge.Defs

theorem Challenge.main : Challenge.f 1 = 43 := sorry')"
axiom_commit="$(solution axiom 'import Challenge.Defs

axiom Challenge.cheat : Challenge.f 1 = 43

theorem Challenge.main : Challenge.f 1 = 43 := Challenge.cheat')"
redefined_commit="$(solution redefined 'def Challenge.f (_ : Nat) : Nat := 43

theorem Challenge.main : Challenge.f 1 = 43 := rfl' norequire)"
statement_commit="$(solution statement 'import Challenge.Defs

theorem Challenge.main : Challenge.f 0 = 42 := rfl')"
missing_commit="$(solution missing 'import Challenge.Defs

theorem Challenge.other : Challenge.f 1 = 43 := rfl')"
# Prover code with side effects: the module runs a shell at elaboration time
# that tries to reach the host's file system, the network and the other
# workspace, writes what it saw into the one writable path (.lake, read back
# on the host below) and leaves a process behind. The proof itself is honest,
# so the verdict must be PASSED -- side effects are not what the kernels judge
# -- while nothing may have escaped.
challenge_host_dir="$work/out/challenge"
escape_commit="$(solution escape "import Challenge.Defs

#eval do
  let _ ← IO.Process.output { cmd := \"sh\", args := #[\"-c\", \"
    exec >/work/.lake/probe.txt 2>&1
    echo ran
    (echo x >/work/escaped) 2>/dev/null && echo work-writable
    echo x >/tmp/leanvfy-escaped 2>/dev/null
    mkdir -p '$work/out' && echo x >'$work/out/escaped' 2>/dev/null
    [ -e '$challenge_host_dir' ] && echo challenge-visible
    [ -e /opt/bin/comparator ] && echo verifier-visible
    [ -e /etc/passwd ] && echo etc-visible
    curl -sk --max-time 5 '$base/escaped' -o /dev/null && echo network
    nohup sleep 314159 >/dev/null 2>&1 &
    echo done
  \"] }
  pure ()

theorem Challenge.main : Challenge.f 1 = 43 := rfl")"

# --- the pipeline, step by step as leanvfy.yml runs it ------------------------
export THEOREM=Challenge.main CHALLENGE_MODULE=Challenge SOLUTION_MODULE=Solution
export ALLOWED_AXIOMS=propext,Quot.sound,Classical.choice

echo "Comparator configuration"
cfg="$work/comparator.json"
targets="$work/export-targets"
expect_accept "write-comparator-config.sh" bash "$config" "$cfg" "$targets"
grep -qx "$THEOREM" "$targets" && ok "export targets contain the theorem" || bad "theorem missing from export targets"
grep -qx "Classical.choice" "$targets" && ok "export targets contain the permitted axioms" || bad "axioms missing from export targets"
[ "$(jq -r '.theorem_names | join(",")' "$cfg")" = "$THEOREM" ] \
    && [ "$(jq -r '.permitted_axioms | join(",")' "$cfg")" = "$ALLOWED_AXIOMS" ] \
    && [ "$(jq -r '.external_kernels | keys | join(",")' "$cfg")" = "eink0rn,nanoda" ] \
    && ok "config names the theorem, the axiom policy and both external kernels" || bad "config content differs"
expect_reject "config refuses a missing THEOREM" env -u THEOREM bash "$config" "$work/x.json" "$work/x"

echo "Challenge: fetch, dependencies, digest, build and export"
C="$challenge_host_dir"
expect_accept "fetch challenge (--require-toml)" bash "$fetch" --require-toml "$base/challenge.git" "$challenge_commit" "$C"
expect_accept "materialize challenge dependencies" bash "$mat" "$C"
[ -d "$C/.lake/packages/dep" ] && ok "dependency dep materialized" || bad "dependency dep missing"
challenge_digest="$(bash "$digest" "$C" "$challenge_commit")"
[[ "$challenge_digest" =~ ^[a-f0-9]{64}$ ]] && ok "challenge tree digest $challenge_digest" || bad "no challenge digest"
challenge_export="$work/exports/challenge.export"
expect_accept "build and export challenge" bash "$build" "$C" Challenge "$targets" "$challenge_export"
[ -s "$challenge_export" ] && ok "challenge export written ($(wc -c <"$challenge_export") bytes)" || bad "challenge export missing"

# solution_pipeline <label> <commit> <module> -> runs fetch, materialize,
# digest, build/export and comparator for one solution; prints the stage that
# failed (fetch, build, compare) or "passed".
solution_pipeline() {
    local label="$1" commit="$2" module="$3"
    local S="$work/out/sol-$label" export="$work/exports/$label.export"
    {
        bash "$fetch" "$base/$label.git" "$commit" "$S" && bash "$mat" "$S" \
            && bash "$digest" "$S" "$commit" >"$work/out/sol-$label.digest"
    } >"$work/$label.log" 2>&1 || {
        echo fetch
        return
    }
    bash "$build" "$S" "$module" "$targets" "$export" >>"$work/$label.log" 2>&1 || {
        echo build
        return
    }
    bash "$compare" "$challenge_export" "$export" "$cfg" >>"$work/$label.log" 2>&1 || {
        echo compare
        return
    }
    echo passed
}
# expect_stage <desc> <label> <commit> <module> <passed|build|compare>
expect_stage() {
    local desc="$1" label="$2" commit="$3" module="$4" want="$5" got
    got="$(solution_pipeline "$label" "$commit" "$module")"
    if [ "$got" = "$want" ]; then
        ok "$desc ($got)"
    else
        bad "$desc: expected $want, got $got"
        tail -40 "$work/$label.log" | sed 's/^/       /' >&2
    fi
}

echo "Verdicts"
expect_stage "honest proof importing the challenge's definitions" good "$good_commit" Solution passed
grep -q "Landlock self-test" "$work/good.log" && bad "landrun self-test reported a problem" || ok "landrun self-tests passed inside the comparator jail"
expect_stage "honest proof restating the definitions without dependencies" restated "$restated_commit" Solution passed
expect_stage "sorry is rejected by comparator" sorry "$sorry_commit" Solution compare
expect_stage "an extra axiom is rejected by comparator" axiom "$axiom_commit" Solution compare
expect_stage "a redefined constant in the statement's closure is rejected" redefined "$redefined_commit" Solution compare
expect_stage "a different statement is rejected" statement "$statement_commit" Solution compare
expect_stage "a solution not declaring the theorem fails to export" missing "$missing_commit" Solution build
got="$(
    S="$work/out/sol-nomod"
    bash "$fetch" "$base/good.git" "$good_commit" "$S" >/dev/null 2>&1 && bash "$mat" "$S" >/dev/null 2>&1
    if bash "$build" "$S" Nope "$targets" "$work/exports/nomod.export" >"$work/nomod.log" 2>&1; then echo passed; else echo build; fi
)"
[ "$got" = build ] && ok "a module that does not exist fails to build" || bad "nonexistent module: expected build failure, got $got"

echo "Comparator jail with bad exports"
echo "not an export" >"$work/exports/garbage.export"
expect_reject "garbage solution export" bash "$compare" "$challenge_export" "$work/exports/garbage.export" "$cfg"
expect_reject "challenge export (with sorry) offered as the solution" bash "$compare" "$challenge_export" "$challenge_export" "$cfg"
expect_reject "missing export file" bash "$compare" "$challenge_export" "$work/exports/nope.export" "$cfg"

echo "Build jail argument checks"
: >"$work/empty-targets"
printf 'a b\n' >"$work/bad-targets"
S="$work/out/sol-good"
expect_reject "empty targets file" bash "$build" "$S" Solution "$work/empty-targets" "$work/exports/x.export"
expect_reject "target with whitespace" bash "$build" "$S" Solution "$work/bad-targets" "$work/exports/x.export"
expect_reject "module name with a slash" bash "$build" "$S" "Solution/../x" "$targets" "$work/exports/x.export"
mkdir -p "$work/out/nolake"
expect_reject "workspace without .lake" bash "$build" "$work/out/nolake" Solution "$targets" "$work/exports/x.export"
mkdir -p "$work/out/lakelink" && ln -s /tmp "$work/out/lakelink/.lake"
expect_reject "workspace whose .lake is a symlink" bash "$build" "$work/out/lakelink" Solution "$targets" "$work/exports/x.export"

echo "Jail containment (solution that runs shell commands at build time)"
rm -f /tmp/leanvfy-escaped "$work/out/escaped"
expect_stage "hostile-but-honest solution still passes" escape "$escape_commit" Solution passed
probe="$work/out/sol-escape/.lake/probe.txt"
if [ -f "$probe" ] && grep -qx ran "$probe" && grep -qx 'done' "$probe"; then
    ok "the probe ran inside the jail and could write to .lake"
    for marker in work-writable challenge-visible verifier-visible etc-visible network; do
        grep -qx "$marker" "$probe" && bad "jail leak: $marker" || ok "not $marker"
    done
else
    bad "the probe did not run (no $probe); the containment checks are void"
    [ -f "$probe" ] && sed 's/^/       /' "$probe" >&2
fi
[ -e /tmp/leanvfy-escaped ] && bad "jail wrote to the host's /tmp" || ok "host /tmp untouched"
[ -e "$work/out/escaped" ] && bad "jail wrote to a host path" || ok "host work directory untouched"
grep -q escaped "$server_log" && bad "jail reached the network" || ok "no request from the jail reached the server"
pgrep -f 'sleep 314159' >/dev/null && bad "a process outlived its jail" || ok "no process outlived the jail"

test_summary
