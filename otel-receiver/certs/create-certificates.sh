#!/bin/bash

# Generates certificates into this folder based on backends.conf:
#   ca.crt                     the CA every certificate trusts (agent's caCertPath)
#   client.crt, client.key     the agent's certificate for mutual TLS
#   server.crt, server.key     shared server certificate (CERTS=shared)
#   <backend>.crt, <backend>.key   dedicated certificate (CERTS=dedicated)
#
# Existing certificates are kept - re-running quick-start.sh for a config
# change does not rotate the CA, so certificates already copied to agents stay
# valid. Missing certificates (e.g. a backend just switched to CERTS=dedicated)
# are added and signed by the same CA. Regenerate everything with:
#   FORCE=1 bash create-certificates.sh
#
# Server certificate SANs cover localhost, host.docker.internal, 127.0.0.1 and
# each backend's container name / .internal hostname, so agents can use any of
# them as the endpoint host. Validity and subject are overridable via env:
#   DAYS=90 ORG="My Org" FORCE=1 bash create-certificates.sh

set -euo pipefail
cd "$(dirname "$0")"

DAYS=${DAYS:-3650}
FORCE=${FORCE:-0}
ORG=${ORG:-MongoDB Test}

CONF=../backends.conf
[[ -f "$CONF" ]] && source "$CONF"

mkdir -p ext

# uppercases a backend name and turns dashes into underscores (macOS bash 3.2 has no ${var^^})
backend_key() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; }

# write an openssl extension file: base SANs + extra DNS names
write_ext() {
  local out=$1 eku=$2 cn=$3
  shift 3
  {
    echo "[ v3_req ]"
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = $eku"
    echo "subjectAltName = @alt_names"
    echo
    echo "[ alt_names ]"
    local i=1 name
    for name in "localhost" "host.docker.internal" "127.0.0.1" "$@"; do
      if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "IP.$i=$name"
      else
        echo "DNS.$i=$name"
      fi
      i=$((i+1))
    done
  } > "$out"
}

# generate a CA-signed keypair unless it already exists: sign_cert <name> <cn> <eku> <extra dns names...>
sign_cert() {
  local name=$1 cn=$2 eku=$3
  shift 3
  if [[ "$FORCE" != "1" && -f "$name.crt" ]]; then
    echo "  $name.crt $name.key kept"
    return
  fi
  write_ext "ext/$name.cnf" "$eku" "$cn" "$@"
  openssl genrsa -out "$name.key" 2048 2>/dev/null
  openssl req -new -key "$name.key" -out "$name.csr" -subj "/O=${ORG}/CN=${cn}"
  openssl x509 -req -days "$DAYS" -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "$name.crt" -extfile "ext/$name.cnf" -extensions v3_req 2>/dev/null
  rm -f "$name.csr"
  echo "  $name.crt $name.key (CN=$cn)"
}

# CA, generated once - everything is signed by it. The v3_ca extensions
# (CA:true) are what make verifiers accept it as a CA. LibreSSL's req has no
# -extfile, extensions go in via -config
if [[ "$FORCE" != "1" && -f ca.crt ]]; then
  echo "  ca.crt kept"
else
  cat > ext/ca.cnf <<'EOF'
[ req ]
distinguished_name = dn
default_md = sha256
x509_extensions = v3_ca

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign

[ dn ]
EOF
  openssl genrsa -out ca.key 4096 2>/dev/null
  openssl req -new -x509 -days "$DAYS" -key ca.key -out ca.crt \
    -config ext/ca.cnf \
    -subj "/O=${ORG}/CN=otel-receiver-ca"
  echo "  ca.crt (CN=otel-receiver-ca)"
fi

# the agent's client certificate, shared by every backend
sign_cert client otel-agent clientAuth

# server certificates: shared covers every backend, dedicated is per backend
# (victoriametrics runs unauthenticated locally, it never presents a certificate)
shared_names=(prometheus prometheus.internal grafana-otel grafana-otel.internal victoriametrics victoriametrics.internal otelcol otelcol.internal)

for backend in prometheus grafana-otel otelcol
do
  backend_key=$(backend_key "$backend")
  cert_mode="${backend_key}_CERTS"
  if [[ "${!cert_mode:-shared}" == "dedicated" ]]
  then
    sign_cert "$backend" "$backend.internal" serverAuth "$backend" "$backend.internal"
  fi
done

sign_cert server otel-receiver.internal serverAuth "${shared_names[@]}"

rm -rf ext
echo
echo "Certificates in $(pwd), valid $DAYS days from generation:"
ls -1 *.crt *.key | sed 's/^/  /'
