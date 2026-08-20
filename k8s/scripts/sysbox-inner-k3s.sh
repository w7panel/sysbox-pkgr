#!/bin/sh

# Experimental command-mode launcher for Sysbox inside a non-systemd K3s pod.
set -eu

bin_dir="${SYSBOX_INNER_BIN_DIR:-/opt/sysbox/bin/generic}"
host_root="${SYSBOX_INNER_HOST_ROOT:-/}"
mount_ns_pid="${SYSBOX_INNER_MOUNT_NS_PID:-}"
config_template="${K3S_CONTAINERD_CONFIG_TEMPLATE:-/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl}"
data_root="${SYSBOX_INNER_DATA_ROOT:-/var/lib/rancher/k3s/sysbox-inner}"
fs_mountpoint="${SYSBOX_INNER_FS_MOUNTPOINT:-/var/lib/sysboxfs-inner}"
snapshotter_socket="${SYSBOX_INNER_SNAPSHOTTER_SOCKET:-/run/sysbox/sysbox-snapshotter.sock}"
snapshotter_root="${SYSBOX_INNER_SNAPSHOTTER_ROOT:-/var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.sysbox}"
containerd_socket="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
pause_image="${K3S_PAUSE_IMAGE:-rancher/mirrored-pause:3.6}"
log_dir="${SYSBOX_INNER_LOG_DIR:-/var/log}"
PATH="$bin_dir:$PATH"

# A nested-agent Pod has its own mount namespace, while the L2 K3s/containerd
# process keeps the real /run/k3s and /run/sysbox mounts in PID 1's namespace.
# Running the daemons in that namespace makes their Unix sockets visible to
# the containerd that consumes them. The default remains the historical local
# namespace for standalone launcher use.
run_in_runtime_ns() {
	if [ -n "$mount_ns_pid" ]; then
		nsenter -m -t "$mount_ns_pid" -- "$@"
	else
		"$@"
	fi
}

runtime_shell() {
	if [ -n "$mount_ns_pid" ]; then
		program=$1
		shift
		nsenter -m -t "$mount_ns_pid" -- sh -ec "$program" sh "$@"
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
		runtime_shell '[ -S "$1" ]' "$socket"
	else
		[ -S "$socket" ] && grep -Fq " $socket" /proc/net/unix
	fi
}

remove_stale_socket() {
	socket=$1
	if [ -n "$mount_ns_pid" ]; then
		runtime_shell 'if [ -e "$1" ] && [ ! -S "$1" ]; then exit 42; fi; case "$1" in */sysmgr.sock) pidfile=/run/sysbox/sysmgr.pid ;; */sysfs.sock) pidfile=/run/sysbox/sysfs.pid ;; *) pidfile= ;; esac; if [ -n "$pidfile" ]; then pid=$(cat "$pidfile" 2>/dev/null || true); case "$pid" in ""|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac; rm -f "$1" "$pidfile"; fi' "$socket" || {
			[ "$?" -eq 42 ] || die "refusing to replace non-socket path: $socket"
		}
		return 0
	fi
	if [ -e "$socket" ] && [ ! -S "$socket" ]; then
		die "refusing to replace non-socket path: $socket"
	fi
	if [ -S "$socket" ] && ! socket_is_live "$socket"; then
		rm -f "$socket"
	fi
}

remove_stale_pidfile() {
	pidfile=$1
	if [ -n "$mount_ns_pid" ]; then
		runtime_shell 'if [ -f "$1" ]; then pid=$(cat "$1" 2>/dev/null || true); case "$pid" in ""|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac; rm -f "$1"; fi' "$pidfile"
		return 0
	fi
	if [ -f "$pidfile" ]; then
		pid=$(cat "$pidfile" 2>/dev/null || true)
		case "$pid" in
			''|*[!0-9]*) ;;
			*)
				# A daemon from a previous workload restart can survive in the
				# pod sandbox PID namespace while its socket is already gone.
				kill "$pid" 2>/dev/null || true
				;;
		esac
		rm -f "$pidfile"
	fi
}

wait_for_socket() {
	pid=$1
	socket=$2
	log=$3
	i=0
	while [ "$i" -lt 30 ]; do
		socket_is_live "$socket" && return 0
		run_in_runtime_ns kill -0 "$pid" 2>/dev/null || die "Sysbox daemon exited; see $log"
		i=$((i + 1))
		sleep 1
	done
	die "timed out waiting for $socket"
}

for binary in sysbox-runc sysbox-mgr sysbox-fs sysbox-snapshotter rsync; do
	[ -x "$bin_dir/$binary" ] || die "inner K3s Sysbox binary is missing: $bin_dir/$binary"
done
[ -c /dev/fuse ] || die "inner K3s Sysbox requires a /dev/fuse device"
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
if command -v modprobe >/dev/null 2>&1; then
	install -m 0755 "$(readlink -f "$(command -v modprobe)")" "$bin_dir/kmod"
	mkdir -p "$host_root/usr/sbin" "$host_root/usr/bin"
	ln -sf "$bin_dir/kmod" "$host_root/usr/sbin/modprobe"
	ln -sf "$bin_dir/kmod" "$host_root/usr/bin/modprobe"
fi
if command -v iptables >/dev/null 2>&1; then
	iptables_multi=$(readlink -f "$(command -v iptables)")
	install -m 0755 "$iptables_multi" "$bin_dir/xtables-multi"
	mkdir -p "$host_root/usr/sbin" "$host_root/usr/bin"
	for utility in iptables ip6tables iptables-restore iptables-save ip6tables-restore ip6tables-save; do
		ln -sf "$bin_dir/xtables-multi" "$host_root/usr/sbin/$utility"
	done
fi
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

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false

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

if [ "${SYSBOX_INNER_START_DAEMONS:-true}" != "true" ]; then
	exit 0
fi

managed_pids=
managed_sockets=
required_sockets="/run/sysbox/sysmgr.sock /run/sysbox/sysfs.sock $snapshotter_socket"
for socket in $required_sockets; do
	remove_stale_socket "$socket"
done
if ! socket_is_live /run/sysbox/sysmgr.sock; then
	remove_stale_pidfile /run/sysbox/sysmgr.pid
fi
if ! socket_is_live /run/sysbox/sysfs.sock; then
	remove_stale_pidfile /run/sysbox/sysfs.pid
fi
if ! socket_is_live /run/sysbox/sysmgr.sock; then
	run_in_runtime_ns "$bin_dir/sysbox-mgr" --mapping-mode nested-identity --disable-inner-image-preload --disable-idmapped-mount --disable-ovfs-on-idmapped-mount --data-root "$data_root" >"$log_dir/sysbox-mgr.log" 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets /run/sysbox/sysmgr.sock"
	wait_for_socket "$pid" /run/sysbox/sysmgr.sock "$log_dir/sysbox-mgr.log"
fi
if ! socket_is_live /run/sysbox/sysfs.sock; then
	run_in_runtime_ns "$bin_dir/sysbox-fs" --mountpoint "$fs_mountpoint" >"$log_dir/sysbox-fs.log" 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets /run/sysbox/sysfs.sock"
	wait_for_socket "$pid" /run/sysbox/sysfs.sock "$log_dir/sysbox-fs.log"
fi
if ! socket_is_live "$snapshotter_socket"; then
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
			run_in_runtime_ns "$bin_dir/sysbox-snapshotter" --socket "$snapshotter_socket" --root "$snapshotter_root" --containerd-socket "$containerd_socket"
		) >"$log_dir/sysbox-snapshotter.log" 2>&1 &
	else
		run_in_runtime_ns "$bin_dir/sysbox-snapshotter" --socket "$snapshotter_socket" --root "$snapshotter_root" --containerd-socket "$containerd_socket" >"$log_dir/sysbox-snapshotter.log" 2>&1 &
	fi
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets $snapshotter_socket"
	if socket_is_live "$containerd_socket"; then
		wait_for_socket "$pid" "$snapshotter_socket" "$log_dir/sysbox-snapshotter.log"
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
			rm -f "$socket"
		done
		exit "$status"
	}
	trap cleanup EXIT
	trap 'exit 0' TERM INT
	while :; do
		for pid in $managed_pids; do
			kill -0 "$pid" 2>/dev/null || die "managed Sysbox daemon exited"
		done
		for socket in $required_sockets; do
			socket_is_live "$socket" || die "Sysbox daemon socket is not live: $socket"
		done
		sleep 5 &
		wait $!
	done
fi
