#!/usr/bin/env bash
# Publishes the image at nix attribute $attr to $ref under its imageTag, then
# points latest at it. Building and pushing only happen for a tag the registry
# lacks, so an unchanged closure publishes nothing.
set -euo pipefail

ref=${ref,,}
tag=$(nix-instantiate --eval --read-write-mode -A "$attr.imageTag" | tr -d '"')

# skopeo's default, /var/tmp, doesn't exist on the NixOS runners.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
skopeo() { command skopeo --tmpdir "$tmp" "$@"; }

digest() {
  skopeo inspect --creds "$creds" --format '{{.Digest}}' "docker://$ref:$1" 2>/dev/null || true
}

if [ -z "$(digest "$tag")" ]; then
  image=$(nix-build --no-out-link -A "$attr")
  skopeo --insecure-policy copy --dest-creds "$creds" "$transport:$image" "docker://$ref:$tag"
fi

if [ "$(digest latest)" != "$(digest "$tag")" ]; then
  skopeo --insecure-policy copy --src-creds "$creds" --dest-creds "$creds" \
    "docker://$ref:$tag" "docker://$ref:latest"
fi
