#!/usr/bin/env bash
# Verify a leanvfy attestation: that the theorem, as stated in the challenge
# commit the verifier audited, was proven under the leanvfy workflow at a
# trusted revision, on a GitHub-hosted runner.
#
# Usage:
#   verify.sh --theorem <name> --challenge <dir|https-url> --challenge-commit <id>
#             --prover <owner>[/<repo>] [--bundle <file> [--trusted-root <file>]]
#             [options]
#
#   --theorem NAME             Fully-qualified name of the theorem, as declared
#                              in the challenge module
#   --challenge DIR|URL        The audited challenge: any clone holding the
#                              commit, or an https URL cloned into a temporary
#                              directory
#   --challenge-commit ID      Full commit id of the audited challenge
#   --challenge-module MOD     Module of the challenge declaring the theorem
#                              (default: Challenge)
#   --prover OWNER[/REPO]      Repository (or owner) the prover ran the
#                              workflow in. Attestations are looked up there
#                              via the GitHub API unless --bundle is given
#   --bundle FILE              Sigstore bundle to verify instead of fetching
#                              from GitHub: one bundle as a JSON file (the
#                              `bundle` of --json, or `gh attestation
#                              download`'s output) or several as JSON lines.
#                              Untrusted input: it is what the prover hands
#                              over, and every claim in it is checked the
#                              same way; --prover is then checked against
#                              the certificate's source repository by gh
#   --trusted-root FILE        Sigstore trusted root (`gh attestation
#                              trusted-root > FILE` on a networked machine)
#                              for verifying a bundle without network access.
#                              As security-relevant as this checkout: it holds
#                              the keys signatures are checked against, so
#                              obtain it from a machine and account you trust
#                              and refresh it as Sigstore rotates keys
#   --workflow-commit ID       Revision of this repository trusted to have
#                              produced the attestation; repeatable. Default:
#                              HEAD of the checkout this script runs from
#   --workflow-repo OWNER/REPO GitHub repository the reusable workflow is
#                              called from (default: theproofnetwork/leanvfy)
#   --allowed-axioms LIST      Comma-separated axioms the verifier accepts the
#                              proof to depend on (default:
#                              propext,Quot.sound,Classical.choice)
#   --digest-only              Print the challenge tree digest and stop; no
#                              attestation is looked at
#   --json                     Print the verified statement, certificate
#                              summary, timestamps and the verified bundle as
#                              JSON instead of the report (`.bundle` can be
#                              archived and re-verified with --bundle)
#
# Needs git, jq and the GitHub CLI (`gh`, authenticated: `gh auth login` or
# GH_TOKEN; verification fetches the Sigstore trust root unless --trusted-root
# is given and, without --bundle, the attestations through the API). Runs on
# Linux and macOS.
#
# What is checked, and against what (README "Attestation contents"):
#   1. The attestation subject. The verifier's own clone of the challenge is
#      listed exactly as scripts/tree-digest.sh does on the runner (the
#      NUL-terminated listing, not its hash, is what `gh attestation verify`
#      hashes), so the attestation found is one whose subject is the audited
#      tree.
#   2. Signature and certificate, by `gh attestation verify`: Sigstore chain,
#      transparency log / timestamp, OIDC issuer, signing workflow
#      (leanvfy.yml in --workflow-repo), GitHub-hosted runner, predicate type.
#   3. The certificate again, here, plus what gh cannot know: the signing
#      workflow's commit (job_workflow_sha) must be one of the trusted
#      revisions, and the predicate must bind the audited digest to the
#      *challenge* role (not the solution's), name the audited commit, module
#      and theorem, say PASSED, and repeat the toolchain (from toolchain.lock)
#      and the axiom policy (from leanvfy.yml) exactly as committed at that
#      workflow revision. The policy must also be one the verifier accepts
#      (--allowed-axioms).
# The predicate's solution block is reported, not judged: the solution is
# whatever the workflow at that commit accepted. Nothing about the prover's
# repository is trusted: --prover tells gh where to look and is checked
# against the certificate's source repository, never the other way round.
set -euo pipefail

WORKFLOW_PATH=.github/workflows/leanvfy.yml
PREDICATE_TYPE=https://github.com/theproofnetwork/leanvfy/predicate/v1
STATEMENT_TYPE=https://in-toto.io/Statement/v1
OIDC_ISSUER=https://token.actions.githubusercontent.com

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    # The option block of the header comment, up to the "Needs ..." paragraph.
    awk 'NR > 1 && (!/^#/ || /^# Needs/) { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}" >&2
    exit 2
}
fail() {
    echo "Error: $1" >&2
    exit 1
}

theorem="" challenge="" challenge_commit="" challenge_module=Challenge
prover="" bundle="" trusted_root="" workflow_repo=theproofnetwork/leanvfy
allowed_axioms=propext,Quot.sound,Classical.choice
digest_only=0 json_out=0
trusted=()
while [ $# -gt 0 ]; do
    case "$1" in
        --theorem | --challenge | --challenge-commit | --challenge-module | --prover | --bundle | --trusted-root | --workflow-commit | --workflow-repo | --allowed-axioms)
            [ $# -ge 2 ] || fail "$1 needs a value"
            ;;
    esac
    case "$1" in
        --theorem) theorem="$2" ;;
        --challenge) challenge="$2" ;;
        --challenge-commit) challenge_commit="$2" ;;
        --challenge-module) challenge_module="$2" ;;
        --prover) prover="$2" ;;
        --bundle) bundle="$2" ;;
        --trusted-root) trusted_root="$2" ;;
        --workflow-commit) trusted+=("$2") ;;
        --workflow-repo) workflow_repo="$2" ;;
        --allowed-axioms) allowed_axioms="$2" ;;
        --digest-only) digest_only=1 ;;
        --json) json_out=1 ;;
        -h | --help) usage ;;
        *) fail "unknown argument '$1' (try --help)" ;;
    esac
    case "$1" in
        --digest-only | --json) shift ;;
        *) shift 2 ;;
    esac
done

[ -n "$challenge" ] || usage
[[ "$challenge_commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || fail "--challenge-commit must be a full lowercase commit id"
if [ "$digest_only" -eq 0 ]; then
    [ -n "$theorem" ] && [ -n "$prover" ] || usage
    [[ "$theorem" =~ ^[^[:space:][:cntrl:]]+$ ]] || fail "--theorem must be a single Lean declaration name"
    [[ "$challenge_module" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]] || fail "--challenge-module must be a dotted Lean module name"
    [[ "$prover" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]] || fail "--prover must be <owner> or <owner>/<repo>"
    [[ "$workflow_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--workflow-repo must be <owner>/<repo>"
    [ -z "$bundle" ] || [ -f "$bundle" ] || fail "bundle '$bundle' does not exist"
    [ -z "$trusted_root" ] || [ -f "$trusted_root" ] || fail "trusted root '$trusted_root' does not exist"
    [ -z "$trusted_root" ] || [ -n "$bundle" ] || fail "--trusted-root is for verifying a bundle; pass --bundle"
fi

for tool in git jq; do
    command -v "$tool" >/dev/null || fail "$tool is required"
done
[ "$digest_only" -eq 1 ] || command -v gh >/dev/null || fail "the GitHub CLI (gh) is required"
if command -v sha256sum >/dev/null; then
    sha256() { sha256sum | cut -d' ' -f1; }
else
    sha256() { shasum -a 256 | cut -d' ' -f1; }
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- 1. the subject: the audited challenge tree, listed as on the runner -----
# Same algorithm as scripts/tree-digest.sh (the reference implementation),
# without its jail: this is the verifier's own clone of a repository they have
# already audited. Any clone holding the commit gives the same listing.
if [[ "$challenge" =~ ^https:// ]]; then
    echo "Cloning $challenge" >&2
    git clone -q --no-checkout -- "$challenge" "$work/challenge"
    challenge_dir="$work/challenge"
elif [ -d "$challenge" ]; then
    challenge_dir="$challenge"
else
    fail "--challenge must be a directory or an https URL"
fi
git -C "$challenge_dir" cat-file -e "$challenge_commit^{commit}" 2>/dev/null \
    || fail "commit $challenge_commit is not in $challenge_dir (fetch it first)"

tree_listing() {
    local repo="$1" commit="$2" tab entry meta path mode type oid
    tab="$(printf '\t')"
    git -C "$repo" ls-tree -r -z "$commit" | while IFS= read -r -d '' entry; do
        meta="${entry%%"$tab"*}"
        path="${entry#*"$tab"}"
        read -r mode type oid <<<"$meta"
        if [ "$type" != blob ]; then
            echo "Error: unsupported tree entry ($type) at $path; the workflow rejects submodules" >&2
            exit 1
        fi
        printf '%s %s %s\0' "$mode" "$(git -C "$repo" cat-file blob "$oid" | sha256)" "$path"
    done
}
# Written straight to the subject file: the records are NUL-terminated (the
# one byte a tree entry name cannot contain), and a shell variable would drop
# those bytes.
subject="$work/challenge@$challenge_commit"
tree_listing "$challenge_dir" "$challenge_commit" >"$subject" || fail "could not list the challenge tree"
challenge_digest="$(sha256 <"$subject")"
if [ "$digest_only" -eq 1 ]; then
    echo "$challenge_digest"
    exit 0
fi

# --- trusted workflow revisions and what each one pins -----------------------
# The trust anchor is a revision of this repository: by default the one this
# script is run from, i.e. the code the verifier has in front of them. What
# the predicate must repeat -- the toolchain block and the axiom policy -- is
# derived from that commit (not the working tree) the way the workflow derives
# it: the toolchain block from toolchain.lock as scripts/build-predicate.sh
# expands it, the policy from ALLOWED_AXIOMS in leanvfy.yml.
if [ ${#trusted[@]} -eq 0 ]; then
    trusted=("$(git -C "$here" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)") \
        || fail "not running from a clone of the workflow repository; pass --workflow-commit"
fi
expected='{}'
for commit in "${trusted[@]}"; do
    [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || fail "--workflow-commit must be a full lowercase commit id, got '$commit'"
    git -C "$here" show "$commit:toolchain.lock" >"$work/lock" 2>/dev/null \
        || fail "toolchain.lock at workflow commit $commit is not in this clone (fetch it first)"
    axioms="$(git -C "$here" show "$commit:$WORKFLOW_PATH" 2>/dev/null | sed -n 's/^  ALLOWED_AXIOMS: *//p')"
    [ -n "$axioms" ] || fail "cannot read ALLOWED_AXIOMS from $WORKFLOW_PATH at workflow commit $commit"
    expected="$(jq --argjson m "$expected" --arg c "$commit" --arg axioms "$axioms" \
        --arg lock_sha "$(sha256 <"$work/lock")" '
        $m + {($c): {
          allowedAxioms: ($axioms | split(",") | map(select(length > 0))),
          toolchain: {
            lock: { name: "toolchain.lock", digest: { sha256: $lock_sha } },
            lean: { name: "lean4", uri: .lean.url, digest: { sha256: .lean.sha256 }, annotations: { version: .lean.version } },
            tools: [ .tools[] | { name, uri: .url, digest: { sha256 },
              annotations: ({ repository: .repo, commit, engine }
                + (if (.patches // []) | length > 0 then { patches } else {} end)) } ]
          }
        }}' "$work/lock")"
done

# --- 2. signature, certificate and lookup by gh ------------------------------
scope=(--repo "$prover")
[[ "$prover" == */* ]] || scope=(--owner "$prover")
source=()
[ -z "$bundle" ] || source=(--bundle "$bundle")
[ -z "$trusted_root" ] || source+=(--custom-trusted-root "$trusted_root")
if ! gh attestation verify "$subject" "${scope[@]}" ${source[@]+"${source[@]}"} \
    --cert-oidc-issuer "$OIDC_ISSUER" \
    --signer-workflow "$workflow_repo/$WORKFLOW_PATH" \
    --deny-self-hosted-runners \
    --predicate-type "$PREDICATE_TYPE" \
    --format json >"$work/results.json" 2>"$work/gh.log"; then
    cat "$work/gh.log" >&2
    fail "gh attestation verify found no valid attestation for the audited challenge tree ($challenge_digest)"
fi

# --- 3. the claim ------------------------------------------------------------
# Every attestation gh accepted is checked in full; the first one that passes
# wins. Each check names what it saw, so a rejection says which claim differs.
checks='
def cert: .verificationResult.signature.certificate;
def stmt: .verificationResult.statement;
def pred: stmt.predicate;
def expect(what; got; want): if got != want then "\(what) is \(got | tojson), expected \(want | tojson)" else empty end;
(cert.buildSignerDigest // "") as $signer
| [
  expect("OIDC issuer"; cert.issuer; $issuer),
  (if (cert.subjectAlternativeName // "" | startswith($san_prefix)) then empty
   else "signing workflow is \(cert.subjectAlternativeName | tojson), expected \($san_prefix)<ref>" end),
  (if ($expected | has($signer)) then empty
   else "signed by workflow commit \($signer | tojson), not a trusted revision (\($expected | keys | join(", ")))" end),
  expect("runner environment"; cert.runnerEnvironment; "github-hosted"),
  expect("statement type"; stmt._type; $stmt_type),
  expect("predicate type"; stmt.predicateType; $ptype),
  (if any(stmt.subject[]?; .digest.sha256 == $digest) then empty
   else "no subject carries the audited tree digest \($digest)" end),
  expect("verificationResult"; pred.verificationResult; "PASSED"),
  expect("theorem"; pred.theorem; $theorem),
  expect("challenge commit"; pred.challenge.digest.gitCommit; $commit),
  expect("challenge tree digest"; pred.challenge.digest.sha256; $digest),
  expect("challenge module"; pred.challenge.annotations.module; $mod),
  (if ($expected | has($signer)) then
     $expected[$signer] as $exp
     | expect("toolchain.lock digest"; pred.toolchain.lock.digest.sha256; $exp.toolchain.lock.digest.sha256),
       expect("lean release"; pred.toolchain.lean; $exp.toolchain.lean),
       expect("tool set"; [pred.toolchain.tools[]?.name]; [$exp.toolchain.tools[].name]),
       (($exp.toolchain.tools | map({(.name): .}) | add) as $want
        | pred.toolchain.tools[]? | expect("tool \(.name)"; .; $want[.name])),
       expect("axiom policy of the workflow"; pred.policy.allowedAxioms; $exp.allowedAxioms)
   else empty end),
  (((pred.policy.allowedAxioms // []) - $accept) as $extra
   | if $extra == [] then empty
     else "solution may depend on axioms not accepted with --allowed-axioms: \($extra | join(", "))" end)
]'
n="$(jq 'length' "$work/results.json")"
accepted=""
for ((i = 0; i < n; i++)); do
    reasons="$(jq -c --argjson i "$i" \
        --arg issuer "$OIDC_ISSUER" \
        --arg san_prefix "https://github.com/$workflow_repo/$WORKFLOW_PATH@" \
        --argjson expected "$expected" \
        --argjson accept "$(jq -cn --arg a "$allowed_axioms" '$a | split(",") | map(select(length > 0))')" \
        --arg stmt_type "$STATEMENT_TYPE" \
        --arg ptype "$PREDICATE_TYPE" \
        --arg digest "$challenge_digest" \
        --arg theorem "$theorem" \
        --arg commit "$challenge_commit" \
        --arg mod "$challenge_module" \
        ".[\$i] | $checks" "$work/results.json")"
    if [ "$reasons" = "[]" ]; then
        accepted="$i"
        break
    fi
    echo "Attestation $((i + 1)) of $n rejected:" >&2
    jq -r '.[] | "  - " + .' <<<"$reasons" >&2
done
[ -n "$accepted" ] || fail "no attestation for the audited challenge tree makes the expected claim"

if [ "$json_out" -eq 1 ]; then
    # The bundle is the verified attestation itself, for archiving; --bundle
    # takes it back.
    jq --argjson i "$accepted" '.[$i] | (.verificationResult | {statement, certificate: .signature.certificate, verifiedTimestamps}) + {bundle: .attestation.bundle}' "$work/results.json"
    exit 0
fi

jq -r --argjson i "$accepted" '
.[$i].verificationResult
| .signature.certificate as $cert
| .statement.predicate as $pred
| def checkout(c): "\(c.uri) @ \(c.digest.gitCommit)\n                   module \(c.annotations.module), tree sha256 \(c.digest.sha256)";
  "VERIFIED: \($pred.theorem), as stated in module \($pred.challenge.annotations.module) of challenge commit \($pred.challenge.digest.gitCommit), was proven.",
  "",
  "  theorem          \($pred.theorem)",
  "  challenge        \(checkout($pred.challenge))",
  "  solution         \(checkout($pred.solution))",
  "  allowed axioms   \($pred.policy.allowedAxioms | join(", "))",
  "  workflow         \($cert.subjectAlternativeName)",
  "                   commit \($cert.buildSignerDigest)",
  "  runner           \($cert.runnerEnvironment)",
  "  prover           \($cert.sourceRepositoryURI) (checked against --prover)",
  "  prover run       \($cert.runInvocationURI) (\($cert.buildTrigger) on \($cert.sourceRepositoryRef))",
  "  signed           \([.verifiedTimestamps[]? | "\(.timestamp) (\(.type))"] | join(", "))",
  "  lean             \($pred.toolchain.lean.annotations.version)",
  "  tools            \([$pred.toolchain.tools[]
                          | "\(.name) \(.annotations.repository)@\(.annotations.commit[:12])"
                            + (if .annotations.engine then " [engine]" else "" end)
                            + (if .annotations.patches then " [patched: \(.annotations.patches | join(", "))]" else "" end)]
                         | join("\n                   "))"
' "$work/results.json"
