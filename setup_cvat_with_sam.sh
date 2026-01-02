#!/usr/bin/env bash
set -euo pipefail

############################################
# Load .env (local only)
############################################
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
if [ -f "$ENV_FILE" ]; then
  # load KEY=VALUE lines (no spaces around '=')
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
# User-configurable variables
############################################
CVAT_DIR="${CVAT_DIR:-$HOME/cvat}"
CVAT_VERSION_TAG="${CVAT_VERSION_TAG:-v2.54.0}"
CVAT_HOST="${CVAT_HOST:-localhost}"

# Allow access via IP (e.g., Tailscale IP) even when Traefik uses Host rules.
CVAT_ALLOW_IP_ACCESS="${CVAT_ALLOW_IP_ACCESS:-1}"
CVAT_TAILSCALE_IP="${CVAT_TAILSCALE_IP:-}"


# Create an admin user automatically (recommended).
# Change these before running if you want.
DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_USERNAME="$(echo "$DJANGO_SUPERUSER_USERNAME" | tr -cd 'a-zA-Z0-9@._+-')"

DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-admin@example.com}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-1234}"

# Nuclio CLI (nuctl) version must match CVAT's serverless compose expectation.
NUCTL_VERSION="${NUCTL_VERSION:-1.13.0}"

# Deploy SAM with CPU by default (stable).
# If you later want GPU, set DEPLOY_SAM_GPU=1 and add a GPU-enabled function spec yourself.
DEPLOY_SAM_GPU="${DEPLOY_SAM_GPU:-0}"

############################################
# Helpers
############################################
log() { echo -e "\n[+] $*\n"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $1"; exit 1; }; }

############################################
# 0) Basic packages
############################################
log "Installing basic packages (curl, git, jq, ca-certificates)..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl git jq gnupg lsb-release

############################################
# 1) Docker Engine + Docker Compose plugin (official repo)
############################################
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

log "Enabling and starting Docker..."
sudo systemctl enable docker
sudo systemctl restart docker

# Allow non-root docker usage
if ! groups "$USER" | grep -q "\bdocker\b"; then
  log "Adding user '$USER' to docker group (you may need to log out/in once after script finishes)..."
  sudo usermod -aG docker "$USER"
fi

############################################
# 2) NVIDIA Container Toolkit (Docker GPU support)
############################################
log "Installing NVIDIA Container Toolkit (for Docker GPU support)..."
# We keep it simple: install package + configure runtime via nvidia-ctk (official).
# Assumes NVIDIA driver is already installed and 'nvidia-smi' works on host.
sudo apt-get update -y
sudo apt-get install -y nvidia-container-toolkit || true

if command -v nvidia-ctk >/dev/null 2>&1; then
  log "Configuring Docker runtime for NVIDIA (nvidia-ctk runtime configure)..."
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
else
  echo "[WARN] nvidia-ctk not found. If you need GPU in containers, install NVIDIA Container Toolkit properly."
fi

# Quick sanity check (non-fatal)
if command -v nvidia-smi >/dev/null 2>&1; then
  log "Host GPU check (nvidia-smi):"
  nvidia-smi || true
else
  echo "[WARN] nvidia-smi not found on host. Install NVIDIA driver first if you need GPU."
fi

############################################
# 3) Clone CVAT and checkout a known version
############################################
log "Cloning CVAT into: $CVAT_DIR"
if [ ! -d "$CVAT_DIR/.git" ]; then
  git clone https://github.com/cvat-ai/cvat.git "$CVAT_DIR"
else
  log "CVAT repo already exists, fetching updates..."
  git -C "$CVAT_DIR" fetch --all --tags
fi

log "Checking out CVAT tag: $CVAT_VERSION_TAG"
git -C "$CVAT_DIR" checkout "$CVAT_VERSION_TAG"

############################################
# 4) Bring up CVAT with Serverless (Nuclio) enabled
############################################
log "Starting CVAT with serverless compose (Nuclio enabled)..."
cd "$CVAT_DIR"

############################################
# 4.1) Traefik Host-rule workaround for IP access (Tailscale etc.)
############################################
COMPOSE_FILES=(-f docker-compose.yml -f components/serverless/docker-compose.serverless.yml)

# --- replace your current "cvat-ui-any PathPrefix(/)" block with this ---

if [ "$CVAT_ALLOW_IP_ACCESS" = "1" ]; then
  if [ -z "$CVAT_TAILSCALE_IP" ] && command -v tailscale >/dev/null 2>&1; then
    CVAT_TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi

  if [ -n "$CVAT_TAILSCALE_IP" ]; then
    log "Enabling IP access via Traefik override (Host mismatch workaround). IP: $CVAT_TAILSCALE_IP"
    cat > docker-compose.override.yml <<YML
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
    COMPOSE_FILES+=(-f docker-compose.override.yml)
  else
    echo "[WARN] CVAT_ALLOW_IP_ACCESS=1 but CVAT_TAILSCALE_IP is empty and tailscale not found."
    echo "       IP access workaround not enabled."
  fi
fi


# Important: use the serverless compose file as per docs
docker compose "${COMPOSE_FILES[@]}" up -d --build

############################################
# 5) Initialize DB (migrate) + ensure groups + create admin
############################################
log "Applying DB migrations..."
docker exec -it cvat_server bash -lc "python3 manage.py migrate"

log "Ensuring required auth groups exist (admin/user/worker)..."
docker exec -it cvat_server bash -lc \
  "python3 manage.py shell -c \"from django.conf import settings; \
  from django.contrib.auth.models import Group; \
  names=set(['admin','user','worker']); \
  names.add(getattr(settings,'IAM_ADMIN_ROLE','admin')); \
  [Group.objects.get_or_create(name=n) for n in sorted(names)]; \
  print('Ensured groups:', sorted(names))\""

log "Ensuring CVAT admin user exists (idempotent, from .env)..."
docker exec -i cvat_server \
  -e DJANGO_SUPERUSER_USERNAME="$DJANGO_SUPERUSER_USERNAME" \
  -e DJANGO_SUPERUSER_EMAIL="$DJANGO_SUPERUSER_EMAIL" \
  -e DJANGO_SUPERUSER_PASSWORD="$DJANGO_SUPERUSER_PASSWORD" \
  bash -lc 'python3 manage.py shell << "PY"
from django.contrib.auth import get_user_model
import os

U = get_user_model()
uname = os.environ["DJANGO_SUPERUSER_USERNAME"]
email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "")
pwd   = os.environ["DJANGO_SUPERUSER_PASSWORD"]

u, created = U.objects.get_or_create(username=uname, defaults={"email": email})
u.email = email
u.is_active = True
u.is_staff = True
u.is_superuser = True
u.set_password(pwd)
u.save()

print("superuser:", u.username, "created:", created)
PY'

log "Verifying users..."
docker exec -i cvat_server bash -lc 'python3 manage.py shell << "PY"
from django.contrib.auth import get_user_model
U=get_user_model()
print("users:", U.objects.count())
for u in U.objects.all()[:10]:
    print(u.username, u.email, u.is_superuser, u.is_active)
PY'


############################################
# 6) Install nuctl (Nuclio CLI) and deploy SAM function
############################################
log "Installing nuctl v$NUCTL_VERSION..."
TMPDIR="$(mktemp -d)"
pushd "$TMPDIR" >/dev/null

ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
  echo "[ERROR] This script currently expects x86_64/amd64. Detected: $ARCH"
  exit 1
fi

curl -fL -o nuctl "https://github.com/nuclio/nuclio/releases/download/${NUCTL_VERSION}/nuctl-${NUCTL_VERSION}-linux-amd64"
chmod +x nuctl
sudo mv nuctl /usr/local/bin/nuctl

popd >/dev/null
rm -rf "$TMPDIR"

log "nuctl installed: $(nuctl version || true)"

log "Deploying SAM (Segment Anything) Nuclio function..."
cd "$CVAT_DIR/serverless"

if [ "$DEPLOY_SAM_GPU" = "1" ] && [ -f "./deploy_gpu.sh" ]; then
  echo "[WARN] You enabled DEPLOY_SAM_GPU=1. This will try deploy_gpu.sh if present,"
  echo "       but GPU function specs may still require manual tuning in the nuclio config."
  ./deploy_gpu.sh pytorch/facebookresearch/sam/nuclio/
else
  ./deploy_cpu.sh pytorch/facebookresearch/sam/nuclio/
fi

log "Listing Nuclio functions (should include SAM)..."
nuctl get functions -n nuclio || true

############################################
# 7) Final hints
############################################
cat <<EOF

========================================
✅ Done.

CVAT:
  http://${CVAT_HOST}:8080
  Login:
    user: ${DJANGO_SUPERUSER_USERNAME}
    pass: ${DJANGO_SUPERUSER_PASSWORD}

Nuclio dashboard:
  http://${CVAT_HOST}:8070

In CVAT UI:
  Open a job -> AI Tools -> (Interactors / Auto Annotation)
  You should find SAM available after Nuclio function is healthy.

Notes:
- If 'docker' command fails without sudo, log out/in to apply docker group membership.
- If SAM function shows unhealthy, open Nuclio dashboard (8070) and check logs.

Stop:
  cd "$CVAT_DIR"
  docker compose -f docker-compose.yml -f components/serverless/docker-compose.serverless.yml down

========================================
EOF

# ./setup_cvat_with_sam.sh
