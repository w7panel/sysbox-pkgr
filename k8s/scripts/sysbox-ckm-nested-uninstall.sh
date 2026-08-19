#!/bin/sh

# Remove only state written by CKM's pre-start nested-runtime bootstrap. The
# independently installed w7panel-sysbox Chart owns its Kubernetes resources
# and must be uninstalled separately before disabling innerSysbox on a CKM.
set -eu

template="${K3S_CONTAINERD_CONFIG_TEMPLATE:-/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl}"

if [ -f "$template" ] && \
	grep -Fq '# Managed by Sysbox nested runtime.' "$template" && \
	grep -Fq 'runtimes.sysbox-runc' "$template"; then
	rm -f "$template"
else
	echo "not removing unmanaged containerd template: $template" >&2
fi

rm -f /run/sysbox/nested-runtime-ready \
	/run/sysbox/sysmgr.sock \
	/run/sysbox/sysfs.sock \
	/run/sysbox/sysbox-snapshotter.sock
rm -rf /var/lib/rancher/k3s/sysbox-inner /var/lib/sysbox-inner /var/lib/sysboxfs-inner
rm -f /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/99-sysbox-inner-eviction.conf
