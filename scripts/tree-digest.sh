#!/usr/bin/env bash
# Content digest of a git commit's tree, used as the attestation subject for the
# challenge and solution repositories.
#
# Usage: tree-digest.sh <checkout_dir> <commit>
#
# Prints one lowercase hex sha256. Algorithm, so that a verifier can recompute it
# on an independent clone (this script is the reference implementation):
#
#   1. list the tree recursively:  git ls-tree -r -z <commit>
#      giving records "<mode> blob <blob-oid>\t<path>" in git's canonical order
#      (bytewise by path). Only blobs occur: submodule entries (gitlinks, mode
#      160000) are rejected, since their content is not in the repository.
#   2. replace each <blob-oid> by the sha256 of that blob's content
#      (git cat-file blob <oid> | sha256sum), and drop the word "blob";
#   3. the digest is the sha256 of the resulting NUL-terminated records
#      "<mode> <sha256-of-content> <path>\0", concatenated in that order.
#
# Why not the commit id: git ids are SHA-1 (in almost every repository), and
# actions/attest indexes subjects by sha256. Why not `git archive`: its tar
# output is not specified to be byte-stable across git versions. This digest
# binds exactly what a source review looks at -- every path, its mode (regular,
# executable or symlink) and its bytes -- and nothing else.
#
# Why the encoding is unambiguous (a digest over a concatenation is only as
# strong as that concatenation is injective): mode and content hash are fixed
# width, blob bytes never appear directly (only their hash, so no file content
# can be mistaken for records), and the one variable-width field, the path, is
# terminated by the single byte a git tree entry name cannot contain. Newlines
# *are* legal in tree names, so a newline-terminated listing would let one
# entry named "a\n<mode> <hash> b" masquerade as the two entries a and b.
#
# The listing is produced inside the read-only, network-less jail of git-jail.sh:
# reading packs and resolving deltas are git code paths of their own, and the
# object store is prover-controlled bytes, so git gets the same wall here as it
# did when fetching. Only the listing leaves the jail; the final sha256 over it
# is taken on the host.
set -euo pipefail

dir="${1:-}"
commit="${2:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ] || ! [[ "$commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]]; then
    echo "Usage: $(basename "$0") <checkout_dir> <commit>" >&2
    exit 1
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-jail.sh
source "$here/git-jail.sh"

# Runs inside the jail (bash, git and sha256sum from /usr/bin). Paths are taken
# from -z output so names with unusual characters are not quoted or escaped by
# git, and re-emitted NUL-terminated for the same reason.
list_tree='
set -euo pipefail
tab=$(printf "\t")
git ls-tree -r -z "$1" | while IFS= read -r -d "" entry; do
    meta="${entry%%"$tab"*}"
    path="${entry#*"$tab"}"
    read -r mode type oid <<<"$meta"
    if [ "$type" != "blob" ]; then
        echo "Error: unsupported tree entry ($type) at $path; submodules are not accepted" >&2
        exit 1
    fi
    content_sha="$(git cat-file blob "$oid" | sha256sum | cut -d" " -f1)"
    printf "%s %s %s\0" "$mode" "$content_sha" "$path"
done
'
# Piped, not captured: bash variables cannot hold NUL bytes, so a $(...) would
# silently drop the record terminators. pipefail makes a failure in the jail
# fail the script.
git_jail "$(realpath "$dir")" read bash -c "$list_tree" bash "$commit" | sha256sum | awk '{print $1}'
