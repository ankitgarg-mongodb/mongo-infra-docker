#!/bin/bash

# Generates certificates into this folder based on backends.conf:
#   ca.crt                     the CA every certificate trusts (agent's caCertPath)
#   client.crt, client.key     the agent's certificate for mutual TLS
#   client-encrypted.crt,      the agent's keypair when CLIENT_KEY_PASSWORD
#   client-encrypted.key       (backends.conf) is set - its key is PEM-encrypted
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

# generate an RSA key, PEM-encrypted when KEY_PASSWORD is set (used for the
# agent's client-encrypted key; traditional format with a DEK-Info header so
# Go-based consumers can decrypt it)
gen_key() {
  local out=$1
  if [[ -n "${KEY_PASSWORD:-}" ]]; then
    openssl genrsa -out "$out.tmp" 2048 2>/dev/null
    openssl rsa -traditional -aes256 -passout "pass:${KEY_PASSWORD}" \
      -in "$out.tmp" -out "$out" 2>/dev/null
    rm -f "$out.tmp"
  else
    openssl genrsa -out "$out" 2048 2>/dev/null
  fi
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
  gen_key "$name.key"
  # an encrypted key (KEY_PASSWORD set) must be unlocked for the CSR step;
  # for plain keys -passin is never consulted
  local passin=()
  [[ -n "${KEY_PASSWORD:-}" ]] && passin=(-passin "pass:${KEY_PASSWORD}")
  openssl req -new -key "$name.key" ${passin[@]+"${passin[@]}"} -out "$name.csr" -subj "/O=${ORG}/CN=${cn}"
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

# the agent's keypair for the clientKeyPassword flow: generated only when
# CLIENT_KEY_PASSWORD (backends.conf) is set, its key PEM-encrypted with that
# password. Changing or clearing the password regenerates the pair; the plain
# client.* pair above is untouched and keeps serving the stack-internal
# clients (collector fan-out, grafana datasources), which cannot decrypt
# PEM-encrypted keys
if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
  if [[ -f client-encrypted.key ]] && \
     ! openssl rsa -in client-encrypted.key -passin "pass:${CLIENT_KEY_PASSWORD}" -noout >/dev/null 2>&1
  then
    echo "  client-encrypted.key does not decrypt with CLIENT_KEY_PASSWORD - regenerating"
    rm -f client-encrypted.crt client-encrypted.key
  fi
  KEY_PASSWORD=$CLIENT_KEY_PASSWORD
  sign_cert client-encrypted otel-agent clientAuth
  KEY_PASSWORD=
else
  rm -f client-encrypted.crt client-encrypted.key
fi

# server certificates: shared covers every backend, dedicated is per backend
shared_names=(prometheus prometheus.internal grafana-otel grafana-otel.internal victoriametrics victoriametrics.internal otelcol otelcol.internal)

for backend in prometheus grafana-otel victoriametrics otelcol
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
