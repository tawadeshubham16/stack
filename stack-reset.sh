#!/usr/bin/env bash
set -euo pipefail

# Resets the swarm stack: removes existing services/containers/networks, recreates
# required shared networks, loads env vars, and deploys the stack compose files.

STACK_NAME="${STACK_NAME:-stack}"
ENV_FILE="${ENV_FILE:-.env}"

log() { printf '==> %s\n' "$*"; }

require_swarm() {
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
  if [[ "$state" != "active" ]]; then
    log "Swarm not active (state: ${state:-unknown}); initializing..."
    docker swarm init >/dev/null
  fi
}

remove_stack_artifacts() {
  log "Removing stack '${STACK_NAME}' (services, tasks, networks)"
  docker stack rm "$STACK_NAME" 2>/dev/null || true

  # Wait briefly for swarm to tear down tasks.
  for _ in {1..15}; do
    if ! docker stack ps "$STACK_NAME" >/dev/null 2>&1 || [[ -z "$(docker stack ps "$STACK_NAME" --quiet 2>/dev/null)" ]]; then
      break
    fi
    sleep 2
  done

  # Remove any lingering services/containers/networks tied to the stack.
  docker service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" -q | xargs -r docker service rm
  docker ps -a --filter "label=com.docker.stack.namespace=${STACK_NAME}" -q | xargs -r docker rm -f
  docker network ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" -q | xargs -r docker network rm
}

recreate_network() {
  local name="$1"
  log "Ensuring overlay network '${name}' exists"
  if docker network inspect "$name" >/dev/null 2>&1; then
    docker network rm "$name" >/dev/null 2>&1 || true
  fi
  docker network create --driver overlay --attachable "$name" >/dev/null 2>&1 \
    || docker network inspect "$name" >/dev/null
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Loading environment from ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    log "Env file ${ENV_FILE} not found; continuing without it"
  fi
}

deploy_stack() {
  log "Deploying stack '${STACK_NAME}'"
  docker stack deploy \
    -c traefik.yml \
    -c postgres.yml \
    -c minio.yml \
    -c portfolio.yml \
    "$STACK_NAME"
}

main() {
  require_swarm
  remove_stack_artifacts
  recreate_network traefik-public
  recreate_network postgres_db
  load_env
  deploy_stack
  log "Done."
}

main "$@"
