#!/usr/bin/env bash
# Behavioural tests for the untrusted-input scripts: fetch-repo.sh,
# materialize-deps.sh and tree-digest.sh (plus verify.sh's re-implementation of
# the digest). Linux only (bubblewrap); run by
# .github/workflows/test-scripts.yml and usable locally with sudo (it installs a
# throwaway CA into the system trust store for the duration of the run).
#
# Adversarial repositories are served from the local https server of
# test-lib.sh, because every hostile tree has to arrive the way a prover's
# would: over https, through the jail. Rejections that need no server (URL
# shapes, manifest contents) are tested directly. When
# GITHUB_REPOSITORY/GITHUB_SHA are set the smart-HTTP happy path is exercised
# against that public repository as well.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/test-lib.sh
source "$here/test-lib.sh"
test_init

# --- fixtures ---------------------------------------------------------------

# A dependency package and a good root package whose manifest pins it.
d="$(new_repo dep)"
printf 'name = "dep"\n[[lean_lib]]\nname = "Dep"\n' >"$d/lakefile.toml"
echo 'def dep := 1' >"$d/Dep.lean"
dep_commit="$(publish dep "$d")"

d="$(new_repo good)"
printf 'name = "good"\n[[lean_lib]]\nname = "Challenge"\n' >"$d/lakefile.toml"
echo 'theorem t : 1 = 1 := sorry' >"$d/Challenge.lean"
cat >"$d/lake-manifest.json" <<EOF
{"version": "1.1.0", "packagesDir": ".lake/packages", "lakeDir": ".lake", "name": "good",
 "packages": [{"url": "$base/dep.git", "type": "git", "subDir": null, "scope": "", "rev": "$dep_commit",
               "name": "dep", "manifestFile": "lake-manifest.json", "inputRev": "main", "inherited": false, "configFile": "lakefile.toml"}]}
EOF
good_commit="$(publish good "$d")"

d="$(new_repo lake_symlink)"
ln -s /etc "$d/.lake"
echo x >"$d/f"
lake_symlink_commit="$(publish lake_symlink "$d")"

d="$(new_repo lake_dir_deep)"
mkdir -p "$d/sub/.lake"
echo x >"$d/sub/.lake/f"
lake_dir_deep_commit="$(publish lake_dir_deep "$d")"

d="$(new_repo manifest_symlink)"
ln -s /etc/passwd "$d/lake-manifest.json"
printf 'name = "m"\n' >"$d/lakefile.toml"
manifest_symlink_commit="$(publish manifest_symlink "$d")"

d="$(new_repo olean)"
printf 'name = "o"\n' >"$d/lakefile.toml"
mkdir -p "$d/build/lib"
echo x >"$d/build/lib/Foo.olean"
olean_commit="$(publish olean "$d")"

d="$(new_repo lakefile_lean)"
echo 'import Lake' >"$d/lakefile.lean"
echo x >"$d/Foo.lean"
lakefile_lean_commit="$(publish lakefile_lean "$d")"

d="$(new_repo no_lakefile)"
echo x >"$d/Foo.lean"
no_lakefile_commit="$(publish no_lakefile "$d")"

d="$(new_repo submodule)"
printf 'name = "s"\n' >"$d/lakefile.toml"
printf '[submodule "vendored"]\n\tpath = vendored\n\turl = %s/dep.git\n' "$base" >"$d/.gitmodules"
git -C "$d" add -A >/dev/null
git -C "$d" update-index --add --cacheinfo "160000,$dep_commit,vendored"
submodule_commit="$(publish submodule "$d" noadd)"

# Two trees a newline-terminated digest listing could not tell apart: files a
# and b, versus a single file named "a<newline><mode> <sha256 of b> b" holding
# a's content (git allows newlines in names). The digest records are NUL-
# terminated precisely so that these differ.
d="$(new_repo two_files)"
echo alpha >"$d/a"
echo beta >"$d/b"
two_files_commit="$(publish two_files "$d")"
d="$(new_repo forged_name)"
echo alpha >"$d/$(printf 'a\n100644 %s b' "$(sha256sum <"$work/src/two_files/b" | cut -d' ' -f1)")"
forged_name_commit="$(publish forged_name "$d")"

# --- local https server ------------------------------------------------------
https_server

fetch="$here/fetch-repo.sh"
mat="$here/materialize-deps.sh"
digest="$here/tree-digest.sh"
zeros="$(printf '0%.0s' $(seq 40))"

echo "URL shapes"
rm -f /tmp/leanvfy-pwned
expect_reject "ext:: transport" bash "$fetch" "ext::sh -c touch% /tmp/leanvfy-pwned" "$zeros" "$(out)"
expect_reject "file:// transport" bash "$fetch" "file:///etc" "$zeros" "$(out)"
expect_reject "ssh:// transport" bash "$fetch" "ssh://git@github.com/a/b" "$zeros" "$(out)"
expect_reject "http:// (no TLS)" bash "$fetch" "http://127.0.0.1:8443/good.git" "$good_commit" "$(out)"
expect_reject "userinfo in URL" bash "$fetch" "https://user:pw@127.0.0.1:8443/good.git" "$good_commit" "$(out)"
expect_reject "newline in URL" bash "$fetch" "$(printf 'https://127.0.0.1:8443/good.git\nx')" "$good_commit" "$(out)"
expect_reject "leading dash" bash "$fetch" "--upload-pack=touch /tmp/leanvfy-pwned" "$zeros" "$(out)"
expect_reject "short commit" bash "$fetch" "$base/good.git" "${good_commit:0:12}" "$(out)"
expect_reject "branch name as commit" bash "$fetch" "$base/good.git" "master" "$(out)"
expect_reject "redirect to file://" bash "$fetch" "$base/redirect-file/good.git" "$good_commit" "$(out)"
expect_reject "redirect to http://" bash "$fetch" "$base/redirect-http/good.git" "$good_commit" "$(out)"
[ -e /tmp/leanvfy-pwned ] && bad "a rejected URL executed a command" || ok "no command execution from URLs"

echo "Host git configuration must not leak into the jail"
# If the jail honoured the host's global config this rewrite would turn the
# https fetch into a file:// one (and fail on protocol.allow), or hooksPath
# would run the marker script.
export GIT_CONFIG_GLOBAL="$work/hostile-gitconfig"
mkdir -p "$work/hooks"
printf '#!/bin/sh\ntouch /tmp/leanvfy-pwned\n' >"$work/hooks/post-checkout"
chmod +x "$work/hooks/post-checkout"
cat >"$GIT_CONFIG_GLOBAL" <<EOF
[url "file://$srv/lakefile_lean.git"]
	insteadOf = $base/good.git
[core]
	hooksPath = $work/hooks
[credential]
	helper = !sh -c 'touch /tmp/leanvfy-pwned'
EOF
o="$(out)"
expect_accept "fetch ignores host gitconfig" bash "$fetch" "$base/good.git" "$good_commit" "$o"
[ -f "$o/Challenge.lean" ] && ok "fetched the https repository, not the rewritten one" || bad "URL rewrite from host config took effect"
[ -e /tmp/leanvfy-pwned ] && bad "host hooksPath/credential helper ran" || ok "no hook or credential helper ran"
unset GIT_CONFIG_GLOBAL

echo "Tree policy"
expect_reject "committed .lake symlink" bash "$fetch" "$base/lake_symlink.git" "$lake_symlink_commit" "$(out)"
expect_reject "nested .lake directory" bash "$fetch" "$base/lake_dir_deep.git" "$lake_dir_deep_commit" "$(out)"
expect_reject "committed .olean" bash "$fetch" "$base/olean.git" "$olean_commit" "$(out)"
expect_reject "submodule entry" bash "$fetch" "$base/submodule.git" "$submodule_commit" "$(out)"
expect_reject "lakefile.lean with --require-toml" bash "$fetch" --require-toml "$base/lakefile_lean.git" "$lakefile_lean_commit" "$(out)"
expect_reject "no lakefile with --require-toml" bash "$fetch" --require-toml "$base/no_lakefile.git" "$no_lakefile_commit" "$(out)"
expect_accept "lakefile.lean without --require-toml" bash "$fetch" "$base/lakefile_lean.git" "$lakefile_lean_commit" "$(out)"
o="$(out)"
expect_accept "good repo with --require-toml" bash "$fetch" --require-toml "$base/good.git" "$good_commit" "$o"
[ -d "$o/.lake" ] && [ ! -L "$o/.lake" ] && ok ".lake created as a plain directory" || bad ".lake missing after fetch"
[ "$(git -C "$o" rev-parse HEAD)" = "$good_commit" ] && ok "HEAD is the requested commit" || bad "HEAD differs"
expect_reject "destination already exists" bash "$fetch" "$base/good.git" "$good_commit" "$o"
o2="$(out)"
mkdir -p "$(dirname "$o2")"
ln -s /etc "$o2"
expect_reject "destination is a symlink" bash "$fetch" "$base/good.git" "$good_commit" "$o2"

echo "Manifest validation (materialize-deps.sh)"
mkmanifest() {
    local d
    d="$(out)"
    mkdir -p "$d/.lake"
    printf '%s' "$1" >"$d/lake-manifest.json"
    echo "$d"
}
expect_reject "path dependency" bash "$mat" "$(mkmanifest '{"packages":[{"type":"path","dir":"../x","name":"x"}]}')"
expect_reject "branch as rev" bash "$mat" "$(mkmanifest "{\"packages\":[{\"type\":\"git\",\"url\":\"$base/dep.git\",\"rev\":\"main\",\"name\":\"dep\"}]}")"
expect_reject "packagesDir escape" bash "$mat" "$(mkmanifest "{\"packagesDir\":\"../x\",\"packages\":[]}")"
expect_reject "lakeDir elsewhere" bash "$mat" "$(mkmanifest "{\"lakeDir\":\"build\",\"packages\":[]}")"
expect_reject "duplicate names" bash "$mat" "$(mkmanifest "{\"packages\":[{\"type\":\"git\",\"url\":\"$base/dep.git\",\"rev\":\"$dep_commit\",\"name\":\"a\"},{\"type\":\"git\",\"url\":\"$base/dep.git\",\"rev\":\"$dep_commit\",\"name\":\"a\"}]}")"
expect_reject "name with slash" bash "$mat" "$(mkmanifest "{\"packages\":[{\"type\":\"git\",\"url\":\"$base/dep.git\",\"rev\":\"$dep_commit\",\"name\":\"a/b\"}]}")"
expect_reject "name .." bash "$mat" "$(mkmanifest "{\"packages\":[{\"type\":\"git\",\"url\":\"$base/dep.git\",\"rev\":\"$dep_commit\",\"name\":\"..\"}]}")"
expect_reject "http url in manifest" bash "$mat" "$(mkmanifest "{\"packages\":[{\"type\":\"git\",\"url\":\"http://127.0.0.1:8443/dep.git\",\"rev\":\"$dep_commit\",\"name\":\"dep\"}]}")"
expect_reject "manifest not an object" bash "$mat" "$(mkmanifest '[]')"
expect_reject "manifest is a symlink" bash "$mat" "$(
    d="$(out)"
    mkdir -p "$d/.lake"
    ln -s /etc/passwd "$d/lake-manifest.json"
    echo "$d"
)"
expect_reject "missing .lake" bash "$mat" "$(
    d="$(out)"
    mkdir -p "$d"
    printf '{"packages":[]}' >"$d/lake-manifest.json"
    echo "$d"
)"
expect_accept "empty package list" bash "$mat" "$(mkmanifest '{"packages":[]}')"
o="$(out)"
expect_accept "fetch repo whose manifest is a symlink" bash "$fetch" "$base/manifest_symlink.git" "$manifest_symlink_commit" "$o"
expect_reject "materialize rejects the symlinked manifest" bash "$mat" "$o"
expect_reject "no manifest at all" bash "$mat" "$(
    d="$(out)"
    mkdir -p "$d/.lake"
    echo "$d"
)"

echo "Dependencies end to end"
o="$(out)"
bash "$fetch" --require-toml "$base/good.git" "$good_commit" "$o" >/dev/null
expect_accept "materialize good manifest" bash "$mat" "$o"
p="$o/.lake/packages/dep"
[ "$(git -C "$p" rev-parse HEAD 2>/dev/null)" = "$dep_commit" ] && ok "dependency at pinned revision" || bad "dependency revision wrong"
[ "$(git -C "$p" remote get-url origin 2>/dev/null)" = "$base/dep.git" ] && ok "dependency origin is the manifest url" || bad "dependency origin differs"
[ -d "$p/.lake" ] && ok "dependency got its own empty .lake" || bad "dependency .lake missing"

echo "Tree digest"
d1="$(bash "$digest" "$o" "$good_commit")"
ref="$work/ref"
git clone -q "$srv/good.git" "$ref"
d2="$(bash "$digest" "$ref" "$good_commit")"
[ "$d1" = "$d2" ] && [[ "$d1" =~ ^[a-f0-9]{64}$ ]] && ok "digest reproducible on an independent clone ($d1)" || bad "digest mismatch: $d1 vs $d2"
d3="$(bash "$digest" "$work/src/dep" "$dep_commit")"
[ "$d3" != "$d1" ] && ok "different trees give different digests" || bad "digest collision between fixtures"
expect_reject "digest refuses submodule trees" bash "$digest" "$work/src/submodule" "$submodule_commit"
d5="$(bash "$digest" "$work/src/two_files" "$two_files_commit")"
d6="$(bash "$digest" "$work/src/forged_name" "$forged_name_commit")"
[ "$d5" != "$d6" ] && [[ "$d6" =~ ^[a-f0-9]{64}$ ]] && ok "a newline in a path cannot forge listing records" || bad "digest collision via newline in path: $d5 vs $d6"
# verify.sh recomputes the subject on the verifier's machine, without the jail;
# it must agree with the reference implementation byte for byte.
verify="$here/../verify.sh"
d4="$(bash "$verify" --challenge "$ref" --challenge-commit "$good_commit" --digest-only)"
[ "$d4" = "$d1" ] && ok "verify.sh recomputes the same digest" || bad "verify.sh digest differs: $d4 vs $d1"
d7="$(bash "$verify" --challenge "$work/src/forged_name" --challenge-commit "$forged_name_commit" --digest-only)"
[ "$d7" = "$d6" ] && ok "verify.sh agrees on a tree with a newline in a path" || bad "verify.sh digest differs on newline path: $d7 vs $d6"
expect_reject "verify.sh refuses submodule trees" bash "$verify" --challenge "$work/src/submodule" --challenge-commit "$submodule_commit" --digest-only

if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ]; then
    echo "Smart HTTP against GitHub"
    o="$(out)"
    expect_accept "fetch $GITHUB_REPOSITORY@$GITHUB_SHA by object id" bash "$fetch" "https://github.com/$GITHUB_REPOSITORY" "$GITHUB_SHA" "$o"
    grep -q "Fetch by object id refused" "$work/last.log" && bad "GitHub needed the full-fetch fallback" || ok "fetched with --depth 1 by object id"
fi

test_summary
