#!/bin/sh
# Embeds api/openapi.yaml into the hub (served at GET /v2/openapi.yaml).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
{ printf '/// Generated from api/openapi.yaml by scripts/sync-openapi.sh; a test keeps them equal.\nlet openAPISpec = #"""\n'
  cat "$root/api/openapi.yaml"
  printf '\n"""#\n'; } > "$root/hub/Sources/LocalHubCore/OpenAPISpec.swift"
