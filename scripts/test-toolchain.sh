#!/usr/bin/env bash
# Tests for toolchain.lock and everything derived from it on the trusted side:
# check-toolchain-lock.py (the pre-commit shape check), provision-toolchain.sh
# (download + sha256 enforcement + installation, against a fake lockfile whose
# artifacts are served by the local https server of test-lib.sh) and
# build-predicate.sh (predicate assembly and schema validation).
#
# Linux only; needs sudo (provision-toolchain.sh installs as root, the test CA
# goes into the system store), jq, curl, python3, tar, zstd and
# check-jsonschema on PATH (pip install -r scripts/requirements.txt). Run by
# .github/workflows/test-scripts.yml. Nothing is downloaded from the internet.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/test-lib.sh
source "$here/test-lib.sh"
test_init
command -v check-jsonschema >/dev/null || {
    echo "check-jsonschema is required: pip install --require-hashes -r scripts/requirements.txt" >&2
    exit 1
}

check="$here/check-toolchain-lock.py"
provision="$here/provision-toolchain.sh"
predicate="$here/build-predicate.sh"
lock="$root/toolchain.lock"

# --- check-toolchain-lock.py -------------------------------------------------
# Variants of the real lockfile, in a directory that also holds the patches it
# refers to (the check resolves them relative to the lockfile).
echo "toolchain.lock shape check"
mkdir -p "$work/lock"
cp -r "$root/patches" "$work/lock/"
variant() { # variant <jq filter> -> path of the modified lockfile (jq errors are fatal)
    local f
    f="$(mktemp "$work/lock/XXXXXXXX.lock")"
    jq "$1" "$lock" >"$f" || exit 1
    echo "$f"
}
expect_accept "the committed toolchain.lock" python3 "$check" "$lock"
expect_accept "an unmodified copy" python3 "$check" "$(variant '.')"
expect_reject "http lean url" python3 "$check" "$(variant '.lean.url |= sub("https:"; "http:")')"
expect_reject "short lean sha256" python3 "$check" "$(variant '.lean.sha256 |= .[:63]')"
expect_reject "uppercase sha256" python3 "$check" "$(variant '.tools[0].sha256 |= ascii_upcase')"
expect_reject "tool url outside release_tag" python3 "$check" "$(variant '.tools[0].url |= sub("tools-"; "other-")')"
expect_reject "tool url with the wrong name" python3 "$check" "$(variant '.tools[0].name as $n | .tools[0].url |= sub($n; "x")')"
expect_reject "tool commit is not a full SHA-1" python3 "$check" "$(variant '.tools[0].commit |= .[:39]')"
expect_reject "malformed release_tag" python3 "$check" "$(variant '.release_tag = "a b"')"
expect_reject "patch that does not exist" python3 "$check" "$(variant '.tools[1].patches += ["patches/comparator/nope.patch"]')"
expect_reject "patch outside patches/" python3 "$check" "$(variant '.tools[1].patches = ["../toolchain.lock"]')"
expect_reject "build toolchain with http url" python3 "$check" "$(variant '.build_toolchains.go.url |= sub("https:"; "http:")')"
expect_reject "not JSON" python3 "$check" "$(
    f="$work/lock/notjson.lock"
    echo '{' >"$f"
    echo "$f"
)"
expect_reject "missing file" python3 "$check" "$work/lock/absent.lock"

# --- provision-toolchain.sh ----------------------------------------------------
# A fake Lean release (a tarball with a single top-level directory holding
# bin/lean) and two fake tools, served over https; a lockfile pointing at them
# with the correct hashes, and variants with wrong ones.
echo "Provisioning"
https_server
mkdir -p "$work/fake/lean-0.0.0-linux/bin"
printf '#!/bin/sh\necho fake lean\n' >"$work/fake/lean-0.0.0-linux/bin/lean"
chmod +x "$work/fake/lean-0.0.0-linux/bin/lean"
tar --zstd -cf "$srv/lean.tar.zst" -C "$work/fake" lean-0.0.0-linux
printf '#!/bin/sh\necho tool-a\n' >"$srv/tool-a"
printf '#!/bin/sh\necho tool-b\n' >"$srv/tool-b"
sha() { sha256sum "$1" | cut -d' ' -f1; }
fake_lock() { # fake_lock <jq filter> -> path
    local f
    f="$(mktemp "$work/XXXXXXXX.lock")"
    jq -n --arg base "$base" \
        --arg lean_sha "$(sha "$srv/lean.tar.zst")" \
        --arg a_sha "$(sha "$srv/tool-a")" \
        --arg b_sha "$(sha "$srv/tool-b")" '{
        release_tag: "tools-test",
        lean: { version: "v0.0.0", url: ($base + "/lean.tar.zst"), sha256: $lean_sha },
        tools: [
          { name: "tool-a", url: ($base + "/tool-a"), sha256: $a_sha, install: "toolchain" },
          { name: "tool-b", url: ($base + "/tool-b"), sha256: $b_sha, install: "verifier" }
        ]
      }' | jq "$1" >"$f" || exit 1
    echo "$f"
}
export LEAN_ROOT="$work/inst/lean" VERIFIER_BIN_DIR="$work/inst/bin"
mkdir -p "$work/inst"

expect_accept "fake toolchain with matching hashes" bash "$provision" "$(fake_lock '.')"
[ -x "$LEAN_ROOT/bin/lean" ] && ok "lean installed under LEAN_ROOT/bin" || bad "LEAN_ROOT/bin/lean missing"
[ -x "$LEAN_ROOT/bin/tool-a" ] && ok "install: toolchain goes to LEAN_ROOT/bin" || bad "tool-a not in LEAN_ROOT/bin"
[ -x "$VERIFIER_BIN_DIR/tool-b" ] && ok "install: verifier goes to VERIFIER_BIN_DIR" || bad "tool-b not in VERIFIER_BIN_DIR"
[ ! -e "$VERIFIER_BIN_DIR/tool-a" ] && [ ! -e "$LEAN_ROOT/bin/tool-b" ] && ok "each tool only where its install target says" || bad "tool installed in both places"
[ "$(stat -c '%U:%G %a' "$VERIFIER_BIN_DIR/tool-b")" = "root:root 555" ] && ok "tools are root-owned and 0555" || bad "tool ownership/mode: $(stat -c '%U:%G %a' "$VERIFIER_BIN_DIR/tool-b")"
[ "$(stat -c '%U %a' "$LEAN_ROOT/bin/lean")" = "root 555" ] && ok "toolchain is root-owned and read-only" || bad "toolchain still writable"
if [ "$(id -u)" != 0 ]; then
    touch "$LEAN_ROOT/x" 2>/dev/null && bad "LEAN_ROOT writable by the runner user" || ok "LEAN_ROOT not writable by the runner user"
fi

# A previous installation is replaced, not merged: a stray file must not survive.
sudo touch "$VERIFIER_BIN_DIR/stale"
expect_accept "re-provisioning" bash "$provision" "$(fake_lock '.')"
[ ! -e "$VERIFIER_BIN_DIR/stale" ] && ok "stale files are wiped on re-provisioning" || bad "stale file survived"

expect_accept "--lean-only" env VERIFIER_BIN_DIR="$work/inst/untouched" bash "$provision" --lean-only "$(fake_lock '.')"
[ ! -e "$work/inst/untouched" ] && ok "--lean-only leaves VERIFIER_BIN_DIR alone" || bad "--lean-only touched VERIFIER_BIN_DIR"
[ ! -e "$LEAN_ROOT/bin/tool-a" ] && ok "--lean-only installs no tools" || bad "--lean-only installed a tool"

expect_reject "lean sha256 mismatch" bash "$provision" "$(fake_lock '.lean.sha256 = ("0" * 64)')"
expect_reject "tool sha256 mismatch" bash "$provision" "$(fake_lock '.tools[1].sha256 = ("0" * 64)')"
expect_reject "malformed sha256" bash "$provision" "$(fake_lock '.lean.sha256 = "abc"')"
expect_reject "http url" bash "$provision" "$(fake_lock '.lean.url |= sub("https:"; "http:")')"
expect_reject "redirect to http" bash "$provision" "$(fake_lock '.tools[0].url |= sub("/tool-a"; "/redirect-http/tool-a")')"
expect_reject "redirect to file://" bash "$provision" "$(fake_lock '.tools[0].url |= sub("/tool-a"; "/redirect-file/tool-a")')"
expect_reject "404" bash "$provision" "$(fake_lock '.tools[0].url |= sub("/tool-a"; "/absent")')"
expect_reject "unknown install target" bash "$provision" "$(fake_lock '.tools[0].install = "elsewhere"')"
expect_reject "tool name with a slash" bash "$provision" "$(fake_lock '.tools[0].name = "../x"')"
expect_reject "tarball without bin/lean" bash "$provision" "$(
    tar --zstd -cf "$srv/nolean.tar.zst" -C "$work/fake/lean-0.0.0-linux" bin/lean
    fake_lock ".lean.url = \"$base/nolean.tar.zst\" | .lean.sha256 = \"$(sha "$srv/nolean.tar.zst")\""
)"
expect_reject "relative LEAN_ROOT" env LEAN_ROOT=relative bash "$provision" "$(fake_lock '.')"
expect_reject "LEAN_ROOT=/" env LEAN_ROOT=/ bash "$provision" "$(fake_lock '.')"
expect_reject "no lockfile argument" bash "$provision"
unset LEAN_ROOT VERIFIER_BIN_DIR

# --- build-predicate.sh --------------------------------------------------------
echo "Predicate"
THEOREM="Foo.main"
CHALLENGE_REPO="https://github.com/a/b" CHALLENGE_MODULE="Challenge.Statement"
CHALLENGE_COMMIT="$(printf 'a%.0s' $(seq 40))" CHALLENGE_DIGEST="$(printf '1%.0s' $(seq 64))"
SOLUTION_REPO="https://github.com/c/d" SOLUTION_MODULE="Solution"
SOLUTION_COMMIT="$(printf 'b%.0s' $(seq 40))" SOLUTION_DIGEST="$(printf '2%.0s' $(seq 64))"
ALLOWED_AXIOMS="propext,Quot.sound,Classical.choice"
TOOLCHAIN_LOCK="$lock" SCHEMA_FILE="$root/schemas/leanvfy-v1.json"
export THEOREM CHALLENGE_REPO CHALLENGE_COMMIT CHALLENGE_MODULE CHALLENGE_DIGEST \
    SOLUTION_REPO SOLUTION_COMMIT SOLUTION_MODULE SOLUTION_DIGEST ALLOWED_AXIOMS TOOLCHAIN_LOCK SCHEMA_FILE
p="$work/predicate.json"
expect_accept "predicate from the committed lockfile validates" bash "$predicate" "$p"
jq -e --arg t "$THEOREM" --arg c "$CHALLENGE_COMMIT" --arg d "$CHALLENGE_DIGEST" --arg m "$CHALLENGE_MODULE" '
    .verificationResult == "PASSED" and .theorem == $t
    and .challenge.name == "challenge@" + $c and .challenge.digest.gitCommit == $c
    and .challenge.digest.sha256 == $d and .challenge.annotations.module == $m
    and .solution.uri == "https://github.com/c/d"
    and .policy.allowedAxioms == ["propext", "Quot.sound", "Classical.choice"]' "$p" >/dev/null \
    && ok "claim fields copied verbatim" || bad "claim fields differ"
[ "$(jq -r '.toolchain.lock.digest.sha256' "$p")" = "$(sha256sum "$lock" | cut -d' ' -f1)" ] \
    && ok "toolchain.lock digest is the file's sha256" || bad "lock digest differs"
jq -e --slurpfile l "$lock" '
    .toolchain.lean.uri == $l[0].lean.url and .toolchain.lean.digest.sha256 == $l[0].lean.sha256
    and .toolchain.lean.annotations.version == $l[0].lean.version
    and ([.toolchain.tools[].name] == [$l[0].tools[].name])
    and ([.toolchain.tools[].digest.sha256] == [$l[0].tools[].sha256])
    and ([.toolchain.tools[].annotations.commit] == [$l[0].tools[].commit])
    and ([.toolchain.tools[].annotations.engine] == [$l[0].tools[].engine])' "$p" >/dev/null \
    && ok "toolchain block mirrors the lockfile" || bad "toolchain block differs from the lockfile"
[ "$(jq -c '.toolchain.tools[] | select(.name == "comparator") | .annotations.patches' "$p")" = '["patches/comparator/supply-exports.patch"]' ] \
    && ok "patched tool lists its patches" || bad "comparator patches missing"
[ "$(jq -c '[.toolchain.tools[] | select(.name != "comparator") | .annotations | has("patches")] | unique' "$p")" = '[false]' ] \
    && ok "unpatched tools carry no patches key" || bad "patches key on an unpatched tool"
jq -e '[.toolchain.tools[] | select(.annotations.engine)] | length >= 3' "$p" >/dev/null \
    && ok "at least three engines (comparator and two independent kernels)" || bad "fewer than three engines"
for var in THEOREM CHALLENGE_DIGEST ALLOWED_AXIOMS TOOLCHAIN_LOCK SCHEMA_FILE; do
    expect_reject "missing $var" env -u "$var" bash "$predicate" "$work/x.json"
done
expect_reject "no output path" bash "$predicate"
expect_reject "lockfile that does not exist" env TOOLCHAIN_LOCK="$work/absent.lock" bash "$predicate" "$work/x.json"
expect_reject "schema rejects a module name with a space" env CHALLENGE_MODULE="Bad Module" bash "$predicate" "$work/x.json"
expect_reject "schema rejects a short commit id" env SOLUTION_COMMIT=abc bash "$predicate" "$work/x.json"
expect_reject "schema rejects a short tree digest" env SOLUTION_DIGEST=abc bash "$predicate" "$work/x.json"
expect_reject "schema rejects a theorem with a newline" env THEOREM="$(printf 'a\nb')" bash "$predicate" "$work/x.json"
expect_reject "schema rejects a repository uri without a scheme" env CHALLENGE_REPO="no scheme" bash "$predicate" "$work/x.json"
expect_reject "schema rejects a lockfile without tools" env TOOLCHAIN_LOCK="$(variant '.tools = []')" bash "$predicate" "$work/x.json"
expect_reject "schema rejects a malformed tool sha256" env TOOLCHAIN_LOCK="$(variant '.tools[0].sha256 = "zz"')" bash "$predicate" "$work/x.json"
expect_accept "an empty axiom list is allowed" env ALLOWED_AXIOMS="," bash "$predicate" "$work/x.json"
[ "$(jq -c '.policy.allowedAxioms' "$work/x.json")" = "[]" ] && ok "ALLOWED_AXIOMS=, gives an empty policy" || bad "empty policy differs"

test_summary
