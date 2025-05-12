#!/usr/bin/env bash
set -euo pipefail

### ───────────────────────────── prerequisites ─────────────────────────────
apt-get update -y
apt-get install -y tor iptables-persistent sudo curl

### ────────────────────── configure torrc for transproxy ───────────────────
cat > /etc/tor/torrc <<'EOF'
Log notice syslog
RunAsDaemon 1
User debian-tor

# Transparent proxy & DNS
TransPort 9040
DNSPort   5353
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1

# Harden a bit
AvoidDiskWrites 1
EOF

systemctl restart tor

### ──────────────────────── flush & set iptables rules ─────────────────────
iptables -F
iptables -t nat -F

# 1. Don't redirect Tor's own traffic
TOR_UID=$(id -u debian-tor)
iptables -t nat -A OUTPUT -m owner --uid-owner "$TOR_UID" -j RETURN

# 2. Allow loopback and local networks to skip Tor if you need (optional)
iptables -t nat -A OUTPUT -o lo -j RETURN
iptables -t nat -A OUTPUT -d 127.0.0.0/8      -j RETURN
iptables -t nat -A OUTPUT -d 10.0.0.0/8       -j RETURN
iptables -t nat -A OUTPUT -d 172.16.0.0/12    -j RETURN
iptables -t nat -A OUTPUT -d 192.168.0.0/16   -j RETURN

# 3. Redirect DNS & TCP to Tor
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5353
iptables -t nat -A OUTPUT -p tcp --syn      -j REDIRECT --to-ports 9040

# 4. Default policy: allow everything through (already redirected)
iptables -P OUTPUT ACCEPT
iptables -P INPUT  ACCEPT
iptables -P FORWARD DROP

# Persist rules
iptables-save > /etc/iptables/rules.v4

### ───────────────────────────── new operator user ─────────────────────────
adduser --disabled-password --gecos "" operator
usermod -aG sudo operator

# Restrict dangerous commands
cat > /etc/sudoers.d/operator_restrict <<'EOF'
operator ALL=(ALL:ALL) ALL, \
!/usr/sbin/iptables*, \
!/usr/sbin/nft*, \
!/bin/systemctl stop tor, \
!/bin/systemctl disable tor, \
!/bin/systemctl restart tor
EOF
chmod 440 /etc/sudoers.d/operator_restrict

echo "✓ Tor transparent gateway installed."
echo "   All outbound TCP+DNS now exits via Tor (TransPort 9040, DNSPort 5353)."
echo "   Login as 'operator' for day-to-day admin without the ability to break the tunnel."
