# Developer scripts

A toolbox of small, dependable command-line scripts for everyday
development chores: tidying git branches, freeing a stuck port, waiting for
a database to come up, unpacking an archive, finding what's eating your
disk.

Each script is a single self-contained file: bash for most of them, and
Python 3 for the data tools, which need real JSON, CSV and date parsing.
Copy one into any folder on your `PATH` and it works on its own. All of
them:

- print a short manual with `--help`;
- ask before deleting anything, and have a `--dry-run` where it matters;
- exit with `0` on success, `1` on failure, `2` on a usage mistake;
- turn off colour when the output isn't a terminal or `NO_COLOR` is set;
- run on Linux and macOS (bash 3.2 or later, Python 3.8 or later, and
  standard system tools).

## The scripts

### Git

The `git-*` scripts become git subcommands once they're on your `PATH`, so
you can type `git sync` instead of `git-sync`.

| Command | What it does |
| --- | --- |
| [`git clean-branches`](bin/git-clean-branches) | Delete local branches already merged into main. `-g` also removes branches whose remote branch is gone, which catches squash-merged pull requests. |
| [`git sync`](bin/git-sync) | Fetch, fast-forward your local main, and rebase the current branch onto it. Stashes and restores uncommitted work. |
| [`git standup`](bin/git-standup) | Your commits since the last working day, across all branches. `-r ~/code` covers every repo in a folder. |

### Ports, processes and servers

| Command | What it does |
| --- | --- |
| [`ports`](bin/ports) | Which process is listening on which TCP port. |
| [`killport`](bin/killport) | Kill whatever is holding a port. `killport 3000` |
| [`wait-for`](bin/wait-for) | Wait until `host:port` or a URL is up, then run a command. Built for docker-compose entrypoints and CI. |
| [`serve`](bin/serve) | Serve a folder over HTTP on `127.0.0.1`. Picks a free port if 8000 is taken. |
| [`retry`](bin/retry) | Re-run a flaky command with exponential backoff. |
| [`onchange`](bin/onchange) | Re-run a command whenever files change. `-r` restarts long-running servers. |

### Files and disk space

| Command | What it does |
| --- | --- |
| [`extract`](bin/extract) | Unpack any common archive: tar.gz, zip, xz, zst, 7z, rar and more. Never overwrites existing files unless you pass `--force`. |
| [`backup`](bin/backup) | Make a timestamped copy of a file, or a `.tar.gz` of a folder, before you change it. |
| [`bigfiles`](bin/bigfiles) | The largest files in a folder. `-g` finds the largest files ever committed to a repo's history. |
| [`clean-artifacts`](bin/clean-artifacts) | Find `node_modules`, `__pycache__`, `target` and similar folders, show their size, and delete them. Never deletes a folder that git tracks files in or that holds a repository. |

### Code and projects

| Command | What it does |
| --- | --- |
| [`todos`](bin/todos) | List TODO, FIXME, HACK, XXX and BUG comments. `-c` just counts them. |
| [`loc`](bin/loc) | Lines of code by file type. Inside a repo it counts only tracked files. |
| [`envcheck`](bin/envcheck) | Compare `.env` against `.env.example`: missing, empty and extra keys. Prints key names only, never values. |
| [`gensecret`](bin/gensecret) | Random passwords, hex keys, base64 tokens, PINs and UUIDs. |
| [`mkscript`](bin/mkscript) | Start a new bash script with strict mode, `--help` and option parsing already written. |

### Video and audio (ffmpeg)

Friendly front ends for the [ffmpeg](https://ffmpeg.org) jobs people look
up every time. They all start with `ff`, so `ff<Tab>` lists them. They
never overwrite a file unless you pass `--force`, and a failed run never
leaves a half-written file behind.

| Command | What it does |
| --- | --- |
| [`ffinfo`](bin/ffinfo) | A short, readable summary of a media file: length, size, codecs, resolution, frame rate, audio channels. |
| [`ffshrink`](bin/ffshrink) | Make videos smaller for sharing (H.264 MP4). `-r 720` for 720p, `-s 25M` to fit an upload limit, `--hevc` for even smaller files. |
| [`fftrim`](bin/fftrim) | Cut a clip from START to END. Instant and lossless by default; `--exact` for a frame-accurate cut. |
| [`ffgif`](bin/ffgif) | Turn a video, or part of one, into a good-looking GIF using a custom colour palette. |
| [`ffaudio`](bin/ffaudio) | Pull the soundtrack out of a video without re-encoding, or convert it to mp3, m4a, opus, flac or wav. |
| [`ffthumbs`](bin/ffthumbs) | A thumbnail, N evenly spaced frames, or a contact sheet (`-s 4x4`) of a whole video. |
| [`ffconcat`](bin/ffconcat) | Join clips end to end, losslessly when they match, or with `-r` for any mix of sizes and formats. |

### Data and text

| Command | What it does |
| --- | --- |
| [`jsonfmt`](bin/jsonfmt) | Pretty-print, minify (`-c`), sort (`-s`) or check (`--check`) JSON. Shows exactly where broken JSON breaks. Never rounds big numbers. `-w` reformats files in place. |
| [`jwt-decode`](bin/jwt-decode) | Show a JWT's header and claims, when it was issued and expires, and whether it has expired. Decodes only; doesn't check the signature. |
| [`epoch`](bin/epoch) | Convert Unix timestamps (seconds, ms, µs or ns) to dates and ISO dates back to timestamps, in UTC and local time. |
| [`urlencode`](bin/urlencode) | Percent-encode text for a URL. `-f` for form style (`+` for spaces). |
| [`urldecode`](bin/urldecode) | Decode `%XX` codes. `-p` takes a whole URL apart into host, path and decoded query parameters. |
| [`csvview`](bin/csvview) | Show a CSV or TSV file as an aligned table. Handles quoted commas and line breaks, and detects the delimiter. |

## Install

```sh
git clone https://github.com/Richard-john-Tate/Developer_scripts.git
cd Developer_scripts
./install.sh
```

This links every script into `~/.local/bin`. Because they're links,
`git pull` keeps them up to date. The installer tells you if that folder
isn't on your `PATH` yet and what line to add to your shell profile.

Options:

- `./install.sh --prefix /usr/local/bin` installs somewhere else.
- `./install.sh --copy` copies the scripts instead of linking them.
- `./install.sh --uninstall` removes only what the installer put there.

You can also skip the installer and copy any single file from `bin/`.

## Examples

```sh
# Git housekeeping
git clean-branches -n            # preview which merged branches would go
git clean-branches -fg           # fetch, then delete merged + squash-merged
git sync                         # update main and rebase onto it
git standup -d 7                 # everything you did this week

# "Address already in use"
ports 3000                       # who has it?
killport 3000                    # make them let go

# Containers and CI
wait-for db:5432 redis:6379 -- ./start.sh
retry -n 5 -d 2 -- curl -fsS https://example.com/health

# Development loop
serve -o dist                    # preview a static build in the browser
onchange -e py -- pytest -q      # re-run tests on every save
onchange -r -p src -- node app.js

# Files
extract release.tar.zst
backup config.yml                # config.yml.20261126-143002.bak
bigfiles -g -n 10                # what made this repo so big?
clean-artifacts -n ~/code        # how much space would I get back?

# Video and audio
ffinfo holiday.mov               # what's in this file?
ffshrink -r 720 screen-recording.mov
ffshrink -s 25M -o upload.mp4 gameplay.mkv
fftrim talk.mp4 12:30 +45        # 45 seconds from 12:30
ffgif -s 1:05 -t 4 -w 320 match.mp4 goal.gif
ffaudio -t mp3 lecture.mp4
ffthumbs -s 4x4 lecture.mp4      # contact sheet of the whole video
ffconcat part1.mp4 part2.mp4 part3.mp4

# Data and text
curl -s https://api.github.com/repos/git/git | jsonfmt
jsonfmt --check config/*.json    # exit status 1 if any is broken
pbpaste | jwt-decode             # what's in this token? has it expired?
epoch 1764201600                 # -> 2025-11-27 00:00:00 UTC
epoch 2026-11-27T09:00:00Z       # -> 1795770000
urldecode -p "$LONG_TRACKING_LINK"
csvview -n 20 export.csv

# Projects
todos -c
loc
envcheck                         # exit status 1 if keys are missing
gensecret -t hex 64
mkscript deploy "Build and ship the site"
```

Run any command with `--help` for all its options.

## Requirements

Bash and the tools that ship with Linux and macOS, plus Python 3 for the
data tools (`jsonfmt`, `jwt-decode`, `epoch`, `urlencode`, `urldecode`,
`csvview`). Python 3 comes with most Linux systems, and with the Xcode
command line tools on macOS. Some scripts need an extra tool, or use one
if it's there:

| Script | Uses |
| --- | --- |
| `ports`, `killport` | `lsof`, or `ss`/`netstat`/`fuser` on Linux |
| `serve` | `python3`, `php` or `busybox` |
| `wait-for` | `curl` or `wget`, for URLs only |
| `extract` | `unzip`, `zstd`, `7z` or `unrar` for those formats |
| `todos` | `rg` (ripgrep), if installed, for speed and `.gitignore` support |
| `ff*` | `ffmpeg` and `ffprobe` (macOS: `brew install ffmpeg`; Debian/Ubuntu: `sudo apt install ffmpeg`) |

## Development

```sh
make test     # run the test suite (tests/run.sh)
make lint     # shellcheck every script
make check    # both
```

The tests need only bash, git and the usual system tools. Tests that need
an optional tool, such as `python3`, `zip` or `ffmpeg`, are skipped if it's
missing.
Pass a name to run a subset: `tests/run.sh killport`.

To add a script, start it with `bin/mkscript bin/my-tool "What it does"`
so it matches the others, then add tests to `tests/run.sh`.
