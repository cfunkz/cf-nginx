#!/usr/bin/env bash
# cf-nginx installer for Debian/Ubuntu (idempotent: safe to re-run to upgrade).
#
#   sudo ./install.sh                 install or upgrade, then run setup
#   sudo ./install.sh --uninstall     remove integration and program files
#   sudo ./install.sh --purge         ...and delete /etc/cf-nginx + /var/lib/cf-nginx
#   sudo ./install.sh --no-setup      install files only
set -Eeuo pipefail
umask 022

PREFIX="${PREFIX:-/usr/local}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBIN="$PREFIX/sbin"
SHARE="$PREFIX/share/cf-nginx"
UNIT_DIR=/etc/systemd/system

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"

have_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

uninstall() {
    local purge="$1"
    if [[ -x "$SBIN/cf-nginx" ]]; then
        if (( purge )); then "$SBIN/cf-nginx" uninstall --purge || true
        else "$SBIN/cf-nginx" uninstall || true; fi
    fi
    rm -f "$UNIT_DIR/cf-nginx-update.service" "$UNIT_DIR/cf-nginx-update.timer"
    if have_systemd; then systemctl daemon-reload || true; fi
    rm -f "$SBIN/cf-nginx"
    rm -rf "$SHARE"
    info "cf-nginx removed."
}

case "${1:-}" in
    --uninstall) uninstall 0; exit 0 ;;
    --purge)     uninstall 1; exit 0 ;;
    ""|--no-setup) ;;
    *) die "unknown option $1" ;;
esac

[[ -f /etc/debian_version ]] || info "warning: this installer targets Debian/Ubuntu; continuing anyway"
if command -v dpkg-query >/dev/null 2>&1 \
    && dpkg-query -W -f='${Status}' cf-nginx 2>/dev/null | grep -q 'install ok installed'; then
    die "the cf-nginx .deb package is installed; upgrade it with the new .deb instead (or 'apt remove cf-nginx' first)"
fi

if ! command -v nginx >/dev/null 2>&1 && [[ ! -x /usr/sbin/nginx ]]; then
    die "nginx is not installed. Install it first:  apt install nginx"
fi

missing=()
for c in curl flock awk diff; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if (( ${#missing[@]} )); then
    info "installing missing dependencies: ${missing[*]}"
    pkgs=()
    for c in "${missing[@]}"; do
        case "$c" in curl) pkgs+=(curl) ;; flock) pkgs+=(util-linux) ;; awk) pkgs+=(mawk) ;; diff) pkgs+=(diffutils) ;; esac
    done
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
fi

install -d -m 0755 "$SBIN" "$SHARE"
install -m 0755 "$SRC/bin/cf-nginx" "$SBIN/cf-nginx.new" && mv -f "$SBIN/cf-nginx.new" "$SBIN/cf-nginx"
install -m 0644 "$SRC/share/cf-nginx/ips-v4.seed" "$SRC/share/cf-nginx/ips-v6.seed" \
                "$SRC/share/cf-nginx/cf-nginx.conf" "$SHARE/"
if [[ ! -f /etc/cf-nginx/cf-nginx.conf ]]; then
    install -d -m 0755 /etc/cf-nginx
    install -m 0644 "$SRC/share/cf-nginx/cf-nginx.conf" /etc/cf-nginx/cf-nginx.conf
fi

if have_systemd; then
    for u in cf-nginx-update.service cf-nginx-update.timer; do
        sed "s|@SBINDIR@|$SBIN|g" "$SRC/systemd/$u" > "$UNIT_DIR/$u.new"
        chmod 0644 "$UNIT_DIR/$u.new"
        mv -f "$UNIT_DIR/$u.new" "$UNIT_DIR/$u"
    done
    systemctl daemon-reload
fi

info "installed cf-nginx $("$SBIN/cf-nginx" --version | awk '{print $2}') to $SBIN"
[[ "${1:-}" == --no-setup ]] && exit 0
exec "$SBIN/cf-nginx" setup
