#!/bin/sh
# Render ${FABRIC_BGP_PASSWORD} from the environment into /etc/frr/frr.conf,
# then exec the image's docker-start. Loopbacks are NOT set here: zebra
# applies `interface lo` / `ip address` from frr.conf so the /32, the
# `network` statement and `bgp router-id` stay one file (no race with
# zebra, no second source of truth).
set -eu
tmpl=/etc/frr/frr.conf.tmpl
out=/etc/frr/frr.conf
pw=${FABRIC_BGP_PASSWORD:-lab-bgp}
if [ ! -f "$tmpl" ]; then
  echo "fabric-entrypoint: missing $tmpl" >&2
  exit 1
fi
python3 -c '
import os, pathlib, sys
src, dst, pw = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(src).read_text()
pathlib.Path(dst).write_text(text.replace("${FABRIC_BGP_PASSWORD}", pw))
os.chown(dst, 100, 101)
os.chmod(dst, 0o640)
' "$tmpl" "$out" "$pw"
exec /usr/lib/frr/docker-start
