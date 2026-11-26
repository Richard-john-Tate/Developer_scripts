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
  expect_out python3
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
  (cd site && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
  srv=$!
  run wait-for -t 10 "http://127.0.0.1:$port/health"
  kill "$srv" 2>/dev/null
  expect_status 0
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
