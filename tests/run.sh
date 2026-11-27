#!/usr/bin/env bash
#
# Test suite for the scripts in bin/. Needs only bash, git and coreutils;
# tests for optional tools (python3, curl, zip, ...) are skipped if the tool
# is missing.
#
#   tests/run.sh            run everything
#   tests/run.sh killport   run tests whose name contains "killport"
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$ROOT/bin:$PATH"
export NO_COLOR=1 LC_ALL=C

SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/devscripts-test.XXXXXX")
trap 'rm -rf "$SUITE_TMP"' EXIT

# Keep the developer's own git config out of the tests.
export HOME=$SUITE_TMP/home GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
cat >"$HOME/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.com
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[advice]
	detachedHead = false
EOF

have() { command -v "$1" >/dev/null 2>&1; }

# --- assertions -------------------------------------------------------------
# run CMD...  sets $out (stdout and stderr together) and $status.
run() { out=$("$@" 2>&1); status=$?; }
fail() { printf '    FAIL: %s\n' "$*"; printf '    output was:\n%s\n' "$(printf '%s\n' "$out" | sed 's/^/      | /')"; exit 1; }
skip() { printf '    (skipped: %s)\n' "$*"; exit 3; }
expect_status() { [ "$status" -eq "$1" ] || fail "expected exit status $1, got $status"; }
expect_out() { case $out in *"$1"*) ;; *) fail "expected output to contain: $1" ;; esac; }
expect_no_out() { case $out in *"$1"*) fail "expected output NOT to contain: $1" ;; esac; }
expect_file() { [ -e "$1" ] || fail "expected file to exist: $1"; }
expect_no_file() { [ ! -e "$1" ] || fail "expected file to be gone: $1"; }

# A clone ("work") of a bare repo ("remote.git") with one commit on main.
make_repo() {
  git init -q --bare remote.git
  git clone -q remote.git work 2>/dev/null
  cd work || exit 1
  echo hello >README
  git add README
  git commit -q -m "initial commit"
  git push -q origin main 2>/dev/null
  git remote set-head origin main >/dev/null
}
commit() { echo "$1" >"$1"; git add "$1"; git commit -q -m "$2"; }

# Start a TCP listener on a free port; sets $listen_port and $listen_pid.
start_listener() {
  have python3 || skip "python3 not installed"
  python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(5)
print(s.getsockname()[1], flush=True)
time.sleep(60)' >port.txt &
  listen_pid=$!
  local i=0
  while [ ! -s port.txt ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  listen_port=$(cat port.txt)
  [ -n "$listen_port" ] || fail "could not start a listener"
}

# A port that nothing listens on (bound and released straight away).
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# --- every script -----------------------------------------------------------

test_all_scripts_have_help() {
  for script in "$ROOT"/bin/*; do
    run "$script" --help
    [ "$status" -eq 0 ] || fail "$(basename "$script") --help exited $status"
    case $out in Usage:*) ;; *) fail "$(basename "$script") --help doesn't start with Usage:" ;; esac
  done
}

test_all_scripts_reject_unknown_options() {
  for script in "$ROOT"/bin/*; do
    run "$script" --no-such-option
    [ "$status" -eq 2 ] || fail "$(basename "$script") --no-such-option exited $status, want 2"
  done
}

# --- git-clean-branches -----------------------------------------------------

test_git_clean_branches_deletes_merged_only() {
  make_repo
  git checkout -q -b merged-feature; commit a "feature a"
  git checkout -q main; git merge -q --no-ff --no-edit merged-feature
  git checkout -q -b unmerged-feature; commit b "feature b"
  git checkout -q main
  git branch develop
  run git clean-branches -n
  expect_status 0
  expect_out merged-feature
  expect_no_out unmerged-feature
  expect_no_out develop
  git show-ref --quiet refs/heads/merged-feature || fail "dry run deleted a branch"

  run git clean-branches -y
  expect_status 0
  ! git show-ref --quiet refs/heads/merged-feature || fail "merged branch still there"
  git show-ref --quiet refs/heads/unmerged-feature || fail "unmerged branch was deleted"
  git show-ref --quiet refs/heads/develop || fail "protected branch was deleted"
}

test_git_clean_branches_gone_catches_squash_merges() {
  make_repo
  git checkout -q -b squashed; commit c "feature c"
  git push -q -u origin squashed 2>/dev/null
  git checkout -q main
  # Squash-merge on the "server" and delete the remote branch, like GitHub does.
  git merge -q --squash squashed; git commit -q -m "feature c (squashed)"
  git push -q origin main 2>/dev/null
  git push -q origin --delete squashed 2>/dev/null

  run git clean-branches -f -n
  expect_status 0
  expect_out "Nothing to clean"

  run git clean-branches -fgy
  expect_status 0
  expect_out "Deleted branch squashed"
  ! git show-ref --quiet refs/heads/squashed || fail "gone branch still there"
}

test_git_clean_branches_needs_yes_without_tty() {
  make_repo
  git branch old-merged
  run git clean-branches </dev/null
  expect_status 1
  expect_out "--yes"
  git show-ref --quiet refs/heads/old-merged || fail "deleted without confirmation"
}

test_git_clean_branches_outside_repo() {
  run git-clean-branches
  expect_status 1
  expect_out "not inside a git work tree"
}

test_git_clean_branches_works_from_a_feature_branch() {
  make_repo
  git branch in-progress   # started before "finished" was merged
  git checkout -q -b finished; commit d "finished work"
  git checkout -q main; git merge -q --no-ff --no-edit finished
  git checkout -q in-progress; commit w "wip"
  # Not on main: "git branch -d" alone would refuse to delete "finished".
  run git clean-branches -y
  expect_status 0
  ! git show-ref --quiet refs/heads/finished || fail "merged branch not deleted from a feature branch"
}

test_git_clean_branches_gone_ignores_local_upstreams() {
  make_repo
  git checkout -q -b part1; commit p1 "part 1"
  git checkout -q -b part2 --track part1; commit p2 "part 2"
  git checkout -q main; git merge -q --no-ff --no-edit part1
  run git clean-branches -y
  expect_status 0
  run git clean-branches -g -y
  git show-ref --quiet refs/heads/part2 || fail "stacked branch on a deleted local branch was deleted"
}

test_git_clean_branches_branch_named_like_a_tag() {
  make_repo
  git branch release-1.0; git tag release-1.0
  run git clean-branches -bmain -y
  expect_status 0
  ! git show-ref --quiet refs/heads/release-1.0 || fail "branch shadowed by a tag not deleted"
  git show-ref --quiet refs/tags/release-1.0 || fail "the tag was deleted"
}

# --- git-standup ------------------------------------------------------------

test_git_standup_shows_my_recent_commits() {
  make_repo
  git checkout -q -b old-branch
  GIT_COMMITTER_DATE="2001-01-01T12:00:00" git commit -q --allow-empty --date="2001-01-01T12:00:00" -m "ancient history"
  git checkout -q main
  commit mine "my recent work"
  echo x >theirs; git add theirs
  git -c user.name=Someone -c user.email=someone@example.com commit -q -m "their work"

  run git standup -d 1
  expect_status 0
  expect_out "my recent work"
  expect_no_out "their work"
  expect_no_out "ancient history"

  run git standup -d 1 -A
  expect_out "their work"
}

test_git_standup_ignores_stash() {
  make_repo
  echo change >>README
  git stash -q
  run git standup -d 1
  expect_no_out "WIP on"
  expect_no_out "index on"
}

test_git_standup_recursive() {
  mkdir -p code/one code/two
  (cd code/one && git init -q && commit f "work in one") >/dev/null
  (cd code/two && git init -q) >/dev/null
  run git-standup -d 1 -r code
  expect_status 0
  expect_out "code/one"
  expect_out "work in one"
  expect_no_out "code/two"
}

# --- git-sync ---------------------------------------------------------------

test_git_sync_rebases_onto_updated_main() {
  make_repo
  git checkout -q -b feature; commit feat "feature work"
  # Someone else pushes to main.
  (cd .. && git clone -q remote.git other 2>/dev/null && cd other &&
    commit upstream "upstream work" && git push -q origin main 2>/dev/null)
  echo "uncommitted" >>README

  run git sync
  expect_status 0
  git merge-base --is-ancestor origin/main HEAD || fail "feature isn't on top of origin/main"
  [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] || fail "local main not fast-forwarded"
  grep -q uncommitted README || fail "uncommitted change was lost"
  [ "$(git symbolic-ref --short HEAD)" = feature ] || fail "not back on the feature branch"
}

test_git_sync_on_main_fast_forwards() {
  make_repo
  (cd .. && git clone -q remote.git other 2>/dev/null && cd other &&
    commit upstream "upstream work" && git push -q origin main 2>/dev/null)
  run git sync
  expect_status 0
  [ -f upstream ] || fail "main wasn't fast-forwarded"
}

test_git_sync_refuses_detached_head() {
  make_repo
  git checkout -q --detach
  run git sync
  expect_status 1
  expect_out detached
}

# --- ports / killport -------------------------------------------------------

test_ports_lists_a_listener() {
  have lsof || have ss || have netstat || skip "no lsof, ss or netstat"
  start_listener
  run ports "$listen_port"
  kill "$listen_pid" 2>/dev/null
  expect_status 0
  expect_out "$listen_port"
  expect_out "$listen_pid"
  # "ython": Linux shows "python3 -c ...", macOS the full path of Python.app.
  expect_out ython
}

test_ports_reports_nothing_listening() {
  have python3 || skip "python3 not installed"
  have lsof || have ss || have netstat || skip "no lsof, ss or netstat"
  run ports "$(free_port)"
  expect_status 1
  expect_out "Nothing you can see is listening"
}

test_ports_when_lsof_finds_nothing() {
  # lsof exits 1 when nothing matches; that must not kill the script.
  mkdir fakebin
  printf '#!/bin/sh\nexit 1\n' >fakebin/lsof; chmod +x fakebin/lsof
  run env PATH="$PWD/fakebin:$PATH" ports
  expect_status 1
  expect_out "No listening TCP ports found"
}

test_killport_kills_a_listener() {
  have lsof || have ss || have fuser || skip "no lsof, ss or fuser"
  start_listener
  run killport -n "$listen_port"
  expect_status 0
  expect_out "dry run"
  kill -0 "$listen_pid" 2>/dev/null || fail "dry run killed the process"

  run killport "$listen_port"
  expect_status 0
  expect_out killed
  sleep 0.2
  ! kill -0 "$listen_pid" 2>/dev/null || { kill "$listen_pid"; fail "process still alive"; }
}

test_killport_validates_ports() {
  run killport abc
  expect_status 2
  run killport 70000
  expect_status 2
  run killport
  expect_status 2
}

# --- wait-for ---------------------------------------------------------------

test_wait_for_open_port_then_runs_command() {
  start_listener
  run wait-for -t 5 "127.0.0.1:$listen_port" -- echo "it ran"
  kill "$listen_pid" 2>/dev/null
  expect_status 0
  expect_out "is up"
  expect_out "it ran"
}

test_wait_for_times_out() {
  have python3 || skip "python3 not installed"
  run wait-for -t 1 -i 1 "127.0.0.1:$(free_port)" -- echo "should not run"
  expect_status 1
  expect_out "timed out"
  expect_no_out "should not run"
}

test_wait_for_waits_for_late_service() {
  have python3 || skip "python3 not installed"
  port=$(free_port)
  (sleep 2; exec python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port)); s.listen(5); time.sleep(10)") &
  late=$!
  run wait-for -t 10 "$port"
  kill "$late" 2>/dev/null
  pkill -f "s.bind(('127.0.0.1', $port))" 2>/dev/null
  expect_status 0
  expect_out "is up"
}

test_wait_for_rejects_bad_target() {
  run wait-for localhost:http
  expect_status 2
}

test_wait_for_http_url() {
  have curl || have wget || skip "no curl or wget"
  have python3 || skip "python3 not installed"
  port=$(free_port)
  mkdir site && echo ok >site/health
  (cd site && exec python3 -m http.server "$port" --bind 127.0.0.1 >../server.log 2>&1) &
  srv=$!
  # Wait for the test server itself first: on macOS a connection made while
  # it's still starting is dropped, not refused, which would eat the timeout.
  wait-for -q -t 20 "127.0.0.1:$port" || { kill "$srv"; fail "the test web server didn't start"; }
  run wait-for -t 10 "http://127.0.0.1:$port/health"
  status_ok=$status
  run wait-for -t 2 "http://127.0.0.1:$port/missing"
  kill "$srv" 2>/dev/null
  [ "$status_ok" -eq 0 ] || fail "the health URL wasn't seen as up"
  expect_status 1
  expect_out "404"
}

test_wait_for_explains_a_timeout() {
  have python3 || skip "python3 not installed"
  run wait-for -t 1 "127.0.0.1:$(free_port)"
  expect_status 1
  expect_out "last attempt: nothing accepted a connection"
}

# --- serve ------------------------------------------------------------------

test_serve_serves_files() {
  have python3 || have php || skip "no python3 or php"
  have curl || skip "curl not installed"
  port=$(free_port)
  mkdir site && echo "hello from serve" >site/index.html
  serve -p "$port" site >serve.log 2>&1 &
  srv=$!
  wait-for -q -t 10 "127.0.0.1:$port"
  run curl -fsS "http://127.0.0.1:$port/index.html"
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  expect_status 0
  expect_out "hello from serve"
  grep -q "http://127.0.0.1:$port/" serve.log || fail "serve didn't print its URL"
}

test_serve_refuses_busy_port() {
  start_listener
  run serve -p "$listen_port"
  kill "$listen_pid" 2>/dev/null
  expect_status 1
  expect_out "already in use"
}

# --- extract ----------------------------------------------------------------

test_extract_tarballs_and_single_files() {
  mkdir -p src/sub && echo one >src/a.txt && echo two >src/sub/b.txt
  tar -czf pkg.tar.gz src
  tar -cjf pkg.tbz2 src
  tar -cJf PKG.TAR.XZ src
  echo single >note.txt && gzip -c note.txt >note.txt.gz && rm note.txt

  for archive in pkg.tar.gz pkg.tbz2 PKG.TAR.XZ; do
    rm -rf out
    run extract -d out "$archive"
    expect_status 0
    [ "$(cat out/src/sub/b.txt)" = two ] || fail "$archive not extracted properly"
  done

  run extract -d out note.txt.gz
  expect_status 0
  [ "$(cat out/note.txt)" = single ] || fail "gz not decompressed"
  expect_file note.txt.gz

  run extract -d out note.txt.gz
  expect_status 1
  expect_out "already exists"
}

test_extract_never_overwrites_without_force() {
  mkdir -p pkg && echo new >pkg/config.yml && echo other >pkg/extra.txt
  tar -czf pkg.tar.gz pkg
  rm -rf pkg
  mkdir pkg && echo mine >pkg/config.yml
  run extract pkg.tar.gz
  expect_status 1
  expect_out "already exist"
  [ "$(cat pkg/config.yml)" = mine ] || fail "an existing file was overwritten"
  expect_no_file pkg/extra.txt
  [ -z "$(find . -maxdepth 1 -name '.extract.*')" ] || fail "temporary folder left behind"

  run extract --force pkg.tar.gz
  expect_status 0
  [ "$(cat pkg/config.yml)" = new ] || fail "--force didn't overwrite"
}

test_extract_name_starting_with_dash() {
  mkdir d && echo x >d/f && tar -cf ./-odd.tar d && rm -rf d
  run extract -d out -- -odd.tar
  expect_status 0
  expect_file out/d/f
}

test_extract_zip_and_list() {
  { have zip && have unzip; } || skip "zip/unzip not installed"
  mkdir src && echo z >src/z.txt
  zip -qr pkg.zip src
  run extract -l pkg.zip
  expect_status 0
  expect_out src/z.txt
  run extract pkg.zip -d out
  expect_status 0
  expect_file out/src/z.txt
}

test_extract_unknown_format() {
  echo x >file.weird
  run extract file.weird
  expect_status 1
  expect_out "don't know how"
}

# --- backup -----------------------------------------------------------------

test_backup_file_and_directory() {
  echo data >config.yml
  mkdir proj && echo code >proj/main.c
  run backup config.yml proj/
  expect_status 0
  set -- config.yml.*.bak
  [ -f "$1" ] || fail "no file backup made"
  [ "$(cat "$1")" = data ] || fail "file backup has the wrong contents"
  set -- proj.*.tar.gz
  [ -f "$1" ] || fail "no directory backup made"
  tar -tzf "$1" | grep -q '^proj/main.c$' || fail "tarball doesn't contain proj/main.c"

  # Two backups in the same second get different names.
  run backup config.yml
  run backup config.yml
  [ "$(find . -maxdepth 1 -name 'config.yml.*.bak' | wc -l)" -ge 2 ] || fail "second backup overwrote the first"
}

test_backup_dest_and_copy() {
  mkdir proj && echo code >proj/main.c
  run backup -c -d backups proj
  expect_status 0
  set -- backups/proj.*.bak
  [ -f "$1/main.c" ] || fail "directory copy not made in --dest"
}

test_backup_symlinked_directory_has_real_contents() {
  mkdir -p releases/v42 && echo app >releases/v42/app.js
  ln -s releases/v42 current
  run backup current
  expect_status 0
  set -- current.*.tar.gz
  tar -tzf "$1" | grep -q 'v42/app.js' || fail "backup of a symlinked dir has no files in it"
  run backup -c current
  set -- current.*.bak
  [ -f "$1/app.js" ] && [ ! -L "$1" ] || fail "--copy of a symlinked dir isn't a real copy"
}

test_backup_refuses_dest_inside_source() {
  mkdir proj && echo code >proj/main.c
  run backup -c -d proj/backups proj
  expect_status 1
  expect_out "inside"
  expect_no_file proj/backups/proj
}

test_backup_name_starting_with_dash() {
  echo x >-notes.txt
  run backup -- -notes.txt
  expect_status 0
  set -- ./-notes.txt.*.bak
  [ -f "$1" ] || fail "no backup made"
}

# --- bigfiles ---------------------------------------------------------------

test_bigfiles_orders_by_size_and_skips_node_modules() {
  mkdir -p d/node_modules d/sub
  head -c 300000 /dev/zero >d/sub/big.bin
  head -c 2000 /dev/zero >d/small.bin
  head -c 900000 /dev/zero >d/node_modules/huge.bin
  run bigfiles -n 5 d
  expect_status 0
  expect_no_out huge.bin
  first=$(printf '%s\n' "$out" | head -n 1)
  case $first in *big.bin*) ;; *) fail "largest file not listed first" ;; esac
  expect_out "293.0K"

  run bigfiles -a d
  expect_out huge.bin
}

test_bigfiles_dir_named_like_a_skipped_folder() {
  mkdir venv && head -c 5000 /dev/zero >venv/lib.bin
  ln -s venv linked
  run bigfiles venv
  expect_out lib.bin
  run bigfiles linked
  expect_out lib.bin
}

test_bigfiles_git_history() {
  make_repo
  head -c 500000 /dev/urandom >blob.bin
  git add blob.bin; git commit -q -m "add blob"
  git rm -q blob.bin; git commit -q -m "remove blob"
  run bigfiles -g -n 3
  expect_status 0
  expect_out blob.bin
}

# --- todos ------------------------------------------------------------------

test_todos_finds_and_counts_markers() {
  mkdir src
  printf '%s\n' '# TODO: first' 'x = 1  # FIXME later' '# todos are fine' 'TODOS no' '// HACK' '// TODO again' >src/app.py
  run todos src
  expect_status 0
  expect_out "app.py:1:"
  expect_out "FIXME later"
  expect_no_out "todos are fine"
  expect_no_out "TODOS no"

  run todos -c src
  expect_status 0
  printf '%s\n' "$out" | grep -Eq '^ *2 TODO$' || fail "TODO count should be 2"
  printf '%s\n' "$out" | grep -Eq '^ *1 HACK$' || fail "HACK count should be 1"
}

test_todos_count_with_git_grep_config() {
  make_repo
  printf '%s\n' '# TODO one' '# FIXME two' >app.py
  git add app.py
  git config grep.lineNumber true
  mkdir ../fakebin
  for tool in bash sed sort uniq grep cat git dirname; do ln -s "$(command -v "$tool")" ../fakebin/; done
  run env PATH="$PWD/../fakebin" bash "$ROOT/bin/todos" -c
  expect_status 0
  printf '%s\n' "$out" | grep -Eq '^ *1 TODO$' || fail "git grep count output has line numbers"
}

test_todos_without_ripgrep_or_git() {
  mkdir src && echo "XXX: fix" >src/a.c
  # Hide rg and git by giving the script a PATH without them.
  mkdir fakebin
  for tool in bash sed sort uniq grep cat dirname; do ln -s "$(command -v "$tool")" fakebin/; done
  run env PATH="$PWD/fakebin" bash "$ROOT/bin/todos" src
  expect_status 0
  expect_out "a.c:1:XXX: fix"
}

test_todos_none_found() {
  mkdir src && echo "clean code" >src/a.c
  run todos src
  expect_status 0
  expect_out "No TODO, FIXME"
}

# --- loc --------------------------------------------------------------------

test_loc_counts_tracked_files_by_type() {
  make_repo
  printf 'a\nb\nc\n' >one.py; printf 'x\ny' >two.py; printf 'all: x\n' >Makefile
  printf 'IGNORED\n' >untracked.py
  printf '\000\001\002' >image.png
  : >__init__.py
  git add one.py two.py Makefile image.png __init__.py
  git commit -q -m code
  run loc
  expect_status 0
  printf '%s\n' "$out" | grep -Eq '^\.py +2 +5$' || fail ".py should be 2 files, 5 lines"
  printf '%s\n' "$out" | grep -Eq '^Makefile +1 +1$' || fail "Makefile row wrong"
  expect_no_out ".png"
  printf '%s\n' "$out" | grep -Eq '^TOTAL +4 +7$' || fail "TOTAL row wrong"
}

test_loc_outside_git_skips_node_modules() {
  mkdir -p p/node_modules/lib && printf '1\n2\n' >p/app.js && printf 'x\n' >p/node_modules/lib/index.js
  run loc p
  expect_status 0
  printf '%s\n' "$out" | grep -Eq '^\.js +1 +2$' || fail "node_modules should be skipped"
}

# --- envcheck ---------------------------------------------------------------

test_envcheck_reports_missing_empty_and_extra() {
  printf '%s\n' '# config' 'DATABASE_URL=postgres://x' 'export API_KEY=' 'PORT = 3000' 'DEBUG=1 # inline' >.env.example
  printf '%s\n' 'DATABASE_URL=postgres://secret-value' 'API_KEY=""' 'LEGACY=1' >.env
  run envcheck
  expect_status 1
  expect_out "Missing from .env"
  expect_out "PORT"
  expect_out "DEBUG"
  expect_out "Empty in .env:"
  expect_out "API_KEY"
  expect_out "LEGACY"
  expect_no_out "secret-value"
}

test_envcheck_passes_and_strict_mode() {
  printf 'A=1\nB=2\n' >.env.sample
  printf 'A=x\nB=y\nC=z\n' >.env
  run envcheck
  expect_status 0
  expect_out "has every key"
  run envcheck --strict
  expect_status 1
  run envcheck -q --strict
  [ -z "$out" ] || fail "--quiet printed something"
}

test_envcheck_missing_files() {
  run envcheck
  expect_status 2
  printf 'A=1\n' >.env.example
  run envcheck
  expect_status 2
  expect_out "copy it from"
}

# --- clean-artifacts --------------------------------------------------------

test_clean_artifacts_respects_safety_rules() {
  make_repo
  mkdir -p web/node_modules/pkg py/__pycache__ rust/target/debug java/target build
  echo x >web/node_modules/pkg/index.js
  touch rust/Cargo.toml java/notes.txt
  echo "tracked" >build/keep.sh; git add build/keep.sh; git commit -q -m "tracked build dir"

  run clean-artifacts -n
  expect_status 0
  expect_out web/node_modules
  expect_out py/__pycache__
  expect_out rust/target
  expect_no_out java/target
  expect_out "dry run"
  expect_file web/node_modules

  run clean-artifacts -a -y
  expect_status 0
  expect_out "skipping ./build"
  expect_no_file web/node_modules
  expect_no_file py/__pycache__
  expect_no_file rust/target
  expect_file java/target
  expect_file build/keep.sh
}

test_clean_artifacts_protects_repos_and_start_dir() {
  # Not a git repo itself, but holds projects that are.
  mkdir -p code/out/src code/app/node_modules/x code/build
  (cd code/out && git init -q && echo x >src/a.c && git add . && git commit -q -m x)
  echo junk >code/build/junk.o
  run clean-artifacts -a -n code
  expect_out "skipping code/out (contains a git repository)"
  expect_out code/app/node_modules
  expect_out code/build
  run clean-artifacts -a -y code
  expect_file code/out/.git
  expect_no_file code/build
  # The folder you point it at is never itself deleted.
  mkdir -p proj/build && echo x >proj/build/o
  run clean-artifacts -a -y proj/build
  expect_file proj/build/o
}

test_clean_artifacts_gradle_only_in_projects() {
  mkdir -p home/.gradle proj/.gradle
  echo "signing.password=secret" >home/.gradle/gradle.properties
  touch proj/build.gradle
  run clean-artifacts -n .
  expect_out proj/.gradle
  expect_no_out home/.gradle
}

test_clean_artifacts_symlinked_dir() {
  mkdir -p real/node_modules/x && ln -s real link
  run clean-artifacts -n link
  expect_out link/node_modules
}

test_clean_artifacts_needs_yes_without_tty() {
  mkdir -p node_modules
  run clean-artifacts . </dev/null
  expect_status 1
  expect_file node_modules
}

# --- retry ------------------------------------------------------------------

test_retry_until_success() {
  # Fails twice, then succeeds.
  cat >flaky <<'EOF'
#!/usr/bin/env bash
n=$(cat count 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >count
[ "$n" -ge 3 ]
EOF
  chmod +x flaky
  run retry -d 0 ./flaky
  expect_status 0
  [ "$(cat count)" = 3 ] || fail "expected 3 attempts"
  expect_out "attempt 2 failed"
}

test_retry_gives_up_with_last_status() {
  run retry -n 3 -d 0 sh -c 'exit 7'
  expect_status 7
  expect_out "giving up after 3"
}

test_retry_leading_zero_values() {
  # Bash arithmetic reads 08 as a (bad) octal number unless told otherwise.
  run retry -n 2 -d 0 -b 08 -m 09 false
  expect_status 1
  expect_out "giving up"
}

test_retry_needs_a_command() {
  run retry -n 2
  expect_status 2
}

# --- gensecret --------------------------------------------------------------

test_gensecret_types() {
  run gensecret
  expect_status 0
  printf '%s' "$out" | grep -Eqx '[A-Za-z0-9]{32}' || fail "default isn't 32 alphanumerics: $out"
  run gensecret -t hex 64
  printf '%s' "$out" | grep -Eqx '[0-9a-f]{64}' || fail "bad hex: $out"
  run gensecret -t pin
  printf '%s' "$out" | grep -Eqx '[0-9]{6}' || fail "bad pin: $out"
  run gensecret -t url 40
  printf '%s' "$out" | grep -Eqx '[A-Za-z0-9_-]{40}' || fail "bad url-safe: $out"
  run gensecret -t base64 24
  printf '%s' "$out" | grep -Eqx '[A-Za-z0-9+/]{24}' || fail "bad base64: $out"
  run gensecret -t uuid -c 20
  [ "$(printf '%s\n' "$out" | grep -Ecx '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}')" -eq 20 ] ||
    fail "bad uuid(s): $out"
  run gensecret -t strong -c 50 8
  [ "$(printf '%s\n' "$out" | grep '[a-z]' | grep '[A-Z]' | grep '[0-9]' | grep -c '[^A-Za-z0-9]')" -eq 50 ] ||
    fail "a strong password is missing a character class: $out"
}

test_gensecret_quiet_when_sigpipe_is_ignored() {
  # CI systems and some editors start programs with SIGPIPE ignored, which
  # used to make "tr | head" print "write error: Broken pipe".
  run bash -c "trap '' PIPE; gensecret; gensecret -t strong 40; gensecret -t pin"
  expect_status 0
  expect_no_out "rror"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 3 ] || fail "expected 3 secrets"
}

test_gensecret_is_random_and_validates() {
  a=$(gensecret) b=$(gensecret)
  [ "$a" != "$b" ] || fail "two secrets were identical"
  run gensecret 0
  expect_status 2
  run gensecret -t nope
  expect_status 2
}

# --- onchange ---------------------------------------------------------------

test_onchange_reruns_on_change() {
  mkdir w && echo 1 >w/file.txt
  onchange -i 0.2 -p w -- sh -c 'echo ran >>runs.log' >/dev/null 2>&1 &
  pid=$!
  sleep 1
  echo 2 >w/file.txt
  sleep 1.2
  touch w/new.txt
  sleep 1.2
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  runs=$(wc -l <runs.log | tr -d ' ')
  [ "$runs" -eq 3 ] || fail "expected 3 runs (start + 2 changes), got $runs"
}

test_onchange_ext_filter() {
  mkdir w
  onchange -i 0.2 -p w -e py -- sh -c 'echo ran >>runs.log' >/dev/null 2>&1 &
  pid=$!
  sleep 1
  echo x >w/notes.md
  sleep 1
  echo x >w/app.py
  sleep 1
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  runs=$(wc -l <runs.log | tr -d ' ')
  [ "$runs" -eq 2 ] || fail "expected 2 runs (start + app.py), got $runs"
}

test_onchange_watch_dir_named_dist() {
  mkdir dist && echo 1 >dist/app.js
  onchange -i 0.2 -p dist -- sh -c 'echo ran >>runs.log' >/dev/null 2>&1 &
  pid=$!
  sleep 1
  echo 2 >dist/app.js
  sleep 1.2
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ "$(wc -l <runs.log | tr -d ' ')" -eq 2 ] || fail "changes in a watched folder named dist were missed"
}

test_onchange_restart_mode() {
  mkdir w && echo 1 >w/file.txt
  # Each run writes its PID and then sleeps like a server would.
  onchange -r -i 0.2 -p w -- sh -c 'echo $$ >>pids.log; exec sleep 30' >/dev/null 2>&1 &
  pid=$!
  sleep 1
  echo 2 >w/file.txt
  sleep 1.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 0.3
  [ "$(wc -l <pids.log | tr -d ' ')" -eq 2 ] || fail "expected the server to start twice"
  while read -r p; do
    ! kill -0 "$p" 2>/dev/null || { kill "$p"; fail "old server process $p still running"; }
  done <pids.log
}

# --- mkscript ---------------------------------------------------------------

test_mkscript_creates_working_script() {
  run mkscript -E tools/hello "Say hello"
  expect_status 0
  [ -x tools/hello ] || fail "script not executable"
  run tools/hello --help
  expect_status 0
  expect_out "Say hello"
  run tools/hello world
  expect_status 0
  expect_out world
  run tools/hello
  expect_status 2
  if have shellcheck; then
    run shellcheck tools/hello
    expect_status 0
  fi

  run mkscript -E tools/hello
  expect_status 1
  expect_out "already exists"
}

test_mkscript_description_is_not_code() {
  # shellcheck disable=SC2016  # the $ and backticks are meant literally
  run mkscript -E price 'Charge $5 per `whoami` seat'
  expect_status 0
  run ./price --help
  expect_status 0
  # shellcheck disable=SC2016
  expect_out 'Charge $5 per `whoami` seat'
}

test_mkscript_replaces_symlinks_instead_of_writing_through() {
  echo original >target.sh
  ln -s target.sh link.sh
  run mkscript -E link.sh
  expect_status 1
  run mkscript -E -f link.sh
  expect_status 0
  [ "$(cat target.sh)" = original ] || fail "wrote through the symlink"
  [ ! -L link.sh ] || fail "symlink not replaced"
}

# --- install.sh -------------------------------------------------------------

test_install_and_uninstall() {
  run "$ROOT/install.sh" --prefix "$PWD/prefix/bin"
  expect_status 0
  [ -L prefix/bin/killport ] || fail "killport not linked"
  [ "$(find prefix/bin -type l | wc -l | tr -d ' ')" -eq "$(find "$ROOT/bin" -type f | wc -l | tr -d ' ')" ] ||
    fail "not every script was linked"
  expect_out "not on your PATH"

  run "$ROOT/install.sh" --prefix "$PWD/prefix/bin"
  expect_status 0
  expect_no_out skipped

  echo "mine" >prefix/bin/extract.keep; mv prefix/bin/extract.keep prefix/bin/extract
  run "$ROOT/install.sh" --uninstall --prefix "$PWD/prefix/bin"
  expect_status 0
  expect_no_file prefix/bin/killport
  [ "$(cat prefix/bin/extract)" = mine ] || fail "uninstall removed a file it didn't install"
}

test_install_refuses_its_own_bin() {
  ln -s "$ROOT/bin" linked-bin
  run "$ROOT/install.sh" --uninstall --prefix "$PWD/linked-bin"
  expect_status 1
  expect_file "$ROOT/bin/killport"
  run "$ROOT/install.sh" --force --prefix "$ROOT/bin"
  expect_status 1
  [ ! -L "$ROOT/bin/killport" ] || fail "replaced a script with a link to itself"
}

# --- ffmpeg scripts ---------------------------------------------------------

need_ffmpeg() { { have ffmpeg && have ffprobe; } || skip "ffmpeg not installed"; }

# make_video NAME SECONDS WxH [audio]  writes a small H.264 test clip.
make_video() {
  set -- "$1" "$2" "$3" "${4:-}"
  if [ "$4" = audio ]; then
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=duration=$2:size=$3:rate=25" \
      -f lavfi -i "sine=duration=$2" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
      -c:a aac -shortest "$1"
  else
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=duration=$2:size=$3:rate=25" \
      -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$1"
  fi
}
media_duration() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1"; }
media_size() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
# about ACTUAL EXPECTED TOLERANCE: true if they're within TOLERANCE.
about() { awk -v a="$1" -v e="$2" -v t="$3" 'BEGIN { d = a - e; if (d < 0) d = -d; exit !(d <= t) }'; }
no_partials() { [ -z "$(find . -name '*.partial.*')" ] || fail "a .partial file was left behind"; }

test_ffinfo_summary() {
  need_ffmpeg
  make_video clip.mp4 3 320x240 audio
  run ffinfo clip.mp4
  expect_status 0
  expect_out "3.0s"
  expect_out "video     h264 320x240 25 fps"
  expect_out "audio     aac mono 44.1 kHz"
  echo "not media" >notes.txt
  run ffinfo notes.txt
  expect_status 1
  expect_out "not a media file"
}

test_ffshrink_scales_short_side_and_refuses_overwrite() {
  need_ffmpeg
  make_video tall.mp4 2 720x1280 audio
  run ffshrink -r 480 -p ultrafast tall.mp4
  expect_status 0
  [ "$(media_size tall.small.mp4)" = 480x854 ] || fail "portrait video not scaled to 480p: $(media_size tall.small.mp4)"
  run ffshrink -r 480 tall.mp4
  expect_status 1
  expect_out "already exists"
  run ffshrink -r 2000 -m -p ultrafast -o big.mp4 tall.mp4
  expect_status 0
  [ "$(media_size big.mp4)" = 720x1280 ] || fail "video was enlarged"
  [ -z "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 big.mp4)" ] ||
    fail "--mute left the audio in"
  no_partials
}

test_ffshrink_target_size() {
  need_ffmpeg
  ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=duration=6:size=1280x720:rate=30 \
    -c:v libx264 -crf 5 -preset ultrafast big.mp4
  run ffshrink -s 300K -p ultrafast big.mp4
  expect_status 0
  size=$(wc -c <big.small.mp4 | tr -d ' ')
  [ "$size" -le 300000 ] || fail "asked for 300K, got $size bytes"
  [ "$size" -ge 150000 ] || fail "asked for 300K, got only $size bytes"
  no_partials
}

test_ffshrink_bad_input_leaves_nothing() {
  need_ffmpeg
  echo "not a video" >fake.mp4
  run ffshrink fake.mp4
  expect_status 1
  expect_no_file fake.small.mp4
  no_partials
}

test_fftrim_exact_and_copy() {
  need_ffmpeg
  make_video long.mp4 10 320x240 audio
  run fftrim -e long.mp4 2 +3
  expect_status 0
  about "$(media_duration long.clip.mp4)" 3 0.1 || fail "exact clip isn't 3s: $(media_duration long.clip.mp4)"
  run fftrim long.mp4 0:06 -o end.mp4
  expect_status 0
  expect_file end.mp4
  run fftrim long.mp4 8 5
  expect_status 2
  run fftrim long.mp4 99
  expect_status 1
  expect_out "past the end"
  run fftrim long.mp4 1:2:3:4
  expect_status 2
}

test_ffgif_makes_a_gif() {
  need_ffmpeg
  make_video clip.mp4 4 640x480
  run ffgif -s 1 -t 2 -w 200 clip.mp4
  expect_status 0
  [ "$(media_size clip.gif)" = 200x150 ] || fail "wrong GIF size: $(media_size clip.gif)"
  about "$(media_duration clip.gif)" 2 0.2 || fail "GIF isn't 2s long"
  run ffgif clip.mp4 out.png
  expect_status 2
}

test_ffaudio_copy_and_convert() {
  need_ffmpeg
  make_video talk.mp4 2 320x240 audio
  make_video silent.mp4 1 320x240
  run ffaudio talk.mp4
  expect_status 0
  expect_out "copied aac audio"
  [ "$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 talk.m4a)" = aac ] || fail "talk.m4a isn't AAC"
  run ffaudio -t mp3 talk.mp4
  expect_status 0
  [ "$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 talk.mp3)" = mp3 ] || fail "talk.mp3 isn't MP3"
  run ffaudio silent.mp4
  expect_status 1
  expect_out "has no audio"
  run ffaudio talk.m4a
  expect_status 1
  expect_out "is the input file"
}

test_ffthumbs_modes() {
  need_ffmpeg
  make_video film.mp4 10 640x360
  run ffthumbs film.mp4
  expect_status 0
  [ "$(media_size film.thumb.jpg)" = 640x360 ] || fail "thumbnail has the wrong size"
  run ffthumbs -n 3 -w 160 film.mp4
  expect_status 0
  for n in 01 02 03; do expect_file "film.thumb-$n.jpg"; done
  [ "$(media_size film.thumb-02.jpg)" = 160x90 ] || fail "--width ignored"
  run ffthumbs -s 3x2 -w 100 film.mp4
  expect_status 0
  # 3 tiles of 100 + 4 gaps of 4 = 316 wide; 2 tiles of 56 + 3 gaps = 124 high.
  [ "$(media_size film.sheet.jpg)" = 316x124 ] || fail "contact sheet has the wrong size: $(media_size film.sheet.jpg)"
  run ffthumbs -a 99 film.mp4 -f
  expect_status 1
  expect_out "past the end"
}

test_ffconcat_lossless_mismatch_and_reencode() {
  need_ffmpeg
  make_video "part 1.mp4" 2 320x240 audio
  make_video "it's part 2.mp4" 3 320x240 audio
  make_video portrait.mp4 2 240x320
  run ffconcat -o joined.mp4 "part 1.mp4" "it's part 2.mp4"
  expect_status 0
  about "$(media_duration joined.mp4)" 5 0.2 || fail "joined file isn't 5s: $(media_duration joined.mp4)"

  run ffconcat -o nope.mp4 "part 1.mp4" portrait.mp4
  expect_status 1
  expect_out "--reencode"
  expect_no_file nope.mp4

  run ffconcat -r -o mixed.mp4 "part 1.mp4" portrait.mp4 "it's part 2.mp4"
  expect_status 0
  about "$(media_duration mixed.mp4)" 7 0.2 || fail "re-encoded join isn't 7s: $(media_duration mixed.mp4)"
  [ "$(media_size mixed.mp4)" = 320x240 ] || fail "not scaled to the first video's size"
  no_partials
}

# --- data and text (Python) --------------------------------------------------

need_python() { have python3 || skip "python3 not installed"; }

test_jsonfmt_formats_and_keeps_numbers_exact() {
  need_python
  run sh -c 'echo "{\"id\": 12345678901234567890, \"price\": 1.10, \"b\": [1, {}], \"a\": \"café\"}" | jsonfmt -s'
  expect_status 0
  expect_out '"id": 12345678901234567890'
  expect_out '"price": 1.10'
  expect_out '"a": "café"'
  first_key=$(printf '%s\n' "$out" | sed -n 2p)
  [ "$first_key" = '  "a": "café",' ] || fail "--sort-keys didn't sort: $first_key"
  run sh -c 'echo "{\"b\": 1, \"a\": [1, 2]}" | jsonfmt -c'
  [ "$out" = '{"b":1,"a":[1,2]}' ] || fail "compact output wrong: $out"
}

test_jsonfmt_reports_errors_with_position() {
  need_python
  printf '{\n  "a": 1,\n  "b": [1, 2,,]\n}\n' >bad.json
  run jsonfmt bad.json
  expect_status 1
  expect_out "bad.json: line 3, column 14"
  run jsonfmt --check bad.json
  expect_status 1
  echo 'NaN' >nan.json
  run jsonfmt --check nan.json
  expect_status 1
  echo '[1]' >good.json
  run jsonfmt --check good.json
  expect_status 0
  [ -z "$out" ] || fail "--check printed something for valid JSON"
}

test_jsonfmt_write_in_place() {
  need_python
  printf '{"z":1,"y":[true,null]}' >data.json
  chmod 640 data.json
  run jsonfmt -w -s data.json
  expect_status 0
  expect_out "reformatted data.json"
  [ "$(head -n 2 data.json | tail -n 1)" = '  "y": [' ] || fail "file not reformatted"
  case $(ls -l data.json) in -rw-r-----*) ;; *) fail "permissions changed: $(ls -l data.json)" ;; esac
  run jsonfmt -w -s data.json
  expect_no_out reformatted
  echo '{broken' >broken.json
  run jsonfmt -w broken.json
  expect_status 1
  [ "$(cat broken.json)" = '{broken' ] || fail "a broken file was rewritten"
  run jsonfmt -w
  expect_status 2
}

test_epoch_both_directions() {
  need_python
  run env TZ=UTC epoch -q 1764201600
  [ "$out" = 2025-11-27T00:00:00Z ] || fail "timestamp -> date wrong: $out"
  run env TZ=UTC epoch -q 1764201600000
  [ "$out" = 2025-11-27T00:00:00Z ] || fail "milliseconds not detected: $out"
  run env TZ=UTC epoch -q 2025-11-27T00:00:00Z
  [ "$out" = 1764201600 ] || fail "date -> timestamp wrong: $out"
  run env TZ=Europe/Paris epoch -q "2025-11-27 01:00"
  [ "$out" = 1764201600 ] || fail "local time zone not applied: $out"
  run env TZ=Europe/Paris epoch -q -u "2025-11-27 00:00"
  [ "$out" = 1764201600 ] || fail "--utc not applied: $out"
  run env TZ=UTC epoch -q 2025-11-27T02:00:00+0200
  [ "$out" = 1764201600 ] || fail "+0200 offset not applied: $out"
  run env TZ=Europe/Paris epoch 1764201600
  expect_out "CET"
  run epoch tomorrow
  expect_status 1
  expect_out "ISO 8601"
}

# Builds an unsigned test JWT from a JSON payload.
make_jwt() {
  python3 -c '
import base64, json, sys
b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
print(b({"alg": "HS256", "typ": "JWT"}) + "." + b(json.loads(sys.argv[1])) + ".c2ln")' "$1"
}

test_jwt_decode_shows_claims_and_expiry() {
  need_python
  old=$(make_jwt '{"sub":"42","name":"José","exp":1700000000}')
  run jwt-decode "$old"
  expect_status 0
  expect_out '"name": "José"'
  expect_out "EXPIRED"
  expect_out "Signature: not checked"
  run jwt-decode -e "$old"
  expect_status 1
  fresh=$(make_jwt '{"sub":"42","exp":9999999999}')
  run sh -c "echo 'Authorization: Bearer $fresh' | jwt-decode -e -p"
  expect_status 0
  expect_out '"exp": 9999999999'
  expect_no_out Header
  run jwt-decode not.a-token
  expect_status 1
  expect_out "3 parts"
}

test_urlencode_and_urldecode_round_trip() {
  need_python
  run urlencode "café & crème/?#"
  [ "$out" = 'caf%C3%A9%20%26%20cr%C3%A8me%2F%3F%23' ] || fail "urlencode wrong: $out"
  run urldecode "$out"
  [ "$out" = 'café & crème/?#' ] || fail "round trip failed: $out"
  run urlencode -f "big cats"
  [ "$out" = 'big+cats' ] || fail "--form wrong: $out"
  run urlencode -p "dir name/file.txt"
  [ "$out" = 'dir%20name/file.txt' ] || fail "--path wrong: $out"
  run sh -c 'printf "one two\nthree\n" | urlencode'
  [ "$out" = "$(printf 'one%%20two\nthree')" ] || fail "stdin lines wrong: $out"
  run urldecode -p 'https://example.com:8443/a%20b?q=big+cats&next=https%3A%2F%2Fx.com%2F#top'
  expect_out "host:      example.com"
  expect_out "port:      8443"
  expect_out "path:      /a b"
  expect_out "q    = big cats"
  expect_out "next = https://x.com/"
}

test_csvview_aligns_tricky_csv() {
  need_python
  printf 'name,qty,notes\nAlice,30,"has ""quotes"", and commas"\nBob,4,"two\nlines"\n' >t.csv
  run csvview t.csv
  expect_status 0
  expect_out 'name  | qty | notes'
  expect_out 'Alice |  30 | has "quotes", and commas'
  expect_out 'Bob   |   4 | two\nlines'
  printf 'a;b\n1;2\n' | csvview >semi.txt
  grep -q '^a | b$' semi.txt || fail "semicolon delimiter not detected"
  run csvview -n 1 -w 8 t.csv
  expect_out 'has "...'
  expect_no_out Bob
  run csvview missing.csv
  expect_status 1
}

# --- docker scripts ---------------------------------------------------------
#
# These use a fake "docker" command, so they need no Docker daemon. It logs
# every call to $FAKE_DOCKER/calls.log and answers from files there:
#   containers.tsv  ID, NAME, IMAGE, STATUS, PORTS, IMAGE-ID, VOLUMES
#                   (running = "Up..."; VOLUMES = mounted volume names, comma-separated)
#   images.tsv      ID, REPOSITORY:TAG, SIZE, dangling (yes/no)
#   volumes.tsv     names of all volumes
# Touch $FAKE_DOCKER/down to make it act as if the daemon isn't running.

fake_docker() {
  export FAKE_DOCKER=$PWD/fake
  mkdir -p "$FAKE_DOCKER" fakebin
  : >"$FAKE_DOCKER/calls.log"
  cat >fakebin/docker <<'STUB'
#!/usr/bin/env bash
d=$FAKE_DOCKER
me=$(basename "$0")
printf '%s %s\n' "$me" "$*" >>"$d/calls.log"
if [ -e "$d/down" ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
  exit 1
fi
fmt='' all=0 dangling=0
for a in "$@"; do
  case $prev in --format) fmt=$a ;; esac
  case $a in --all|-a) all=1 ;; dangling=true) dangling=1 ;; esac
  prev=$a
done
# Fill in {{.Key}} placeholders in $fmt from tab-separated records on stdin.
render() {
  awk -F'\t' -v fmt="$1" -v keys="$2" '
    BEGIN { nk = split(keys, k, " ") }
    { s = fmt; for (i = 1; i <= nk; i++) gsub("\\{\\{\\." k[i] "\\}\\}", $i, s); print s }'
}
case "$1 ${2:-}" in
  "ps "*)
    awk -F'\t' -v all="$all" 'all || $4 ~ /^Up/' "$d/containers.tsv" |
      render "$fmt" "ID Names Image Status Ports ImageID" ;;
  "inspect "*)
    shift 3   # inspect --format FORMAT
    case $fmt in
      *.Mounts*)   # one mounted volume name per line
        for id in "$@"; do awk -F'\t' -v id="$id" '$1 == id { n = split($7, v, ","); for (i = 1; i <= n; i++) print v[i] }' "$d/containers.tsv"; done ;;
      *)
        for id in "$@"; do awk -F'\t' -v id="$id" '$1 == id' "$d/containers.tsv"; done |
          render "$fmt" "ID Names ImageName Status Ports Image" ;;
    esac ;;
  "images "*)
    awk -F'\t' -v dangling="$dangling" '!dangling || $4 == "yes"' "$d/images.tsv" |
      render "${fmt//\{\{.Repository\}\}:\{\{.Tag\}\}/\{\{.RepoTag\}\}}" "ID RepoTag Size" ;;
  "volume ls") cat "$d/volumes.tsv" ;;
  "system df") printf 'TYPE   TOTAL   ACTIVE   SIZE   RECLAIMABLE\nImages 3 1 1GB 600MB (60%%)\n' ;;
  "builder prune")
    if [ "$me" = podman ]; then echo "Error: unknown command \"builder\" for \"podman\"" >&2; exit 125; fi
    case " $* " in *" --help "*) echo "Usage: docker builder prune" ;; *) echo "Total:	0B" ;; esac ;;
  "volume prune")
    case " $* " in
      *" --help "*) if [ "$me" = podman ]; then echo "  -f, --force"; else echo "  -a, --all   Remove all unused volumes"; fi ;;
      *) echo "Total reclaimed space: 5GB" ;;
    esac ;;
  *" prune") echo "Total reclaimed space: 1MB" ;;
  "exec "*|"logs "*) echo "ran: $me $*" ;;
  *) echo "fake docker: unexpected command: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x fakebin/docker
  cp fakebin/docker fakebin/podman
  export PATH="$PWD/fakebin:$PATH"
  unset DOCKER
  tab=$(printf '\t')
  # Two running containers with similar names, one stopped, one crashed.
  cat >"$FAKE_DOCKER/containers.tsv" <<EOF
aaa111${tab}shop-web-1${tab}shop/web:latest${tab}Up 2 hours${tab}0.0.0.0:8080->80/tcp, [::]:8080->80/tcp${tab}sha256:img-web
bbb222${tab}shop-web-admin${tab}shop/admin:2.1${tab}Up 5 minutes (healthy)${tab}127.0.0.1:9000->9000/tcp, 9001/tcp${tab}sha256:img-admin
ccc333${tab}shop-db-1${tab}postgres:16${tab}Up 2 hours${tab}5432/tcp${tab}sha256:img-pg${tab}pgdata
ddd444${tab}old-migration${tab}shop/web:latest${tab}Exited (0) 3 days ago${tab}${tab}sha256:img-web${tab}migrations-cache
eee555${tab}crashed-worker${tab}shop/worker:1.0${tab}Exited (1) 10 minutes ago${tab}${tab}sha256:img-worker
EOF
  cat >"$FAKE_DOCKER/images.tsv" <<EOF
sha256:img-web${tab}shop/web:latest${tab}210MB${tab}no
sha256:img-admin${tab}shop/admin:2.1${tab}180MB${tab}no
sha256:img-pg${tab}postgres:16${tab}430MB${tab}no
sha256:img-worker${tab}shop/worker:1.0${tab}95MB${tab}no
sha256:img-old${tab}<none>:<none>${tab}205MB${tab}yes
EOF
  printf 'pgdata\npgdata-old\nmigrations-cache\n' >"$FAKE_DOCKER/volumes.tsv"
}
calls() { cat "$FAKE_DOCKER/calls.log"; }

test_dps_tidies_ports_and_filters() {
  fake_docker
  run dps
  expect_status 0
  expect_out "shop-web-1"
  expect_out "8080->80"
  expect_no_out "0.0.0.0"
  expect_no_out "[::]"
  expect_out "127.0.0.1:9000->9000, 9001/tcp"
  expect_no_out "old-migration"

  run dps -a migration
  expect_status 0
  expect_out "old-migration"
  expect_no_out "shop-web-1"

  run dps nothing-like-this
  expect_status 1
  expect_out 'No running containers match "nothing-like-this"'
}

test_dps_daemon_down() {
  fake_docker
  touch "$FAKE_DOCKER/down"
  run dps
  expect_status 1
  expect_out "Cannot connect to the Docker daemon"
}

test_dshell_matching_rules() {
  fake_docker
  # An exact name wins even though "shop-web-admin" also contains it.
  run dshell shop-web-1 -- ls /
  expect_status 0
  expect_out "ran: docker exec -i shop-web-1 ls /"

  # One partial match (case-insensitive) is used; ID prefixes work too.
  run dshell ADMIN -- true
  expect_out "exec -i shop-web-admin true"
  run dshell ccc -- true
  expect_out "exec -i shop-db-1 true"

  # Several matches: list them, run nothing.
  : >"$FAKE_DOCKER/calls.log"
  run dshell web
  expect_status 1
  expect_out "several running containers match 'web'"
  expect_out "  shop-web-1"
  expect_out "  shop-web-admin"
  calls | grep -q ' exec ' && fail "ran exec despite an ambiguous name"

  # Stopped containers aren't candidates.
  run dshell migration
  expect_status 1
  expect_out "no running container matches"
}

test_dshell_shell_fallback_and_flags() {
  fake_docker
  run dshell -u root -w /app db
  expect_status 0
  expect_out "exec -i -u root -w /app shop-db-1 sh -c"
  expect_out "command -v bash"
  run dshell
  expect_status 1
  expect_out "several containers are running"
  run dshell db extra
  expect_status 2
}

test_dshell_only_container() {
  fake_docker
  awk -F'\t' '$2 == "shop-db-1" || $4 !~ /^Up/' "$FAKE_DOCKER/containers.tsv" >c && mv c "$FAKE_DOCKER/containers.tsv"
  run dshell -- whoami
  expect_status 0
  expect_out "exec -i shop-db-1 whoami"
}

test_dlogs_follow_and_options() {
  fake_docker
  run dlogs db
  expect_status 0
  expect_out "ran: docker logs --tail 100 --follow shop-db-1"
  run dlogs -n 5 -s 10m -t -F admin
  expect_out "ran: docker logs --tail 5 --since 10m --timestamps shop-web-admin"
  run dlogs -n all -F db
  expect_out "logs --tail all shop-db-1"
}

test_dlogs_falls_back_to_stopped_containers() {
  fake_docker
  run dlogs worker
  expect_status 0
  expect_out "crashed-worker is not running"
  expect_out "ran: docker logs --tail 100 crashed-worker"
  expect_no_out "--follow"
  # A running match is preferred over a stopped one.
  run dlogs shop-web
  expect_status 1
  expect_out "several running containers"
  run dlogs
  expect_status 2
  run dlogs -n lots db
  expect_status 2
}

test_docker_clean_dry_run_lists_and_removes_nothing() {
  fake_docker
  run docker-clean -n
  expect_status 0
  expect_out "Stopped containers (2):"
  expect_out "old-migration"
  expect_out "crashed-worker"
  expect_no_out "  shop-db-1"
  expect_out "Dangling images (1):"
  expect_out "<none>:<none>  (img-old"
  expect_out "dry run"
  calls | grep -q prune && fail "dry run called prune"
  return 0
}

test_docker_clean_all_skips_images_in_use() {
  fake_docker
  run docker-clean -a -n
  expect_status 0
  expect_out "Unused images (2):"
  expect_out "shop/worker:1.0"   # only its stopped container used it
  expect_out "<none>:<none>"
  expect_no_out "postgres:16  ("
  expect_no_out "shop/web:latest  ("
}

test_docker_clean_runs_prunes_in_order() {
  fake_docker
  run docker-clean -y
  expect_status 0
  expect_out "Total reclaimed space"
  [ "$(calls | grep prune | grep -v -- --help)" = "docker container prune --force
docker image prune --force
docker network prune --force
docker builder prune --force" ] || fail "unexpected prune calls: $(calls | grep prune)"
  calls | grep -q 'volume prune' && fail "pruned volumes without --volumes"

  : >"$FAKE_DOCKER/calls.log"
  run docker-clean -ay --volumes
  expect_status 0
  expect_out "WARNING: the volumes above will be deleted"
  expect_out "pgdata-old"
  calls | grep -q '^docker image prune --all --force$' || fail "--all not passed to image prune"
  calls | grep -q '^docker volume prune --all --force$' || fail "volumes not pruned with --all"
}

test_docker_clean_volume_preview_includes_stopped_containers() {
  fake_docker
  # migrations-cache belongs to a *stopped* container. That container is
  # removed first, so its volume goes too: the preview must list it.
  run docker-clean -n --volumes
  expect_status 0
  expect_out "Volumes no running container uses (2)"
  expect_out "pgdata-old"
  expect_out "migrations-cache"
  printf '%s\n' "$out" | grep -qx '  pgdata' && fail "listed a volume a running container uses"
  calls | grep -q 'prune' && fail "dry run pruned something"
  true
}

test_docker_clean_needs_yes_without_tty() {
  fake_docker
  run docker-clean </dev/null
  expect_status 1
  expect_out "--yes"
  calls | grep -q prune && fail "pruned without confirmation"
  return 0
}

test_docker_scripts_use_podman_when_asked() {
  fake_docker
  run env DOCKER=podman docker-clean -y --volumes
  expect_status 0
  calls | grep -q '^docker ' && fail "called docker instead of podman"
  calls | grep -q '^podman builder prune --force' && fail "tried to prune a build cache podman doesn't have"
  calls | grep -q '^podman volume prune --force$' || fail "podman volumes not pruned with its own flags"
  run env DOCKER=podman dshell db -- true
  expect_out "ran: podman exec -i shop-db-1 true"
}

# Tests for the image scripts (imgresize, imgconvert, imgshrink, imgstrip,
# favicon). Meant to be merged into tests/run.sh, which provides run,
# expect_*, fail, skip and have, and sets $out and $status.
# shellcheck disable=SC2154  # out and status are set by run() in tests/run.sh

# --- images -----------------------------------------------------------------

need_imagemagick() { { have magick || { have convert && have identify; }; } || skip "ImageMagick not installed"; }
im() { if have magick; then magick "$@"; else convert "$@"; fi; }
im_identify() { if have magick; then magick identify "$@"; else identify "$@"; fi; }
img_size() { im_identify -format '%wx%h' "${1}[0]"; }
img_pixels() { im_identify -format '%#' "${1}[0]"; }        # a hash of the pixels
img_frames() { im_identify -format '%n\n' "$1" | head -n 1; }
img_metadata() { im_identify -verbose "$1" 2>/dev/null; }
img_no_partials() { [ -z "$(find . -name '*.partial.*')" ] || fail "a .partial file was left behind"; }

# make_photo FILE ORIENTATION: an 800x600 JPEG carrying EXIF (orientation,
# GPS position, camera serial number), XMP and a comment, like a phone photo.
make_photo() {
  have python3 || skip "python3 not installed"
  im -size 800x600 gradient:red-blue "$1.plain.jpg"
  python3 - "$1.plain.jpg" "$1" "$2" <<'PY'
import struct, sys
src, dst, orientation = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, "rb").read()
def entry(tag, typ, count, value):
    return struct.pack(">HHI", tag, typ, count) + value
gps_off = 8 + 2 + 12 * 3 + 4
data_off = gps_off + 2 + 12 * 4 + 4
serial = b"SN-123456789\x00"
lat = struct.pack(">IIIIII", 51, 1, 30, 1, 0, 1)
lon = struct.pack(">IIIIII", 0, 1, 7, 1, 0, 1)
ifd0 = (struct.pack(">H", 3)
        + entry(0x0112, 3, 1, struct.pack(">HH", orientation, 0))
        + entry(0x8825, 4, 1, struct.pack(">I", gps_off))
        + entry(0xA431, 2, len(serial), struct.pack(">I", data_off))
        + struct.pack(">I", 0))
gps = (struct.pack(">H", 4)
       + entry(1, 2, 2, b"N\x00\x00\x00")
       + entry(2, 5, 3, struct.pack(">I", data_off + len(serial)))
       + entry(3, 2, 2, b"W\x00\x00\x00")
       + entry(4, 5, 3, struct.pack(">I", data_off + len(serial) + len(lat)))
       + struct.pack(">I", 0))
tiff = b"MM\x00\x2a" + struct.pack(">I", 8) + ifd0 + gps + serial + lat + lon
seg = lambda m, p: b"\xff" + bytes([m]) + struct.pack(">H", len(p) + 2) + p
xmp = b"http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta photoshop:City=\"Secretville\"/>"
open(dst, "wb").write(data[:2] + seg(0xE1, b"Exif\x00\x00" + tiff) + seg(0xE1, xmp)
                      + seg(0xFE, b"private comment") + data[2:])
PY
  rm -f "$1.plain.jpg"
}

test_imgresize_shrinks_but_never_enlarges() {
  need_imagemagick
  im -size 800x600 gradient:red-blue a.jpg
  im -size 300x200 xc:white b.png
  im -delay 10 -size 400x400 xc:red xc:green xc:blue anim.gif
  run imgresize -m 400 a.jpg
  expect_status 0
  [ "$(img_size a.resized.jpg)" = 400x300 ] || fail "-m 400 gave $(img_size a.resized.jpg)"
  run imgresize -w 2000 -o big.jpg a.jpg
  expect_status 0
  [ "$(img_size big.jpg)" = 800x600 ] || fail "the image was enlarged"
  run imgresize --height 150 b.png
  [ "$(img_size b.resized.png)" = 225x150 ] || fail "--height 150 gave $(img_size b.resized.png)"
  run imgresize -p 50 anim.gif
  expect_status 0
  [ "$(img_frames anim.resized.gif)" = 3 ] || fail "the animation lost frames"
  [ "$(img_size anim.resized.gif)" = 200x200 ] || fail "-p 50 gave $(img_size anim.resized.gif)"

  run imgresize -m 400 a.jpg
  expect_status 1
  expect_out "already exists"
  run imgresize -p 150 a.jpg
  expect_status 2
  run imgresize a.jpg
  expect_status 2
  img_no_partials
}

test_imgresize_turns_photos_upright() {
  need_imagemagick
  make_photo sideways.jpg 6
  run imgresize -m 400 sideways.jpg
  expect_status 0
  [ "$(img_size sideways.resized.jpg)" = 300x400 ] || fail "not turned upright: $(img_size sideways.resized.jpg)"
}

test_imgconvert_formats() {
  need_imagemagick
  im -size 200x100 xc:none -fill red -draw 'circle 100,50 100,10' logo.png
  im -delay 10 -size 100x100 xc:red xc:green anim.gif
  run imgconvert -t jpg logo.png anim.gif
  expect_status 0
  [ "$(im logo.jpg -format '%[pixel:p{0,0}]' info:)" = "srgb(255,255,255)" ] ||
    fail "transparency wasn't put on white"
  expect_file anim.jpg
  expect_no_file anim-0.jpg
  run imgconvert -t webp -q 70 logo.png
  expect_status 0
  [ "$(im_identify -format '%m' logo.webp)" = WEBP ] || fail "logo.webp isn't WebP"

  run imgconvert -t png logo.png
  expect_status 1
  expect_out "already a .png"
  run imgconvert -t png -q 50 logo.webp
  expect_status 2
  run imgconvert -t bmp logo.png
  expect_status 2
  run imgconvert logo.png
  expect_status 2
  img_no_partials
}

test_imgshrink_removes_location_and_turns_upright() {
  need_imagemagick
  make_photo photo.jpg 6
  run imgshrink photo.jpg
  expect_status 0
  expect_out "% of the original"
  [ "$(img_size photo.small.jpg)" = 600x800 ] || fail "not turned upright: $(img_size photo.small.jpg)"
  case $(img_metadata photo.small.jpg) in
    *GPS*|*SN-123456789*|*Secretville*|*"private comment"*) fail "metadata survived imgshrink" ;;
  esac
  [ "$(im_identify -format '%Q' photo.small.jpg)" = 82 ] || fail "JPEG quality isn't 82"

  run imgshrink --keep-metadata -o kept.jpg photo.jpg
  expect_status 0
  case $(img_metadata kept.jpg) in *GPS*) ;; *) fail "--keep-metadata dropped the EXIF" ;; esac
  img_no_partials
}

test_imgshrink_limits_size() {
  need_imagemagick
  im -size 3000x1000 gradient:white-black wide.png
  run imgshrink wide.png
  expect_status 0
  [ "$(img_size wide.small.png)" = 2048x683 ] || fail "not limited to 2048: $(img_size wide.small.png)"
  run imgshrink -m 0 -o same.png wide.png
  [ "$(img_size same.png)" = 3000x1000 ] || fail "-m 0 resized the image"
  run imgshrink -m 400 -q 0 wide.png
  expect_status 2
}

test_imgstrip_is_lossless_and_keeps_orientation() {
  need_imagemagick
  make_photo photo.jpg 6
  run imgstrip photo.jpg
  expect_status 0
  expect_out "EXIF (with GPS location)"
  expect_out "kept the orientation"
  [ "$(img_pixels photo.jpg)" = "$(img_pixels photo.clean.jpg)" ] || fail "the picture itself changed"
  case $(img_metadata photo.clean.jpg) in
    *GPS*|*SN-123456789*|*Secretville*|*"private comment"*) fail "metadata survived imgstrip" ;;
  esac
  [ "$(im_identify -format '%[EXIF:Orientation]' photo.clean.jpg)" = 6 ] || fail "the orientation was lost"

  im -size 200x100 xc:none -fill red -draw 'circle 100,50 100,10' -set comment "secret note" shot.png
  run imgstrip shot.png
  expect_status 0
  [ "$(img_pixels shot.png)" = "$(img_pixels shot.clean.png)" ] || fail "the PNG picture changed"
  case $(img_metadata shot.clean.png) in *"secret note"*) fail "PNG comment survived" ;; esac

  cp photo.jpg inplace.jpg
  run imgstrip -i inplace.jpg
  expect_status 0
  cmp -s inplace.jpg photo.clean.jpg || fail "--in-place result differs from the normal one"

  run imgstrip photo.jpg
  expect_status 1
  expect_out "already exists"
}

test_imgstrip_damaged_and_other_formats() {
  need_imagemagick
  make_photo photo.jpg 1
  head -c 3000 photo.jpg >cut.jpg
  run imgstrip cut.jpg
  expect_status 1
  expect_out "damaged or cut short"
  expect_no_file cut.clean.jpg
  img_no_partials

  im -size 100x100 xc:blue -set comment "hidden" pic.webp
  run imgstrip pic.webp
  expect_status 0
  expect_out "re-encoded"
  case $(img_metadata pic.clean.webp) in *hidden*) fail "WebP comment survived" ;; esac
}

test_favicon_makes_every_icon() {
  need_imagemagick
  im -size 800x400 xc:none -fill '#3366cc' -draw 'roundrectangle 0,0 799,399 40,40' logo.png
  run favicon -d site logo.png
  expect_status 0
  expect_out '<link rel="apple-touch-icon"'
  [ "$(im_identify -format '%wx%h ' site/favicon.ico)" = "48x48 32x32 16x16 " ] ||
    fail "favicon.ico sizes: $(im_identify -format '%wx%h ' site/favicon.ico)"
  [ "$(img_size site/favicon-32x32.png)" = 32x32 ] || fail "favicon-32x32.png size"
  [ "$(img_size site/apple-touch-icon.png)" = 180x180 ] || fail "apple-touch-icon.png size"
  [ "$(img_size site/icon-192.png)" = 192x192 ] || fail "icon-192.png size"
  [ "$(img_size site/icon-512.png)" = 512x512 ] || fail "icon-512.png size"
  # A wide logo is centred on a transparent square, not stretched.
  [ "$(im site/icon-512.png -format '%[pixel:p{0,0}]' info:)" = "srgba(0,0,0,0)" ] ||
    fail "icon-512.png isn't padded with transparency"
  # %[opaque] checks the pixels themselves (the %A alpha flag reads
  # differently between ImageMagick versions).
  case $(im_identify -format '%[opaque]' site/apple-touch-icon.png) in
    [Tt]rue) ;;
    *) fail "apple-touch-icon.png should have no transparency" ;;
  esac

  run favicon -d site logo.png
  expect_status 1
  expect_out "already exists"

  im -size 100x100 xc:red small.png
  run favicon -d small small.png
  expect_status 0
  expect_out "will be blurry"
  img_no_partials
}

test_imgstrip_in_place_keeps_permissions_and_refuses_symlinks() {
  need_imagemagick
  make_photo private.jpg 1
  chmod 600 private.jpg
  run imgstrip -i private.jpg
  expect_status 0
  case $(ls -l private.jpg) in -rw-------*) ;; *) fail "--in-place changed the permissions: $(ls -l private.jpg)" ;; esac
  make_photo real.jpg 1
  ln -s real.jpg link.jpg
  run imgstrip -i link.jpg
  expect_status 1
  expect_out "is a symlink"
  [ -L link.jpg ] || fail "the symlink was replaced"
  case $(img_metadata real.jpg) in *GPS*) ;; *) fail "the linked photo was changed" ;; esac
}

# --- runner -----------------------------------------------------------------

filter=${1:-}
passed=0 failed=0 skipped=0 failures=''
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  case $t in *"$filter"*) ;; *) continue ;; esac
  dir=$SUITE_TMP/$t
  mkdir -p "$dir"
  printf '%s\n' "${t#test_}"
  (cd "$dir" && "$t") 2>&1
  case $? in
    0) passed=$((passed + 1)) ;;
    3) skipped=$((skipped + 1)) ;;
    *) failed=$((failed + 1)); failures="$failures ${t#test_}" ;;
  esac
done

echo
echo "$passed passed, $failed failed, $skipped skipped"
if [ "$failed" -gt 0 ]; then
  echo "Failed:$failures"
  exit 1
fi
