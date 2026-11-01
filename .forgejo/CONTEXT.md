# forge-ci

Composite actions and workflows that hartlandia's repos on forge.channings.me share, consumed by URL from nixham.

## Language

### Forks

**forge repo**:
A repo whose source of truth is forge.channings.me, e.g. `hartlandia/KaiT2en-NixOS`.
_Avoid_: origin, our repo

**upstream**:
The third-party repo a **forge repo** was originally forked from, e.g. `kaiT2en/KaiT2en-Fedora`. Changes only flow in from it.
_Avoid_: super, fedora, parent

**mirror**:
The GitHub copy a **forge repo** auto-pushes to, e.g. `LukeChannings/KaiT2en-NixOS`. Changes only flow out to it. Never the **upstream**, even though it sits on GitHub too.
_Avoid_: upstream, GitHub repo

**sync PR**:
A pull request on the **forge repo** that brings the **upstream**'s new commits into its default branch.
_Avoid_: upstream PR, merge PR

**sync branch**:
The one long-lived branch a **sync PR** is opened from. The bot only ever adds **upstream** merges to it, never resets it, so whoever resolves its conflicts can push their reconciliation there too. Gone once the **sync PR** merges.
_Avoid_: sync-<date>, upstream branch

## Example dialogue

> **Dev:** "Should the sync PR fetch from the GitHub repo?"
> **Expert:** "Which one? `LukeChannings/KaiT2en-NixOS` is the **mirror**: it only ever holds what the **forge repo** already has. The **sync PR** fetches from the **upstream**, `kaiT2en/KaiT2en-Fedora`."
> **Dev:** "Upstream conflicts with our Nix layer. Do I open my own branch to fix it?"
> **Expert:** "No, check out the **sync branch**, merge main, resolve, push. The next run merges newer upstream commits on top of your work rather than replacing it."
