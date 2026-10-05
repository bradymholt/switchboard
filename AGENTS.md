# Switchboard — notes for Claude

## Working on switchboard

Ship each change end to end without being asked: commit to a feature branch, open a PR, and
merge it. An unmerged PR is an unshipped change.

Run `swift build` before merging, then merge with `gh pr merge --squash --auto`. The `default`
ruleset on `main` requires the `build` check, so a plain merge is refused while it is pending;
`--auto` merges when it passes and is the standing instruction, not something to ask about. Keep
unrelated work out of the commit. Don't use `--admin`, and stop rather than merge when something
looks wrong.

Merging does not publish a release. Releases are cut by dispatching the `Release` workflow with
a version; do that only when asked.
