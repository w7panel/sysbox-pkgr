#!/bin/sh

# Experimental command-mode launcher for Sysbox inside a non-systemd K3s pod.
set -eu

bin_dir="${SYSBOX_INNER_BIN_DIR:-/opt/sysbox/bin/generic}"
config_template="${K3S_CONTAINERD_CONFIG_TEMPLATE:-/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl}"
data_root="${SYSBOX_INNER_DATA_ROOT:-/var/lib/rancher/k3s/sysbox-inner}"
fs_mountpoint="${SYSBOX_INNER_FS_MOUNTPOINT:-/var/lib/sysboxfs-inner}"
snapshotter_socket="${SYSBOX_INNER_SNAPSHOTTER_SOCKET:-/run/sysbox-snapshotter.sock}"
snapshotter_root="${SYSBOX_INNER_SNAPSHOTTER_ROOT:-/var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.sysbox}"
containerd_socket="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
pause_image="${K3S_PAUSE_IMAGE:-rancher/mirrored-pause:3.6}"
PATH="$bin_dir:$PATH"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

wait_for_socket() {
	pid=$1
	socket=$2
	log=$3
	i=0
	while [ "$i" -lt 30 ]; do
		[ -S "$socket" ] && return 0
		kill -0 "$pid" 2>/dev/null || die "Sysbox daemon exited; see $log"
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
mkdir -p /usr/local/bin
ln -sf "$bin_dir/mount.fuse3" /usr/local/bin/mount.fuse3

mkdir -p /run/sysbox "$data_root" "$fs_mountpoint" "$snapshotter_root" "$(dirname "$config_template")"
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
if ! grep -q '^ID=' /etc/os-release 2>/dev/null; then
	mkdir -p /usr/lib
	echo 'ID=k3s' >/usr/lib/os-release
fi
# The dedicated handler and manager must agree on the explicit identity mode;
# neither component reads or modifies the outer container's subuid files.
cat >"$bin_dir/sysbox-runc-inner" <<EOF
#!/bin/sh
export SYSBOX_ALLOW_PROC_EXEC=true
exec "$bin_dir/sysbox-runc" --mapping-mode nested-identity --log /var/log/sysbox-runc-inner.log --log-format json "\$@"
EOF
chmod 0755 "$bin_dir/sysbox-runc-inner"
cat >"$config_template" <<EOF
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
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
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
  BinaryName = "$bin_dir/sysbox-runc-inner"

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
EOF

if [ "${SYSBOX_INNER_START_DAEMONS:-true}" != "true" ]; then
	exit 0
fi

managed_pids=
managed_sockets=
if [ ! -S /run/sysbox/sysmgr.sock ]; then
	"$bin_dir/sysbox-mgr" --mapping-mode nested-identity --disable-inner-image-preload --disable-idmapped-mount --disable-ovfs-on-idmapped-mount --data-root "$data_root" >/var/log/sysbox-mgr.log 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets /run/sysbox/sysmgr.sock"
	wait_for_socket "$pid" /run/sysbox/sysmgr.sock /var/log/sysbox-mgr.log
fi
if [ ! -S /run/sysbox/sysfs.sock ]; then
	"$bin_dir/sysbox-fs" --mountpoint "$fs_mountpoint" >/var/log/sysbox-fs.log 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets /run/sysbox/sysfs.sock"
	wait_for_socket "$pid" /run/sysbox/sysfs.sock /var/log/sysbox-fs.log
fi
if [ ! -S "$snapshotter_socket" ]; then
	"$bin_dir/sysbox-snapshotter" --socket "$snapshotter_socket" --root "$snapshotter_root" --containerd-socket "$containerd_socket" >/var/log/sysbox-snapshotter.log 2>&1 &
	pid=$!
	managed_pids="$managed_pids $pid"
	managed_sockets="$managed_sockets $snapshotter_socket"
	wait_for_socket "$pid" "$snapshotter_socket" /var/log/sysbox-snapshotter.log
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
		sleep 5 &
		wait $!
	done
fi
