#!/usr/bin/env bash
# Tests for verify.sh, the verifier's side of an attestation, without Sigstore:
# a shim `gh` on PATH records how `gh attestation verify` was invoked and
# returns a canned `--format json` result, built around a predicate that
# scripts/build-predicate.sh produced from toolchain.lock at HEAD -- the same
# producer the attest job runs, so a drift between what the workflow signs and
# what verify.sh expects fails here. Every claim verify.sh checks (steps 2 and
# 3 of its header) is then tampered with in turn.
#
# Portable: needs git, jq and check-jsonschema (pip install -r
# scripts/requirements.txt); no bubblewrap, no sudo, no network. Must run
# from a clone of this repository whose HEAD holds toolchain.lock and
# leanvfy.yml (verify.sh derives the expected toolchain block and axiom policy
# from that commit). The digest's agreement with scripts/tree-digest.sh is
# covered by test-fetch.sh. Run by .github/workflows/test-scripts.yml.
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
# A clone of this repository with a second revision whose toolchain.lock
# differs (verify.sh derives what it expects from commits, not the working
# tree); verify.sh itself is the working-tree copy.
wf="$work/leanvfy"
git clone -q "$root" "$wf"
cp "$root/verify.sh" "$wf/verify.sh"
verify="$wf/verify.sh"
wf_commit="$(git -C "$wf" rev-parse --verify 'HEAD^{commit}')"
git -C "$wf" checkout -q -b other
jq '.lean.version = "v9.9.9"' "$wf/toolchain.lock" >"$wf/toolchain.lock.new" && mv "$wf/toolchain.lock.new" "$wf/toolchain.lock"
git -C "$wf" commit -q -am "other revision"
other_commit="$(git -C "$wf" rev-parse HEAD)"
git -C "$wf" checkout -q --detach "$wf_commit"
wf_repo=theproofnetwork/leanvfy
wf_path=.github/workflows/leanvfy.yml

# --- the audited challenge: a tree with an executable, a symlink, a nested
# directory and a space in a name ------------------------------------------------
c="$(new_repo challenge)"
mkdir -p "$c/Sub dir"
printf 'name = "c"\n[[lean_lib]]\nname = "Challenge"\n' >"$c/lakefile.toml"
echo 'theorem T.main : 1 = 1 := sorry' >"$c/Challenge.lean"
echo 'x' >"$c/Sub dir/f.lean"
printf '#!/bin/sh\n' >"$c/run.sh" && chmod +x "$c/run.sh"
ln -s Challenge.lean "$c/link"
git -C "$c" add -A && git -C "$c" commit -q -m fixture
commit="$(git -C "$c" rev-parse HEAD)"

echo "Digest"
d="$(bash "$verify" --challenge "$c" --challenge-commit "$commit" --digest-only)"
[[ "$d" =~ ^[a-f0-9]{64}$ ]] && ok "--digest-only prints a sha256 ($d)" || bad "--digest-only printed '$d'"
# The listing verify.sh hashes, recomputed here: <mode> <sha256 of blob> <path>\0
# per blob in git's order (scripts/tree-digest.sh is the reference; this is
# a second, independent spelling of the same definition).
d_ref="$(
    git -C "$c" ls-tree -r "$commit" | while read -r mode _ oid path; do
        printf '%s %s %s\0' "$mode" "$(git -C "$c" cat-file blob "$oid" | sha256sum | cut -d' ' -f1)" "$path"
    done | sha256sum | cut -d' ' -f1
)"
[ "$d" = "$d_ref" ] && ok "digest matches the documented definition" || bad "digest $d differs from $d_ref"
expect_reject "commit not in the clone" bash "$verify" --challenge "$c" --challenge-commit "$(printf 'a%.0s' $(seq 40))" --digest-only
expect_reject "short commit id" bash "$verify" --challenge "$c" --challenge-commit abc --digest-only
expect_reject "file:// challenge" bash "$verify" --challenge "file://$c" --challenge-commit "$commit" --digest-only
expect_reject "challenge directory that does not exist" bash "$verify" --challenge "$work/nope" --challenge-commit "$commit" --digest-only
expect_reject "no arguments" bash "$verify"
expect_reject "option without value" bash "$verify" --theorem
expect_reject "unknown option" bash "$verify" --challenge "$c" --challenge-commit "$commit" --digest-only --bogus
{ bash "$verify" --help 2>&1 || true; } | grep -q -- '--challenge-commit ID' && ok "--help prints the option block" || bad "--help output"

# --- a predicate as the attest job builds it, from HEAD's lockfile ------------
git -C "$wf" show "$wf_commit:toolchain.lock" >"$work/toolchain.lock"
mkdir -p "$work/schemas"
git -C "$wf" show "$wf_commit:schemas/leanvfy-v1.json" >"$work/schemas/leanvfy-v1.json"
git -C "$wf" show "$wf_commit:schemas/in-toto-v1.json" >"$work/schemas/in-toto-v1.json"
axioms="$(git -C "$wf" show "$wf_commit:$wf_path" | sed -n 's/^  ALLOWED_AXIOMS: *//p')"
[ -n "$axioms" ] || {
    echo "cannot read ALLOWED_AXIOMS from $wf_path at $wf_commit" >&2
    exit 1
}
THEOREM=T.main CHALLENGE_REPO=https://github.com/a/c CHALLENGE_COMMIT="$commit" CHALLENGE_MODULE=Challenge \
    CHALLENGE_DIGEST="$d" SOLUTION_REPO=https://github.com/p/s SOLUTION_COMMIT="$(printf 'b%.0s' $(seq 40))" \
    SOLUTION_MODULE=Solution SOLUTION_DIGEST="$(printf 'b%.0s' $(seq 64))" ALLOWED_AXIOMS="$axioms" \
    TOOLCHAIN_LOCK="$work/toolchain.lock" SCHEMA_FILE="$work/schemas/leanvfy-v1.json" \
    bash "$here/build-predicate.sh" "$work/predicate.json" >/dev/null

# --- shim gh ------------------------------------------------------------------
# Records its arguments and the sha256 of the subject file it was handed (what
# the real gh would hash to look the attestation up), then prints the canned
# result.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$GH_ARGS_OUT"
sha256sum "$3" | cut -d' ' -f1 >"$GH_SUBJECT_OUT"
cat "$GH_RESULT"
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_ARGS_OUT="$work/gh-args" GH_SUBJECT_OUT="$work/gh-subject" GH_RESULT="$work/result.json"

# result <jq filter>: write the canned gh result -- one attestation whose
# certificate says what a genuine run's would -- modified by <jq filter>.
result() {
    jq -n --arg commit "$commit" --arg digest "$d" --arg wf_commit "$wf_commit" \
        --arg san "https://github.com/$wf_repo/$wf_path@refs/heads/main" \
        --slurpfile pred "$work/predicate.json" '[{
          verificationResult: {
            signature: { certificate: {
              issuer: "https://token.actions.githubusercontent.com",
              subjectAlternativeName: $san,
              buildSignerURI: $san,
              buildSignerDigest: $wf_commit,
              runnerEnvironment: "github-hosted",
              sourceRepositoryURI: "https://github.com/prover/repo",
              sourceRepositoryRef: "refs/heads/main",
              buildTrigger: "push",
              runInvocationURI: "https://github.com/prover/repo/actions/runs/1/attempts/1"
            } },
            verifiedTimestamps: [{ type: "Tlog", uri: "https://rekor.sigstore.dev", timestamp: "2026-09-15T08:00:00Z" }],
            statement: {
              _type: "https://in-toto.io/Statement/v1",
              predicateType: "https://github.com/theproofnetwork/leanvfy/predicate/v1",
              subject: [
                { name: ("challenge@" + $commit), digest: { sha256: $digest } },
                { name: ("solution@" + ("b" * 40)), digest: { sha256: ("b" * 64) } }
              ],
              predicate: $pred[0]
            }
          }
        }]' | jq "$1" >"$GH_RESULT"
}
run() { bash "$verify" --theorem T.main --challenge "$c" --challenge-commit "$commit" --prover prover/repo "$@"; }
# expect_reject_for <desc> <reason substring> [verify.sh args...]: rejected, and
# the rejection names the differing claim.
expect_reject_for() {
    local desc="$1" reason="$2"
    shift 2
    if run "$@" >"$work/last.log" 2>&1; then
        bad "$desc (was accepted)"
    elif grep -q -- "$reason" "$work/last.log"; then
        ok "$desc"
    else
        bad "$desc (rejected, but not for '$reason')"
        sed 's/^/       /' "$work/last.log" >&2
    fi
}

echo "Genuine attestation"
result '.'
expect_accept "accepted" run
grep -q '^VERIFIED: T.main, as stated in module Challenge of challenge commit' "$work/last.log" && ok "report names theorem, module and commit" || bad "report differs"
grep -q 'prover/repo/actions/runs/1' "$work/last.log" && ok "report shows the prover's run" || bad "run URL missing from report"
[ "$(cat "$GH_SUBJECT_OUT")" = "$d" ] && ok "gh was handed the tree listing whose sha256 is the digest" || bad "subject file hash $(cat "$GH_SUBJECT_OUT") differs from $d"
args="$(tr '\n' ' ' <"$GH_ARGS_OUT")"
[[ "$args" == "attestation verify "* ]] && ok "gh attestation verify" || bad "gh called as: $args"
for flag in "--repo prover/repo" "--cert-oidc-issuer https://token.actions.githubusercontent.com" \
    "--signer-workflow $wf_repo/$wf_path" "--deny-self-hosted-runners" \
    "--predicate-type https://github.com/theproofnetwork/leanvfy/predicate/v1" "--format json"; do
    [[ " $args " == *" $flag "* ]] && ok "gh given $flag" || bad "gh not given $flag: $args"
done
[[ "$args" != *"--bundle"* ]] && ok "no --bundle unless asked" || bad "--bundle passed unasked"
expect_accept "--json" run --json
jq -e '.statement.predicate.theorem == "T.main" and .certificate.runnerEnvironment == "github-hosted" and (.verifiedTimestamps | length) == 1' "$work/last.log" >/dev/null \
    && ok "--json prints statement, certificate and timestamps" || bad "--json output differs"
expect_accept "--prover owner and --bundle" run --prover prover --bundle "$GH_RESULT"
args="$(tr '\n' ' ' <"$GH_ARGS_OUT")"
[[ " $args " == *" --owner prover "* ]] && [[ " $args " == *" --bundle $GH_RESULT "* ]] && ok "gh given --owner and --bundle" || bad "args: $args"
expect_accept "--workflow-commit naming HEAD explicitly" run --workflow-commit "$wf_commit"
expect_accept "--workflow-commit HEAD plus another trusted revision" run --workflow-commit "$other_commit" --workflow-commit "$wf_commit"
expect_accept "--allowed-axioms superset" run --allowed-axioms "$axioms,Extra.ax"
expect_accept "--workflow-repo matching the certificate" run --workflow-repo "$wf_repo"

echo "Rejections (each names the differing claim)"
result '.[0].verificationResult.statement.predicate.theorem = "T.other"'
expect_reject_for "wrong theorem" "theorem is"
result '.'
expect_reject_for "wrong module" "challenge module is" --challenge-module Other
result '.[0].verificationResult.statement.predicate.challenge.digest.gitCommit = ("a" * 40)'
expect_reject_for "wrong challenge commit" "challenge commit is"
result '.[0].verificationResult.statement.predicate.challenge.digest.sha256 = ("a" * 64)'
expect_reject_for "wrong challenge tree digest" "challenge tree digest is"
# The audited digest appears as a subject but is bound to the solution role.
result '.[0].verificationResult.statement.predicate as $p
        | .[0].verificationResult.statement.predicate.challenge = ($p.solution | .annotations.module = "Challenge")
        | .[0].verificationResult.statement.predicate.solution = $p.challenge'
expect_reject_for "audited tree attested in the solution role" "challenge commit is"
result '.[0].verificationResult.statement.subject = [{ name: "other", digest: { sha256: ("f" * 64) } }]'
expect_reject_for "subject without the audited digest" "no subject carries the audited tree digest"
result '.[0].verificationResult.statement.predicate.verificationResult = "FAILED"'
expect_reject_for "FAILED predicate" "verificationResult is"
result '.[0].verificationResult.signature.certificate.buildSignerDigest = ("c" * 40)'
expect_reject_for "untrusted workflow commit" "not a trusted revision"
result '.[0].verificationResult.signature.certificate |= del(.buildSignerDigest)'
expect_reject_for "certificate without a signer digest" "not a trusted revision"
result '.'
expect_reject_for "only another revision trusted" "not a trusted revision" --workflow-commit "$other_commit"
expect_reject_for "trusted revision not in the clone" "not in this clone" --workflow-commit "$(printf 'c%.0s' $(seq 40))"
# Signed by the other (trusted) revision, but the predicate repeats HEAD's
# toolchain: what a workflow at that revision would sign differs.
result ".[0].verificationResult.signature.certificate.buildSignerDigest = \"$other_commit\""
expect_reject_for "toolchain block is not the signing revision's" "lean release is" --workflow-commit "$other_commit"
result '.[0].verificationResult.signature.certificate.runnerEnvironment = "self-hosted"'
expect_reject_for "self-hosted runner" "runner environment is"
result '.[0].verificationResult.signature.certificate.issuer = "https://evil.example"'
expect_reject_for "wrong OIDC issuer" "OIDC issuer is"
result ".[0].verificationResult.signature.certificate.subjectAlternativeName = \"https://github.com/evil/leanvfy/$wf_path@refs/heads/main\""
expect_reject_for "signing workflow in another repository" "signing workflow is"
result ".[0].verificationResult.signature.certificate.subjectAlternativeName = \"https://github.com/$wf_repo/.github/workflows/build-tools.yml@refs/heads/main\""
expect_reject_for "another workflow of this repository" "signing workflow is"
result '.'
expect_reject_for "--workflow-repo not matching the certificate" "signing workflow is" --workflow-repo other/repo
result '.[0].verificationResult.statement._type = "https://in-toto.io/Statement/v0.1"'
expect_reject_for "wrong statement type" "statement type is"
result '.[0].verificationResult.statement.predicateType = "https://slsa.dev/provenance/v1"'
expect_reject_for "wrong predicate type" "predicate type is"
result '.[0].verificationResult.statement.predicate.toolchain.lock.digest.sha256 = ("d" * 64)'
expect_reject_for "toolchain.lock digest differs from the trusted revision" "toolchain.lock digest is"
result '.[0].verificationResult.statement.predicate.toolchain.lean.annotations.version = "v0.0.0"'
expect_reject_for "lean release differs" "lean release is"
result '.[0].verificationResult.statement.predicate.toolchain.tools |= map(if .name == "comparator" then .digest.sha256 = ("e" * 64) else . end)'
expect_reject_for "a tool binary hash differs" "tool comparator is"
result '.[0].verificationResult.statement.predicate.toolchain.tools |= map(if .name == "comparator" then del(.annotations.patches) else . end)'
expect_reject_for "a tool's patches differ" "tool comparator is"
result '.[0].verificationResult.statement.predicate.toolchain.tools |= .[1:]'
expect_reject_for "a tool is missing" "tool set is"
result '.[0].verificationResult.statement.predicate.toolchain.tools += [{ name: "extra", uri: "https://x/y", digest: { sha256: ("a" * 64) }, annotations: { repository: "a/b", commit: ("a" * 40), engine: true } }]'
expect_reject_for "an extra tool" "tool set is"
result '.[0].verificationResult.statement.predicate.policy.allowedAxioms += ["Foo.ax"]'
expect_reject_for "axiom policy differs from the workflow" "axiom policy of the workflow is"
result '.[0].verificationResult.statement.predicate.policy.allowedAxioms |= .[1:]'
expect_reject_for "axiom policy narrower than the workflow's is still a mismatch" "axiom policy of the workflow is"
result '.'
expect_reject_for "verifier accepts fewer axioms than the policy" "not accepted with --allowed-axioms" --allowed-axioms propext
result '[]'
expect_reject_for "gh found nothing" "no attestation for the audited challenge tree"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: no attestations found" >&2
exit 1
EOF
expect_reject_for "gh fails" "no valid attestation"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$GH_ARGS_OUT"
sha256sum "$3" | cut -d' ' -f1 >"$GH_SUBJECT_OUT"
cat "$GH_RESULT"
EOF

echo "Several attestations"
result '. + . | .[0].verificationResult.statement.predicate.theorem = "T.other"'
expect_accept "a genuine one after a rejected one is accepted" run
grep -q 'Attestation 1 of 2 rejected' "$work/last.log" && ok "the rejected one is reported" || bad "no rejection report"
result '. + . | .[0].verificationResult.statement.predicate.theorem = "T.other" | .[1].verificationResult.signature.certificate.runnerEnvironment = "self-hosted"'
expect_reject "two bad ones are both rejected" run

echo "Argument checks"
expect_reject "--theorem with whitespace" run --theorem "T main"
expect_reject "--challenge-module with a slash" run --challenge-module "A/B"
expect_reject "--prover with three components" run --prover a/b/c
expect_reject "--workflow-repo without owner" run --workflow-repo repo
expect_reject "--workflow-commit that is not a commit id" run --workflow-commit main
expect_reject "--bundle that does not exist" run --bundle "$work/absent"
expect_reject "missing --prover" bash "$verify" --theorem T.main --challenge "$c" --challenge-commit "$commit"

test_summary
