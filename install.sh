#!/usr/bin/env bash
# install.sh - install / uninstall ftp-honeypot on Debian (tested target: Debian 13 "trixie")
#
#   sudo ./install.sh                         install with fail2ban (only loopback is whitelisted)
#   sudo ./install.sh --ignore-local          also whitelist your local networks (auto-detected LAN)
#   sudo ./install.sh --ignore "1.2.3.4 2001:db8::/48"   also whitelist these IPs / networks
#   sudo ./install.sh --no-fail2ban           honeypot + logging only, no banning
#   sudo ./install.sh --no-geoip              don't download the DB-IP database (no country/city in ftp-honeypot-bans)
#   sudo ./install.sh --uninstall             remove everything (logs are kept)

set -euo pipefail

APP=ftp-honeypot
PREFIX=/opt/$APP
LOGDIR=/var/log/$APP
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_FAIL2BAN=1
WITH_GEOIP=1
EXTRA_IGNORE=""
IGNORE_LOCAL=0
ACTION=install

c_ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[!!]\033[0m %s\n' "$*"; }
die()    { printf '\033[31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ignore)       [[ -n "${2:-}" ]] || die "--ignore needs a value, e.g. --ignore \"1.2.3.4\""
                        EXTRA_IGNORE="$EXTRA_IGNORE $2"; shift 2 ;;
        --ignore-local) IGNORE_LOCAL=1; shift ;;
        --no-fail2ban)  WITH_FAIL2BAN=0; shift ;;
        --no-geoip)     WITH_GEOIP=0; shift ;;
        --uninstall)    ACTION=uninstall; shift ;;
        -h|--help)      usage ;;
        *)              die "unknown option: $1 (see --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run me as root (sudo $0)"
command -v systemctl >/dev/null || die "systemd is required"

# --------------------------------------------------------------------------
do_uninstall() {
    c_info "stopping and removing $APP"
    systemctl disable --now "$APP.service" 2>/dev/null || true
    systemctl disable --now "$APP-geoip-update.timer" 2>/dev/null || true
    rm -f /etc/systemd/system/$APP.service \
          /etc/systemd/system/$APP-geoip-update.service /etc/systemd/system/$APP-geoip-update.timer
    systemctl daemon-reload

    if [[ -f /etc/fail2ban/jail.d/$APP.conf ]]; then
        rm -f /etc/fail2ban/jail.d/$APP.conf /etc/fail2ban/filter.d/$APP.conf \
              /etc/fail2ban/fail2ban.d/$APP.conf
        systemctl restart fail2ban 2>/dev/null || true
        c_ok "fail2ban jail removed (existing bans were lifted)"
    fi

    rm -f /etc/logrotate.d/$APP /usr/local/sbin/$APP-bans /usr/local/sbin/$APP-geoip-update
    rm -rf "$PREFIX" /var/lib/$APP /var/lib/private/$APP
    if id "$APP" >/dev/null 2>&1; then userdel "$APP" 2>/dev/null || true; fi
    c_ok "uninstalled. Logs kept in $LOGDIR (delete them yourself if you want)."
}

# --------------------------------------------------------------------------
detect_local_networks() {
    # Directly connected networks (your LAN), IPv4 and IPv6, link-local excluded.
    command -v ip >/dev/null || return 0
    {
        ip -o -4 route show scope link 2>/dev/null | awk '{print $1}'
        ip -o -6 route show proto kernel 2>/dev/null | awk '{print $1}'
        ip -o -6 route show proto ra 2>/dev/null | awk '{print $1}'
    } | { grep -E '/' || true; } | { grep -v '^fe80' || true; } | sort -u | tr '\n' ' '
}

do_install() {
    for f in honeypot.py systemd/$APP.service fail2ban/filter.d/$APP.conf \
             fail2ban/jail.d/$APP.conf fail2ban/fail2ban.d/$APP.conf logrotate/$APP \
             $APP-bans geoip/$APP-geoip-update systemd/$APP-geoip-update.service \
             systemd/$APP-geoip-update.timer; do
        [[ -f "$SRC/$f" ]] || die "missing $SRC/$f - run this from the repo folder"
    done

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        [[ "${ID:-}" == "debian" ]] || c_warn "this is $PRETTY_NAME, not Debian - continuing anyway"
    fi

    # Is something already on port 21 (that isn't us)?
    if ss -Hltn 'sport = :21' 2>/dev/null | grep -q . && ! systemctl is-active --quiet "$APP"; then
        ss -Hltnp 'sport = :21' || true
        die "something is already listening on TCP 21. Stop it first (e.g. vsftpd/proftpd)."
    fi

    c_info "installing packages"
    pkgs=(python3 logrotate)
    [[ $WITH_FAIL2BAN -eq 1 ]] && pkgs+=(fail2ban nftables)
    [[ $WITH_FAIL2BAN -eq 1 && $WITH_GEOIP -eq 1 ]] && pkgs+=(python3-maxminddb curl)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${pkgs[@]}" >/dev/null
    c_ok "packages: ${pkgs[*]}"

    if ! id "$APP" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent \
                --shell /usr/sbin/nologin "$APP"
        c_ok "created system user '$APP'"
    fi

    install -d -m 0755 "$PREFIX"
    install -m 0644 "$SRC/honeypot.py" "$PREFIX/honeypot.py"
    install -m 0644 "$SRC/README.md" "$PREFIX/README.md" 2>/dev/null || true
    install -d -m 0750 -o "$APP" -g "$APP" "$LOGDIR"
    touch "$LOGDIR/$APP.log"
    chown "$APP:$APP" "$LOGDIR/$APP.log"; chmod 0640 "$LOGDIR/$APP.log"
    c_ok "honeypot installed in $PREFIX, logs in $LOGDIR"

    install -m 0644 "$SRC/systemd/$APP.service" /etc/systemd/system/$APP.service
    install -m 0644 "$SRC/logrotate/$APP" /etc/logrotate.d/$APP
    systemctl daemon-reload
    systemctl enable --now "$APP.service" >/dev/null 2>&1
    systemctl restart "$APP.service"
    sleep 1
    systemctl is-active --quiet "$APP" || { journalctl -u "$APP" -n 20 --no-pager; die "service failed to start"; }
    c_ok "service $APP is running"

    if [[ $WITH_FAIL2BAN -eq 1 ]]; then
        local nets="" ignore
        if [[ $IGNORE_LOCAL -eq 1 ]]; then
            nets="$(detect_local_networks)"
            [[ -n "$nets" ]] || c_warn "--ignore-local: no local network detected"
        fi
        ignore="$(echo "$nets $EXTRA_IGNORE" | xargs)"
        c_info "whitelisting (never banned): 127.0.0.1/8 ::1 ${ignore:-<nothing else>}"
        [[ -n "$ignore" ]] || c_warn "nothing but loopback is whitelisted: a LAN machine touching port 21 WILL be banned (use --ignore-local or --ignore)"

        install -d -m 0755 /etc/fail2ban/filter.d /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d
        install -m 0644 "$SRC/fail2ban/fail2ban.d/$APP.conf" /etc/fail2ban/fail2ban.d/$APP.conf
        install -m 0755 "$SRC/$APP-bans" /usr/local/sbin/$APP-bans
        if [[ $WITH_GEOIP -eq 1 ]]; then
            install -m 0755 "$SRC/geoip/$APP-geoip-update" /usr/local/sbin/$APP-geoip-update
            install -m 0644 "$SRC/systemd/$APP-geoip-update.service" "$SRC/systemd/$APP-geoip-update.timer" \
                /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable --now "$APP-geoip-update.timer" >/dev/null 2>&1 || true
            if [[ -s /var/lib/$APP/dbip-city-lite.mmdb ]]; then
                c_ok "GeoIP database present (refreshed monthly)"
            else
                c_info "downloading the DB-IP GeoIP database (refreshed monthly)"
                if /usr/local/sbin/$APP-geoip-update >/dev/null; then
                    c_ok "GeoIP database installed: ftp-honeypot-bans shows country and city"
                else
                    c_warn "GeoIP download failed; bans work, locations won't show. Retry: sudo $APP-geoip-update"
                fi
            fi
        fi
        install -m 0644 "$SRC/fail2ban/filter.d/$APP.conf" /etc/fail2ban/filter.d/$APP.conf
        sed "s|@IGNOREIP@|$ignore|" "$SRC/fail2ban/jail.d/$APP.conf" \
            > /etc/fail2ban/jail.d/$APP.conf
        chmod 0644 /etc/fail2ban/jail.d/$APP.conf

        fail2ban-client -t >/dev/null || die "fail2ban config test failed (run: fail2ban-client -t)"
        systemctl enable --now fail2ban >/dev/null 2>&1
        # restart, not reload: dbpurgeage is a server setting
        systemctl restart fail2ban
        sleep 2
        fail2ban-client status "$APP" >/dev/null 2>&1 \
            && c_ok "fail2ban jail '$APP' active: one connection to port 21 = 1 month ban on all ports (repeat: up to 1 year)" \
            || c_warn "fail2ban jail not up yet - check: fail2ban-client status $APP"
    fi

    cat <<EOF

Done.
  Live log:        tail -f $LOGDIR/$APP.log
  Service:         systemctl status $APP
EOF
    [[ $WITH_FAIL2BAN -eq 1 ]] && cat <<EOF
  Manage bans:     sudo $APP-bans          (interactive: list, details, unban)
  Whitelist:       /etc/fail2ban/jail.d/$APP.conf  (ignoreip)

  Add every address you connect from to ignoreip BEFORE testing, or re-run:
    sudo $0 --ignore "<your IP>"      (one or more IPs / networks)
    sudo $0 --ignore-local            (your whole LAN)
EOF
    echo
    c_warn "Remember to forward TCP 21 on your router to this machine (and disable any FTP on the router itself)."
}

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
