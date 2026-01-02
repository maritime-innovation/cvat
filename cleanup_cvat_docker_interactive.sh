#!/usr/bin/env bash
set -euo pipefail

# ========= configurable filters =========
# "CVAT/Nuclio 関連っぽいもの" を名前で拾うフィルタ。
# 環境によって命名が違うならここを調整してください。
NAME_GREP_RE='cvat|nuclio|openvino|analytics|clickhouse|redis|postgres|datumaro|serverless|sam'

# ========= helpers =========
hr() { echo "------------------------------------------------------------"; }
log() { echo -e "\n[+] $*\n"; }

confirm_step() {
  local prompt="$1"
  while true; do
    read -r -p "$prompt [y/N]: " ans
    case "${ans:-}" in
      y|Y) return 0 ;;
      n|N|"") echo "  -> skipped"; return 1 ;;
      *) echo "  -> please type 'y' or 'n'";;
    esac
  done
}

# ========= listings =========
list_containers() {
  docker ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' \
    | (head -n 1; tail -n +2 | grep -Ei "$NAME_GREP_RE" || true)
}

list_images() {
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' \
    | (head -n 1; tail -n +2 | grep -Ei "$NAME_GREP_RE" || true)
}

list_volumes() {
  docker volume ls --format 'table {{.Name}}\t{{.Driver}}' \
    | (head -n 1; tail -n +2 | grep -Ei "$NAME_GREP_RE" || true)
}

list_networks() {
  docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' \
    | (head -n 1; tail -n +2 | grep -Ei "$NAME_GREP_RE" || true)
}

# ========= main =========
echo "========================================"
echo " CVAT / Nuclio Docker INTERACTIVE CLEANUP"
echo "========================================"
echo
echo "Target filter (regex): $NAME_GREP_RE"
echo

hr
echo "Current candidate CONTAINERS:"
list_containers
hr
echo "Current candidate IMAGES:"
list_images
hr
echo "Current candidate VOLUMES:"
list_volumes
hr
echo "Current candidate NETWORKS:"
list_networks
hr

echo
echo "⚠️ NOTE:"
echo " - Removing volumes will delete CVAT DB/data (tasks/annotations)."
echo " - Removing images may take time and will require re-pull/rebuild later."
echo

# ----- Step 1: stop containers -----
if confirm_step "Step 1) Stop candidate containers?"; then
  log "Stopping containers..."
  # Stop by container name match (safer than image match)
  docker ps -a --format '{{.Names}}' \
    | grep -Ei "$NAME_GREP_RE" \
    | xargs -r docker stop || true
fi

# Show status after step
hr
echo "Candidate CONTAINERS after Step 1:"
list_containers
hr

# ----- Step 2: remove containers -----
if confirm_step "Step 2) Remove candidate containers (docker rm -f)?"; then
  log "Removing containers..."
  docker ps -a --format '{{.Names}}' \
    | grep -Ei "$NAME_GREP_RE" \
    | xargs -r docker rm -f || true
fi

hr
echo "Candidate CONTAINERS after Step 2:"
list_containers
hr

# ----- Step 3: docker compose down (optional) -----
# compose down can remove extra orphans; but requires running in a compose dir.
# We'll offer it, but it may be skipped if not in CVAT repo folder.
if confirm_step "Step 3) Run docker compose down (if you are in CVAT repo dir)?"; then
  log "Running docker compose down (best-effort)..."
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose -f docker-compose.yml \
                 -f components/serverless/docker-compose.serverless.yml \
                 down --volumes --remove-orphans 2>/dev/null || true
fi

# ----- Step 4: remove volumes -----
hr
echo "Candidate VOLUMES currently:"
list_volumes
hr

if confirm_step "Step 4) Remove candidate volumes (DATA LOSS)?"; then
  log "Removing volumes..."
  docker volume ls --format '{{.Name}}' \
    | grep -Ei "$NAME_GREP_RE" \
    | xargs -r docker volume rm -f || true
fi

hr
echo "Candidate VOLUMES after Step 4:"
list_volumes
hr

# ----- Step 5: remove networks -----
hr
echo "Candidate NETWORKS currently:"
list_networks
hr

if confirm_step "Step 5) Remove candidate networks?"; then
  log "Removing networks..."
  docker network ls --format '{{.Name}}' \
    | grep -Ei "$NAME_GREP_RE" \
    | xargs -r docker network rm || true
fi

hr
echo "Candidate NETWORKS after Step 5:"
list_networks
hr

# ----- Step 6: remove images -----
hr
echo "Candidate IMAGES currently:"
list_images
hr

if confirm_step "Step 6) Remove candidate images (docker rmi -f)?"; then
  log "Removing images..."
  # remove by image ID to handle duplicated repo:tag lines safely
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
    | grep -Ei "$NAME_GREP_RE" \
    | awk '{print $2}' \
    | sort -u \
    | xargs -r docker rmi -f || true
fi

hr
echo "Candidate IMAGES after Step 6:"
list_images
hr

# ----- Step 7: prune dangling (optional) -----
if confirm_step "Step 7) docker system prune (dangling only)?"; then
  log "Running docker system prune..."
  docker system prune -f
fi

echo
echo "========================================"
echo " ✅ INTERACTIVE CLEANUP FINISHED"
echo "========================================"
echo
echo "Final Docker state (quick view):"
echo
docker ps -a
echo
docker volume ls
echo
docker network ls

newgrp docker
# ./cleanup_cvat_docker_interactive.sh
