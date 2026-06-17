FROM rockylinux:9

# Pre-create munge and slurm groups/users with IDs matching the host system fast-cad
# host slurm: uid=966, gid=957
# host munge: uid=974, gid=970
RUN groupadd -g 970 munge && \
    useradd -u 974 -g 970 -d /run/munge -s /sbin/nologin -c "Runs Uid 'N' Gid Emporium" munge && \
    groupadd -g 957 slurm && \
    useradd -u 966 -g 957 -d /var/lib/slurm -s /sbin/nologin -c "Slurm Workload Manager" slurm

# Install required packages: code-server, Ceph client, SSSD, curl, VNC, Xfce
# Update system and enable additional repos
RUN dnf -y update && \
    dnf -y install epel-release dnf-plugins-core && \
    dnf config-manager --set-enabled crb && \
    # Install code-server via official script
    curl -fsSL https://code-server.dev/install.sh | sh && \
    curl -fsSL https://download.ceph.com/keys/release.asc -o /etc/pki/rpm-gpg/CEPH-KEY.asc && \
    rpm --import /etc/pki/rpm-gpg/CEPH-KEY.asc && \
    echo -e "[ceph]\nname=Ceph packages for \$basearch\nbaseurl=https://download.ceph.com/rpm-reef/el9/\$basearch\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/CEPH-KEY.asc\n\n[ceph-noarch]\nname=Ceph noarch packages\nbaseurl=https://download.ceph.com/rpm-reef/el9/noarch\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/CEPH-KEY.asc" > /etc/yum.repos.d/ceph.repo && \
    dnf -y groupinstall "xfce" && dnf -y install ceph-common sssd tigervnc-server xorg-x11-server-Xvfb && \
    dnf clean all && \
    dnf -y install python3-pip && \
    pip3 install flask ldap3 pysaml2 websockify && \
    mkdir -p /opt/novnc && \
    curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz | tar -xz --strip-components=1 -C /opt/novnc && \
    dnf clean all

# Install NodeSource Node.js 24 repo, VS Code repo, GitHub CLI repo, and Google Chrome repo
RUN curl -fsSL https://rpm.nodesource.com/setup_24.x | bash - && \
    rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo && \
    dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && \
    rpm --import https://dl.google.com/linux/linux_signing_key.pub && \
    echo -e "[google-chrome]\nname=google-chrome\nbaseurl=http://dl.google.com/linux/chrome/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\ngpgkey=https://dl.google.com/linux/linux_signing_key.pub" > /etc/yum.repos.d/google-chrome.repo

RUN dnf -y install code gh nodejs authselect google-chrome-stable okular evince vim xclip xsel nginx slurm slurm-slurmd environment-modules.x86_64 xmlsec1 xmlsec1-openssl && \
    dnf -y remove xfce4-pulseaudio-plugin pavucontrol && \
    dnf clean all && \
    rm -f /etc/xdg/autostart/xfce-polkit.desktop /etc/xdg/autostart/xfce4-screensaver.desktop /etc/xdg/autostart/org.gnome.SettingsDaemon.Sound.desktop && \
    python3 -c "import xml.etree.ElementTree as ET; tree = ET.parse('/etc/xdg/xfce4/panel/default.xml'); root = tree.getroot(); [p.remove(v) for p in root.findall('.//property[@name=\'plugin-ids\']') for v in p.findall('value') if v.attrib.get('value')=='8']; [p.remove(pr) for p in root.findall('.//property[@name=\'plugins\']') for pr in p.findall('property') if pr.attrib.get('name')=='plugin-8']; tree.write('/etc/xdg/xfce4/panel/default.xml', encoding='UTF-8', xml_declaration=True)" && \
    mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml && \
    echo -e '<?xml version="1.0" encoding="UTF-8"?>\n<channel name="xfwm4" version="1.0">\n  <property name="general" type="empty">\n    <property name="use_compositing" type="bool" value="false"/>\n  </property>\n</channel>' > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml && \
    mkdir -p /etc/environment-modules && \
    echo "/opt/tools/modules" > /etc/environment-modules/modulespath && \
    echo 'export MODULES_PATH="/opt/tools/modules"' > /etc/profile.d/modules-custom.sh && \
    echo 'export MODULEPATH="/opt/tools/modules"' >> /etc/profile.d/modules-custom.sh && \
    echo 'if [ -f /usr/share/Modules/init/bash_completion ]; then source /usr/share/Modules/init/bash_completion; fi' >> /etc/profile.d/modules-custom.sh

# Install GitHub Copilot CLI globally
RUN npm install -g @github/copilot

# Install Antigravity CLI system-wide
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin && \
    ln -sf /usr/local/bin/agy /usr/local/bin/antigravity-cli

# Install Claude Code (Claude CLI) system-wide
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    mkdir -p /usr/local/bin && \
    mv /root/.local/bin/claude /usr/local/bin/claude

# Create a non‑root user for Kasm
RUN useradd -m -s /bin/bash -u 1000 kasm_user && \
    mkdir -p /home/kasm_user && \
    chown kasm_user:kasm_user /home/kasm_user

# Copy SLDAP (LDAP) configuration and keys
RUN mkdir -p /etc/kasm/auth /usr/local/share/ca-certificates
COPY Google_2026_09_02_8804.crt /etc/kasm/auth/google.crt
COPY Google_2026_09_02_8804.key /etc/kasm/auth/google.key
COPY Google_2026_09_02_8804.crt /usr/local/share/ca-certificates/Google_2026_09_02_8804.crt
COPY Google_2026_09_02_8804.key /usr/local/share/ca-certificates/Google_2026_09_02_8804.key
RUN chmod 600 /etc/kasm/auth/google.key /usr/local/share/ca-certificates/Google_2026_09_02_8804.key && \
    chmod 644 /etc/kasm/auth/google.crt /usr/local/share/ca-certificates/Google_2026_09_02_8804.crt
COPY sssd.conf /etc/sssd/sssd.conf

# Ceph configuration (keyring supplied via env var at runtime)
RUN mkdir -p /etc/ceph
COPY ceph.conf /etc/ceph/ceph.conf
# Ceph client keyring will be supplied via CEPH_KEYRING_CONTENT env var at runtime
# Permissions will be set when keyring is written

# Set permissions for SSSD config, select SSSD profile, and configure pam_mkhomedir
RUN chmod 600 /etc/sssd/sssd.conf && \
    chown root:root /etc/sssd/sssd.conf && \
    authselect select sssd --force && \
    echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/system-auth

# Add Polkit rules to bypass password prompts for desktop services inside the VNC container
RUN mkdir -p /etc/polkit-1/rules.d && \
    echo 'polkit.addRule(function(action, subject) { return polkit.Result.YES; });' > /etc/polkit-1/rules.d/02-allow-all.rules && \
    chown polkitd:root /etc/polkit-1/rules.d/02-allow-all.rules && \
    chmod 644 /etc/polkit-1/rules.d/02-allow-all.rules

# Install code‑server extensions (example)
RUN mkdir -p /home/kasm_user/.config/code-server && \
    echo '{"extensions": ["ms-python.python","golang.Go"]}' > /home/kasm_user/.config/code-server/settings.json && \
    chown -R kasm_user:kasm_user /home/kasm_user/.config

# Set low‑bandwidth VNC options via environment variables (used by entrypoint)
ENV KASM_VNC_RESOLUTION=1280x720 \
    KASM_VNC_FPS=15 \
    KASM_VNC_COLOR_DEPTH=8 \
    KASM_VNC_CODEC=h264

# Add custom brand wallpaper (persimmons.ai)
COPY persimmons.png /usr/share/backgrounds/persimmons.png
RUN mkdir -p /usr/share/backgrounds/xfce && \
    cp /usr/share/backgrounds/persimmons.png /usr/share/backgrounds/xfce/xfce-shapes.svg

# Add custom Nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Add custom entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5901 8080 8000
COPY ldap_vnc_auth.py /opt/auth/ldap_vnc_auth.py
COPY generate_saml_config.py /opt/auth/generate_saml_config.py
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
