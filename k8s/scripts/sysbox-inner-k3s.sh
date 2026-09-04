#!/bin/sh

# Experimental command-mode launcher for Sysbox inside a non-systemd K3s pod.
set -eu

bin_dir="${SYSBOX_INNER_BIN_DIR:-/opt/sysbox/bin/generic}"
host_root="${SYSBOX_INNER_HOST_ROOT:-/}"
mount_ns_pid="${SYSBOX_INNER_MOUNT_NS_PID:-}"
enter_pid_ns="${SYSBOX_INNER_ENTER_PID_NS:-false}"
config_template="${K3S_CONTAINERD_CONFIG_TEMPLATE:-/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl}"
data_root="${SYSBOX_INNER_DATA_ROOT:-/var/lib/rancher/k3s/sysbox-inner}"
fs_mountpoint="${SYSBOX_INNER_FS_MOUNTPOINT:-/var/lib/sysboxfs-inner}"
snapshotter_socket="${SYSBOX_INNER_SNAPSHOTTER_SOCKET:-/run/sysbox/sysbox-snapshotter.sock}"
snapshotter_root="${SYSBOX_INNER_SNAPSHOTTER_ROOT:-/var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.sysbox}"
containerd_socket="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
pause_image="${K3S_PAUSE_IMAGE:-rancher/mirrored-pause:3.6}"
log_dir="${SYSBOX_INNER_LOG_DIR:-/var/log}"
helper_dir="${SYSBOX_HELPER_DIR:-/opt/sysbox/bin/aux}"
export PATH="$helper_dir:$bin_dir:$PATH"

# A nested-agent Pod has private mount and network namespaces, while the L2
# K3s/containerd process keeps the real /run sockets and Unix-socket namespace
# in PID 1. Join both before starting or checking daemons.
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

runtime_shell() {
	if [ -n "$mount_ns_pid" ]; then
		program=$1
		shift
		if [ "$enter_pid_ns" = "true" ]; then
			nsenter -m -n -p -r -t "$mount_ns_pid" -- sh -ec "$program" sh "$@"
		else
			nsenter -m -n -t "$mount_ns_pid" -- sh -ec "$program" sh "$@"
		fi
	else
		program=$1
		shift
		sh -ec "$program" sh "$@"
	fi
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

socket_is_live() {
	socket=$1
	if [ -n "$mount_ns_pid" ]; then
		runtime_shell '[ -S "$1" ] && grep -Fq " $1" /proc/net/unix' "$socket"
	else
		[ -S "$socket" ] && grep -Fq " $socket" /proc/net/unix
	fi
}

daemon_is_live() {
	socket=$1
	pidfile=$2
	expected=$3
	runtime_shell '
		[ -S "$1" ] && [ -r "$2" ] || exit 1
		pid=$(cat "$2" 2>/dev/null || true)
		case "$pid" in ""|*[!0-9]*) exit 1 ;; esac
		[ -e "/proc/$pid/exe" ] || exit 1
		[ "$(basename "$(readlink "/proc/$pid/exe")" | sed "s/ (deleted)$//")" = "$3" ] || exit 1
		[ "$(readlink "/proc/$pid/ns/mnt")" = "$(readlink /proc/1/ns/mnt)" ] || exit 1
		[ "$(readlink "/proc/$pid/ns/net")" = "$(readlink /proc/1/ns/net)" ] || exit 1
		grep -Fq " $1" /proc/net/unix
	' "$socket" "$pidfile" "$expected"
}

# nsenter -p returns an outer (L1) PID to the launcher, while the daemon gets
# a different PID in the entered L2 PID namespace.  Find the actual daemon
# there instead of persisting the outer nsenter PID in a pidfile.
write_runtime_daemon_pid() {
	expected=$1
	pidfile=$2
	i=0
	while [ "$i" -lt 30 ]; do
		if runtime_shell '
			target_mnt=$(readlink /proc/1/ns/mnt)
			target_net=$(readlink /proc/1/ns/net)
			for proc in /proc/[0-9]*; do
				[ -e "$proc/exe" ] || continue
				[ "$(basename "$(readlink "$proc/exe" 2>/dev/null || true)" | sed "s/ (deleted)$//")" = "$1" ] || continue
				[ "$(readlink "$proc/ns/mnt" 2>/dev/null || true)" = "$target_mnt" ] || continue
				[ "$(readlink "$proc/ns/net" 2>/dev/null || true)" = "$target_net" ] || continue
				echo "${proc##*/}" >"$2"
				exit 0
			done
			exit 1
		' sh "$expected" "$pidfile"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

stop_daemon() {
	socket=$1
	pidfile=$2
	expected=$3
	runtime_shell '
		target_mnt=$(readlink /proc/1/ns/mnt)
		target_net=$(readlink /proc/1/ns/net)
		for proc in /proc/[0-9]*; do
			[ -e "$proc/exe" ] || continue
			[ "$(basename "$(readlink "$proc/exe" 2>/dev/null || true)" | sed "s/ (deleted)$//")" = "$3" ] || continue
			[ "$(readlink "$proc/ns/mnt" 2>/dev/null || true)" = "$target_mnt" ] || continue
			[ "$(readlink "$proc/ns/net" 2>/dev/null || true)" = "$target_net" ] || continue
			kill "${proc##*/}" 2>/dev/null || true
		done
		rm -f "$1" "$2"
	' "$socket" "$pidfile" "$expected"
}

snapshotter_is_live() {
	# sysbox-snapshotter has no native pidfile. In an entered PID namespace
	# the outer nsenter PID cannot be translated reliably, so use the socket
	# plus containerd RPC as the liveness contract.
	if [ "$enter_pid_ns" = "true" ]; then
		socket_is_live "$snapshotter_socket" || return 1
		run_in_runtime_ns /proc/1/root/bin/ctr \
			--address "$containerd_socket" snapshots --snapshotter sysbox ls >/dev/null 2>&1
		return $?
	fi
	daemon_is_live "$snapshotter_socket" /run/sysbox/sysbox-snapshotter.pid sysbox-snapshotter || return 1
	if socket_is_live "$containerd_socket"; then
		run_in_runtime_ns /proc/1/root/bin/ctr \
			--address "$containerd_socket" snapshots --snapshotter sysbox ls >/dev/null 2>&1
	fi
}

wait_for_socket() {
	pid=$1
	socket=$2
	log=$3
	i=0
	while [ "$i" -lt 30 ]; do
		socket_is_live "$socket" && return 0
		# When entering an L2 PID namespace, $pid is the outer nsenter
		# process and is not meaningful inside the target namespace.  The
		# socket probe remains authoritative until daemon_live validates the
		# daemon's real target-namespace PID.
		if [ "$enter_pid_ns" != "true" ]; then
			run_in_runtime_ns kill -0 "$pid" 2>/dev/null || die "Sysbox daemon exited; see $log"
		fi
		i=$((i + 1))
		sleep 1
	done
	die "timed out waiting for $socket"
}

wait_for_snapshotter() {
	pid=$1
	log=$2
	i=0
	while [ "$i" -lt 30 ]; do
		snapshotter_is_live && return 0
		if [ "$enter_pid_ns" != "true" ]; then
			run_in_runtime_ns kill -0 "$pid" 2>/dev/null || die "Sysbox snapshotter exited; see $log"
		fi
		i=$((i + 1))
		sleep 1
	done
	die "timed out waiting for $snapshotter_socket"
}

for binary in sysbox-runc sysbox-snapshotter rsync; do
	[ -x "$bin_dir/$binary" ] || die "inner K3s Sysbox binary is missing: $bin_dir/$binary"
done
[ -c /dev/fuse ] || die "inner K3s Sysbox requires a /dev/fuse device"

# The rancher/k3s image keeps its iptables and modprobe helpers under
# /bin/aux, outside PATH. CKM bootstrap images carry that directory under
# /opt/sysbox/bin/aux; retain /bin/aux as a compatibility fallback. Copy
# resolved helpers into the shared inner bin so kube-proxy and sysbox-mgr see
# stable commands in the L1 rootfs.
mkdir -p "$host_root/usr/sbin" "$host_root/usr/bin"
if [ -e "$helper_dir/modprobe" ]; then
	install -m 0755 "$(readlink -f "$helper_dir/modprobe")" "$bin_dir/kmod"
	ln -sf "$bin_dir/kmod" "$host_root/usr/sbin/modprobe"
	ln -sf "$bin_dir/kmod" "$host_root/usr/bin/modprobe"
fi
if [ -e "$helper_dir/iptables-nft" ]; then
	# Do not copy k3s' iptables-detect.sh wrapper. It rewrites links in its
	# own directory and recursively invokes itself when relocated. Install the
	# real xtables multi-call binary under each command basename instead.
	iptables_backend="$(readlink -f "$helper_dir/iptables-nft")"
	for utility in \
		iptables ip6tables iptables-restore iptables-save ip6tables-restore ip6tables-save \
		iptables-nft iptables-nft-restore iptables-nft-save \
		ip6tables-nft ip6tables-nft-restore ip6tables-nft-save \
		iptables-legacy iptables-legacy-restore iptables-legacy-save \
		ip6tables-legacy ip6tables-legacy-restore ip6tables-legacy-save; do
		[ -e "$helper_dir/$utility" ] || continue
		install -m 0755 "$iptables_backend" "$bin_dir/$utility"
		ln -sf "$bin_dir/$utility" "$host_root/usr/sbin/$utility"
		ln -sf "$bin_dir/$utility" "$host_root/usr/bin/$utility"
	done
fi
for dependency in modprobe iptables fusermount3 fuse-overlayfs; do
	command -v "$dependency" >/dev/null || die "inner K3s Sysbox requires $dependency in PATH"
done

# Minimal K3s images don't ship the generic mount helper used by containerd's
# fuse3 snapshot mounts. Translate its fixed mount-helper arguments to the
# fuse-overlayfs CLI already present in the K3s image.
if [ ! -x "$bin_dir/mount.fuse3" ]; then
	cat >"$bin_dir/mount.fuse3" <<'EOF'
#!/bin/sh
set -eu

[ "$#" -ge 2 ] || exit 1
target=$2
shift 2
options=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			[ "$#" -ge 2 ] || exit 1
			if [ -n "$options" ]; then
				options="$options,$2"
			else
				options=$2
			fi
			shift 2
			;;
		-t)
			[ "$#" -ge 2 ] || exit 1
			shift 2
			;;
		*)
			exit 1
			;;
	esac
done
[ -n "$options" ] || exit 1
exec fuse-overlayfs -o "$options" "$target"
EOF
	chmod 0755 "$bin_dir/mount.fuse3"
fi
mkdir -p "$host_root/usr/local/bin"
ln -sf "$bin_dir/mount.fuse3" "$host_root/usr/local/bin/mount.fuse3"
ln -sf "$bin_dir/rsync" "$host_root/usr/local/bin/rsync"
# The minimal K3s rootfs does not carry kmod, but sysbox-mgr's preflight
# requires modprobe to be discoverable in the runtime mount namespace. Keep a
# copy in the shared inner bin directory and expose it through both standard
# lookup locations in the L2 root.
# Persistent rootfs layers may carry an opaque /usr/local directory from an
# earlier container incarnation. Keep the host dependency visible through the
# stable /usr/bin path used by sysbox-mgr's preflight check as well.
mkdir -p "$host_root/usr/bin"
ln -sf "$bin_dir/rsync" "$host_root/usr/bin/rsync"
ln -sf "$bin_dir/mount.fuse3" "$host_root/usr/bin/mount.fuse3"

run_in_runtime_ns mkdir -p /run/sysbox "$data_root" "$fs_mountpoint" "$snapshotter_root" "$(dirname "$config_template")" "$log_dir"
# The outer PoC node can reserve a large fraction of its disk. Keep the inner
# kubelet's eviction threshold below the usable space so the nested runtime
# test is not evicted before runc is exercised.
mkdir -p /var/lib/rancher/k3s/agent/etc/kubelet.conf.d
cat >/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/99-sysbox-inner-eviction.conf <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
evictionHard:
  nodefs.available: 1Gi
  imagefs.available: 1Gi
evictionMinimumReclaim:
  nodefs.available: 1Gi
  imagefs.available: 1Gi
EOF
# rancher/k3s images expose only PRETTY_NAME in /etc/os-release. Sysbox needs
# an ID to select the generic kernel-header path.
if ! grep -q '^ID=' "$host_root/etc/os-release" 2>/dev/null; then
	mkdir -p "$host_root/usr/lib"
	echo 'ID=k3s' >"$host_root/usr/lib/os-release"
fi
# The dedicated handler and manager must agree on the explicit identity mode;
# neither component reads or modifies the outer container's subuid files. Keep
# the wrapper distinct from the unmodified image binary and expose it through
# the standard sysbox-runc handler (never a second RuntimeClass name).
if [ ! -x "$bin_dir/sysbox-runc.real" ]; then
	# Keep the canonical binary path intact. The CKM server command and
	# readiness checks use /opt/sysbox/bin/generic/sysbox-runc on every
	# restart; moving it away made a previously initialized L1 fail after
	# the first Pod restart. The nested wrapper calls this private copy.
	cp -a "$bin_dir/sysbox-runc" "$bin_dir/sysbox-runc.real"
fi
cat >"$bin_dir/sysbox-runc-nested" <<EOF
#!/bin/sh
export SYSBOX_ALLOW_PROC_EXEC=true
exec "$bin_dir/sysbox-runc.real" --mapping-mode nested-identity --log /var/log/sysbox-runc-nested.log --log-format json "\$@"
EOF
chmod 0755 "$bin_dir/sysbox-runc-nested"
cat >"$config_template" <<EOF
# Managed by Sysbox nested runtime. Remove only after the L1 Sysbox chart is uninstalled.
version = 3
imports = ["/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/*.toml"]
root = "/var/lib/rancher/k3s/agent/containerd"
state = "/run/k3s/containerd"

[proxy_plugins."sysbox"]
  type = "snapshot"
  address = "$snapshotter_socket"

[grpc]
  address = "/run/k3s/containerd/containerd.sock"

[plugins.'io.containerd.internal.v1.opt']
  path = "/var/lib/rancher/k3s/agent/containerd"

[plugins.'io.containerd.grpc.v1.cri']
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  # L3 runtimes cannot write the outer /proc/sys tree from nested userns.
  enable_unprivileged_ports = false
  enable_unprivileged_icmp = false
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = "/var/lib/rancher/k3s/data/cni"
  conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "overlayfs"
  sandbox_image = "$pause_image"
  disable_snapshot_annotations = false
  use_local_image_pull = true

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = "$pause_image"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  # Use the lightweight runtime for the default handler as well.  The
  # standard runc binary does not create /dev/ptmx in these nested rootfs
  # mounts, which makes interactive `kubectl exec -it` fail for Pods that do
  # not set runtimeClassName.  runc-lite keeps the normal runc handler name
  # while providing the required tty setup.

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false
  BinaryName = "$bin_dir/runc-lite"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.sysbox-runc]
  runtime_type = "io.containerd.runc.v2"
  snapshotter = "sysbox"
  pod_annotations = ["sysbox/rootfs-rw-layer", "sysbox/volume-init", "sysbox/skip-special-mounts", "sysbox/allow-proc-exec"]
  container_annotations = ["sysbox/rootfs-rw-layer", "sysbox/skip-special-mounts", "sysbox/allow-proc-exec"]

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.sysbox-runc.options]
  SystemdCgroup = false
  BinaryName = "$bin_dir/sysbox-runc-nested"

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
EOF

managed_pids=
managed_sockets=
start_full_daemons="${SYSBOX_INNER_START_DAEMONS:-true}"
if [ "$start_full_daemons" = "true" ]; then
	if ! daemon_is_live /run/sysbox/sysmgr.sock /run/sysbox/sysmgr.pid sysbox-mgr; then
		stop_daemon /run/sysbox/sysmgr.sock /run/sysbox/sysmgr.pid sysbox-mgr
	fi
	if ! daemon_is_live /run/sysbox/sysfs.sock /run/sysbox/sysfs.pid sysbox-fs; then
		stop_daemon /run/sysbox/sysfs.sock /run/sysbox/sysfs.pid sysbox-fs
	fi
fi
if ! snapshotter_is_live; then
	stop_daemon "$snapshotter_socket" /run/sysbox/sysbox-snapshotter.pid sysbox-snapshotter
fi
if ! daemon_is_live /run/sysbox/sysmgr.sock /run/sysbox/sysmgr.pid sysbox-mgr; then
	if [ "$start_full_daemons" != "true" ]; then
		:
	else
	run_in_runtime_ns "$bin_dir/sysbox-mgr" --mapping-mode nested-identity --disable-inner-image-preload --disable-idmapped-mount --disable-ovfs-on-idmapped-mount --data-root "$data_root" >"$log_dir/sysbox-mgr.log" 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets /run/sysbox/sysmgr.sock"
	wait_for_socket "$pid" /run/sysbox/sysmgr.sock "$log_dir/sysbox-mgr.log"
	fi
fi
if ! daemon_is_live /run/sysbox/sysfs.sock /run/sysbox/sysfs.pid sysbox-fs; then
	if [ "$start_full_daemons" != "true" ]; then
		:
	else
	run_in_runtime_ns "$bin_dir/sysbox-fs" --mountpoint "$fs_mountpoint" >"$log_dir/sysbox-fs.log" 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets /run/sysbox/sysfs.sock"
	wait_for_socket "$pid" /run/sysbox/sysfs.sock "$log_dir/sysbox-fs.log"
	fi
fi
if ! snapshotter_is_live; then
	start_snapshotter() {
		# Replace the launcher shell with the real process. This is important
		# when containerd is still booting: the pidfile is written before the
		# socket appears, so the PID must remain the snapshotter PID after the
		# wait rather than a short-lived helper shell.
		if [ -n "$mount_ns_pid" ]; then
			if [ "$enter_pid_ns" = "true" ]; then
				exec nsenter -m -n -p -r -t "$mount_ns_pid" -- \
					"$bin_dir/sysbox-snapshotter" --socket "$snapshotter_socket" \
					--root "$snapshotter_root" --containerd-socket "$containerd_socket"
			else
				exec nsenter -m -n -t "$mount_ns_pid" -- \
					"$bin_dir/sysbox-snapshotter" --socket "$snapshotter_socket" \
					--root "$snapshotter_root" --containerd-socket "$containerd_socket"
			fi
		else
			exec "$bin_dir/sysbox-snapshotter" --socket "$snapshotter_socket" \
			--root "$snapshotter_root" --containerd-socket "$containerd_socket"
		fi
	}
	# K3s creates its containerd socket only after this launcher returns. Start
	# the snapshotter in the background in that first-boot path; on subsequent
	# invocations (for example the standalone nested Chart agent) it starts
	# immediately and is checked before returning.
	if ! socket_is_live "$containerd_socket"; then
		(
			i=0
			while [ "$i" -lt 120 ] && ! socket_is_live "$containerd_socket"; do
				i=$((i + 1))
				sleep 1
			done
			socket_is_live "$containerd_socket" || exit 1
			start_snapshotter
		) >"$log_dir/sysbox-snapshotter.log" 2>&1 &
	else
		start_snapshotter >"$log_dir/sysbox-snapshotter.log" 2>&1 &
	fi
	pid=$!
	# The socket/RPC probe above is authoritative for snapshotter; do not write
	# the L1 nsenter PID into an L2 pidfile.
	write_runtime_daemon_pid sysbox-snapshotter /run/sysbox/sysbox-snapshotter.pid || true
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets $snapshotter_socket"
	if socket_is_live "$containerd_socket"; then
		wait_for_snapshotter "$pid" "$log_dir/sysbox-snapshotter.log"
	fi
fi

if [ "${SYSBOX_INNER_KEEPALIVE:-false}" = "true" ]; then
	cleanup() {
		status=$?
		trap - EXIT TERM INT
		for pid in $managed_pids; do
			kill "$pid" 2>/dev/null || true
		done
		wait 2>/dev/null || true
		for socket in $managed_sockets; do
			runtime_shell 'rm -f "$1"' "$socket"
		done
		runtime_shell 'rm -f "$1"' /run/sysbox/sysbox-snapshotter.pid
		exit "$status"
	}
	trap cleanup EXIT
	trap 'exit 0' TERM INT
	health_failures=0
	while :; do
		health_ok=true
		for pid in $managed_pids; do
			kill -0 "$pid" 2>/dev/null || health_ok=false
		done
		daemon_is_live /run/sysbox/sysmgr.sock /run/sysbox/sysmgr.pid sysbox-mgr || health_ok=false
		daemon_is_live /run/sysbox/sysfs.sock /run/sysbox/sysfs.pid sysbox-fs || health_ok=false
		snapshotter_is_live || health_ok=false
		if [ "$health_ok" = true ]; then
			health_failures=0
		else
			health_failures=$((health_failures + 1))
			echo "WARN: nested Sysbox daemon health check failed ($health_failures/6)" >&2
			[ "$health_failures" -lt 6 ] || die "nested Sysbox daemon health check failed repeatedly"
		fi
		sleep 5 &
		wait $!
	done
fi
