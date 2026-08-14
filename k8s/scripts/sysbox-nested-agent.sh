#!/bin/sh

# Install and supervise Sysbox for a K3s node running inside a Sysbox container.
set -eu

source_bin_dir="${SYSBOX_IMAGE_BIN_DIR:-/opt/sysbox/bin/generic}"
bin_dir="${SYSBOX_INNER_BIN_DIR:-/var/lib/sysbox-inner/bin}"
launcher="${SYSBOX_INNER_LAUNCHER:-/opt/sysbox/scripts/sysbox-inner-k3s.sh}"
containerd_socket="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
runtime_name="sysbox-runc"
runtime_binary="$bin_dir/sysbox-runc-inner"
ready_label="sysbox.w7panel.io/nested-runtime"

[ -n "${NODE_NAME:-}" ] || { echo "ERROR: NODE_NAME is required" >&2; exit 1; }

mkdir -p "$bin_dir"
for binary in sysbox-runc sysbox-mgr sysbox-fs sysbox-snapshotter rsync fusermount3; do
	[ -x "$source_bin_dir/$binary" ] || { echo "ERROR: missing image binary: $binary" >&2; exit 1; }
	install -m 0755 "$source_bin_dir/$binary" "$bin_dir/.$binary.new"
	mv -f "$bin_dir/.$binary.new" "$bin_dir/$binary"
done

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
	if crictl --runtime-endpoint "unix://$containerd_socket" info 2>/dev/null |
		jq -e --arg runtime "$runtime_name" --arg binary "$runtime_binary" '
			.config.containerd.runtimes[$runtime] as $handler |
			$handler != null and
			$handler.snapshotter == "sysbox" and
			$handler.options.BinaryName == $binary
		' >/dev/null; then
		if kubectl label node "$NODE_NAME" "$ready_label=ready" --overwrite >/dev/null; then
			touch /run/sysbox/nested-runtime-ready
			wait "$launcher_pid"
			exit $?
		fi
	fi
	sleep 5
done

wait "$launcher_pid"
