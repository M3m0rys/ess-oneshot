#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ESS Community One-Shot Install (K3s + cert-manager + Let's Encrypt + ESS)
# - DOMAIN + PUBLIC_IP als Pflicht-Parameter (ENV oder CLI)
# - IPv4-only
# - Matrix User Directory Search: standardmäßig alle lokalen User findbar
#
# Requirements:
# - Ubuntu Server (z.B. 24.04) frisch
# - DNS A-Records existieren und zeigen auf PUBLIC_IP:
#   @, matrix, element, auth, admin, rtc -> PUBLIC_IP
# - Keine AAAA-Records (wenn du IPv6 nicht nutzt)
# ============================================================

usage() {
  cat <<EOF
Usage (ENV):
  DOMAIN=example.com PUBLIC_IP=203.0.113.10 LE_EMAIL=admin@example.com ./install-ess.sh

Usage (Args):
  ./install-ess.sh example.com 203.0.113.10 admin@example.com

Optional ENV:
  SSH_PORT=22
  ESS_NS=ess
  ESS_RELEASE=ess

Notes:
- PUBLIC_IP wird nur für Hinweise/Logs genutzt, keine DNS-Änderung wird gemacht.
- Für Let's Encrypt muss Port 80 erreichbar sein (HTTP-01).
EOF
}

DOMAIN="${DOMAIN:-${1:-}}"
PUBLIC_IP="${PUBLIC_IP:-${2:-}}"
LE_EMAIL="${LE_EMAIL:-${3:-}}"

SSH_PORT="${SSH_PORT:-22}"
ESS_NS="${ESS_NS:-ess}"
ESS_RELEASE="${ESS_RELEASE:-ess}"

if [[ -z "${DOMAIN}" || -z "${PUBLIC_IP}" || -z "${LE_EMAIL}" ]]; then
  usage
  exit 1
fi

HS_MATRIX="matrix.${DOMAIN}"
HS_ELEMENT="element.${DOMAIN}"
HS_AUTH="auth.${DOMAIN}"
HS_ADMIN="admin.${DOMAIN}"
HS_RTC="rtc.${DOMAIN}"

CONFIG_DIR="/root/ess-config-values"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "==> ESS Community Install (IPv4-only)"
echo "    Domain:    ${DOMAIN}"
echo "    Public IP: ${PUBLIC_IP}"
echo "    LE Email:  ${LE_EMAIL}"
echo

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Bitte als root ausführen."
  exit 1
fi

echo "==> 0) Quickcheck: Systemzeit (APT bricht bei falscher Uhr ab)"
timedatectl status --no-pager | sed -n '1,12p' || true

echo "==> 1) System Update + Basis-Pakete"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y
apt install -y curl ca-certificates ufw

echo "==> 2) Firewall (UFW) – ESS + MatrixRTC"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP (redirect + LE http01)'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 8448/tcp comment 'Matrix Federation (optional)'
ufw allow 30881/tcp comment 'MatrixRTC TCP'
ufw allow 30882/udp comment 'MatrixRTC UDP'
ufw --force enable
ufw status verbose

echo "==> 3) K3s installieren"
if ! systemctl is-active --quiet k3s; then
  curl -sfL https://get.k3s.io | sh -
fi

echo "==>    Warte auf K3s..."
sleep 60
systemctl status k3s --no-pager || true

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cat >/etc/profile.d/k3s-kubeconfig.sh <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF

echo "==>    Kubernetes Basis-Check"
kubectl get nodes -o wide
kubectl get pods -A

echo "==> 4) Helm installieren"
if ! need_cmd helm; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version

echo "==> 5) Namespace '${ESS_NS}' anlegen"
kubectl get namespace "${ESS_NS}" >/dev/null 2>&1 || kubectl create namespace "${ESS_NS}"

echo "==> 6) cert-manager installieren"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.yaml
echo "==>    Warte auf cert-manager..."
sleep 60
kubectl get pods -n cert-manager

echo "==> 6b) cert-manager: Nameserver für HTTP01 Self-Checks setzen (stabiler)"
if ! kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--acme-http01-solver-nameservers='; then
  kubectl patch deployment cert-manager -n cert-manager --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--acme-http01-solver-nameservers=8.8.8.8:53,1.1.1.1:53"}]'
  sleep 20
  kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s || true
fi

echo "==> 7) Values-Dateien erstellen"
mkdir -p "${CONFIG_DIR}"

cat > "${CONFIG_DIR}/letsencrypt-issuer.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${LE_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

cat > "${CONFIG_DIR}/hostnames.yaml" <<EOF
serverName: ${DOMAIN}

synapse:
  ingress:
    host: ${HS_MATRIX}

elementWeb:
  ingress:
    host: ${HS_ELEMENT}

matrixAuthenticationService:
  ingress:
    host: ${HS_AUTH}

elementAdmin:
  ingress:
    host: ${HS_ADMIN}

matrixRTC:
  ingress:
    host: ${HS_RTC}

wellKnownDelegation:
  enabled: true
EOF

cat > "${CONFIG_DIR}/tls.yaml" <<'EOF'
certManager:
  clusterIssuer: letsencrypt-prod
EOF

# User Directory Search: alle lokalen User per Suche auffindbar
cat > "${CONFIG_DIR}/user-directory.yaml" <<'EOF'
synapse:
  additional:
    user-directory.yaml:
      config: |
        user_directory:
          enabled: true
          search_all_users: true
          prefer_local_users: true
EOF

echo "==> 8) ClusterIssuer anwenden"
kubectl apply -f "${CONFIG_DIR}/letsencrypt-issuer.yaml"
kubectl get clusterissuer

echo "==> 9) ESS installieren"
helm upgrade --install --namespace "${ESS_NS}" "${ESS_RELEASE}" \
  oci://ghcr.io/element-hq/ess-helm/matrix-stack \
  -f "${CONFIG_DIR}/hostnames.yaml" \
  -f "${CONFIG_DIR}/tls.yaml" \
  -f "${CONFIG_DIR}/user-directory.yaml" \
  --wait --timeout 12m

echo "==> 10) Checks"
kubectl get pods -n "${ESS_NS}"
kubectl get ingress -n "${ESS_NS}" || true
kubectl get certificates -n "${ESS_NS}" || true

echo
echo "==> Fertig!"
echo "   Element Web:   https://${HS_ELEMENT}"
echo "   Admin:         https://${HS_ADMIN}"
echo "   Auth (MAS):    https://${HS_AUTH}"
echo "   Homeserver:    https://${HS_MATRIX}"
echo "   MatrixRTC:     https://${HS_RTC}"
echo
echo "==> Admin-User anlegen (interaktiv):"
echo "   kubectl exec -n ${ESS_NS} -it deployment/${ESS_RELEASE}-matrix-authentication-service -- mas-cli manage register-user"
echo
echo "==> DNS Reminder (A-Records, keine AAAA):"
echo "   @, matrix, element, auth, admin, rtc -> ${PUBLIC_IP}"
