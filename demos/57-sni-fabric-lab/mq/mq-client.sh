#!/bin/bash
# A native IBM MQ client (the MQ samples amqsputc / amqsgetc) connecting to QM1 through
# Envoy's shared SNI port, the way an application outside the cluster would.
#
# Usage (inside the mq-client container): mq-client.sh [hostname|channel|nocert|-h|--help]
# Run it with: podman compose run --rm mq-client [mode]   (the default mode is hostname)
#   hostname  OutboundSNI=HOSTNAME with a client certificate: must put and get (the design)
#   channel   MQ's default SNI, built from the channel name: Envoy has no chain for it, so the
#             connection must be refused
#   nocert    no client certificate: QM1 requires one (SSLCAUTH REQUIRED), so it must refuse
# Exits 0 when the outcome matches what the mode expects.
set -euo pipefail

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
mode="${1:-hostname}"
case "${mode}" in
  hostname|channel|nocert) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "mq-client: unknown mode: ${mode}" >&2; exit 1 ;;
esac
readonly QUEUE="DEV.QUEUE.2"
readonly P12="/tls/mq-client/tls.p12"
readonly P12_PASSWORD="fabric-lab"
password="$(cat /secrets/mq-client/mq-app-password)"
work="$(mktemp -d)"

# Builds the client's GSKit keystore from the PEM-derived PKCS#12 (gen-certs.sh), or a
# keystore holding only the CA when there should be no client certificate.
# The keystore's own password is random and stashed beside it; nothing else needs it.
runmqakm -keydb -create -db "${work}/client.kdb" -pw "kdb-${RANDOM}${RANDOM}" -type cms -stash >/dev/null
if [ "${mode}" = "nocert" ]; then
  runmqakm -cert -add -db "${work}/client.kdb" -stashed -file /tls/ca/ca.crt -label fabric-ca >/dev/null
else
  runmqakm -cert -import -file "${P12}" -pw "${P12_PASSWORD}" -type pkcs12 \
    -target "${work}/client.kdb" -target_stashed -target_type cms >/dev/null
fi

sni="HOSTNAME"
[ "${mode}" = "channel" ] && sni="CHANNEL"
cat > "${work}/mqclient.ini" <<EOF
CHANNELS:
   ChannelDefinitionDirectory=/mq
   ChannelDefinitionFile=ccdt.json
SSL:
   SSLKeyRepository=${work}/client
   CertificateLabel=mq-client
   OutboundSNI=${sni}
EOF
export MQCLNTCF="${work}/mqclient.ini"
export MQSAMP_USER_ID="app"

echo "mode=${mode} OutboundSNI=${sni} -> qm1.fabric.localtest.me:10443 (Envoy edge_sni) -> QM1"
stamp="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
# amqsputc reads the password first, then one message per line until an empty line.
put_out="$(printf '%s\nfabric %s one\nfabric %s two\n\n' "${password}" "${stamp}" "${stamp}" \
  | /opt/mqm/samp/bin/amqsputc "${QUEUE}" QM1 2>&1 || true)"
# The samples print their password prompt on the same line as their first output: strip it.
echo "${put_out}" | sed -e 's/Enter password: //' -e 's/^/  put: /'

if [ "${mode}" != "hostname" ]; then
  if echo "${put_out}" | grep -q -E 'MQCONNX ended with reason code (2059|2393|2397|2538|2009)'; then
    echo "RESULT ok: refused as expected for mode ${mode}"
    exit 0
  fi
  echo "RESULT FAIL: mode ${mode} should have been refused"
  exit 1
fi

# amqsgetc reads the password, then waits 15 s for messages after the last one.
get_out="$(printf '%s\n' "${password}" | /opt/mqm/samp/bin/amqsgetc "${QUEUE}" QM1 2>&1 || true)"
echo "${get_out}" | sed -e 's/Enter password: //' -e 's/^/  get: /'
got="$(echo "${get_out}" | grep -c "fabric ${stamp}" || true)"
if [ "${got}" -eq 2 ]; then
  echo "RESULT ok: both messages put and got back through Envoy with OutboundSNI=HOSTNAME"
  exit 0
fi
echo "RESULT FAIL: expected 2 messages back, got ${got}"
exit 1
