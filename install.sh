#!/usr/bin/env bash
#
# install.sh: put the scripts in bin/ on your PATH.
#
set -euo pipefail
unset CDPATH   # so "cd dir" never jumps somewhere else

readonly PROG=${0##*/}

usage() {
  cat <<EOF
Usage: ./$PROG [options]

Link every script in bin/ into a folder on your PATH (default:
~/.local/bin). The links point back at this checkout, so "git pull"
updates them; use --copy if you'd rather have standalone copies.

Options:
  -p, --prefix DIR  install into DIR (default: ~/.local/bin, or \$PREFIX/bin
                    if PREFIX is set)
  -c, --copy        copy the scripts instead of linking them
  -f, --force       replace existing files with the same names
  -u, --uninstall   remove scripts that this installed
  -h, --help        show this help
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
usage_error() { printf '%s: %s\nTry "./%s --help".\n' "$PROG" "$*" "$PROG" >&2; exit 2; }

if [ -n "${PREFIX:-}" ]; then target=$PREFIX/bin; else target=$HOME/.local/bin; fi
copy=0 force=0 uninstall=0
while [ $# -gt 0 ]; do
  case $1 in
    -p|--prefix)    [ $# -ge 2 ] || usage_error "$1 needs a value"; target=$2; shift ;;
    -c|--copy)      copy=1 ;;
    -f|--force)     force=1 ;;
    -u|--uninstall) uninstall=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage_error "unknown argument: $1" ;;
  esac
  shift
done

src=$(cd "$(dirname "$0")/bin" && pwd)

# If the target is this checkout's own bin/ (directly or through a symlink),
# "uninstalling" or --force would delete or clobber the scripts themselves.
if [ -d "$target" ] && [ "$target" -ef "$src" ]; then
  die "$target is this checkout's bin/ folder; nothing to install or remove there"
fi

if [ "$uninstall" -eq 1 ]; then
  [ -d "$target" ] || { echo "Nothing installed in $target."; exit 0; }
  removed=0
  for script in "$src"/*; do
    dest=$target/$(basename "$script")
    # Only remove links that point here, or copies identical to ours.
    if { [ -L "$dest" ] && [ "$(readlink "$dest")" = "$script" ]; } ||
       { [ -f "$dest" ] && [ ! -L "$dest" ] && ! [ "$dest" -ef "$script" ] && cmp -s "$dest" "$script"; }; then
      rm -f "$dest"
      echo "removed $dest"
      removed=$((removed + 1))
    fi
  done
  echo "Removed $removed script(s) from $target."
  exit 0
fi

mkdir -p "$target"
target=$(cd "$target" && pwd)   # absolute, for the PATH hint below
installed=0 skipped=0
for script in "$src"/*; do
  [ -f "$script" ] && [ -x "$script" ] || continue
  dest=$target/$(basename "$script")
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$script" ] && [ "$copy" -eq 0 ]; then
    installed=$((installed + 1))   # already linked here
    continue
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ "$force" -eq 0 ]; then
      echo "skipped $dest (already exists; use --force to replace it)" >&2
      skipped=$((skipped + 1))
      continue
    fi
    rm -f "$dest"
  fi
  if [ "$copy" -eq 1 ]; then
    cp "$script" "$dest"
    chmod +x "$dest"
  else
    ln -s "$script" "$dest"
  fi
  installed=$((installed + 1))
done

if [ "$skipped" -gt 0 ]; then
  echo "Installed $installed script(s) into $target ($skipped skipped)."
else
  echo "Installed $installed script(s) into $target."
fi
case ":$PATH:" in
  *":$target:"*) ;;
  *) echo
     echo "$target is not on your PATH yet. Add this to your ~/.bashrc or ~/.zshrc:"
     echo "  export PATH=\"$target:\$PATH\"" ;;
esac
