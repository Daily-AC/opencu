# Disposable XFCE desktop for OpenCU Linux acceptance. It mirrors the shape of
# an agent-owned desktop: Xvnc (TigerVNC) display, XFCE, a browser, a terminal
# and an editor, run by an ordinary user with no root access at runtime.
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      tigervnc-standalone-server tigervnc-tools xfce4 xfce4-terminal mousepad \
      firefox-esr chromium dbus-x11 at-spi2-core libatk-adaptor \
      fonts-noto-cjk fonts-dejavu-core x11-utils xdotool imagemagick \
      python3 ca-certificates procps curl git less \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 -s /bin/bash her
COPY session.sh /usr/local/bin/opencu-test-session
RUN chmod 755 /usr/local/bin/opencu-test-session
USER her
WORKDIR /home/her
ENV DISPLAY=:1
CMD ["/usr/local/bin/opencu-test-session"]
