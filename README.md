# ESS One-Shot Installer

A one-shot script to install ESS on a server with a single command.

## Prerequisites

### Firewall settings for V-Server

Allow the following ports:

- `80/tcp`
- `443/tcp`
- `30881/tcp`
- `30882/udp`

## Install

Run the installer like this:

```bash
sudo SSH_PORT=2222 DOMAIN="example.com" PUBLIC_IP="203.0.113.10" LE_EMAIL="admin@example.com" ./install-ess.sh
```
