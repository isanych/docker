#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
	cat <<'EOF'
Usage: ./build.sh

Build the static Linux dockerd and docker-proxy binaries into:
  bundles/binary-daemon/

The build honors the environment variables supported by hack/make.sh, such as
VERSION, DOCKER_BUILDTAGS, DOCKER_DEBUG, and DOCKER_LDFLAGS.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

if (( $# != 0 )); then
	usage >&2
	exit 2
fi

cd -- "$REPO_ROOT"

if [[ ! -x hack/make.sh ]]; then
	printf 'build.sh: error: hack/make.sh was not found\n' >&2
	exit 1
fi

if ! command -v go >/dev/null 2>&1; then
	printf 'build.sh: error: Go is required to build Docker\n' >&2
	exit 1
fi

export DOCKER_STATIC=1
exec "$REPO_ROOT/hack/make.sh" binary
