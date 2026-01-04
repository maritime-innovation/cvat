#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CVAT + Serverless (Nuclio) + SAM setup (idempotent-ish, resumable)
#
# Goal:
# - If the script stops mid-way, re-running should skip completed steps
# - If environment/config changes, re-running should apply only the needed fixes
#
# Notes:
# - By default, existing admin user password is NOT overwritten (safer).
#   Set SYNC_ADMIN=1 to force-sync admin password/flags each run.
# - By default, SAM deploy is skipped if the function already exists.
#   Set REDEPLOY_SAM=1 to force redeploy.
###############################################################################

############################################
# Args / Flags (simple env toggles)
############################################
# Usage examples:
#   ./setup_cvat_with_sam.sh
#   SYNC_ADMIN=1 ./setup_cvat_with_sam.sh
#   REDEPLOY_SAM=1 ./setup_cvat_with_sam.sh
#   FORCE_REBUILD=1 ./setup_cvat_with_sam.sh
SYNC_ADMIN="${SYNC_ADMIN:-0}"         # 1 = always overwrite admin user password/flags
REDEPLOY_SAM="${REDEPLOY_SAM:-0}"     # 1 = redeploy SAM even if exists
FORCE_REBUILD="${FORCE_REBUILD:-0}"   # 1 = docker compose up --build always (still safe)
NO_APT="${NO_APT:-0}"                 # 1 = skip apt installs
NO_DOCKER_INSTALL="${NO_DOCKER_INSTALL:-0}"  # 1 = skip docker install even if missing

############################################
# Load .env (local only)
############################################
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "[ERROR] .env not found at: $ENV_FILE"
  echo "        Create it from .env.example: cp .env.example .env"
  exit 1
fi

############################################
# User-configurable variables (defaults)
############################################
CVAT_DIR="${CVAT_DIR:-$HOME/cvat}"
CVAT_VERSION_TAG="${CVAT_VERSION_TAG:-v2.54.0}"
CVAT_HOST="${CVAT_HOST:-localhost}"

# Git repo/ref to deploy from (fork + branch)
# Git repo/ref to deploy from (fork + branch)
CVAT_REPO_URL="${CVAT_REPO_URL:-git@github.com:maritime-innovation/cvat.git}"
CVAT_GIT_REF="${CVAT_GIT_REF:-gbr/develop}"
CVAT_REMOTE_NAME="${CVAT_REMOTE_NAME:-origin}"

# Strict SAM1 function name (Nuclio)
SAM_FUNCTION_NAME="${SAM_FUNCTION_NAME:-pth-facebookresearch-sam-vit-h}"

# Allow access via IP (e.g., Tailscale IP) even when Traefik uses Host rules.
CVAT_ALLOW_IP_ACCESS="${CVAT_ALLOW_IP_ACCESS:-1}"
CVAT_TAILSCALE_IP="${CVAT_TAILSCALE_IP:-}"

# Admin creation (idempotent)
DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_USERNAME="$(echo "$DJANGO_SUPERUSER_USERNAME" | tr -cd 'a-zA-Z0-9@._+-')"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-admin@example.com}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-1234}"

# Nuclio CLI version
NUCTL_VERSION="${NUCTL_VERSION:-1.13.0}"

# Deploy SAM CPU/GPU
DEPLOY_SAM_GPU="${DEPLOY_SAM_GPU:-0}"

############################################
# Helpers
############################################
log() { echo -e "\n[+] $*\n"; }
warn() { echo -e "\n[WARN] $*\n" >&2; }
die() { echo -e "\n[ERROR] $*\n" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# State file (per CVAT_DIR) to support resume + config drift detection
STATE_DIR="$CVAT_DIR/.setup_state"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.env"

# Read state
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
fi

state_get() {
  local k="$1"
  # shellcheck disable=SC2154
  eval "echo \"\${STATE_${k}:-}\""
}

state_set() {
  local k="$1" v="$2"
  # write/update line in STATE_FILE
  if grep -q "^STATE_${k}=" "$STATE_FILE" 2>/dev/null; then
    # mac sed compat not needed (Ubuntu), but keep safe:
    sed -i "s|^STATE_${k}=.*$|STATE_${k}=\"${v//\"/\\\"}\"|g" "$STATE_FILE"
  else
    echo "STATE_${k}=\"${v//\"/\\\"}\"" >> "$STATE_FILE"
  fi
}

# Compute a config signature for steps that should rerun when env changes
compute_signature() {
  echo "CVAT_REPO_URL=$CVAT_REPO_URL|CVAT_GIT_REF=$CVAT_GIT_REF|NUCTL_VERSION=$NUCTL_VERSION|ALLOW_IP=$CVAT_ALLOW_IP_ACCESS|TAILSCALE_IP=$CVAT_TAILSCALE_IP|DEPLOY_SAM_GPU=$DEPLOY_SAM_GPU|CVAT_HOST=$CVAT_HOST"
}

# Wait helpers
wait_http_ok() {
  local url="$1" tries="${2:-60}" sleep_s="${3:-2}"
  for i in $(seq 1 "$tries"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

############################################
# 0) Pre-flight: derive Tailscale IP if needed
############################################
if [ "$CVAT_ALLOW_IP_ACCESS" = "1" ]; then
  if [ -z "$CVAT_TAILSCALE_IP" ] && command -v tailscale >/dev/null 2>&1; then
    CVAT_TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
fi

# IMPORTANT: export so docker compose sees them (this was your original pitfall)
export CVAT_HOST="$CVAT_HOST"

# If you intend to access via Tailscale IP, it’s usually best that CVAT_HOST matches it
if [ "$CVAT_ALLOW_IP_ACCESS" = "1" ] && [ -n "$CVAT_TAILSCALE_IP" ]; then
  export CVAT_HOST="$CVAT_TAILSCALE_IP"
  CVAT_HOST="$CVAT_TAILSCALE_IP"
fi

SIG_NOW="$(compute_signature)"
SIG_OLD="$(state_get CONFIG_SIGNATURE || true)"

############################################
# 1) Basic packages
############################################
if [ "$NO_APT" = "1" ]; then
  warn "NO_APT=1 set; skipping apt-get installs."
else
  log "Installing basic packages (curl, git, jq, ca-certificates)..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl git jq gnupg lsb-release
fi

############################################
# 2) Docker Engine + Docker Compose plugin
############################################
if [ "$NO_DOCKER_INSTALL" = "1" ]; then
  warn "NO_DOCKER_INSTALL=1 set; skipping docker install even if missing."
else
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine + Compose plugin..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    log "Docker already installed: $(docker --version)"
  fi
fi

log "Enabling and starting Docker..."
sudo systemctl enable docker >/dev/null 2>&1 || true
sudo systemctl restart docker

# Allow non-root docker usage (idempotent)
if ! groups "$USER" | grep -q "\bdocker\b"; then
  log "Adding user '$USER' to docker group (you may need to log out/in once after script finishes)..."
  sudo usermod -aG docker "$USER"
fi

############################################
# 3) NVIDIA Container Toolkit (optional; safe to rerun)
############################################
# Skip if NO_APT=1
if [ "$NO_APT" != "1" ]; then
  log "Installing NVIDIA Container Toolkit (optional, safe to rerun)..."
  sudo apt-get update -y
  sudo apt-get install -y nvidia-container-toolkit || true

  if command -v nvidia-ctk >/dev/null 2>&1; then
    log "Configuring Docker runtime for NVIDIA (nvidia-ctk runtime configure)..."
    sudo nvidia-ctk runtime configure --runtime=docker || true
    sudo systemctl restart docker
  else
    warn "nvidia-ctk not found. (OK if you don't need GPU in containers.)"
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    log "Host GPU check (nvidia-smi):"
    nvidia-smi || true
  fi
fi

############################################
# 4) Clone CVAT and checkout a known version (resumable)
############################################


log "Cloning CVAT into: $CVAT_DIR"
# --- SSH guard (only when repo already exists) ---
if [ -d "$CVAT_DIR/.git" ]; then
  ORIGIN_URL="$(git -C "$CVAT_DIR" remote get-url "$CVAT_REMOTE_NAME" 2>/dev/null || true)"
  if echo "$ORIGIN_URL" | grep -q '^https://github.com/'; then
    log "Git origin is HTTPS. Switching to SSH..."
    git -C "$CVAT_DIR" remote set-url "$CVAT_REMOTE_NAME" "$CVAT_REPO_URL"
  fi
fi
# --- clone or fetch ---
if [ ! -d "$CVAT_DIR/.git" ]; then
  git clone "$CVAT_REPO_URL" "$CVAT_DIR"
else
  log "CVAT repo already exists; verifying remote..."
  # Ensure the configured remote points to the fork (safe update)
  if git -C "$CVAT_DIR" remote get-url "$CVAT_REMOTE_NAME" >/dev/null 2>&1; then
    git -C "$CVAT_DIR" remote set-url "$CVAT_REMOTE_NAME" "$CVAT_REPO_URL"
  else
    git -C "$CVAT_DIR" remote add "$CVAT_REMOTE_NAME" "$CVAT_REPO_URL"
  fi
  log "Fetching updates from $CVAT_REMOTE_NAME..."
  git -C "$CVAT_DIR" fetch "$CVAT_REMOTE_NAME" --prune
fi

# Ref checkout (safe: do not destroy local uncommitted changes)
log "Checking out CVAT ref: $CVAT_GIT_REF"
if ! git -C "$CVAT_DIR" diff --quiet || ! git -C "$CVAT_DIR" diff --cached --quiet; then
  die "Working tree has local uncommitted changes. Commit/stash them before checkout."
fi

# Create local branch tracking remote branch if needed
if git -C "$CVAT_DIR" show-ref --verify --quiet "refs/remotes/$CVAT_REMOTE_NAME/$CVAT_GIT_REF"; then
  # CVAT_GIT_REF is a remote branch name that exists as origin/<name>
  git -C "$CVAT_DIR" checkout -B "$CVAT_GIT_REF" "$CVAT_REMOTE_NAME/$CVAT_GIT_REF"
elif git -C "$CVAT_DIR" show-ref --verify --quiet "refs/heads/$CVAT_GIT_REF"; then
  # Local branch exists
  git -C "$CVAT_DIR" checkout "$CVAT_GIT_REF"
else
  # Could be tag/commit; try direct checkout
  git -C "$CVAT_DIR" checkout "$CVAT_GIT_REF"
fi

# Optional: fast-forward pull if on a branch (safe)
if git -C "$CVAT_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
  log "Updating branch with fast-forward only..."
  git -C "$CVAT_DIR" pull --ff-only "$CVAT_REMOTE_NAME" "$CVAT_GIT_REF" || true
fi

############################################
# 5) Compose override for IP access (only rewrite if content differs)
############################################
cd "$CVAT_DIR"
COMPOSE_FILES=(-f docker-compose.yml -f components/serverless/docker-compose.serverless.yml)

OVERRIDE_PATH="$CVAT_DIR/docker-compose.override.yml"
WANT_OVERRIDE="0"

if [ "$CVAT_ALLOW_IP_ACCESS" = "1" ] && [ -n "$CVAT_TAILSCALE_IP" ]; then
  WANT_OVERRIDE="1"
  DESIRED_OVERRIDE="$(cat <<YML
services:
  cvat_server:
    labels:
      - "traefik.http.routers.cvat-ip.entrypoints=web"
      - "traefik.http.routers.cvat-ip.rule=Host(\`${CVAT_TAILSCALE_IP}\`) && (PathPrefix(\`/api/\`) || PathPrefix(\`/static/\`) || PathPrefix(\`/admin\`) || PathPrefix(\`/django-rq\`))"
      - "traefik.http.routers.cvat-ip.service=cvat"
      - "traefik.http.routers.cvat-ip.priority=2100"

  cvat_ui:
    labels:
      - "traefik.http.routers.cvat-ui-ip.entrypoints=web"
      - "traefik.http.routers.cvat-ui-ip.rule=Host(\`${CVAT_TAILSCALE_IP}\`)"
      - "traefik.http.routers.cvat-ui-ip.service=cvat-ui"
      - "traefik.http.routers.cvat-ui-ip.priority=2000"
YML
)"
  if [ ! -f "$OVERRIDE_PATH" ] || [ "$(cat "$OVERRIDE_PATH")" != "$DESIRED_OVERRIDE" ]; then
    log "Writing/Updating docker-compose.override.yml for IP access (Host workaround). IP: $CVAT_TAILSCALE_IP"
    printf "%s\n" "$DESIRED_OVERRIDE" > "$OVERRIDE_PATH"
  else
    log "docker-compose.override.yml already matches desired content; skipping rewrite."
  fi
  COMPOSE_FILES+=(-f docker-compose.override.yml)
else
  log "IP access workaround not requested or Tailscale IP not available. (CVAT_ALLOW_IP_ACCESS=$CVAT_ALLOW_IP_ACCESS, CVAT_TAILSCALE_IP=$CVAT_TAILSCALE_IP)"
  # If override exists, we do NOT delete it automatically (safer).
  # You can remove it manually if you want.
fi

############################################
# 6) Bring up CVAT with Serverless (Nuclio) enabled
############################################
log "Starting CVAT with serverless compose (Nuclio enabled)..."
BUILD_ARGS=()
if [ "$FORCE_REBUILD" = "1" ] || [ "$SIG_OLD" != "$SIG_NOW" ]; then
  BUILD_ARGS+=(--build)
fi

docker compose "${COMPOSE_FILES[@]}" up -d "${BUILD_ARGS[@]}"

# Basic readiness checks (helps resume reliability)
log "Waiting for CVAT API to be ready..."
if ! wait_http_ok "http://${CVAT_HOST}:8080/api/server/about" 60 2; then
  die "CVAT API did not become ready at http://${CVAT_HOST}:8080/api/server/about"
fi
log "CVAT API is reachable."

log "Waiting for Nuclio dashboard to be ready..."
if ! wait_http_ok "http://${CVAT_HOST}:8070" 60 2; then
  warn "Nuclio dashboard not reachable via host at http://${CVAT_HOST}:8070 yet. (May still be OK; continuing.)"
else
  log "Nuclio dashboard reachable."
fi

############################################
# 7) Initialize DB + groups + admin user
############################################
log "Applying DB migrations (idempotent)..."
docker exec -i cvat_server bash -lc "python3 manage.py migrate"
state_set MIGRATED "1"

log "Ensuring required auth groups exist (idempotent)..."
docker exec -i cvat_server bash -lc \
  "python3 manage.py shell -c \"from django.conf import settings; \
  from django.contrib.auth.models import Group; \
  names=set(['admin','user','worker']); \
  names.add(getattr(settings,'IAM_ADMIN_ROLE','admin')); \
  [Group.objects.get_or_create(name=n) for n in sorted(names)]; \
  print('Ensured groups:', sorted(names))\""
state_set GROUPS "1"

# Admin user handling:
# - Default: create if missing; do NOT overwrite password if exists
# - SYNC_ADMIN=1: always force password/flags to match .env
log "Ensuring CVAT admin user exists..."
docker exec -i \
  -e DJANGO_SUPERUSER_USERNAME="$DJANGO_SUPERUSER_USERNAME" \
  -e DJANGO_SUPERUSER_EMAIL="$DJANGO_SUPERUSER_EMAIL" \
  -e DJANGO_SUPERUSER_PASSWORD="$DJANGO_SUPERUSER_PASSWORD" \
  -e SYNC_ADMIN="$SYNC_ADMIN" \
  cvat_server \
  bash -lc 'python3 manage.py shell << "PY"
from django.contrib.auth import get_user_model
import os

U = get_user_model()
uname = os.environ["DJANGO_SUPERUSER_USERNAME"]
email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "")
pwd   = os.environ["DJANGO_SUPERUSER_PASSWORD"]
sync  = os.environ.get("SYNC_ADMIN", "0") == "1"

u = U.objects.filter(username=uname).first()
if u is None:
    u = U.objects.create_user(username=uname, email=email, password=pwd)
    u.is_active = True
    u.is_staff = True
    u.is_superuser = True
    u.save()
    print("superuser:", u.username, "created: True")
else:
    changed = False
    if u.email != email:
        u.email = email
        changed = True

    if not u.is_active:
        u.is_active = True; changed = True
    if not u.is_staff:
        u.is_staff = True; changed = True
    if not u.is_superuser:
        u.is_superuser = True; changed = True

    if sync:
        u.set_password(pwd)
        changed = True

    if changed:
        u.save()
    print("superuser:", u.username, "created: False", "synced_password:", sync, "changed:", changed)
PY'

state_set ADMIN "1"

log "Verifying users..."
docker exec -i cvat_server bash -lc 'python3 manage.py shell << "PY"
from django.contrib.auth import get_user_model
U=get_user_model()
print("users:", U.objects.count())
for u in U.objects.all()[:10]:
    print(u.username, u.email, u.is_superuser, u.is_active)
PY'

############################################
# 8) Install nuctl and deploy SAM function (resumable)
############################################
need_cmd curl
need_cmd jq

# Strict SAM1 function name (Nuclio)
SAM_FUNCTION_NAME="${SAM_FUNCTION_NAME:-pth-facebookresearch-sam-vit-h}"

nuclio_get_fn_json() {
  nuctl get functions -n nuclio -o json 2>/dev/null || true
}

# functions list accessor: supports different nuctl JSON shapes
nuclio_list_expr='(.items // .functions // .Items // [])'

nuclio_fn_exists() {
  nuclio_get_fn_json | jq -e --arg NAME "$SAM_FUNCTION_NAME" \
    "$nuclio_list_expr | any(.metadata.name? == \$NAME or .name? == \$NAME)" \
    >/dev/null 2>&1
}

nuclio_fn_status() {
  nuclio_get_fn_json | jq -r --arg NAME "$SAM_FUNCTION_NAME" \
    "$nuclio_list_expr
     | map(select(.metadata.name? == \$NAME or .name? == \$NAME))
     | (.[0].status.state // .[0].status // .[0].statusState // \"\")" \
    2>/dev/null | head -n1
}
nuclio_wait_fn_ready() {
  local tries="${1:-180}" sleep_s="${2:-2}"
  local st=""
  for _ in $(seq 1 "$tries"); do
    if ! nuclio_fn_exists; then
      echo "missing"
    else
      st="$(nuclio_fn_status)"
      echo "${st:-unknown}"
      if echo "$st" | grep -qi '^ready$'; then
        return 0
      fi
    fi
    sleep "$sleep_s"
  done
  return 1
}

NUCTL_INSTALLED_VER="$(nuctl version 2>/dev/null | head -n1 || true)"
if ! command -v nuctl >/dev/null 2>&1 || ! echo "$NUCTL_INSTALLED_VER" | grep -q "$NUCTL_VERSION"; then
  log "Installing nuctl v$NUCTL_VERSION..."
  TMPDIR="$(mktemp -d)"
  pushd "$TMPDIR" >/dev/null

  ARCH="$(uname -m)"
  if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
    die "This script currently expects x86_64/amd64. Detected: $ARCH"
  fi

  curl -fL -o nuctl "https://github.com/nuclio/nuclio/releases/download/${NUCTL_VERSION}/nuctl-${NUCTL_VERSION}-linux-amd64"
  chmod +x nuctl
  sudo mv nuctl /usr/local/bin/nuctl

  popd >/dev/null
  rm -rf "$TMPDIR"
else
  log "nuctl already matches desired version ($NUCTL_VERSION); skipping install."
fi

log "nuctl version: $(nuctl version 2>/dev/null | head -n1 || true)"

# Strict existence check for SAM1
SAM_EXISTS="0"
if nuclio_fn_exists; then
  SAM_EXISTS="1"
  log "SAM1 function exists: $SAM_FUNCTION_NAME (state: $(nuclio_fn_status || true))"
else
  log "SAM1 function NOT found: $SAM_FUNCTION_NAME"
fi

# Redeploy conditions:
# - REDEPLOY_SAM=1
# - config signature changed (e.g. GPU flag changed)
# - SAM not exists
if [ "$REDEPLOY_SAM" = "1" ] || [ "$SIG_OLD" != "$SIG_NOW" ] || [ "$SAM_EXISTS" != "1" ]; then
  log "Deploying SAM1 Nuclio function '$SAM_FUNCTION_NAME'..."
  cd "$CVAT_DIR/serverless"

  if [ "$DEPLOY_SAM_GPU" = "1" ] && [ -f "./deploy_gpu.sh" ]; then
    warn "DEPLOY_SAM_GPU=1 set. (You said SAM1 only, so normally keep DEPLOY_SAM_GPU=0)"
    ./deploy_gpu.sh pytorch/facebookresearch/sam/nuclio/
  else
    ./deploy_cpu.sh pytorch/facebookresearch/sam/nuclio/
  fi

  state_set SAM_DEPLOYED "1"
else
  log "SAM1 function already exists and no redeploy requested; skipping SAM deploy."
fi

log "Waiting SAM1 function to become 'ready'..."
if ! nuclio_wait_fn_ready 180 2; then
  warn "SAM1 did not reach 'ready' state in time."
  warn "Current state: $(nuclio_fn_status || echo unknown)"
  warn "Nuclio functions:"
  nuctl get functions -n nuclio || true
else
  log "SAM1 is ready: $SAM_FUNCTION_NAME"
fi

log "Listing Nuclio functions:"
nuctl get functions -n nuclio || true

############################################
# 9) CVAT -> Nuclio connectivity check (important for 'magic wand' visibility)
############################################
log "Checking Nuclio dashboard connectivity from cvat_server..."
if docker exec -i cvat_server bash -lc "curl -fsS http://nuclio:8070/api/functions >/dev/null"; then
  log "OK: cvat_server can reach nuclio dashboard."
else
  warn "NG: cvat_server cannot reach nuclio dashboard at http://nuclio:8070/api/functions"
  warn "This often prevents AI Tools (magic wand) from appearing."
  warn "Check docker network, serverless compose, or nuclio container health."
fi

############################################
# 10) Save current signature (for drift detection on next run)
############################################
state_set CONFIG_SIGNATURE "$SIG_NOW"

############################################
# 11) Final hints
############################################
cat <<EOF

========================================
✅ Done (resumable).

CVAT:
  http://${CVAT_HOST}:8080
  Login:
    user: ${DJANGO_SUPERUSER_USERNAME}
    pass: ${DJANGO_SUPERUSER_PASSWORD}
    (Password is only force-synced when SYNC_ADMIN=1)

Nuclio dashboard:
  http://${CVAT_HOST}:8070

AI Tools:
  In CVAT UI:
    Open a job -> Magic wand -> (Interactors / Auto Annotation)
  If the wand doesn't show:
    - Hard reload browser (Ctrl+Shift+R)
    - Confirm "cvat_server -> http://nuclio:8070/api/functions" is OK (script checks this)

Re-run behavior:
  - Completed steps are skipped where possible
  - If config changes, affected steps re-apply automatically (signature drift)

Common overrides:
  SYNC_ADMIN=1    # overwrite admin password/flags every run
  REDEPLOY_SAM=1  # redeploy SAM even if exists
  FORCE_REBUILD=1 # always rebuild docker images
  NO_APT=1        # skip apt installs

Stop:
  cd "$CVAT_DIR"
  docker compose -f docker-compose.yml -f components/serverless/docker-compose.serverless.yml down

========================================
EOF
