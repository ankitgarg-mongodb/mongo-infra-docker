#!/bin/bash

# Picks which backends the monitoring agent exports to (at most two, a second
# slot needs the otelMultiBackend startup flag) and prints the otelConfig JSON
# for the agent. Terminal output only - containers and docker state are not
# touched, switching backends is purely an agent-side config change.

set -euo pipefail
cd "$(dirname "$0")"

[[ -f backends.conf ]] || { echo "backends.conf is missing"; exit 1; }
# shellcheck source=backends.conf
source backends.conf

backend_key() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; }
backend_port() { case "$1" in prometheus) echo 9090 ;; grafana-otel) echo 4320 ;; victoriametrics) echo 8428 ;; collector) echo 4322 ;; esac; }
backend_path() { case "$1" in prometheus) echo /api/v1/otlp/v1/metrics ;; victoriametrics) echo /opentelemetry/v1/metrics ;; *) echo /v1/metrics ;; esac; }

[[ -f certs/ca.crt ]] || { echo "No certificates - run quick-start.sh first"; exit 1; }

options=(prometheus grafana-otel victoriametrics collector)

# UI prints go to stderr, the picked name is what $(pick ...) captures
say() { echo "$@" >&2; }

# asks for a backend name or menu number, echoes it
pick() {
  local prompt=$1 default=$2 allow_none=$3 choice
  say "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    say "  $i) $opt"
    i=$((i+1))
  done
  if [[ "$allow_none" == "true" ]]; then
    say "  $i) none - a single backend is fine"
  fi
  while true; do
    read -r -p "Backend [$default]: " choice
    choice=${choice:-$default}
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [[ "$allow_none" == "true" && "$choice" -eq ${#options[@]}+1 ]]; then
        return
      fi
      choice=${options[$((choice-1))]:-}
    fi
    local opt
    for opt in "${options[@]}"; do
      [[ "$choice" == "$opt" ]] && { echo "$choice"; return; }
    done
    say "  pick a number between 1 and ${#options[@]}${allow_none:+ (+1 for none)}, or a backend name"
  done
}

echo "All backends are running, the agent exports to at most two of them."
echo

first=$(pick "First backend?" prometheus false)
second=$(pick "Second backend?" grafana-otel true)
[[ "$second" == "$first" ]] && second=""

# emits one backend entry of the agent's otelConfig
backend_json() {
  local name=$1
  local key; key=$(backend_key "$name")
  local tls="${key}_TLS"; tls="${!tls:-none}"
  local scheme=http; [[ "$tls" != "none" ]] && scheme=https
  local ca='""' cc='""' ck='""' ckpw='""'
  if [[ "$tls" != "none" ]]; then
    ca="\"$(pwd)/certs/ca.crt\""
    if [[ "$tls" == "mtls" ]]; then
      # with CLIENT_KEY_PASSWORD set (backends.conf) the agent gets the
      # dedicated PEM-encrypted keypair instead of the plain one the stack's
      # internal TLS clients share
      local keyfile=client
      if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
        keyfile=client-encrypted
        ckpw="\"$CLIENT_KEY_PASSWORD\""
      fi
      cc="\"$(pwd)/certs/$keyfile.crt\""
      ck="\"$(pwd)/certs/$keyfile.key\""
    fi
  fi
  printf '    {\n      "endpoint": "%s://localhost:%s%s",\n      "headers": "",\n      "caCertPath": %s,\n      "clientCertPath": %s,\n      "clientKeyPath": %s,\n      "clientKeyPassword": %s,\n      "compression": "gzip"\n    }' \
    "$scheme" "$(backend_port "$name")" "$(backend_path "$name")" "$ca" "$cc" "$ck" "$ckpw"
}

echo
echo "Set this as the otelConfig setting on the monitoring agent"
echo "(Deployment >> Agents >> Monitoring settings, or in the automation config):"
echo
echo "{"
echo '  "enabled": true,'
echo '  "metricsExportIntervalSec": 30,'
echo '  "backends": ['
backend_json "$first"
if [[ -n "$second" ]]; then
  echo ","
  backend_json "$second"
fi
echo ""
echo "  ]"
echo "}"
echo
if [[ -n "$second" ]]; then
  echo "Two backends need the agent started with the otelMultiBackend flag, one works without it."
fi
if [[ "$first" == "collector" || "$second" == "collector" ]]; then
  echo "NOTE: the collector forwards to prometheus, grafana-otel AND victoriametrics -"
  echo "do not target those directly in the other slot, they would receive every series twice."
fi
echo "Restart the monitoring agent after applying the config."
echo "TLS backends need certs/ca.crt (plus the client cert/key from the config"
echo "above for mtls) copied to the agent's machine - adjust the paths above if"
echo "it does not run on this one."
