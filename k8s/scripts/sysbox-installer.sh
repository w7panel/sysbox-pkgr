#!/bin/sh
set -eu

case "${SYSBOX_INSTALL_MODE:-}:${1:-}" in
  host:install)
    exec /opt/sysbox/scripts/sysbox-deploy-k8s.sh ce install \
      "--snapshotter-enabled=${SYSBOX_SNAPSHOTTER_ENABLED:-false}"
    ;;
  nested:install|nested:status|nested:uninstall)
    exec /opt/sysbox/scripts/sysbox-inner-agent.sh "$1"
    ;;
  *)
    echo "sysbox-installer: unsupported mode or action" >&2
    exit 2
    ;;
esac
