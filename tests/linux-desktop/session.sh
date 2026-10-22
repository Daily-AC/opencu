#!/bin/sh
# Start Xvnc on :1 (VNC only on the container's loopback) and an XFCE session.
set -eu
export DISPLAY=:1
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
Xvnc :1 -geometry "${GEOMETRY:-1600x1000}" -depth 24 -SecurityTypes None \
  -localhost -rfbport 5901 -AlwaysShared >/tmp/xvnc.log 2>&1 &
for _ in $(seq 50); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done
exec dbus-launch --exit-with-session startxfce4 >/tmp/xfce.log 2>&1
