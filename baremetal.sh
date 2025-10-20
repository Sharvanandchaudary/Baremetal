#!/usr/bin/env bash
set -euo pipefail

# Dynamic OpenStack Ironic provisioning script
#
# Requirements:
# - openstackclient + ironicclient available in PATH
# - `openrc.sh` sourced, or provide OS_* env vars
# - jq and GNU parallel or xargs available
#
# Inputs via env or flags (flags override env):
#   --count N                       Number of servers to provision (default: 1)
#   --image IMAGE                   Glance image name or ID
#   --network NETWORK               Neutron network name or ID
#   --resource-class CLASS          Ironic resource class to filter nodes
#   --deploy-interface IFACE        Ironic deploy interface (default: direct)
#   --ssh-key KEYNAME               Nova keypair name to inject (optional)
#   --instance-prefix PREFIX        Name prefix for instances (default: bm)
#   --timeout-seconds SECS          Per-node deploy timeout (default: 3600)
#   --parallelism N                 Parallel deployments (default: 10)
#   --dry-run                       Print actions without executing
#   --openrc PATH                   Path to openrc.sh to source
#
# Env var equivalents (used if flags not passed):
#   COUNT, IMAGE, NETWORK, RESOURCE_CLASS, DEPLOY_INTERFACE,
#   SSH_KEY, INSTANCE_PREFIX, TIMEOUT_SECONDS, PARALLELISM,
#   DRY_RUN (true/false), OPENRC_PATH

usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  --count N
  --image IMAGE
  --network NETWORK
  --resource-class CLASS
  --deploy-interface IFACE
  --ssh-key KEYNAME
  --instance-prefix PREFIX
  --timeout-seconds SECS
  --parallelism N
  --dry-run
  --openrc PATH
  -h, --help
EOF
}

COUNT=${COUNT:-1}
IMAGE=${IMAGE:-}
NETWORK=${NETWORK:-}
RESOURCE_CLASS=${RESOURCE_CLASS:-}
DEPLOY_INTERFACE=${DEPLOY_INTERFACE:-direct}
SSH_KEY=${SSH_KEY:-}
INSTANCE_PREFIX=${INSTANCE_PREFIX:-bm}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-3600}
PARALLELISM=${PARALLELISM:-10}
DRY_RUN=${DRY_RUN:-false}
OPENRC_PATH=${OPENRC_PATH:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --network) NETWORK="$2"; shift 2;;
    --resource-class) RESOURCE_CLASS="$2"; shift 2;;
    --deploy-interface) DEPLOY_INTERFACE="$2"; shift 2;;
    --ssh-key) SSH_KEY="$2"; shift 2;;
    --instance-prefix) INSTANCE_PREFIX="$2"; shift 2;;
    --timeout-seconds) TIMEOUT_SECONDS="$2"; shift 2;;
    --parallelism) PARALLELISM="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --openrc) OPENRC_PATH="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

require_cmd openstack
require_cmd jq

# Source OpenStack credentials if available
if [[ -n "$OPENRC_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$OPENRC_PATH"
fi

# Validate inputs
if [[ -z "$IMAGE" ]]; then echo "--image or IMAGE env is required"; exit 1; fi
if [[ -z "$NETWORK" ]]; then echo "--network or NETWORK env is required"; exit 1; fi
if [[ "$COUNT" -lt 1 ]]; then echo "--count must be >= 1"; exit 1; fi

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

os_json() {
  # openstack supports -f json and --quote minimal to ease jq parsing
  openstack "$@" -f json --quote minimal
}

resolve_image_id() {
  local ref="$1"
  # Try ID directly
  if os_json image show "$ref" >/dev/null 2>&1; then
    os_json image show "$ref" | jq -r '.id'
    return 0
  fi
  # Resolve by name
  os_json image list --name "$ref" | jq -r '.[0].ID // empty'
}

resolve_network_id() {
  local ref="$1"
  if os_json network show "$ref" >/dev/null 2>&1; then
    os_json network show "$ref" | jq -r '.id'
    return 0
  fi
  os_json network list --name "$ref" | jq -r '.[0].ID // empty'
}

pick_available_nodes() {
  # Filters: provision_state == available, maintenance == false, optional resource_class
  if [[ -n "$RESOURCE_CLASS" ]]; then
    os_json baremetal node list --provision-state available --maintenance false \
      | jq -r --arg rc "$RESOURCE_CLASS" '[.[] | select(."Resource Class"==$rc) | .UUID] | .[]'
  else
    os_json baremetal node list --provision-state available --maintenance false \
      | jq -r '.[] | .UUID'
  fi
}

wait_for_active() {
  local server_id="$1"
  local deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
  while true; do
    local status
    status=$(os_json server show "$server_id" | jq -r '.status')
    case "$status" in
      ACTIVE) return 0;;
      ERROR) echo "Server $server_id entered ERROR"; return 1;;
    esac
    if [[ $(date +%s) -ge $deadline ]]; then
      echo "Timeout waiting for server $server_id to become ACTIVE"; return 1
    fi
    sleep 5
  done
}

provision_one() {
  local idx="$1"
  local node_uuid="$2"
  local image_id="$3"
  local network_id="$4"
  local name="${INSTANCE_PREFIX}-${idx}"

  log "Provisioning $name on node $node_uuid"
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: would provision $name on $node_uuid with image $image_id, network $network_id"
    return 0
  fi

  # Build create args
  local args=(
    server create "$name"
    --nic net-id="$network_id"
    --image "$image_id"
    --flavor baremetal
    --hint node="$node_uuid"
  )
  if [[ -n "$SSH_KEY" ]]; then
    args+=( --key-name "$SSH_KEY" )
  fi

  # Some deployments require deploy interface
  if [[ -n "$DEPLOY_INTERFACE" ]]; then
    # Attempt to set on node; ignore failures if not supported
    openstack baremetal node set "$node_uuid" --deploy-interface "$DEPLOY_INTERFACE" >/dev/null 2>&1 || true
  fi

  local create_json
  create_json=$(os_json "${args[@]}")
  local server_id
  server_id=$(jq -r '.id' <<<"$create_json")

  wait_for_active "$server_id"
  log "Provisioned $name (id=$server_id)"
}

main() {
  local image_id network_id
  image_id=$(resolve_image_id "$IMAGE" || true)
  if [[ -z "$image_id" ]]; then echo "Image not found: $IMAGE"; exit 1; fi
  network_id=$(resolve_network_id "$NETWORK" || true)
  if [[ -z "$network_id" ]]; then echo "Network not found: $NETWORK"; exit 1; fi

  mapfile -t nodes < <(pick_available_nodes)
  if [[ ${#nodes[@]} -eq 0 ]]; then
    echo "No available Ironic nodes found"; exit 1
  fi

  if [[ "$COUNT" -gt ${#nodes[@]} ]]; then
    echo "Requested $COUNT nodes but only ${#nodes[@]} available"; exit 1
  fi

  log "Using image=$image_id network=$network_id count=$COUNT parallelism=$PARALLELISM"

  # Prepare work list: index node_uuid
  for i in $(seq 1 "$COUNT"); do
    echo "$i ${nodes[$((i-1))]}"
  done | {
    if command -v parallel >/dev/null 2>&1; then
      parallel -j "$PARALLELISM" --colsep ' ' \
        "$0" _internal_provision {} "$image_id" "$network_id"
    else
      # Fallback to xargs parallelism
      xargs -n 2 -P "$PARALLELISM" -I % bash -c \
        'set -euo pipefail; idx=$(cut -d" " -f1 <<<"%" ); node=$(cut -d" " -f2 <<<"%" ); "$0" _internal_provision "$idx" "$node" ' "$0"
    fi
  }
}

if [[ "${1:-}" == "_internal_provision" ]]; then
  shift
  provision_one "$@"
else
  main
fi


