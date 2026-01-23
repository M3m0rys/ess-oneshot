# ess-oneshot
Oneshot script to install ess on server via one command

Prerequisites

Firewall Settings for V-Server
Allow Ports:
  80/tcp
  443/tcp
  30881/tcp
  30882/udp

install via
```
sudo SSH_PORT=2222 DOMAIN="example.com" PUBLIC_IP="203.0.113.10" LE_EMAIL="admin@example.com" ./install-ess.sh
```
