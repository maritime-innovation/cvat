#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo " CVAT / Nuclio Docker CLEANUP SCRIPT"
echo "========================================"
echo
echo "⚠️  WARNING:"
echo "This will REMOVE ALL CVAT & Nuclio related containers,"
echo "images, volumes, and networks."
echo
read -p "Type 'YES' to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 0
fi

echo
echo "[1/7] Stopping CVAT & Nuclio containers (if running)..."
docker ps -a --format '{{.Names}}' | \
  grep -E 'cvat|nuclio|openvino|analytics|clickhouse|redis|postgres' | \
  xargs -r docker stop || true

echo
echo "[2/7] Removing CVAT & Nuclio containers..."
docker ps -a --format '{{.Names}}' | \
  grep -E 'cvat|nuclio|openvino|analytics|clickhouse|redis|postgres' | \
  xargs -r docker rm -f || true

echo
echo "[3/7] Removing CVAT & Nuclio docker-compose stacks (if present)..."
# Safety: ignore errors if compose files not found
docker compose down --remove-orphans 2>/dev/null || true
docker compose -f docker-compose.yml \
               -f components/serverless/docker-compose.serverless.yml \
               down --volumes --remove-orphans 2>/dev/null || true

echo
echo "[4/7] Removing CVAT & Nuclio volumes..."
docker volume ls --format '{{.Name}}' | \
  grep -E 'cvat|nuclio|postgres|redis|clickhouse|analytics' | \
  xargs -r docker volume rm -f || true

echo
echo "[5/7] Removing CVAT & Nuclio networks..."
docker network ls --format '{{.Name}}' | \
  grep -E 'cvat|nuclio|serverless|analytics' | \
  xargs -r docker network rm || true

echo
echo "[6/7] Removing CVAT & Nuclio images..."
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | \
  grep -E 'cvat|nuclio|openvino|clickhouse|analytics|datumaro|opencv|serverless|sam' | \
  awk '{print $2}' | \
  xargs -r docker rmi -f || true

echo
echo "[7/7] Docker system prune (dangling only)..."
docker system prune -f

echo
echo "========================================"
echo " ✅ CVAT Docker cleanup COMPLETE"
echo "========================================"
echo
echo "Current Docker state:"
docker ps -a
echo
docker volume ls
echo
docker network ls


# ./cleanup_cvat_docker.sh
