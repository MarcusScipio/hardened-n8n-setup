#!/usr/bin/env bash
# =============================================================================
# Provision a GCP VM for the hardened n8n stack.
#
# Creates a dedicated VPC, subnet, Cloud Router, NAT gateway, firewall rules,
# and a hardened Ubuntu VM. Everything scoped and isolated.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - A GCP project with Compute Engine API enabled
#   - Service account with Compute Admin + Network Admin roles
#
# Usage:
#   ./infra/provision-gcp.sh                                        # self-signed TLS
#   ./infra/provision-gcp.sh -d n8n.example.com -e you@email.com   # Let's Encrypt
#
# Options:
#   -d DOMAIN     Domain name (enables Let's Encrypt)
#   -e EMAIL      Email for Let's Encrypt (required with -d)
#   -r REGION     GCP region (default: europe-west1)
#   -z ZONE       GCP zone (default: europe-west1-b)
#   -m MACHINE    Machine type (default: e2-small)
#   -n NAME       VM name (default: n8n-server)
#   -p PROJECT    GCP project ID (default: current gcloud config)
# =============================================================================
set -euo pipefail

# --- Defaults ---
VM_NAME="n8n-server"
REGION="europe-west1"
ZONE="europe-west1-b"
MACHINE="e2-small"
DOMAIN=""
EMAIL=""
PROJECT=""

# Naming convention — all resources prefixed
PREFIX="n8n"
VPC_NAME="${PREFIX}-vpc"
SUBNET_NAME="${PREFIX}-subnet"
ROUTER_NAME="${PREFIX}-router"
NAT_NAME="${PREFIX}-nat"
SUBNET_RANGE="10.10.0.0/24"

# --- Parse flags ---
while getopts "d:e:r:z:m:n:p:" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    z) ZONE="$OPTARG" ;;
    m) MACHINE="$OPTARG" ;;
    n) VM_NAME="$OPTARG" ;;
    p) PROJECT="$OPTARG" ;;
    *) echo "Unknown option: -$opt" && exit 1 ;;
  esac
done

if [[ -n "$DOMAIN" && -z "$EMAIL" ]]; then
  echo "Error: -e EMAIL is required when using -d DOMAIN"
  exit 1
fi

# --- Resolve project ---
if [[ -z "$PROJECT" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null)
fi

if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "Error: no GCP project set. Use -p or: gcloud config set project <ID>"
  exit 1
fi

P="--project=$PROJECT"

echo ""
echo "  Provisioning n8n on GCP"
echo "  ======================="
echo ""
echo "  Project:  ${PROJECT}"
echo "  Region:   ${REGION}"
echo "  Zone:     ${ZONE}"
echo "  Machine:  ${MACHINE}"
echo "  VM name:  ${VM_NAME}"
echo "  VPC:      ${VPC_NAME}"
echo "  Subnet:   ${SUBNET_NAME} (${SUBNET_RANGE})"
if [[ -n "$DOMAIN" ]]; then
  echo "  Domain:   ${DOMAIN}"
  echo "  Email:    ${EMAIL}"
else
  echo "  TLS:      self-signed (no domain)"
fi
echo ""

# =============================================================================
# 1. VPC — custom, no default subnets
# =============================================================================
if gcloud compute networks describe "$VPC_NAME" $P &>/dev/null; then
  echo "  VPC ${VPC_NAME} already exists"
else
  echo "  Creating VPC: ${VPC_NAME}"
  gcloud compute networks create "$VPC_NAME" \
    $P \
    --subnet-mode=custom \
    --quiet
fi

# =============================================================================
# 2. Subnet — single region, private Google access enabled
# =============================================================================
if gcloud compute networks subnets describe "$SUBNET_NAME" $P --region="$REGION" &>/dev/null; then
  echo "  Subnet ${SUBNET_NAME} already exists"
else
  echo "  Creating subnet: ${SUBNET_NAME} (${SUBNET_RANGE})"
  gcloud compute networks subnets create "$SUBNET_NAME" \
    $P \
    --network="$VPC_NAME" \
    --region="$REGION" \
    --range="$SUBNET_RANGE" \
    --enable-private-ip-google-access \
    --quiet
fi

# =============================================================================
# 3. Cloud Router + NAT — outbound internet for the VM
# =============================================================================
if gcloud compute routers describe "$ROUTER_NAME" $P --region="$REGION" &>/dev/null; then
  echo "  Cloud Router ${ROUTER_NAME} already exists"
else
  echo "  Creating Cloud Router: ${ROUTER_NAME}"
  gcloud compute routers create "$ROUTER_NAME" \
    $P \
    --network="$VPC_NAME" \
    --region="$REGION" \
    --quiet
fi

# NAT — check if it exists on the router
if gcloud compute routers nats describe "$NAT_NAME" --router="$ROUTER_NAME" $P --region="$REGION" &>/dev/null; then
  echo "  Cloud NAT ${NAT_NAME} already exists"
else
  echo "  Creating Cloud NAT: ${NAT_NAME}"
  gcloud compute routers nats create "$NAT_NAME" \
    --router="$ROUTER_NAME" \
    $P \
    --region="$REGION" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --quiet
fi

# =============================================================================
# 4. Firewall rules — scoped to VPC, tagged to VM
# =============================================================================

# Allow SSH via IAP (gcloud compute ssh uses this)
create_fw_rule() {
  local NAME="$1" RULES="$2" RANGES="$3" DESC="$4"
  if gcloud compute firewall-rules describe "$NAME" $P &>/dev/null; then
    echo "  Firewall rule ${NAME} already exists"
  else
    echo "  Creating firewall rule: ${NAME}"
    gcloud compute firewall-rules create "$NAME" \
      $P \
      --network="$VPC_NAME" \
      --direction=INGRESS \
      --priority=1000 \
      --action=ALLOW \
      --rules="$RULES" \
      --source-ranges="$RANGES" \
      --target-tags="${PREFIX}-server" \
      --description="$DESC" \
      --quiet
  fi
}

# SSH via Identity-Aware Proxy only (no direct SSH from internet)
create_fw_rule "${PREFIX}-allow-iap-ssh" "tcp:22" "35.235.240.0/20" \
  "Allow SSH through IAP tunnel only"

# HTTP + HTTPS from anywhere (Traefik handles TLS)
create_fw_rule "${PREFIX}-allow-http" "tcp:80" "0.0.0.0/0" \
  "Allow HTTP (redirects to HTTPS)"

create_fw_rule "${PREFIX}-allow-https" "tcp:443" "0.0.0.0/0" \
  "Allow HTTPS inbound"

# Deny everything else (implicit in GCP, but explicit is clearer)
if ! gcloud compute firewall-rules describe "${PREFIX}-deny-all-ingress" $P &>/dev/null; then
  echo "  Creating firewall rule: ${PREFIX}-deny-all-ingress"
  gcloud compute firewall-rules create "${PREFIX}-deny-all-ingress" \
    $P \
    --network="$VPC_NAME" \
    --direction=INGRESS \
    --priority=65534 \
    --action=DENY \
    --rules=all \
    --source-ranges=0.0.0.0/0 \
    --description="Deny all other ingress (explicit catch-all)" \
    --quiet
fi

# =============================================================================
# 5. VM — hardened, on custom VPC
# =============================================================================
echo ""
echo "  Creating VM: ${VM_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

gcloud compute instances create "$VM_NAME" \
  $P \
  --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-balanced \
  --network-interface="network=${VPC_NAME},subnet=${SUBNET_NAME},address=" \
  --tags="${PREFIX}-server" \
  --metadata-from-file=startup-script="${SCRIPT_DIR}/bootstrap.sh" \
  --metadata="n8n-domain=${DOMAIN},acme-email=${EMAIL},postgres-pass=,grafana-pass=,gh-repo=MarcusScipio/hardened-n8n-setup" \
  --scopes=compute-ro,logging-write,monitoring-write \
  --shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --quiet

# --- Get external IP ---
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
  $P \
  --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "none")

echo ""
echo "  VM created."
echo ""

if [[ "$EXTERNAL_IP" != "none" && -n "$EXTERNAL_IP" ]]; then
  echo "  External IP: ${EXTERNAL_IP}"
else
  echo "  No external IP (outbound via Cloud NAT)."
  echo "  SSH access: gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap"
fi
echo ""

if [[ -n "$DOMAIN" ]]; then
  echo "  Next: point ${DOMAIN} -> ${EXTERNAL_IP} in your DNS."
  echo "  Then wait 2-3 minutes for the bootstrap to finish."
  echo ""
  echo "  n8n:     https://${DOMAIN}"
else
  echo "  Wait 2-3 minutes for the bootstrap script to finish."
  echo ""
  echo "  n8n:     https://${EXTERNAL_IP}"
  echo "  (browser will warn about self-signed cert -- that's expected)"
fi

echo ""
echo "  Grafana is NOT exposed publicly."
echo "  Access it via SSH tunnel:"
echo ""
echo "    gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap -- -L 3000:localhost:3000"
echo "    Then open: http://localhost:3000"
echo ""
echo "  SSH:   gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap"
echo "  Logs:  sudo tail -f /var/log/n8n-bootstrap.log"
echo ""
