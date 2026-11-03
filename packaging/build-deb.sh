#!/usr/bin/env bash
# Build cf-nginx_<version>_all.deb into ./dist (no debhelper needed).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
VERSION="$(sed -n 's/^readonly VERSION="\(.*\)"/\1/p' bin/cf-nginx)"
OUT="dist"
ROOT="$(mktemp -d)"
chmod 0755 "$ROOT"   # never ship a 0700 "./" entry
trap 'rm -rf "$ROOT"' EXIT

install -D -m 0755 bin/cf-nginx                "$ROOT/usr/sbin/cf-nginx"
install -D -m 0644 share/cf-nginx/ips-v4.seed  "$ROOT/usr/share/cf-nginx/ips-v4.seed"
install -D -m 0644 share/cf-nginx/ips-v6.seed  "$ROOT/usr/share/cf-nginx/ips-v6.seed"
install -D -m 0644 share/cf-nginx/cf-nginx.conf "$ROOT/usr/share/cf-nginx/cf-nginx.conf"
install -D -m 0644 share/cf-nginx/cf-nginx.conf "$ROOT/etc/cf-nginx/cf-nginx.conf"
for u in cf-nginx-update.service cf-nginx-update.timer; do
    install -d "$ROOT/lib/systemd/system"
    sed 's|@SBINDIR@|/usr/sbin|g' "systemd/$u" > "$ROOT/lib/systemd/system/$u"
    chmod 0644 "$ROOT/lib/systemd/system/$u"
done
install -D -m 0644 README.md "$ROOT/usr/share/doc/cf-nginx/README.md"
install -D -m 0644 LICENSE   "$ROOT/usr/share/doc/cf-nginx/copyright"

install -d "$ROOT/DEBIAN"
cat > "$ROOT/DEBIAN/control" <<CTRL
Package: cf-nginx
Version: $VERSION
Section: httpd
Priority: optional
Architecture: all
Depends: bash (>= 4.4), curl, util-linux, diffutils, mawk | gawk
Recommends: nginx | nginx-core | nginx-full | nginx-light | nginx-extras, openssl
Suggests: ufw
Maintainer: cfunkz <david@techwizards.work>
Homepage: https://github.com/cfunkz/cf-nginx
Description: Cloudflare toolkit for nginx (real IP, headers, origin lock)
 Generates nginx include snippets from Cloudflare's published IP ranges and
 keeps them up to date daily: real visitor IP restoration, trusted CF-*
 headers, origin lockdown to Cloudflare, Authenticated Origin Pulls and
 optional UFW firewall sync. Every change is validated with nginx -t and
 rolled back on failure.
CTRL
echo "/etc/cf-nginx/cf-nginx.conf" > "$ROOT/DEBIAN/conffiles"

cat > "$ROOT/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    if [ -d /run/systemd/system ]; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
    if command -v nginx >/dev/null 2>&1 || [ -x /usr/sbin/nginx ]; then
        /usr/sbin/cf-nginx setup || echo "cf-nginx: setup did not complete; run 'sudo cf-nginx setup' to retry" >&2
    else
        echo "cf-nginx: nginx not found. Install nginx, then run 'sudo cf-nginx setup'." >&2
    fi
fi
exit 0
SH
cat > "$ROOT/DEBIAN/prerm" <<'SH'
#!/bin/sh
set -e
case "$1" in
    remove|deconfigure) /usr/sbin/cf-nginx uninstall || true ;;
esac
exit 0
SH
cat > "$ROOT/DEBIAN/postrm" <<'SH'
#!/bin/sh
set -e
if [ "$1" = purge ]; then rm -rf /var/lib/cf-nginx /etc/cf-nginx; fi
if [ -d /run/systemd/system ]; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
exit 0
SH
chmod 0755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" "$ROOT/DEBIAN/postrm"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/cf-nginx_${VERSION}_all.deb" >/dev/null
echo "$OUT/cf-nginx_${VERSION}_all.deb"
