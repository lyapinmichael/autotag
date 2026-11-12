# autotag
A tool to automate incremental tagging for git repos

#### Rules
Two rules ship built in and are always available: `release` (semver, no prefix)
and `debug` (bleeding calendar tags). User aliases live in `autotag.rules` next to
the script — one line per alias, format documented in the file; they take
precedence over built-ins.

#### Install
`./autotag.sh install` creates an `autotag` symlink in a bin directory on `$PATH`
(default: first writable of `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
`~/bin`; `--bin DIR` to choose). `autotag uninstall` removes it. When autotag is
invoked but not installed on `$PATH`, it prints a reminder to run `autotag install`
and continues.

#### Planned features and improvements: 
- [x] add `fetch` in the beginning of the procedure to get most recent changes from remote
- [ ] introduce config
- [ ] add a flag to automate process more, omit unnecessary interaction based on config
- [x] move rule description to config or other separate file (autotag.rules)
- [x] make helper script to add to `$PATH` to run from any location (`autotag install`)

