#!/usr/bin/env bash
set -euo pipefail

CADuser="cadtv"
CAD_HOME="/home/${CADuser}"
R360_RAW_URL="https://raw.githubusercontent.com/TallGuyJames/CAD-TV-Raspberry-Pi/refs/heads/main/R360.py"

APP_URL="https://overwatch.responder360.com/"
CDP_PORT="9222"

CREDS_DIR="/etc/cadtv"
CREDS_FILE="${CREDS_DIR}/credentials.env"

R360_PY_DST="${CAD_HOME}/R360.py"
XINITRC_DST="${CAD_HOME}/.xinitrc"
BASH_PROFILE_DST="${CAD_HOME}/.bash_profile"

GETTY_DROPIN_DIR="/etc/systemd/system/getty@tty1.service.d"
GETTY_DROPIN_FILE="${GETTY_DROPIN_DIR}/autologin.conf"

# ---------- packages ----------
apt update
apt install -y \
  xserver-xorg curl x11-xserver-utils xinit openbox chromium-browser unclutter dbus-x11 python3-venv python3-full python3-pip python3-xdg

# Some distros use "chromium" not "chromium-browser"
if ! command -v chromium-browser >/dev/null 2>&1; then
  apt install -y chromium
fi

# ---------- user ----------
if ! id "${CADuser}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${CADuser}"
  usermod -aG sudo "${CADuser}"
fi

# ---------- autologin on tty1 ----------
mkdir -p "${GETTY_DROPIN_DIR}"
cat > "${GETTY_DROPIN_FILE}" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${CADuser} --noclear %I \$TERM
EOF

systemctl daemon-reload

# ---------- startx on login ----------
cat > "${BASH_PROFILE_DST}" <<'EOF'
# Auto-start X on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx
fi
EOF
chown "${CADuser}:${CADuser}" "${BASH_PROFILE_DST}"
chmod 0644 "${BASH_PROFILE_DST}"

# ---------- credentials ----------
mkdir -p "${CREDS_DIR}"
touch "${CREDS_FILE}"
chmod 0600 "${CREDS_FILE}"
chown root:root "${CREDS_FILE}"

# Create a template if empty
if [ ! -s "${CREDS_FILE}" ]; then
  echo
  echo "Responder360 CADtv setup"
  echo

  read -rp "Username: " K_USERNAME
  read -rsp "Password: " K_PASSWORD
  echo
  read -rp "Board ID (typically Station7#): " K_BOARDID

  cat > "${CREDS_FILE}" <<EOF
URL=${APP_URL}
USERNAME=${K_USERNAME}
PASSWORD=${K_PASSWORD}
AGENCY=springfd
BOARD_ID=${K_BOARDID}
UNIT=
KEEP_LOGGED_IN=1
EOF

  chmod 0600 "${CREDS_FILE}"
  chown root:${KIOSK_USER} "${CREDS_FILE}"
fi

# Allow CAD user to read creds (optional).
# If you want root-only, remove next 2 lines and run the python as root, not recommended.
chgrp "${CADuser}" "${CREDS_FILE}"
chmod 0640 "${CREDS_FILE}"

# ---------- venv + playwright ----------
sudo -u "${CADuser}" bash -lc "
python3 -m venv ${CAD_HOME}/pw
source ${CAD_HOME}/pw/bin/activate
pip install --upgrade pip
pip install playwright
python -m playwright install chromium
"

# ---------- xinitrc ----------
CHROME_BIN="chromium-browser"
if ! command -v chromium-browser >/dev/null 2>&1; then
  CHROME_BIN="chromium"
fi

cat > "${XINITRC_DST}" <<EOF
#!/bin/sh
xset -dpms
xset s off
xset s noblank

unclutter -idle 0.5 &

eval "\$(dbus-launch --sh-syntax)" >/dev/null

openbox-session &
sleep 1

${CHROME_BIN} \\
  --kiosk \\
  --app="${APP_URL}" \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --no-first-run \\
  --no-default-browser-check \\
  --disable-translate \\
  --disable-features=TranslateUI \\
  --disable-extensions \\
  --disable-pinch \\
  --overscroll-history-navigation=0 \\
  --user-data-dir=${CAD_HOME}/.chromium-kiosk \\
  --remote-debugging-port=${CDP_PORT} \\
  --remote-debugging-address=127.0.0.1 \\
  --new-window &

CHROME_PID=\$!
sleep 2

${CAD_HOME}/pw/bin/python ${R360_PY_DST} || true

wait "\$CHROME_PID"
EOF

chown "${CADuser}:${CADuser}" "${XINITRC_DST}"
chmod 0755 "${XINITRC_DST}"

# ---------- R360.py placeholder ----------
curl -fsSL "${R360_RAW_URL}" -o "${R360_PY_DST}"
chown "${CADuser}:${CADuser}" "${R360_PY_DST}"
chmod 0755 "${R360_PY_DST}"

echo "Done." 
echo "Reboot"