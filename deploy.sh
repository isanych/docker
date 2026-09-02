#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BUNDLE_DIR="${BUNDLE_DIR:-$REPO_ROOT/bundles/binary-daemon}"
readonly SERVICE_NAME="${DOCKER_SERVICE:-docker.service}"

usage() {
	cat <<'EOF'
Usage: sudo ./deploy.sh

Deploy bundles/binary-daemon/dockerd to the system Docker installation on
Ubuntu 26.04 or Amazon Linux. If docker-proxy is installed alongside dockerd
or is on PATH, the matching built docker-proxy binary is deployed as well.

Environment overrides:
  BUNDLE_DIR             Binary bundle directory
  DOCKERD_PATH           Installed dockerd path
  DOCKER_PROXY_PATH      Installed docker-proxy path
  DOCKER_SERVICE         systemd service name (default: docker.service)
  UPDATE_DOCKER_PROXY    Set to 0 to leave docker-proxy unchanged
EOF
}

die() {
	printf 'deploy.sh: error: %s\n' "$*" >&2
	exit 1
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

if (( EUID != 0 )); then
	die "run as root, for example: sudo ./deploy.sh"
fi

if ! command -v systemctl >/dev/null 2>&1; then
	die "systemctl is required"
fi

if [[ ! -r /etc/os-release ]]; then
	die "cannot determine the operating system"
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
	ubuntu:26.04 | amzn:*) ;;
	*) die "this script only deploys to Ubuntu 26.04 or Amazon Linux (found ${PRETTY_NAME:-unknown})" ;;
esac

DOCKERD_SOURCE="$BUNDLE_DIR/dockerd"
DOCKER_PROXY_SOURCE="$BUNDLE_DIR/docker-proxy"
[[ -x "$DOCKERD_SOURCE" ]] || die "run ./build.sh first; missing $DOCKERD_SOURCE"

if ! "$DOCKERD_SOURCE" --version >/dev/null 2>&1; then
	die "the built dockerd binary cannot be executed"
fi

resolve_binary_path() {
	local name="$1"
	local override="${2:-}"
	local candidate=""
	local path=""
	local resolved=""

	if [[ -n "$override" ]]; then
		candidate="$override"
	else
		for path in "/usr/bin/$name" "/usr/local/bin/$name"; do
			if [[ -x "$path" ]]; then
				candidate="$path"
				break
			fi
		done
		if [[ -z "$candidate" ]] && command -v "$name" >/dev/null 2>&1; then
			candidate="$(command -v "$name")"
		fi
	fi

	[[ -n "$candidate" ]] || return 1
	if [[ "$candidate" != /* ]]; then
		candidate="$REPO_ROOT/$candidate"
	fi
	resolved="$(readlink -f -- "$candidate")" || return 1
	[[ -f "$resolved" && -x "$resolved" ]] || return 1
	printf '%s\n' "$resolved"
}

if ! INSTALLED_DOCKERD="$(resolve_binary_path dockerd "${DOCKERD_PATH:-}")"; then
	die "could not find the installed dockerd; set DOCKERD_PATH explicitly"
fi

case "${UPDATE_DOCKER_PROXY:-1}" in
	0) UPDATE_PROXY=0 ;;
	1) UPDATE_PROXY=1 ;;
	*) die "UPDATE_DOCKER_PROXY must be 0 or 1" ;;
esac

INSTALLED_PROXY=""
if (( UPDATE_PROXY )); then
	proxy_override="${DOCKER_PROXY_PATH:-}"
	if [[ -z "$proxy_override" && -x "$(dirname -- "$INSTALLED_DOCKERD")/docker-proxy" ]]; then
		proxy_override="$(dirname -- "$INSTALLED_DOCKERD")/docker-proxy"
	fi

	if [[ -n "$proxy_override" ]]; then
		if ! INSTALLED_PROXY="$(resolve_binary_path docker-proxy "$proxy_override")"; then
			die "could not resolve docker-proxy at $proxy_override"
		fi
	elif INSTALLED_PROXY="$(resolve_binary_path docker-proxy "")"; then
		:
	fi

	if [[ -n "$INSTALLED_PROXY" ]]; then
		[[ -x "$DOCKER_PROXY_SOURCE" ]] || die "missing matching built binary $DOCKER_PROXY_SOURCE"
		if ! "$DOCKER_PROXY_SOURCE" --version >/dev/null 2>&1; then
			die "the built docker-proxy binary cannot be executed"
		fi
	fi
fi

LAST_BACKUP=""
backup_and_replace() {
	local source="$1"
	local target="$2"
	local backup="${target}.bak.$(date -u +%Y%m%d%H%M%S).$$"
	local group=""
	local mode=""
	local owner=""
	local temporary=""

	LAST_BACKUP=""
	while [[ -e "$backup" || -L "$backup" ]]; do
		backup="${target}.bak.$(date -u +%Y%m%d%H%M%S).$$.$RANDOM"
	done

	if ! cp -a -- "$target" "$backup"; then
		rm -f -- "$backup"
		return 1
	fi
	LAST_BACKUP="$backup"

	if ! mode="$(stat -c '%a' -- "$target")" ||
		! owner="$(stat -c '%u' -- "$target")" ||
		! group="$(stat -c '%g' -- "$target")"; then
		return 1
	fi

	if ! temporary="$(mktemp "${target}.tmp.XXXXXX")"; then
		return 1
	fi
	if ! install -o "$owner" -g "$group" -m "$mode" -- "$source" "$temporary"; then
		rm -f -- "$temporary"
		return 1
	fi
	if ! mv -f -- "$temporary" "$target"; then
		rm -f -- "$temporary"
		return 1
	fi
}

restore_binary() {
	local backup="$1"
	local target="$2"
	local temporary=""

	[[ -f "$backup" ]] || return 1
	if ! temporary="$(mktemp "${target}.rollback.XXXXXX")"; then
		return 1
	fi
	if ! rm -f -- "$temporary" || ! cp -a -- "$backup" "$temporary"; then
		rm -f -- "$temporary"
		return 1
	fi
	if ! mv -f -- "$temporary" "$target"; then
		rm -f -- "$temporary"
		return 1
	fi
}

DOCKERD_BACKUP=""
PROXY_BACKUP=""
SERVICE_STOP_ATTEMPTED=0
SERVICE_STARTED=0

rollback() {
	local status=$?
	trap - EXIT

	if (( status == 0 )); then
		exit 0
	fi

	printf 'deploy.sh: deployment failed; rolling back\n' >&2

	if (( SERVICE_STARTED )); then
		if ! systemctl --no-pager stop "$SERVICE_NAME"; then
			printf 'deploy.sh: error: could not stop the failed deployment\n' >&2
		fi
	fi

	if [[ -n "$PROXY_BACKUP" ]] && ! restore_binary "$PROXY_BACKUP" "$INSTALLED_PROXY"; then
		printf 'deploy.sh: error: could not restore %s\n' "$INSTALLED_PROXY" >&2
	fi
	if [[ -n "$DOCKERD_BACKUP" ]] && ! restore_binary "$DOCKERD_BACKUP" "$INSTALLED_DOCKERD"; then
		printf 'deploy.sh: error: could not restore %s\n' "$INSTALLED_DOCKERD" >&2
	fi

	if (( SERVICE_STOP_ATTEMPTED )); then
		if ! systemctl --no-pager start "$SERVICE_NAME"; then
			printf 'deploy.sh: error: could not restart %s after rollback\n' "$SERVICE_NAME" >&2
		fi
	fi

	exit "$status"
}
trap rollback EXIT

SERVICE_STOP_ATTEMPTED=1
if ! systemctl --no-pager stop "$SERVICE_NAME"; then
	die "could not stop $SERVICE_NAME"
fi

if ! backup_and_replace "$DOCKERD_SOURCE" "$INSTALLED_DOCKERD"; then
	DOCKERD_BACKUP="$LAST_BACKUP"
	die "could not replace $INSTALLED_DOCKERD"
fi
DOCKERD_BACKUP="$LAST_BACKUP"
printf 'Updated %s (backup: %s)\n' "$INSTALLED_DOCKERD" "$DOCKERD_BACKUP"

if [[ -n "$INSTALLED_PROXY" ]]; then
	if ! backup_and_replace "$DOCKER_PROXY_SOURCE" "$INSTALLED_PROXY"; then
		PROXY_BACKUP="$LAST_BACKUP"
		die "could not replace $INSTALLED_PROXY"
	fi
	PROXY_BACKUP="$LAST_BACKUP"
	printf 'Updated %s (backup: %s)\n' "$INSTALLED_PROXY" "$PROXY_BACKUP"
fi

if ! systemctl --no-pager start "$SERVICE_NAME"; then
	die "could not start $SERVICE_NAME"
fi
SERVICE_STARTED=1
if ! systemctl --quiet is-active "$SERVICE_NAME"; then
	die "$SERVICE_NAME is not active after deployment"
fi

printf 'Docker daemon version: '
"$INSTALLED_DOCKERD" --version

trap - EXIT
