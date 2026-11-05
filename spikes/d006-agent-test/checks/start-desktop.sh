#!/bin/bash
# Starts a headless sway (1920x1080) on its own session bus; prints a file to `source` for the env.
# Usage: ~/agent-test/tools/start-desktop.sh   then: source ~/agent-test/tools/desktop.env
D=$HOME/agent-test/tools
pkill -u $USER sway 2>/dev/null; pkill -u $USER -f dbus-run-session 2>/dev/null; sleep 1
rm -rf /tmp/xdg-agent; mkdir -m 700 /tmp/xdg-agent
cat > $D/sway.conf <<EOF
output HEADLESS-1 mode 1920x1080@60Hz scale 1
for_window [title="^Files$"] floating enable
EOF
XDG_RUNTIME_DIR=/tmp/xdg-agent WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
 setsid dbus-run-session -- bash -c "echo \$DBUS_SESSION_BUS_ADDRESS > $D/bus; exec sway -c $D/sway.conf" >/tmp/xdg-agent/sway.log 2>&1 &
for i in $(seq 50); do ls /tmp/xdg-agent/wayland-* >/dev/null 2>&1 && [ -s $D/bus ] && break; sleep 0.2; done
W=$(basename $(ls /tmp/xdg-agent/wayland-[0-9]* | grep -v lock | head -1))
cat > $D/desktop.env <<EOF
export XDG_RUNTIME_DIR=/tmp/xdg-agent WAYLAND_DISPLAY=$W DBUS_SESSION_BUS_ADDRESS=$(cat $D/bus)
EOF
echo "desktop up. Run: source $D/desktop.env"
