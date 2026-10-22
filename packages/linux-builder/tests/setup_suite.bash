# Leaves the image --build-image loads: it is linux-builder-image's tests' too.
setup_suite() {
  LB_REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LINUX_BUILDER="$(nix-build --fallback --no-out-link -A linux-builder "$LB_REPO")/bin/linux-builder"
  export LB_REPO LINUX_BUILDER
}
