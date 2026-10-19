#!/usr/bin/env bash
# Step 0: puts mikefarah/yq v4 on the path when the runner has none, as on GitHub-hosted Windows
# runners. The binary is kept in the cache shared by every run of the action in the job, so it is
# downloaded only once, and its checksum is verified against the one this release pins.
#
# Inputs (environment): CATEGORY.
# Writes: the directory of the installed yq to GITHUB_PATH, or prints it when that is not set.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if yq --version 2> /dev/null | grep -q 'mikefarah/yq.* version v\?4\.'; then
  exit 0
fi

case "${RUNNER_OS:-$(uname -s)}" in
  Linux) OS=linux ;;
  macOS | Darwin) OS=darwin ;;
  Windows | MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) die "yq v4 is not on the path, and cannot be installed for the runner's operating system, ${RUNNER_OS:-$(uname -s)}. Install mikefarah/yq v4." ;;
esac
case "${RUNNER_ARCH:-$(uname -m)}" in
  X64 | x86_64 | amd64) ARCH=amd64 ;;
  ARM64 | arm64 | aarch64) ARCH=arm64 ;;
  *) die "yq v4 is not on the path, and cannot be installed for the runner's architecture, ${RUNNER_ARCH:-$(uname -m)}. Install mikefarah/yq v4." ;;
esac
DIST="${OS}_$ARCH"
VERSION="$PINNED_YQ_VERSION"
EXPECTED="$(yq_sha256 "$DIST")" || die "No yq binary is pinned for $DIST."
EXE=""
[ "$OS" = windows ] && EXE=.exe
DIR="$(tool_cache_dir)/yq-$VERSION-$DIST"
FILE="$DIR/yq$EXE"

echo "::group::Install yq $VERSION ($DIST)"
mkdir -p "$DIR"
if [ ! -f "$FILE" ]; then
  download "https://github.com/mikefarah/yq/releases/download/v$VERSION/yq_$DIST$EXE" "$FILE" \
    || die "Could not download yq $VERSION for $DIST."
fi
# Also checked when it comes from the cache, since yq reads every Scan.toml.
ACTUAL="$(sha256_of "$FILE")"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  rm -f "$FILE"
  die "The yq $VERSION download for $DIST has the SHA-256 $ACTUAL, but $EXPECTED was expected."
fi
chmod +x "$FILE"
"$FILE" --version
echo "::endgroup::"

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$(to_native_path "$DIR")" >> "$GITHUB_PATH"
else
  echo "Add $DIR to the path."
fi
