#!/usr/bin/env bash
set -euo pipefail

: "${HEADSCALE_URL:?HEADSCALE_URL is required, e.g. https://headscale.example.com}"
: "${HEADSCALE_API_KEY:?HEADSCALE_API_KEY is required}"

TAG="${GATEWAY_TAG:-tag:gateway}"
NODE_NAME_REGEX="${GATEWAY_NODE_NAME_REGEX:-}"

API="${HEADSCALE_URL%/}/api/v1"
AUTH_HEADER="Authorization: Bearer ${HEADSCALE_API_KEY}"

echo "Route approver started"
echo "HEADSCALE_URL=${HEADSCALE_URL}"
echo "GATEWAY_TAG=${TAG}"
echo "GATEWAY_NODE_NAME_REGEX=${NODE_NAME_REGEX:-<not set>}"

nodes_json="$(
  curl -fsS \
    -H "$AUTH_HEADER" \
    "${API}/node"
)"

node_rows="$(
  echo "$nodes_json" |
  jq -r --arg tag "$TAG" --arg re "$NODE_NAME_REGEX" '
    (.nodes // [])[]
    | select(
        ((.tags // []) | index($tag)) or
        ((.validTags // []) | index($tag)) or
        ((.forcedTags // []) | index($tag)) or
        (($re != "") and ((.name // .givenName // .hostname // "") | test($re)))
      )
    | [
        (.id | tostring),
        (.name // .givenName // .hostname // "unknown"),
        ((.availableRoutes // .subnetRoutes // .routes // []) | join(","))
      ]
    | @tsv
  '
)"

if [[ -z "${node_rows:-}" ]]; then
  echo "No gateway nodes found"
  exit 0
fi

while IFS=$'\t' read -r node_id node_name routes_csv; do
  [[ -z "${node_id:-}" ]] && continue

  echo "Processing node ${node_id} (${node_name})"

  routes_json="$(
    echo "${routes_csv:-}" |
    tr ',' '\n' |
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' |
    sort -u |
    jq -R . |
    jq -s .
  )"

  route_count="$(echo "$routes_json" | jq 'length')"

  if [[ "$route_count" -eq 0 ]]; then
    echo "No advertised IPv4 routes for node ${node_id}"
    continue
  fi

  echo "Approving ${route_count} routes for node ${node_id}"

  curl -fsS \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --argjson routes "$routes_json" '{routes: $routes}')" \
    "${API}/node/${node_id}/approve_routes" \
    >/dev/null

  echo "Approved ${route_count} routes for node ${node_id}"
done <<< "$node_rows"
