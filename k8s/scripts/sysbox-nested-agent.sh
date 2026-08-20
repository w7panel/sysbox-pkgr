#!/bin/sh

# Install and supervise Sysbox for a K3s node running inside a Sysbox container.
set -eu

source_bin_dir="${SYSBOX_IMAGE_BIN_DIR:-/opt/sysbox/bin/generic}"
bin_dir="${SYSBOX_INNER_BIN_DIR:-/var/lib/sysbox-inner/bin}"
launcher="${SYSBOX_INNER_LAUNCHER:-/opt/sysbox/scripts/sysbox-inner-k3s.sh}"
containerd_socket="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
mount_ns_pid="${SYSBOX_INNER_MOUNT_NS_PID:-}"
runtime_name="sysbox-runc"
runtime_binary="$bin_dir/sysbox-runc-nested"
# CKM's bootstrap payload lives in its server container mount namespace, so a
# Chart agent must identify it by the stable wrapper basename rather than by a
# path that is only meaningful inside that other container.
bootstrap_runtime_binary="${SYSBOX_INNER_BOOTSTRAP_RUNTIME_BINARY:-sysbox-runc-nested}"
ready_label="sysbox.w7panel.io/nested-runtime"

[ -n "${NODE_NAME:-}" ] || { echo "ERROR: NODE_NAME is required" >&2; exit 1; }

run_in_runtime_ns() {
	if [ -n "$mount_ns_pid" ]; then
		nsenter -m -t "$mount_ns_pid" -- "$@"
	else
		"$@"
	fi
}

mkdir -p "$bin_dir"
for binary in sysbox-runc sysbox-mgr sysbox-fs sysbox-snapshotter rsync fusermount3; do
	[ -x "$source_bin_dir/$binary" ] || { echo "ERROR: missing image binary: $binary" >&2; exit 1; }
	install -m 0755 "$source_bin_dir/$binary" "$bin_dir/.$binary.new"
	mv -f "$bin_dir/.$binary.new" "$bin_dir/$binary"
done

runtime_loaded() {
	binary=$1
	run_in_runtime_ns crictl --runtime-endpoint "unix://$containerd_socket" info 2>/dev/null |
		jq -e --arg runtime "$runtime_name" --arg binary "$binary" '
			.config.containerd.runtimes[$runtime] as $handler |
			$handler != null and
			$handler.snapshotter == "sysbox" and
			($binary == "sysbox-runc-nested" and ($handler.options.BinaryName | endswith("/sysbox-runc-nested"))) or
			($binary != "sysbox-runc-nested" and $handler.options.BinaryName == $binary)
		' >/dev/null
}

socket_live() {
	socket=$1
	if [ -n "$mount_ns_pid" ]; then
		run_in_runtime_ns sh -ec '[ -S "$1" ]' sh "$socket"
	else
		[ -S "$socket" ] && grep -Fq " $socket" /proc/net/unix
	fi
}

daemons_live() {
	socket_live /run/sysbox/sysmgr.sock &&
		socket_live /run/sysbox/sysfs.sock &&
		socket_live /run/sysbox/sysbox-snapshotter.sock
}

# CKM prepares the handler before K3s starts. In that normal path this Chart
# owns the RuntimeClass and readiness label but must not rewrite containerd's
# already-loaded config or start a second manager/fs/snapshotter set. The
# fallback below remains for manually migrating an existing L1 K3s node.
handler_binary="$runtime_binary"
if runtime_loaded "$bootstrap_runtime_binary"; then
	handler_binary="$bootstrap_runtime_binary"
	if daemons_live; then
	echo "Using CKM-prepared nested sysbox-runc handler: $bootstrap_runtime_binary"
	while :; do
		if runtime_loaded "$bootstrap_runtime_binary" && daemons_live; then
			kubectl label node "$NODE_NAME" "$ready_label=ready" --overwrite >/dev/null || true
			touch /run/sysbox/nested-runtime-ready
		else
			rm -f /run/sysbox/nested-runtime-ready
			kubectl label node "$NODE_NAME" "$ready_label-" >/dev/null 2>&1 || true
		fi
		sleep 5
	done
	fi
fi

rm -f /run/sysbox/nested-runtime-ready
kubectl label node "$NODE_NAME" "$ready_label-" >/dev/null 2>&1 || true

launcher_pid=
cleanup() {
	status=$?
	trap - EXIT TERM INT
	rm -f /run/sysbox/nested-runtime-ready
	kubectl label node "$NODE_NAME" "$ready_label-" >/dev/null 2>&1 || true
	[ -z "$launcher_pid" ] || kill "$launcher_pid" 2>/dev/null || true
	[ -z "$launcher_pid" ] || wait "$launcher_pid" 2>/dev/null || true
	exit "$status"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

SYSBOX_INNER_BIN_DIR="$bin_dir" \
	SYSBOX_INNER_KEEPALIVE=true \
	"$launcher" &
launcher_pid=$!

echo "Waiting for K3s containerd to load $runtime_name with BinaryName=$runtime_binary and snapshotter=sysbox; for first-time migration, roll-recreate the L1 K3s Pod from L0 (no physical-host reboot)."
while kill -0 "$launcher_pid" 2>/dev/null; do
	if runtime_loaded "$handler_binary"; then
		if kubectl label node "$NODE_NAME" "$ready_label=ready" --overwrite >/dev/null; then
			touch /run/sysbox/nested-runtime-ready
			wait "$launcher_pid"
			exit $?
		fi
	fi
	sleep 5
done

wait "$launcher_pid"
