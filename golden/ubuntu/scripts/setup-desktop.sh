#!/bin/bash
# Runs inside the VM via Packer SSH provisioner after OS install.
# Installs XFCE desktop and configures auto-login for lab use.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    lightdm \
    lightdm-gtk-greeter \
    firefox \
    dbus-x11 \
    xdotool \
    x11-utils \
    x11vnc

# Nothing may ever put a password prompt in front of the student. No dedicated
# locker is installed, but xfce4-power-manager blanks the display on idle and
# then calls /usr/bin/xflock4, which — finding no locker — falls back to
# "dm-tool lock" and drops the LightDM greeter over the running session. The
# "xset s off -dpms" autostart below does not prevent this: it only turns off
# the X server's own blanking, not the power manager's. Every lock path (power
# manager, session menu, keyboard shortcut) funnels through xflock4, so making
# that a no-op is the single change that covers them all.
cat > /usr/bin/xflock4 << 'EOF'
#!/bin/sh
# Locking is disabled on lab pool VMs: single-student throwaway desktops that
# auto-login and are only ever reached through Guacamole. See setup-desktop.sh.
exit 0
EOF
chmod 755 /usr/bin/xflock4

# Belt and braces — stop the power manager blanking or DPMS-ing the display at
# all. Written system-wide so it applies before any user session exists.
install -d /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
  </property>
</channel>
EOF

# Auto-login: student sees the desktop immediately on VNC connect — no login screen
cat > /etc/lightdm/lightdm.conf << 'EOF'
[Seat:*]
autologin-user=student
autologin-user-timeout=0
user-session=xfce
greeter-show-manual-login=false
EOF

# Disable screensaver so the VNC session doesn't go dark mid-lab
cat > /etc/xdg/autostart/disable-screensaver.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Disable Screensaver
Exec=xset s off -dpms
Hidden=false
X-GNOME-Autostart-enabled=true
EOF

# x11vnc serves the auto-logged-in XFCE session on :5900 so guacd can reach it
# over the VM's ClusterIP Service — the same shape as RDP on the Windows pool.
#
# The password is capped at 8 characters on purpose: standard VNC auth derives a
# DES key from the first 8 bytes and silently ignores the rest, so a longer value
# here would not match what Guacamole sends. Keep this in sync with
# UBUNTU_VNC_PASS in deploy/api.yaml.
x11vnc -storepasswd 'Lab@2024' /etc/x11vnc.pass
chmod 600 /etc/x11vnc.pass

# Gate x11vnc on a session actually existing, not just on lightdm.service having
# been started. After=display-manager.service only orders against the unit, and
# x11vnc then starts ~0.5s behind LightDM — while LightDM is still writing
# /var/run/lightdm/root/:0 and about to read it back to authenticate its own
# connection to :0. `-auth guess` shells out to xauth against that same file and
# takes lock files beside it; losing that race makes LightDM log
# "Error connecting to XServer :0", give up without ever starting the greeter or
# the autologin session, and leave a bare X root window — a black screen that no
# amount of waiting fixes, because LightDM never retries.
#
# First boot off a freshly cloned disk is where this bites: the filesystem
# resize, SSH host key generation and snapd seeding all land in the same few
# seconds and stretch LightDM's startup right over x11vnc's. Reboots skip that
# work and come up fine, which is what makes it look intermittent.
cat > /usr/local/bin/wait-for-desktop << 'EOF'
#!/bin/sh
# Block until LightDM has a live session on :0. Bounded so a genuinely broken
# desktop fails the unit loudly instead of hanging forever.
for i in $(seq 120); do
    if XAUTHORITY=/var/run/lightdm/root/:0 xdpyinfo -display :0 >/dev/null 2>&1 &&
       loginctl list-sessions --no-legend 2>/dev/null | grep -q seat0; then
        exit 0
    fi
    sleep 1
done
echo "no desktop session on :0 after 120s" >&2
exit 1
EOF
chmod 755 /usr/local/bin/wait-for-desktop

cat > /etc/systemd/system/x11vnc.service << 'EOF'
[Unit]
Description=x11vnc remote desktop for the lab session
After=display-manager.service
Requires=display-manager.service

[Service]
Type=simple
ExecStartPre=/usr/local/bin/wait-for-desktop
# The Xauthority path is explicit rather than `-auth guess`: guessing runs xauth
# against LightDM's file, which is the race described above.
ExecStart=/usr/bin/x11vnc -display :0 -auth /var/run/lightdm/root/:0 \
    -rfbauth /etc/x11vnc.pass \
    -rfbport 5900 -forever -loop -shared -noxdamage -repeat
Restart=always
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

# Boot straight to graphical target
systemctl set-default graphical.target
systemctl enable lightdm
systemctl enable x11vnc
# systemctl enable is a no-op for qemu-guest-agent on Ubuntu 24.04 (no [Install] section).
# Create the wants symlink directly so it starts at boot.
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/qemu-guest-agent.service \
    /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service

# Prevent background updates from running during a student session
systemctl disable apt-daily.timer          2>/dev/null || true
systemctl disable apt-daily-upgrade.timer  2>/dev/null || true
systemctl disable apt-daily.service        2>/dev/null || true
systemctl disable apt-daily-upgrade.service 2>/dev/null || true

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
