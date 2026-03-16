# ESS Community One-Shot Install

Automated setup of the **Element Server Suite (ESS)** on a fresh Ubuntu Server — fully equipped with K3s, cert-manager, Let's Encrypt and MatrixRTC.

---

## Prerequisites

- Ubuntu Server (recommended: 24.04 LTS), fresh installation
- Root access
- A public IPv4 address
- A registered domain name with DNS records configured (see below)

---

## DNS Configuration

The following **A-Records** must point to your public IP **before** running the script. Let's Encrypt requires working DNS records to issue TLS certificates.

| Hostname | Type | Target |
|---|---|---|
| `@` (Root domain) | A | `<YOUR_PUBLIC_IP>` |
| `matrix` | A | `<YOUR_PUBLIC_IP>` |
| `element` | A | `<YOUR_PUBLIC_IP>` |
| `auth` | A | `<YOUR_PUBLIC_IP>` |
| `admin` | A | `<YOUR_PUBLIC_IP>` |
| `rtc` | A | `<YOUR_PUBLIC_IP>` |

> ⚠️ **Important:** Do not create `AAAA` records if you are not using IPv6. The script is configured for IPv4-only.

---

## Firewall Ports

The script configures UFW automatically. The following ports must also be opened in your **external / hosting firewall** (e.g. Hetzner Cloud, AWS Security Groups, etc.):

| Port | Protocol | Purpose |
|---|---|---|
| `22` | TCP | SSH (default; adjustable via `SSH_PORT`) |
| `80` | TCP | HTTP — redirect & Let's Encrypt HTTP-01 Challenge |
| `443` | TCP | HTTPS — all web services |
| `8448` | TCP | Matrix Federation (optional, server-to-server) |
| `30881` | TCP | MatrixRTC (voice/video calls) |
| `30882` | UDP | MatrixRTC (voice/video calls) |

> ℹ️ Port `80` is **required** for Let's Encrypt to issue TLS certificates via HTTP-01 Challenge.

---

## Installation

### 1. Download the script

```bash
wget https://raw.githubusercontent.com/M3m0rys/ess-oneshot/main/install-ess.sh
chmod +x install-ess.sh
```

### 2. Run the script

**Option A — Environment variables:**

```bash
DOMAIN=example.com PUBLIC_IP=203.0.113.10 LE_EMAIL=admin@example.com ./install-ess.sh
```

**Option B — Arguments:**

```bash
./install-ess.sh example.com 203.0.113.10 admin@example.com
```

### Optional parameters

| Variable | Default | Description |
|---|---|---|
| `SSH_PORT` | `22` | SSH port for the UFW rule |
| `ESS_NS` | `ess` | Kubernetes namespace |
| `ESS_RELEASE` | `ess` | Helm release name |

Example with all options:

```bash
SSH_PORT=2222 ESS_NS=matrix ESS_RELEASE=matrix \
  DOMAIN=example.com PUBLIC_IP=203.0.113.10 LE_EMAIL=admin@example.com \
  ./install-ess.sh
```

---

## What the script does

1. **System update** — update APT packages and install base tools
2. **UFW firewall** — configure and open all required ports
3. **K3s** — install and start lightweight Kubernetes
4. **Helm** — install the Kubernetes package manager
5. **Namespace** — create the ESS namespace
6. **cert-manager** — install and configure
7. **Let's Encrypt ClusterIssuer** — set up HTTP-01 solver via Traefik
8. **ESS Helm chart** (`matrix-stack`) — deploy with:
   - TLS certificates via Let's Encrypt
   - User Directory Search (all local users discoverable)
9. **Status checks** — print pod, ingress and certificate status

---

## After Installation

Once the script completes successfully, the following services are available:

| Service | URL |
|---|---|
| Element Web | `https://element.<DOMAIN>` |
| Admin Panel | `https://admin.<DOMAIN>` |
| Auth Service (MAS) | `https://auth.<DOMAIN>` |
| Matrix Homeserver | `https://matrix.<DOMAIN>` |
| MatrixRTC | `https://rtc.<DOMAIN>` |

### Create an admin user

```bash
kubectl exec -n ess -it deployment/ess-matrix-authentication-service -- \
  mas-cli manage register-user
```

---

## Troubleshooting

**Check pod status:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -n ess
kubectl get certificates -n ess
kubectl get ingress -n ess
```

**cert-manager logs:**
```bash
kubectl logs -n cert-manager deployment/cert-manager
```

**Let's Encrypt failing?**
- Verify DNS with `dig matrix.<DOMAIN>` — must resolve to `PUBLIC_IP`
- Port `80` must be reachable from the internet
- Wait a few minutes for DNS propagation if records were recently created

---

## System Requirements

| | Minimum |
|---|---|
| OS | Ubuntu Server 24.04 LTS (fresh install) |
| RAM | 4 GB recommended |
| CPU | 2 cores recommended |
| Disk | 20 GB |
| Access | Root required |
| Network | Outbound internet access for APT, K3s, Helm and Let's Encrypt |
