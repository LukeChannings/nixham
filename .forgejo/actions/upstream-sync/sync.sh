#!/usr/bin/env bash
# Brings the upstream's new commits into $GITHUB_REPOSITORY through a sync PR
# (.forgejo/CONTEXT.md, .forgejo/docs/adr/0001-sync-prs-keep-upstream-history.md).
set -euo pipefail

: "${UPSTREAM:?UPSTREAM is required}"
: "${FORGE_TOKEN:?FORGE_TOKEN is required}"
: "${SIGNING_KEY:?SIGNING_KEY is empty: the merge commits must be signed}"
: "${GIT_NAME:?GIT_NAME is required}" "${GIT_EMAIL:?GIT_EMAIL is required}"
branch=${SYNC_BRANCH:-sync/upstream}
remote=${FORGE_REMOTE:-https://forgejo:$FORGE_TOKEN@${GITHUB_SERVER_URL#*://}/$GITHUB_REPOSITORY.git}
name=${UPSTREAM#*://}
name=${name#*/}
name=${name%.git}

api() {
  local method=$1 path=$2 body status=0
  shift 2
  body=$(curl -sS --fail-with-body -X "$method" -H "Authorization: token $FORGE_TOKEN" \
    -H "Content-Type: application/json" "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/$path" "$@") ||
    status=$?
  if [ "$status" -ne 0 ]; then
    echo "$method $path rejected: $body" >&2
    return "$status"
  fi
  printf '%s' "$body"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(umask 077 && printf '%s\n' "$SIGNING_KEY" >"$work/key")
git clone -q "$remote" "$work/repo"
cd "$work/repo"
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"
git config gpg.format ssh
git config user.signingkey "$work/key"
git config commit.gpgsign true

base=$(git symbolic-ref --short refs/remotes/origin/HEAD)
base=${base#origin/}
git fetch -q --no-tags "$UPSTREAM" "${UPSTREAM_BRANCH:-HEAD}"
up=$(git rev-parse FETCH_HEAD)

start=origin/$base
if git rev-parse -q --verify "origin/$branch" >/dev/null &&
  ! git merge-base --is-ancestor "origin/$branch" "origin/$base"; then
  start=origin/$branch
fi

conflicts=""
pushed=""
if git merge-base --is-ancestor "$up" "$start"; then
  [ "$start" != "origin/$base" ] || {
    echo "$base already has $name at ${up:0:12}"
    exit 0
  }
else
  git checkout -q -B "$branch" "$start"
  if git merge -q --no-ff -m "Merge $name at ${up:0:12}" "$up"; then
    # Only a sync branch someone could have pushed to is protected from force.
    if [ "$start" = "origin/$base" ]; then
      git push -q --force-with-lease="refs/heads/$branch" origin "HEAD:refs/heads/$branch"
    else
      git push -q origin "HEAD:refs/heads/$branch"
    fi
    pushed=1
  else
    conflicts=$(git diff --name-only --diff-filter=U)
    git merge --abort
  fi
fi

# A sync branch only ever grows upstream merges on top of $base, so there is
# nothing to open a PR from until one merge has landed on it.
pr=""
if [ -n "$pushed" ] || [ "$start" = "origin/$branch" ]; then
  pr=$(api GET "pulls?state=open&limit=50" |
    jq --arg b "$branch" '[.[] | select(.head.ref == $b)][0].number // empty')
fi
if [ -n "$pushed" ] && [ -z "$pr" ]; then
  body="Brings $name's new commits into \`$base\`. Rewriting upstream's commits would make every later sync conflict with them, so merge this with a merge commit or a fast-forward -- a rebase only while this branch is 0 behind \`$base\`, which Forgejo turns into a fast-forward -- never squash it, and bring \`$base\` in by merging, never by rebasing.

$(git log --oneline --no-merges "origin/$base..$up" | head -n 100)"
  pr=$(api POST pulls -d "$(jq -nc --arg head "$branch" --arg base "$base" \
    --arg title "Sync with $name" --arg body "$body" '{$head, $base, $title, $body}')" | jq .number)
fi

if [ -n "$conflicts" ]; then
  report="Merging $name at \`${up:0:12}\` into \`$branch\` conflicts in:

$(sed 's/^/- `/; s/$/`/' <<<"$conflicts")"
  # Always on the job log: the comment below needs a scope the token may lack.
  echo "$report" >&2
  if [ -z "$pr" ]; then
    cat >&2 <<EOF

Nothing was pushed. Resetting \`$branch\` to upstream's head would open a PR
that deletes every path \`$base\` has and upstream does not, so the first merge
is yours to make; later runs then merge newer upstream commits on top of it.

  git switch -c $branch origin/$base
  git pull $UPSTREAM ${UPSTREAM_BRANCH:-HEAD}
  git push -u origin $branch
EOF
    exit 1
  fi
  marker="<!-- upstream-sync $up -->"
  if ! api GET "issues/$pr/comments" | jq -e --arg m "$marker" 'any(.[]; .body | contains($m))' >/dev/null; then
    api POST "issues/$pr/comments" -d "$(jq -nc --arg body "$marker
$report

Merge it into \`$branch\` yourself, resolve, and push." '{$body}')" >/dev/null
  fi
fi
