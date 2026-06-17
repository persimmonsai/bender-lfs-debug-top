#!/bin/bash
set -e

# Correct /etc/hosts loopback mapping for container hostname to allow proper Slurm X11 backrouting
if [ -f /etc/hosts ]; then
  echo "Correcting /etc/hosts loopback mapping..."
  MY_HOSTNAME=$(hostname)
  sed "s/127.0.0.1[[:space:]]\+$MY_HOSTNAME/127.0.0.1 /g; s/::1[[:space:]]\+$MY_HOSTNAME/::1 /g" /etc/hosts > /etc/hosts.new && \
  cat /etc/hosts.new > /etc/hosts && \
  rm -f /etc/hosts.new
fi

# ------------------------------------------------------------
# 0. Start DBus and PolicyKit daemon
# ------------------------------------------------------------
echo "Pre-creating X11 socket directories..."
mkdir -p /tmp/.X11-unix /tmp/.ICE-unix
chown -R root:root /tmp/.X11-unix /tmp/.ICE-unix
chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix

echo "Starting dbus..."
mkdir -p /run/dbus
dbus-uuidgen --ensure || true
dbus-daemon --system || true

echo "Starting polkitd..."
if [ -f /usr/lib/polkit-1/polkitd ]; then
  /usr/lib/polkit-1/polkitd --no-debug &
fi

# ------------------------------------------------------------
# 1. Start SSSD (LDAP auth)
# ------------------------------------------------------------
if command -v sssd >/dev/null 2>&1; then
  echo "Starting sssd..."
  sssd -D || true
else
  echo "sssd not installed, skipping..."
fi

# ------------------------------------------------------------
# 2. Mount CephFS (kernel client)
# ------------------------------------------------------------
# Expected environment variables:
#   CEPH_MON   - comma‑separated list of monitor IPs (e.g., "10.0.0.1,10.0.0.2")
#   CEPH_KEYRING - path on the host to the ceph client keyring (mounted read‑only)

if [[ -n "$CEPH_MON" ]]; then
  echo "Preparing Ceph keyring from env var..."
  if [[ -n "$CEPH_KEYRING_CONTENT" ]]; then
    mkdir -p /etc/ceph
    CEPH_KEY=$(echo "$CEPH_KEYRING_CONTENT" | sed -n 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*\(.*\)/\1/p')
    echo "$CEPH_KEY" > /etc/ceph/key
    chmod 600 /etc/ceph/key
    KEYRING_OPT="secretfile=/etc/ceph/key"
  else
    echo "CEPH_KEYRING_CONTENT not set – cannot mount CephFS"
    KEYRING_OPT=""
  fi

  if [[ -n "$KEYRING_OPT" ]]; then
    echo "Mounting CephFS..."
    mkdir -p /mnt/cephfs
    MONS=$(echo "$CEPH_MON" | sed 's/,/:6789,/g')
    MONS="${MONS}:6789"
    mount -t ceph $MONS:/ /mnt/cephfs -o name=client.admin,$KEYRING_OPT || echo "Warning: Failed to mount CephFS"
    echo "CephFS mounted at /mnt/cephfs"
  fi
else
  echo "CEPH_MON not set – skipping CephFS mount"
fi

# ------------------------------------------------------------
# 3. Ensure user home is bind‑mounted (handled by Docker run)
# ------------------------------------------------------------
# The Kasm container expects the user home at /home/kasm_user
# No action needed here because Docker bind‑mount will map
# /work/kasm_home/<userid> -> /home/kasm_user

# ------------------------------------------------------------
# 4. Start code‑server (VS Code web)
# ------------------------------------------------------------
if command -v code-server >/dev/null 2>&1; then
  echo "Starting code‑server..."
  # Run as the non‑root Kasm user (uid 1000 is typical)
  su -s /bin/bash -c "code-server --bind-addr 0.0.0.0:8081 --auth none" kasm_user &
else
  echo "code‑server not installed, skipping..."
fi

# ------------------------------------------------------------
# 5. Launch the original Kasm VNC entrypoint
# ------------------------------------------------------------
# ------------------------------------------------------------
# 5. Start VNC server (Xfce session)
# ------------------------------------------------------------
# Clean any stale X lock file
rm -f /tmp/.X1-lock
# Ensure compositing is disabled in kasm_user's config directory and set custom wallpaper
su - kasm_user -c "mkdir -p /home/kasm_user/.config/xfce4/xfconf/xfce-perchannel-xml"
su - kasm_user -c "cat <<'EOF' > /home/kasm_user/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF"
su - kasm_user -c "cat <<'EOF' > /home/kasm_user/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorVNC-0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/persimmons.png"/>
        </property>
        <property name="workspace1" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/persimmons.png"/>
        </property>
        <property name="workspace2" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/persimmons.png"/>
        </property>
        <property name="workspace3" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/persimmons.png"/>
        </property>
      </property>
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/persimmons.png"/>
        </property>
      </property>
      <property name="monitorDEFAULT" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/persimmons.png"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF"
su - kasm_user -c "vncserver -kill :1 || true"
# Remove stale VNC lock files
su - kasm_user -c "rm -rf /home/kasm_user/.vnc/*"
# Ensure VNC xstartup launches XFCE
su - kasm_user -c "mkdir -p /home/kasm_user/.vnc && cat <<'EOF' > /home/kasm_user/.vnc/xstartup
#!/bin/sh
xrdb \$HOME/.Xresources
vncconfig -nowin &

# Start DBus Session Bus
if [ -z \"\$DBUS_SESSION_BUS_ADDRESS\" ]; then
    eval \$(dbus-launch --sh-syntax)
    export DBUS_SESSION_BUS_ADDRESS
fi

# Start GNOME Keyring Daemon
if [ -z \"\$GNOME_KEYRING_CONTROL\" ]; then
    eval \$(gnome-keyring-daemon --start --components=pkcs11,secrets,ssh)
    export GNOME_KEYRING_CONTROL
    export SSH_AUTH_SOCK
fi

xset s off
xset s noblank
xset -dpms
startxfce4 &
EOF
chmod +x /home/kasm_user/.vnc/xstartup"
# Clean any stale VNC/X locks
rm -f /tmp/.X*-lock

# Generate self-signed certificate for the authentication portal and websockify if not present
mkdir -p /etc/kasm/auth
if [ ! -f /etc/kasm/auth/server.crt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/kasm/auth/server.key \
        -out /etc/kasm/auth/server.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/OU=IT/CN=localhost"
fi
chmod 600 /etc/kasm/auth/server.key

# Ensure token directory for websockify exists
mkdir -p /tmp/tokens

# Start websockify proxy on port 6901, using token-based routing
websockify 6901 --token-plugin=TokenFile --token-source=/tmp/tokens &

# Start VNC server without password as kasm_user (for fallback display :1)
su - kasm_user -c "vncserver :1 -geometry 1280x720 -depth 24 -SecurityTypes None -PasswordFile /dev/null -localhost no -listen tcp || true"

# Modify noVNC light template to hide the Ctrl+Alt+Del button, support resize mode, and add copy/paste sync
python3 -c "
with open('/opt/novnc/vnc_lite.html', 'r') as f:
    content = f.read()
if 'display: none;' not in content:
    content = content.replace('#sendCtrlAltDelButton {', '#sendCtrlAltDelButton {\n            display: none;')
if 'resizeMode' not in content:
    content = content.replace(
        \"rfb.scaleViewport = readQueryVariable('scale', false);\",
        \"const resizeMode = readQueryVariable('resize', 'remote');\n        if (resizeMode === 'remote') {\n            rfb.resizeSession = true;\n        } else if (resizeMode === 'scale') {\n            rfb.scaleViewport = true;\n        } else {\n            rfb.scaleViewport = readQueryVariable('scale', false);\n        }\"
    )
if 'syncLocalClipboard' not in content:
    content = content.replace(
        'rfb.addEventListener(\"desktopname\", updateDesktopName);',
        'rfb.addEventListener(\"desktopname\", updateDesktopName);\n\n        // Clipboard synchronization\n        rfb.addEventListener(\"clipboard\", (e) => {\n            navigator.clipboard.writeText(e.detail.text).catch(err => {});\n        });\n\n        const syncLocalClipboard = () => {\n            navigator.clipboard.readText().then(text => {\n                if (text) {\n                    rfb.clipboardPasteFrom(text);\n                }\n            }).catch(err => {});\n        };\n\n        window.addEventListener(\"focus\", syncLocalClipboard);\n        document.addEventListener(\"visibilitychange\", () => {\n            if (document.visibilityState === \"visible\") {\n                syncLocalClipboard();\n            }\n        });'
    )
with open('/opt/novnc/vnc_lite.html', 'w') as f:
    f.write(content)
"

# SSL certificate generated above

# Set up Munge authentication
if [ -f /work/munge.key ]; then
    echo "Using shared munge key from /work/munge.key..."
    mkdir -p /etc/munge /run/munge /var/lib/munge /var/log/munge
    cp /work/munge.key /etc/munge/munge.key
    chown -R munge:munge /etc/munge /run/munge /var/lib/munge /var/log/munge
    chmod 400 /etc/munge/munge.key
    echo "Starting munged..."
    /usr/sbin/munged --force || echo "Warning: munged failed to start"
else
    echo "Munge key not found at /work/munge.key. Skipping munged start."
fi

# Set up Slurm configuration pointing to /work/slurm
echo "Setting up Slurm configuration symlinks..."
# Create slurm group and user if they don't exist
if ! getent group slurm >/dev/null; then
    groupadd -r slurm
fi
if ! getent passwd slurm >/dev/null; then
    useradd -r -g slurm -d /var/lib/slurm -s /sbin/nologin -c "Slurm Workload Manager" slurm
fi
mkdir -p /etc/slurm
ln -sf /work/slurm/slurm.conf /etc/slurm/slurm.conf
ln -sf /work/slurm/cgroup.conf /etc/slurm/cgroup.conf
mkdir -p /var/spool/slurmd /var/lib/slurm
chown -R slurm:slurm /var/spool/slurmd /var/lib/slurm 2>/dev/null || true

# Start slurmd if configuration exists
if [ -f /work/slurm/slurm.conf ]; then
    echo "Starting slurmd..."
    if [ -n "$HOST_HOSTNAME" ]; then
        echo "Using NodeName override: $HOST_HOSTNAME"
        /usr/sbin/slurmd -N "$HOST_HOSTNAME" || echo "Warning: slurmd failed to start"
    else
        /usr/sbin/slurmd || echo "Warning: slurmd failed to start"
    fi
else
    echo "Slurm configuration not found at /work/slurm/slurm.conf. Skipping slurmd start."
fi

# Start Nginx reverse proxy
echo "Starting Nginx reverse proxy..."
nginx

# Generate SAML configurations from SSSD settings
python3 /opt/auth/generate_saml_config.py || echo "Warning: failed to generate SAML configuration"

# Inject inactivity lock script and End Session button into noVNC
python3 -c '
path = "/opt/novnc/vnc_lite.html"
with open(path) as f:
    content = f.read()

inactivity_js = """
        // Inactivity timeout: 60 minutes (3600000 ms)
        const INACTIVITY_TIMEOUT = 3600000;
        let inactivityTimer;
        function resetInactivityTimer() {
            clearTimeout(inactivityTimer);
            inactivityTimer = setTimeout(() => {
                if (rfb) {
                    try { rfb.disconnect(); } catch(e) {}
                }
                window.location.href = "/logout";
            }, INACTIVITY_TIMEOUT);
        }
        ["mousemove", "mousedown", "keydown", "touchstart", "scroll"].forEach(name => {
            window.addEventListener(name, resetInactivityTimer, true);
        });
        resetInactivityTimer();
"""

if "INACTIVITY_TIMEOUT" not in content:
    content = content.replace("let rfb;", "let rfb;" + chr(10) + inactivity_js)

if "endSessionButton" not in content:
    target_pos = "position: fixed;" + chr(10) + "            top: 0px;" + chr(10) + "            right: 0px;" + chr(10) + "            border: 1px outset;"
    new_pos = "position: fixed;" + chr(10) + "            top: 0px;" + chr(10) + "            right: 110px;" + chr(10) + "            border: 1px outset;"
    content = content.replace(target_pos, new_pos)
    
    style_block = """
        #endSessionButton {
            position: fixed;
            top: 0px;
            right: 0px;
            background-color: #EF4C17;
            color: white;
            font: bold 12px Helvetica;
            border: 1px outset #c43508;
            padding: 5px 10px 4px 10px;
            cursor: pointer;
            z-index: 100;
            transition: background-color 0.2s;
        }
        #endSessionButton:hover {
            background-color: #ff6836;
        }
    </style>"""
    content = content.replace("</style>", style_block)
    
    target_html = "<div id=" + chr(34) + "sendCtrlAltDelButton" + chr(34) + ">Send CtrlAltDel</div>"
    new_html = target_html + chr(10) + "        <div id=" + chr(34) + "endSessionButton" + chr(34) + ">End Session</div>"
    content = content.replace(target_html, new_html)
    
    target_js = ".onclick = sendCtrlAltDel;"
    new_js = target_js + chr(10) + "        document.getElementById(" + chr(34) + "endSessionButton" + chr(34) + ").onclick = () => { window.location.href = " + chr(34) + "/shutdown" + chr(34) + "; };"
    content = content.replace(target_js, new_js)

with open(path, "w") as f:
    f.write(content)
' || echo "Warning: failed to patch noVNC with end session features"

# Start Flask authentication portal (LDAP login) in background
python3 /opt/auth/ldap_vnc_auth.py &

# Keep container running
exec tail -f /dev/null
