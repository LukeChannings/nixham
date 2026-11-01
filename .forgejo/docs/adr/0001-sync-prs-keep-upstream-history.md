# Sync PRs keep upstream's history, unsigned

A **sync PR** merges the **upstream**'s commits as they are, so a **forge repo** that takes sync PRs cannot require signed commits on its default branch. Only the bot's merge commits are signed. We keep upstream's history because upstream then stays an ancestor: each sync only has to merge what's new, and `git merge-base` still finds the last sync.

## Considered Options

- **Squash each sync into one signed commit**, recording the upstream SHA in a trailer and diffing from it next time. Everything on the default branch would be signed, but upstream would stop being an ancestor. Every sync would re-resolve conflicts with `git apply --3way`, and merge-base tooling (e.g. KaiT2en-NixOS's `sync-upstream` skill) would break.
- **Re-sign upstream's commits**: rewriting them changes their SHAs, so every later sync re-conflicts with history the fork already has.

## Consequences

- A sync PR must be merged without rewriting upstream's commits: with a merge commit, a fast-forward, or a rebase while the **sync branch** is 0 commits behind the default branch (Forgejo then fast-forwards). Never squash it, and bring the default branch into a **sync branch** that's behind by merging, never by rebasing.
