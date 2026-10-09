#!/bin/sh
# Reconcile the Sysbox runtime in a K3s node running inside a CKM container.
set -eu

host_data=${SYSBOX_INNER_HOST_DATA:-/host/var/lib/rancher/k3s}
node_data=/var/lib/rancher/k3s
agent_dir=$host_data/sysbox-inner
node_agent_dir=$node_data/sysbox-inner
template=$host_data/agent/etc/containerd/config-v3.toml.tmpl
active_config=$host_data/agent/etc/containerd/config.toml
pending=$agent_dir/restart-pending
original=$agent_dir/original-config-v3.toml.tmpl
original_absent=$agent_dir/original-config-v3.toml.tmpl.absent
image_bins=/opt/sysbox/bin/generic
image_script=/opt/sysbox/scripts/sysbox-inner-k3s.sh
target_pid=

die() { echo "sysbox-inner-agent: $*" >&2; exit 1; }
log() { echo "sysbox-inner-agent: $*" >&2; }
label_key=sysbox.w7panel.io/nested-runtime

set_node_ready() {
  [ -n "${NODE_NAME:-}" ] || return 0
  /bin/kubectl label node "$NODE_NAME" "$label_key=ready" --overwrite >/dev/null 2>&1 || \
    log "could not mark node $NODE_NAME ready"
}

clear_node_ready() {
  [ -n "${NODE_NAME:-}" ] || return 0
  /bin/kubectl label node "$NODE_NAME" "$label_key-" >/dev/null 2>&1 || true
}

# hostPID makes the CKM K3s server visible, but the agent still has its own
# mount and network namespaces. Enter all three before touching L1 /run.
find_target() {
  if [ -n "${SYSBOX_INNER_TARGET_PID:-}" ]; then
    target_pid=$SYSBOX_INNER_TARGET_PID
    [ -e "/proc/$target_pid/exe" ] || die "target PID $target_pid is gone"
    return
  fi
  for proc in /proc/[0-9]*; do
    [ -e "$proc/exe" ] || continue
    case "$(readlink "$proc/exe" 2>/dev/null || true)" in
      */k3s|*/k3s\ \(deleted\)) ;;
      *) continue ;;
    esac
    # K3s overwrites its argv with one padded string, so /proc/cmdline may
    # contain "/bin/k3s server" in argv[0] and no argv[1].
    command=$(tr '\000' '\n' <"$proc/cmdline" 2>/dev/null || true)
    first=$(printf '%s\n' "$command" | sed -n '1p')
    second=$(printf '%s\n' "$command" | sed -n '2p')
    case "$first:$second" in
      */k3s\ server*:*|*/k3s:server) ;;
      *) continue ;;
    esac
    target_pid=${proc##*/}
    return
  done
  die "cannot find the CKM K3s server process"
}

in_node() {
  nsenter -m -n -p -r -t "$target_pid" -- "$@"
}

active_has_lite() {
  [ -f "$active_config" ] || return 1
  grep -Fq 'runtimes.sysbox-runc-lite]' "$active_config" || return 1
  grep -Fq "$node_bin_dir/sysbox-runc-lite" "$active_config" || return 1
  grep -Fq 'snapshotter = "sysbox"' "$active_config" || return 1
}

status() {
  [ -r "$agent_dir/current" ] || return 1
  release=$(cat "$agent_dir/current")
  node_bin_dir=$node_agent_dir/releases/$release/bin/generic
  active_has_lite || return 1
  find_target
  in_node /bin/sh -ec '
    test -S /run/sysbox/sysbox-snapshotter.sock
    /bin/ctr --address /run/k3s/containerd/containerd.sock snapshots --snapshotter sysbox ls >/dev/null
    /bin/crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock info | grep -Fq "sysbox-runc-lite"
  ' >/dev/null 2>&1
}

stage_payload() {
  [ -x "$image_bins/sysbox-runc-lite" ] || die "missing sysbox-runc-lite in image"
  [ -x "$image_bins/sysbox-snapshotter" ] || die "missing sysbox-snapshotter in image"
  [ -r "$image_script" ] || die "missing sysbox-inner-k3s.sh in image"
  # A content-derived release directory leaves running executables intact
  # while a new image is installed. The config names the exact release.
  release=$(sha256sum "$image_bins/sysbox-runc-lite" "$image_bins/sysbox-snapshotter" \
    "$image_bins/rsync" "$image_script" | sha256sum | cut -d ' ' -f 1)
  node_bin_dir=$node_agent_dir/releases/$release/bin/generic
  release_dir=$agent_dir/releases/$release
  if [ ! -x "$release_dir/bin/generic/sysbox-runc-lite" ] || [ ! -r "$release_dir/scripts/sysbox-inner-k3s.sh" ]; then
    mkdir -p "$agent_dir/releases"
    stage=$agent_dir/releases/.stage-$$
    mkdir -p "$stage/bin/generic" "$stage/scripts"
    cp -a "$image_bins/." "$stage/bin/generic/"
    cp "$image_script" "$stage/scripts/sysbox-inner-k3s.sh"
    chmod 0755 "$stage/scripts/sysbox-inner-k3s.sh"
    if [ ! -d "$release_dir" ]; then
      mv "$stage" "$release_dir"
    else
      # A previous interrupted copy is replaced only before it is selected.
      cp -a "$stage/." "$release_dir/"
      rm -rf "$stage"
    fi
  fi
  if [ ! -f "$agent_dir/current" ] || [ "$(cat "$agent_dir/current")" != "$release" ]; then
    printf '%s\n' "$release" >"$agent_dir/current.tmp"
    mv "$agent_dir/current.tmp" "$agent_dir/current"
  fi
}

save_original() {
  [ -e "$original" ] && return
  [ -e "$original_absent" ] && return
  if [ -f "$template" ] && ! grep -Fq '# Managed by Sysbox nested runtime.' "$template"; then
    cp -p "$template" "$original"
  else
    : >"$original_absent"
  fi
}

launch_runtime() {
  find_target
  SYSBOX_INNER_BIN_DIR="$node_bin_dir" \
  SYSBOX_HELPER_DIR=/bin/aux \
  SYSBOX_INNER_START_DAEMONS=false \
  SYSBOX_INNER_CONFIG_ONLY="${1:-false}" \
  in_node /bin/sh "$node_agent_dir/releases/$release/scripts/sysbox-inner-k3s.sh"
}

request_restart() {
  desired=$(sha256sum "$template" | cut -d ' ' -f 1)
  if [ -f "$pending" ] && [ "$(cat "$pending")" = "$desired" ]; then
    log "waiting for K3s to load desired config $desired"
    return
  fi
  printf '%s\n' "$desired" >"$pending.tmp"
  mv "$pending.tmp" "$pending"
  clear_node_ready
  log "K3s config changed; requesting one CKM server restart"
  # Terminating K3s ends the CKM server command. The outer Deployment restarts
  # its Server container, and the nested DaemonSet reconciles after recovery.
  kill -TERM "$target_pid"
}

install_once() {
  mkdir -p "$agent_dir"
  stage_payload
  save_original
  if status; then
    rm -f "$pending" "$agent_dir/restart-required"
    set_node_ready
    return 0
  fi
  before=
  [ ! -f "$template" ] || before=$(sha256sum "$template" | cut -d ' ' -f 1)
  launch_runtime true
  after=$(sha256sum "$template" | cut -d ' ' -f 1)
  if active_has_lite; then
    launch_runtime false
  fi
  if status; then
    rm -f "$pending" "$agent_dir/restart-required"
    set_node_ready
    return 0
  fi
  clear_node_ready
  if [ "$before" != "$after" ] || { [ ! -f "$pending" ] && ! active_has_lite; }; then
    request_restart
  else
    log "desired template installed; waiting for K3s and snapshotter"
  fi
}

uninstall() {
  # The chart pre-delete Job checks for remaining lite Pods before calling us.
  # A failed safety check must never remove the handler under running Pods.
  [ -d "$agent_dir" ] || return 0
  find_target
  clear_node_ready
  changed=false
  if [ -f "$original" ]; then
    cp -p "$original" "$template"
    changed=true
  elif [ -f "$original_absent" ] && [ -f "$template" ] && \
       grep -Fq '# Managed by Sysbox nested runtime.' "$template"; then
    rm -f "$template"
    changed=true
  fi
  rm -f "$agent_dir/current" "$pending"
  rm -f "$host_data/agent/etc/kubelet.conf.d/99-sysbox-inner-eviction.conf"
  rm -rf "$agent_dir/releases"
  rm -f "$original" "$original_absent"
  if [ "$changed" = true ]; then
    # The pre-delete Job and Helm client run inside this K3s process. Killing
    # it here leaves the Helm release stuck in the uninstalling state.
    : >"$agent_dir/restart-required"
    log "restored the pre-Chart containerd template; restart CKM K3s after Helm uninstall completes"
  fi
}

case "${1:-}" in
  install)
    while :; do
      install_once
      sleep 10
    done
    ;;
  status) status ;;
  uninstall) uninstall ;;
  *) die "usage: $0 install|status|uninstall" ;;
esac
