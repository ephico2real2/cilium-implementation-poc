#!/bin/sh
# Runs once in the init container before anything else starts, the way Kubernetes mounts a
# Secret into only the pods that reference it.
#
# /tls      certs/<component> -> /tls/<component>, owned by that component's UID, key 0400,
#           folder 0500; the CA certificate at /tls/ca/ca.crt, readable by everyone.
# /secrets  each consumer gets its own copy of each secret it uses in /secrets/<consumer>/,
#           owned by its UID, 0400.
# /pg-secrets  Postgres's password alone, in /pg-secrets/postgres/. Postgres's entrypoint runs
#           as root with DAC_READ_SEARCH, which reads past file modes, so it must not mount
#           the shared /secrets.
# /mq-pki, /mq-secrets  the queue manager's identity and passwords, in the layout the IBM MQ
#           container reads (/etc/mqm/pki/keys/<label>/, /run/secrets/mq*Password). Only the
#           queue manager mounts these: it shares UID 1001 with mq-client, so a shared volume
#           could not keep the two apart.
# /stores/<store>  each telemetry store's data volume, owned by that store's UID, 0700, with
#           the data/ folder it writes to.
set -eu

die() { echo "init-volumes: $*" >&2; exit 1; }

# Only the components' folders are mounted (certs/ca/ holds the CA key); each has ca.crt.
[ -s /src/certs/web/ca.crt ] || die "/src/certs/web/ca.crt missing; run scripts/gen-certs.sh"

# Copies one file and sets owner and mode.
put() {  # put <src> <dst> <uid> <mode>
  [ -s "$1" ] || die "$1 missing; run scripts/gen-certs.sh and scripts/gen-secrets.sh"
  cp "$1" "$2"
  chown "$3:0" "$2"
  chmod "$4" "$2"
}

# ---------------------------------------------------------------- /tls
# Emptied first (here and in /secrets), so a folder no longer in the list below does not stay
# behind, readable by a UID that may since belong to another component.
find /tls -mindepth 1 -maxdepth 1 -exec rm -rf {} +
for entry in web:101 tcp-svc:10001 orders-api:10002 mq-client:1001; do
  name="${entry%%:*}"
  uid="${entry##*:}"
  mkdir -p "/tls/${name}"
  put "/src/certs/${name}/tls.crt" "/tls/${name}/tls.crt" "${uid}" 0444
  put "/src/certs/${name}/ca.crt" "/tls/${name}/ca.crt" "${uid}" 0444
  put "/src/certs/${name}/tls.key" "/tls/${name}/tls.key" "${uid}" 0400
  [ ! -s "/src/certs/${name}/tls.p12" ] || put "/src/certs/${name}/tls.p12" "/tls/${name}/tls.p12" "${uid}" 0400
  chown "${uid}:0" "/tls/${name}"
  chmod 0500 "/tls/${name}"
  echo "init-volumes: tls/${name} -> uid ${uid}"
done
mkdir -p /tls/ca
put /src/certs/web/ca.crt /tls/ca/ca.crt 0 0444
chmod 0555 /tls/ca
echo "init-volumes: tls/ca/ca.crt -> everyone"

# ---------------------------------------------------------------- /secrets
# A lab from before pg-secrets still holds a root-owned /secrets/postgres: emptied first.
find /secrets -mindepth 1 -maxdepth 1 -exec rm -rf {} +
# consumer:uid:secret,...
for entry in \
  orders-api:10002:admin-token,postgres-password,mq-app-password,worker-token \
  worker:10003:mq-app-password,worker-token \
  postgres-exporter:10010:postgres-password \
  mq-client:1001:mq-app-password \
  grafana:472:grafana-admin-password
do
  consumer="${entry%%:*}"
  rest="${entry#*:}"
  uid="${rest%%:*}"
  list="${rest#*:}"
  mkdir -p "/secrets/${consumer}"
  for secret in $(echo "${list}" | tr ',' ' '); do
    put "/src/secrets/${secret}" "/secrets/${consumer}/${secret}" "${uid}" 0400
  done
  chown "${uid}:0" "/secrets/${consumer}"
  chmod 0500 "/secrets/${consumer}"
  echo "init-volumes: secrets/${consumer} -> uid ${uid} (${list})"
done

# ---------------------------------------------------------------- /pg-secrets
# Postgres reads its password as root before dropping to its own user, so its copy is owned by root.
rm -rf /pg-secrets/postgres
mkdir -p /pg-secrets/postgres
put /src/secrets/postgres-password /pg-secrets/postgres/postgres-password 0 0400
chmod 0500 /pg-secrets/postgres
echo "init-volumes: pg-secrets/postgres -> uid 0 (Postgres only)"

# ---------------------------------------------------------------- /mq-pki, /mq-secrets
rm -rf /mq-pki/keys
mkdir -p /mq-pki/keys/default
put /src/certs/mq/tls.crt /mq-pki/keys/default/tls.crt 1001 0444
put /src/certs/mq/ca.crt /mq-pki/keys/default/ca.crt 1001 0444
put /src/certs/mq/tls.key /mq-pki/keys/default/tls.key 1001 0400
chown -R 1001:0 /mq-pki
chmod 0500 /mq-pki/keys/default
put /src/secrets/mq-admin-password /mq-secrets/mqAdminPassword 1001 0400
put /src/secrets/mq-app-password /mq-secrets/mqAppPassword 1001 0400
echo "init-volumes: mq-pki/keys/default and mq-secrets -> uid 1001 (queue manager only)"

# ---------------------------------------------------------------- /stores
# Podman copies the image's folder over a volume that is still empty when a container mounts
# it, resetting the owner (measured with Tempo's /var/tempo); data/ keeps the volume non-empty.
for entry in tempo:10004 victoria-traces:10005 victoria-metrics:10006 victoria-logs:10007; do
  name="${entry%%:*}"
  uid="${entry##*:}"
  mkdir -p "/stores/${name}/data"
  chown "${uid}:0" "/stores/${name}" "/stores/${name}/data"
  chmod 0700 "/stores/${name}" "/stores/${name}/data"
  echo "init-volumes: stores/${name} -> uid ${uid}"
done
