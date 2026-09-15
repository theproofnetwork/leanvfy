#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced by the test-*.sh scripts: bookkeeping, git fixtures and the local
# https server the untrusted-input tests fetch from.
#
#   test_init                  create $work (removed on exit), fix git identity
#   ok <desc> / bad <desc>     count a passed / failed check
#   expect_accept <desc> <cmd...>   the command must exit 0
#   expect_reject <desc> <cmd...>   the command must exit non-zero
#   test_summary               print the tally; exit status 1 if anything failed
#   new_repo <name>            empty git repository under $work/src; prints its path
#   publish <name> <dir> [noadd]
#                              commit <dir> (git add -A unless noadd), serve it as
#                              $base/<name>.git; prints the commit id
#   https_server               serve $srv over https on $base with a throwaway CA
#                              installed system-wide (sudo) for the duration of
#                              the run; requests are logged to $server_log
#
# Every hostile input has to arrive the way a prover's would -- over https,
# through the jail -- so the fixtures are served by git's dumb protocol over
# python's http.server with a self-signed certificate. Provisioning tests fetch
# their fake toolchain from the same server. The server also answers
# /redirect-file/... and /redirect-http/... with redirects to file:// and
# http://, for the transport tests.
# Linux only; needs bubblewrap, git, jq, curl, openssl, python3, sudo.

pass=0
fail=0
work=""
srv=""
base="https://127.0.0.1:8443"
server_pid=""
server_log=""
ca_file=/usr/local/share/ca-certificates/leanvfy-test.crt

ok() {
    pass=$((pass + 1))
    echo "  ok   $1"
}
bad() {
    fail=$((fail + 1))
    echo "  FAIL $1" >&2
}
# The command's output is kept in $work/last.log for follow-up assertions and
# is shown when the expectation fails.
expect_reject() {
    local desc="$1"
    shift
    if "$@" >"$work/last.log" 2>&1; then
        bad "$desc (was accepted)"
        sed 's/^/       /' "$work/last.log" >&2
    else
        ok "$desc"
    fi
}
expect_accept() {
    local desc="$1"
    shift
    if "$@" >"$work/last.log" 2>&1; then
        ok "$desc"
    else
        bad "$desc (was rejected)"
        sed 's/^/       /' "$work/last.log" >&2
    fi
}
test_summary() {
    echo
    echo "$pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

_test_cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    if [ -f "$ca_file" ]; then
        sudo rm -f "$ca_file"
        sudo update-ca-certificates --fresh >/dev/null
    fi
    [ -n "$work" ] && rm -rf "$work"
}
test_init() {
    work="$(mktemp -d)"
    srv="$work/srv"
    mkdir -p "$srv" "$work/out"
    trap _test_cleanup EXIT
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
}
# A fresh path under $work/out that does not exist yet (fetch-repo.sh insists).
out() { mktemp -u "$work/out/XXXXXXXX"; }

new_repo() {
    local d="$work/src/$1"
    mkdir -p "$d"
    git -C "$d" init -q
    echo "$d"
}
publish() {
    local name="$1" dir="$2"
    [ "${3:-}" = "noadd" ] || git -C "$dir" add -A >/dev/null
    git -C "$dir" commit -q -m "fixture $name" --allow-empty
    rm -rf "$srv/$name.git"
    git clone -q --bare "$dir" "$srv/$name.git"
    git -C "$srv/$name.git" update-server-info
    git -C "$dir" rev-parse HEAD
}

https_server() {
    server_log="$work/server.log"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=leanvfy-test \
        -addext "subjectAltName=IP:127.0.0.1" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    sudo cp "$work/cert.pem" "$ca_file"
    sudo update-ca-certificates >/dev/null
    cat >"$work/server.py" <<'EOF'
import http.server, ssl, sys
root, cert, key, log = sys.argv[1:5]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def do_GET(self):
        with open(log, "a") as f: f.write(self.path + "\n")
        if self.path.startswith("/redirect-file/"):
            self.send_response(302); self.send_header("Location", "file:///etc/passwd"); self.end_headers(); return
        if self.path.startswith("/redirect-http/"):
            self.send_response(302); self.send_header("Location", "http://127.0.0.1:8080" + self.path); self.end_headers(); return
        super().do_GET()
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
EOF
    : >"$server_log"
    python3 "$work/server.py" "$srv" "$work/cert.pem" "$work/key.pem" "$server_log" &
    server_pid=$!
    echo "leanvfy-test" >"$srv/ping"
    for _ in $(seq 50); do
        curl -sf --cacert "$work/cert.pem" "$base/ping" >/dev/null 2>&1 && break
        sleep 0.2
    done
    curl -sf --cacert "$work/cert.pem" "$base/ping" >/dev/null || {
        echo "test server did not come up" >&2
        exit 1
    }
    # The CA must also be trusted through the system store, which is what git
    # and curl inside the jails use.
    curl -sf "$base/ping" >/dev/null || {
        echo "test CA is not trusted by the system store" >&2
        exit 1
    }
}
