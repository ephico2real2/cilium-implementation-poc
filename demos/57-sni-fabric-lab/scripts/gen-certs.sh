#!/usr/bin/env bash
# Generate the lab's private CA and one TLS identity per component.
#
# Each component gets a folder with tls.crt, tls.key and ca.crt: the keys a cert-manager
# Certificate writes into its Secret, and the files the IBM MQ container reads from
# /etc/mqm/pki/keys/<label>/. The same folders therefore work on Compose today and map
# one-to-one onto Kubernetes Secrets later (docs/kubernetes-certs.md).
#
# Usage: scripts/gen-certs.sh [--force] [--out DIR] [-h|--help]
#   --force      regenerate the CA and every certificate
#   --out DIR    output directory (default: <demo>/certs, which git ignores)
#   -h, --help   print this help
# Environment: OPENSSL=<path> picks the openssl binary (OpenSSL 3 or later; not LibreSSL).
#
# Re-running is safe: the CA is kept, and a component's certificate is only reissued when
# it is missing, not signed by the current CA, has different names, or expires within 30 days.
set -euo pipefail
umask 077

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEMO_DIR
readonly DOMAIN="fabric.localtest.me"
readonly CA_DAYS=3650
# 397 days stays inside the shortest validity limit browsers apply to TLS server certificates.
readonly LEAF_DAYS=397
readonly RENEW_WITHIN_SECONDS=$((30 * 24 * 3600))
# Components that also need a PKCS#12 bundle (tls.p12): the MQ client imports it into its
# GSKit keystore, as cert-manager's spec.keystores.pkcs12 would provide it on Kubernetes.
readonly P12_COMPONENTS="mq-client"
# The bundle sits beside tls.key with the same 600 mode, so its password protects nothing
# extra; it is fixed and documented rather than another secret to distribute.
readonly P12_PASSWORD="fabric-lab"

# name | extended key usage | DNS names (comma-separated)
# mq serves both the MQ listener and its web console, so one identity carries both names.
readonly COMPONENTS="
web|serverAuth|web.${DOMAIN}
orders-api|serverAuth|api.${DOMAIN}
tcp-svc|serverAuth|tcp.${DOMAIN}
mq|serverAuth,clientAuth|qm1.${DOMAIN},mqconsole.${DOMAIN}
mq-client|clientAuth|mq-client.${DOMAIN}
"

OUT_DIR="${DEMO_DIR}/certs"
FORCE=0
OPENSSL="${OPENSSL:-openssl}"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { echo "gen-certs: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; OUT_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# macOS ships LibreSSL as /usr/bin/openssl; its flags differ, so require OpenSSL 3 or later.
case "$("${OPENSSL}" version 2>/dev/null)" in
  "OpenSSL 3."*|"OpenSSL 4."*) ;;
  *) die "need OpenSSL 3 or later, found '$("${OPENSSL}" version 2>&1)'. On macOS: brew install openssl, or set OPENSSL=/opt/homebrew/bin/openssl" ;;
esac

readonly CA_DIR="${OUT_DIR}/ca"
readonly CA_CRT="${CA_DIR}/ca.crt"
readonly CA_KEY="${CA_DIR}/ca.key"

random_serial() { echo "0x$("${OPENSSL}" rand -hex 16)"; }

# The DNS names in a certificate, sorted and comma-separated, for comparison.
cert_dns_names() {
  "${OPENSSL}" x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' | sed -n 's/^ *DNS://p' | sort | paste -sd, -
}

pubkey_of_cert() { "${OPENSSL}" x509 -in "$1" -noout -pubkey; }
pubkey_of_key() { "${OPENSSL}" pkey -in "$1" -pubout; }

make_ca() {
  mkdir -p "${CA_DIR}"
  "${OPENSSL}" genrsa -traditional -out "${CA_KEY}" 3072 2>/dev/null
  "${OPENSSL}" req -x509 -new -key "${CA_KEY}" -sha256 -days "${CA_DAYS}" \
    -subj "/O=SNI Fabric Lab/CN=SNI Fabric Lab Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "${CA_CRT}"
  chmod 644 "${CA_CRT}"
  echo "created CA        ${CA_CRT}"
}

# Prints the reason a component's certificate must be (re)issued, or nothing if it is current.
reissue_reason() {
  local dir="$1" want_names="$2"
  [ -s "${dir}/tls.crt" ] && [ -s "${dir}/tls.key" ] || { echo "missing"; return; }
  "${OPENSSL}" verify -CAfile "${CA_CRT}" "${dir}/tls.crt" >/dev/null 2>&1 || { echo "not signed by the current CA"; return; }
  [ "$(cert_dns_names "${dir}/tls.crt")" = "${want_names}" ] || { echo "names changed"; return; }
  "${OPENSSL}" x509 -in "${dir}/tls.crt" -noout -checkend "${RENEW_WITHIN_SECONDS}" >/dev/null || { echo "expires within 30 days"; return; }
  [ "$(pubkey_of_cert "${dir}/tls.crt")" = "$(pubkey_of_key "${dir}/tls.key")" ] || { echo "key does not match"; return; }
}

issue() {
  local name="$1" eku="$2" names="$3"
  local dir="${OUT_DIR}/${name}" san="" n
  mkdir -p "${dir}"
  for n in $(echo "${names}" | tr ',' ' '); do san="${san:+${san},}DNS:${n}"; done

  "${OPENSSL}" genrsa -traditional -out "${dir}/tls.key" 2048 2>/dev/null
  "${OPENSSL}" req -new -key "${dir}/tls.key" -subj "/O=SNI Fabric Lab/CN=${names%%,*}" -out "${dir}/tls.csr"
  # Extensions are written to a file rather than copied from the CSR, so a CSR can never
  # widen what the CA signs.
  cat > "${dir}/ext.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = ${eku}
subjectAltName = ${san}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  "${OPENSSL}" x509 -req -in "${dir}/tls.csr" -CA "${CA_CRT}" -CAkey "${CA_KEY}" \
    -set_serial "$(random_serial)" -days "${LEAF_DAYS}" -sha256 \
    -extfile "${dir}/ext.cnf" -out "${dir}/tls.crt" 2>/dev/null
  cp "${CA_CRT}" "${dir}/ca.crt"
  rm -f "${dir}/tls.csr" "${dir}/ext.cnf"
  # Certificates are public; keys stay 600 (umask). Containers that run as a non-root user
  # can then read the certificates through a mount without the keys being opened up.
  chmod 644 "${dir}/tls.crt" "${dir}/ca.crt"
}

mkdir -p "${OUT_DIR}"
if [ "${FORCE}" -eq 1 ] || [ ! -s "${CA_CRT}" ] || [ ! -s "${CA_KEY}" ]; then
  make_ca
else
  echo "kept CA           ${CA_CRT}"
fi

echo "${COMPONENTS}" | while IFS='|' read -r name eku names; do
  [ -n "${name}" ] || continue
  want="$(echo "${names}" | tr ',' '\n' | sort | paste -sd, -)"
  if [ "${FORCE}" -eq 1 ]; then reason="--force"; else reason="$(reissue_reason "${OUT_DIR}/${name}" "${want}")"; fi
  if [ -n "${reason}" ]; then
    issue "${name}" "${eku}" "${names}"
    printf 'issued %-10s %s (%s)\n' "${name}" "${names}" "${reason}"
  else
    printf 'kept   %-10s %s\n' "${name}" "${names}"
  fi
done

# (Re)build each PKCS#12 bundle that is missing or older than its certificate.
for name in ${P12_COMPONENTS}; do
  dir="${OUT_DIR}/${name}"
  if [ ! -s "${dir}/tls.p12" ] || [ "${dir}/tls.crt" -nt "${dir}/tls.p12" ]; then
    "${OPENSSL}" pkcs12 -export -in "${dir}/tls.crt" -inkey "${dir}/tls.key" -certfile "${dir}/ca.crt" \
      -name "${name}" -passout "pass:${P12_PASSWORD}" -out "${dir}/tls.p12"
    printf 'bundle %-10s %s\n' "${name}" "${dir}/tls.p12"
  fi
done

# Verify everything that was written, whether new or kept.
echo
printf '%-11s %-8s %-54s %-22s %s\n' COMPONENT CHAIN NAMES USAGE EXPIRES
fail=0
echo "${COMPONENTS}" | while IFS='|' read -r name eku names; do
  [ -n "${name}" ] || continue
  dir="${OUT_DIR}/${name}"
  chain="ok"
  "${OPENSSL}" verify -CAfile "${dir}/ca.crt" "${dir}/tls.crt" >/dev/null 2>&1 || chain="FAIL"
  [ "$(pubkey_of_cert "${dir}/tls.crt")" = "$(pubkey_of_key "${dir}/tls.key")" ] || chain="KEY?"
  usage="$("${OPENSSL}" x509 -in "${dir}/tls.crt" -noout -ext extendedKeyUsage | tail -n +2 | sed 's/^ *//; s/TLS Web //g; s/ Authentication//g')"
  expires="$("${OPENSSL}" x509 -in "${dir}/tls.crt" -noout -enddate | cut -d= -f2)"
  printf '%-11s %-8s %-54s %-22s %s\n' "${name}" "${chain}" "$(cert_dns_names "${dir}/tls.crt")" "${usage}" "${expires}"
  [ "${chain}" = "ok" ] || exit 1
done || fail=1
[ "${fail}" -eq 0 ] || die "verification failed; rerun with --force"

cat <<EOF

CA certificate: ${CA_CRT}
To trust it in this Mac's login keychain (browsers stop warning), run it yourself:
  security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db ${CA_CRT}
EOF
