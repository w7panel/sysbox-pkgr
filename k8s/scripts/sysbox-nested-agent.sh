#!/bin/sh

# Install and supervise Sysbox for a K3s node running inside a Sysbox container.
set -eu

source_bin_dir="${SYSBOX_IMAGE_BIN_DIR:-/opt/sysbox/bin/generic}"
bin_dir="${SYSBOX_INNER_BIN_DIR:-/var/lib/sysbox-inner/bin}"
launcher="${SYSBOX_INNER_LAUNCHER:-/opt/sysbox/scripts/sysbox-inner-k3s.sh}"
containerd_socket="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
mount_ns_pid="${SYSBOX_INNER_MOUNT_NS_PID:-}"
enter_pid_ns="${SYSBOX_INNER_ENTER_PID_NS:-false}"
runtime_name="sysbox-runc"
runtime_binary="$bin_dir/sysbox-runc-nested"
# CKM's bootstrap payload lives in its server container mount namespace, so a
# Chart agent must identify it by the stable wrapper basename rather than by a
# path that is only meaningful inside that other container.
bootstrap_runtime_binary="${SYSBOX_INNER_BOOTSTRAP_RUNTIME_BINARY:-sysbox-runc-nested}"
bootstrap_runtime_real="${SYSBOX_INNER_BOOTSTRAP_RUNTIME_REAL:-/proc/1/root/opt/sysbox/bin/generic/sysbox-runc.real}"
ready_label="sysbox.w7panel.io/nested-runtime"

[ -n "${NODE_NAME:-}" ] || { echo "ERROR: NODE_NAME is required" >&2; exit 1; }

cleanup_stale_launchers() {
	for proc_dir in /proc/[0-9]*; do
		pid=${proc_dir##*/}
		[ "$pid" != "$$" ] || continue
		if [ ! -r "$proc_dir/cmdline" ] || [ ! -r "$proc_dir/environ" ]; then
			continue
		fi
		cmdline=$(tr '\000' ' ' <"$proc_dir/cmdline" 2>/dev/null || true)
		case "$cmdline" in
			*"/opt/sysbox/scripts/sysbox-inner-k3s.sh"*)
				tr '\000' '\n' <"$proc_dir/environ" 2>/dev/null |
					grep -qx 'SYSBOX_INNER_KEEPALIVE=true' || continue
				echo "Stopping stale nested Sysbox launcher PID $pid" >&2
				kill -TERM "$pid" 2>/dev/null || true
				;;
		esac
	done
	# Let the launcher trap stop its managed daemons before the new launcher
	# claims the shared Sysbox sockets.
	sleep 3
}

cleanup_stale_launchers

# With hostPID=true, a nested L2 agent sees the L1 PID namespace. PID 1 is
# therefore the L1 server, while the L2 K3s container init is a child process
# (usually `/bin/k3s init`). Entering PID 1 after an L2 restart publishes the
# daemons into the wrong mount/net namespace and leaves a misleading socket.
# Resolve that child only for nested K3s; ordinary L0/L1 agents keep the
# explicit PID 1 behavior.
if [ "$mount_ns_pid" = "1" ]; then
	resolved_mount_ns_pid=
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
		for proc in /proc/[0-9]*; do
			if [ ! -r "$proc/cmdline" ] || [ ! -e "$proc/exe" ]; then
				continue
			fi
			[ "$(basename "$(readlink "$proc/exe" 2>/dev/null || true)")" = k3s ] || continue
			cmdline=$(tr '\000' ' ' <"$proc/cmdline" 2>/dev/null || true)
			case "$cmdline" in
				*"/bin/k3s init"*|*" k3s init"*|*"/bin/k3s server"*|*" k3s server"*)
					resolved_mount_ns_pid=${proc##*/}
					break 2
					;;
			esac
		done
		[ -n "$resolved_mount_ns_pid" ] && break
		sleep 1
	done
	if [ -n "$resolved_mount_ns_pid" ]; then
		mount_ns_pid=$resolved_mount_ns_pid
		enter_pid_ns=true
		export SYSBOX_INNER_MOUNT_NS_PID="$mount_ns_pid"
		export SYSBOX_INNER_ENTER_PID_NS="$enter_pid_ns"
		echo "Using nested L2 K3s mount/net namespace PID $mount_ns_pid"
	fi
fi

run_in_runtime_ns() {
	if [ -n "$mount_ns_pid" ]; then
		if [ "$enter_pid_ns" = "true" ]; then
			nsenter -m -n -p -r -t "$mount_ns_pid" -- "$@"
		else
			nsenter -m -n -t "$mount_ns_pid" -- "$@"
		fi
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

# CKM loads a stable wrapper into containerd before this Chart starts. Upgrade
# the wrapper's real binary atomically through PID 1's root so a Chart rollout
# updates future container tasks without restarting K3s/containerd.
if [ -e "$bootstrap_runtime_real" ]; then
	install -m 0755 "$source_bin_dir/sysbox-runc" "$bootstrap_runtime_real.new"
	mv -f "$bootstrap_runtime_real.new" "$bootstrap_runtime_real"
fi

runtime_loaded() {
	binary=$1
	run_in_runtime_ns crictl --runtime-endpoint "unix://$containerd_socket" info 2>/dev/null |
		jq -e --arg runtime "$runtime_name" --arg binary "$binary" '
			.config.containerd.runtimes[$runtime] as $handler |
			$handler != null and
			$handler.snapshotter == "sysbox" and
			($binary == "sysbox-runc-nested" and (($handler.options.BinaryName | endswith("/sysbox-runc-nested")) or ($handler.options.BinaryName | endswith("/sysbox-runc-inner")))) or
			($binary != "sysbox-runc-nested" and $handler.options.BinaryName == $binary)
		' >/dev/null
}

daemon_live() {
	socket=$1
	pidfile=$2
	expected=$3
	run_in_runtime_ns sh -ec '
		[ -S "$1" ] && [ -r "$2" ] || exit 1
		pid=$(cat "$2" 2>/dev/null || true)
		case "$pid" in ""|*[!0-9]*) exit 1 ;; esac
		[ -e "/proc/$pid/exe" ] || exit 1
		[ "$(basename "$(readlink "/proc/$pid/exe")" | sed "s/ (deleted)$//")" = "$3" ] || exit 1
		[ "$(readlink "/proc/$pid/ns/mnt")" = "$(readlink /proc/1/ns/mnt)" ] || exit 1
		[ "$(readlink "/proc/$pid/ns/net")" = "$(readlink /proc/1/ns/net)" ] || exit 1
		grep -Fq " $1" /proc/net/unix
	' sh "$socket" "$pidfile" "$expected"
}

snapshotter_live() {
	if [ "$enter_pid_ns" = "true" ]; then
		run_in_runtime_ns sh -ec '[ -S "$1" ] && grep -Fq " $1" /proc/net/unix' sh /run/sysbox/sysbox-snapshotter.sock || return 1
		run_in_runtime_ns /proc/1/root/bin/ctr \
			--address "$containerd_socket" snapshots --snapshotter sysbox ls >/dev/null 2>&1
		return $?
	fi
	daemon_live /run/sysbox/sysbox-snapshotter.sock /run/sysbox/sysbox-snapshotter.pid sysbox-snapshotter &&
		run_in_runtime_ns /proc/1/root/bin/ctr \
			--address "$containerd_socket" snapshots --snapshotter sysbox ls >/dev/null 2>&1
}

daemons_live() {
	daemon_live /run/sysbox/sysmgr.sock /run/sysbox/sysmgr.pid sysbox-mgr &&
		daemon_live /run/sysbox/sysfs.sock /run/sysbox/sysfs.pid sysbox-fs &&
		snapshotter_live
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
	health_failures=0
	while :; do
		if runtime_loaded "$bootstrap_runtime_binary" && daemons_live; then
			health_failures=0
			kubectl label node "$NODE_NAME" "$ready_label=ready" --overwrite >/dev/null || true
			touch /run/sysbox/nested-runtime-ready
		else
			rm -f /run/sysbox/nested-runtime-ready
			kubectl label node "$NODE_NAME" "$ready_label-" >/dev/null 2>&1 || true
			health_failures=$((health_failures + 1))
			echo "WARN: CKM-prepared Sysbox daemon health check failed ($health_failures/6)" >&2
			if [ "$health_failures" -ge 6 ]; then
				echo "ERROR: CKM-prepared Sysbox daemon health check failed repeatedly; restarting agent" >&2
				exit 1
			fi
		fi
		sleep 5
	done
	fi
fi

rm -f /run/sysbox/nested-runtime-ready
kubectl label node "$NODE_NAME" "$ready_label-" >/dev/null 2>&1 || true

launcher_pid=
launcher_pgid=
cleanup() {
	status=$?
	trap - EXIT TERM INT
	rm -f /run/sysbox/nested-runtime-ready
	kubectl label node "$NODE_NAME" "$ready_label-" >/dev/null 2>&1 || true
	if [ -n "$launcher_pgid" ]; then
		kill -TERM "-$launcher_pgid" 2>/dev/null || true
	else
		[ -z "$launcher_pid" ] || kill -TERM "$launcher_pid" 2>/dev/null || true
	fi
	[ -z "$launcher_pid" ] || wait "$launcher_pid" 2>/dev/null || true
	exit "$status"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

if command -v setsid >/dev/null 2>&1; then
	SYSBOX_INNER_BIN_DIR="$bin_dir" \
		SYSBOX_INNER_ENTER_PID_NS="$enter_pid_ns" \
		SYSBOX_INNER_KEEPALIVE=true \
		setsid "$launcher" &
	launcher_pid=$!
	launcher_pgid=$launcher_pid
else
	SYSBOX_INNER_BIN_DIR="$bin_dir" \
		SYSBOX_INNER_ENTER_PID_NS="$enter_pid_ns" \
		SYSBOX_INNER_KEEPALIVE=true \
		"$launcher" &
	launcher_pid=$!
fi

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
