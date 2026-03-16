#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Server Hardening Script für ESS Community Install
# - UFW Firewall (nur ESS-Ports)
# - SSH absichern (Passwort-Login mit Brute-Force-Schutz)
# - Fail2Ban (SSH + weitere Dienste)
# ============================================================

SSH_PORT="${SSH_PORT:-22}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Bitte als root ausführen."
  exit 1
fi

echo "============================================"
echo " ESS Server Hardening"
echo " SSH Port: ${SSH_PORT}"
echo "============================================"
echo

# ------------------------------------------------------------
# 1) UFW Firewall
# ------------------------------------------------------------
echo "==> 1) UFW Firewall konfigurieren"

apt install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"  comment 'SSH'
ufw allow 80/tcp             comment 'HTTP (Let'\''s Encrypt HTTP-01)'
ufw allow 443/tcp            comment 'HTTPS'
ufw allow 8448/tcp           comment 'Matrix Federation (optional)'
ufw allow 30881/tcp          comment 'MatrixRTC TCP'
ufw allow 30882/udp          comment 'MatrixRTC UDP'

ufw --force enable
ufw status verbose
echo

# ------------------------------------------------------------
# 2) SSH absichern
# ------------------------------------------------------------
echo "==> 2) SSH absichern"

SSHD_CONF="/etc/ssh/sshd_config"

# Backup anlegen
cp "${SSHD_CONF}" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# Hilfsfunktion: Wert setzen oder ersetzen
set_sshd() {
  local key="$1"
  local val="$2"
  if grep -qE "^#?${key}\s" "${SSHD_CONF}"; then
    sed -i "s|^#\?${key}\s.*|${key} ${val}|" "${SSHD_CONF}"
  else
    echo "${key} ${val}" >> "${SSHD_CONF}"
  fi
}

set_sshd "Port"                    "${SSH_PORT}"
set_sshd "PermitRootLogin"         "no"           # Root-Login deaktivieren
set_sshd "PasswordAuthentication"  "yes"          # Passwort erlaubt (Fail2Ban schützt)
set_sshd "MaxAuthTries"            "3"            # Max. 3 Versuche pro Verbindung
set_sshd "LoginGraceTime"          "30"           # 30s Zeit zum Einloggen
set_sshd "ClientAliveInterval"     "300"          # Keep-alive alle 5 min
set_sshd "ClientAliveCountMax"     "2"            # 2x keine Antwort = Trennung
set_sshd "X11Forwarding"           "no"           # X11 deaktivieren
set_sshd "AllowTcpForwarding"      "no"           # TCP Forwarding deaktivieren
set_sshd "PermitEmptyPasswords"    "no"           # Leere Passwörter verbieten
set_sshd "UseDNS"                  "no"           # DNS-Lookup deaktivieren (schneller)
set_sshd "Protocol"                "2"            # Nur SSH v2

# SSH neu starten
systemctl restart sshd
echo "    SSH Konfiguration gespeichert und neu gestartet."
echo

# ------------------------------------------------------------
# 3) Fail2Ban installieren und konfigurieren
# ------------------------------------------------------------
echo "==> 3) Fail2Ban installieren"

apt install -y fail2ban

# Lokale Konfiguration erstellen (wird bei Updates nicht überschrieben)
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Eigene IP-Adresse niemals bannen (Komma-getrennte Liste oder CIDR)
ignoreip = 127.0.0.1/8 ::1

# Beobachtungszeitraum (10 Minuten)
findtime  = 600

# Ban-Dauer (1 Stunde); -1 = permanent
bantime   = 3600

# Max. Fehlversuche bevor Ban
maxretry  = 5

# Benachrichtigung (optional, leer lassen wenn kein Mailserver)
destemail =
sendername = Fail2Ban
mta = sendmail
action = %(action_)s


# ----------------------------------------------------------
# SSH
# ----------------------------------------------------------
[sshd]
enabled   = true
port      = ${SSH_PORT}
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 3
bantime   = 7200
findtime  = 600

# Härtere Regel für direkte Root-Login-Versuche
[sshd-ddos]
enabled   = true
port      = ${SSH_PORT}
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 2
bantime   = 86400
findtime  = 60


# ----------------------------------------------------------
# Wiederholte Offender (Ban-Zeit verdoppeln)
# ----------------------------------------------------------
[recidive]
enabled   = true
logpath   = /var/log/fail2ban.log
banaction = iptables-allports
bantime   = 604800
findtime  = 86400
maxretry  = 3
EOF

# Fail2Ban aktivieren und starten
systemctl enable fail2ban
systemctl restart fail2ban

echo "    Fail2Ban konfiguriert und gestartet."
echo

# ------------------------------------------------------------
# 4) Weitere System-Härtungen
# ------------------------------------------------------------
echo "==> 4) System-Härtungen"

# Unnötige Pakete entfernen
apt autoremove -y
apt autoclean -y

# Automatische Sicherheitsupdates aktivieren
apt install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades || true

echo "    Automatische Sicherheitsupdates aktiviert."
echo

# ------------------------------------------------------------
# 5) Status-Übersicht
# ------------------------------------------------------------
echo "============================================"
echo " Hardening abgeschlossen – Status-Übersicht"
echo "============================================"
echo
echo "--- UFW Status ---"
ufw status verbose
echo
echo "--- Fail2Ban Status ---"
fail2ban-client status
echo
echo "--- SSH Konfiguration (Auszug) ---"
sshd -T 2>/dev/null | grep -E "^(port|permitrootlogin|passwordauthentication|maxauthtries|logingracetime|x11forwarding)" || true
echo

echo "============================================"
echo " Wichtige Hinweise:"
echo "============================================"
echo " - Root-Login per SSH ist DEAKTIVIERT."
echo "   Stelle sicher, dass ein sudo-User existiert:"
echo "   adduser <username> && usermod -aG sudo <username>"
echo
echo " - Fail2Ban bannt nach 3 Fehlversuchen für 2h (SSH)"
echo "   Eigene IP prüfen: fail2ban-client status sshd"
echo "   IP entbannen:     fail2ban-client set sshd unbanip <IP>"
echo
echo " - SSH Port: ${SSH_PORT}"
echo "============================================"
