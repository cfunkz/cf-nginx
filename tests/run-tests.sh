#!/usr/bin/env bash
# Integration tests for cf-nginx. They modify the real /etc/nginx and start
# nginx, so run them only in a throwaway container or VM:
#
#   sudo CF_NGINX_TEST=1 tests/run-tests.sh
#
# Requires: nginx (Debian/Ubuntu package), curl.
# shellcheck disable=SC2016  # literal nginx $variables in single quotes
set -Eeuo pipefail
[[ "${CF_NGINX_TEST:-}" == 1 ]] || { echo "refusing to run: set CF_NGINX_TEST=1 (this modifies /etc/nginx)"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN="$ROOT/bin/cf-nginx"
FX="$(mktemp -d)"
PORT=18080
SITE=/etc/nginx/sites-available/cftest
PASS=0 FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
# On failure, show the command's output so CI logs say why.
check() {
    local d="$1" out; shift
    if out="$("$@" 2>&1)"; then pass "$d"; else fail "$d"; printf '%s\n' "$out" | sed 's/^/       | /' | tail -n 20; fi
}
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { printf '\n== %s\n' "$*"; }
# nginx reloads asynchronously; give new workers a moment.
get() { sleep 0.7; curl -s -o /dev/null -w '%{http_code}' "$@" "http://127.0.0.1:$PORT/"; }
body() { sleep 0.7; curl -s "$@" "http://127.0.0.1:$PORT/"; }

cleanup() {
    nginx -s stop >/dev/null 2>&1 || true
    rm -rf "$FX"
}
# ---------------------------------------------------------------------------
section "unit: CIDR validation"
# shellcheck source=/dev/null
source "$CFN"
trap cleanup EXIT   # after sourcing: cf-nginx installs its own EXIT trap
for c in 1.2.3.0/24 104.16.0.0/13 255.255.255.255/32; do check "v4 ok $c" valid_v4_cidr "$c"; done
for c in 0.0.0.0/0 1.2.3.0/7 256.1.1.1/24 1.2.3/24 01.2.3.4/24 "1.2.3.4/24;" 1.2.3.4 "1.2.3.4/24 x"; do
    check_not "v4 reject $c" valid_v4_cidr "$c"
done
for c in 2400:cb00::/32 2a06:98c0::/29 2001:db8:0:0:0:0:0:1/128 ::/16 fe80::1/64; do check "v6 ok $c" valid_v6_cidr "$c"; done
for c in ::/0 2400:cb00::/8 2400:::1/32 1::2::3/64 2001:db8::g/64 12345::/32 1:2:3:4:5:6:7:8:9/64 :1:2::/32 "2400:cb00::/32}"; do
    check_not "v6 reject $c" valid_v6_cidr "$c"
done
printf '1.1.1.0/24\n\n 2.2.2.0/24 \r\n3.3.3.0/24' > "$FX/l"
eq "list normalised" "$(validate_list 4 "$FX/l" | tr '\n' ' ')" "1.1.1.0/24 2.2.2.0/24 3.3.3.0/24 "
printf '1.1.1.0/24\n2.2.2.0/24\n0.0.0.0/0\n' > "$FX/l"
check_not "list with /0 rejected" validate_list 4 "$FX/l"
printf '<html>oops</html>\n' > "$FX/l"
check_not "html rejected" validate_list 4 "$FX/l"

# ---------------------------------------------------------------------------
section "setup"
rm -f /etc/nginx/sites-enabled/cftest /etc/nginx/sites-enabled/cfbad
rm -rf /etc/cf-nginx /var/lib/cf-nginx /etc/nginx/cloudflare /etc/nginx/conf.d/00-cloudflare.conf
sed -i '/listen \[::\]/d' /etc/nginx/sites-available/default 2>/dev/null || true  # containers often lack IPv6
# Fixture "Cloudflare" list includes loopback so local curl acts as an edge.
printf '127.0.0.0/8\n173.245.48.0/20\n103.21.244.0/22\n' > "$FX/v4"
printf '2400:cb00::/32\n2606:4700::/32\n' > "$FX/v6"
mkdir -p /etc/cf-nginx
sed -e "s|^IPS_V4_URL=.*|IPS_V4_URL=file://$FX/v4|" -e "s|^IPS_V6_URL=.*|IPS_V6_URL=file://$FX/v6|" \
    -e 's|^ORIGIN_LOCK_ALLOW=.*|ORIGIN_LOCK_ALLOW=|' "$ROOT/share/cf-nginx/cf-nginx.conf" > /etc/cf-nginx/cf-nginx.conf

nginx -t >/dev/null 2>&1 || { echo "base nginx config invalid"; nginx -t; exit 1; }
nginx -s stop >/dev/null 2>&1 || true; sleep 1
nginx

check "setup succeeds" "$CFN" setup -q
check "snippets exist" test -f /etc/nginx/cloudflare/real-ip.conf -a -f /etc/nginx/cloudflare/http.conf
check "hook installed" test -f /etc/nginx/conf.d/00-cloudflare.conf
check "nginx -t ok" nginx -t
check "status ok" "$CFN" status
check "setup idempotent" "$CFN" setup -q
cat > "$SITE" <<EOF
upstream cftest_backend {
    server 127.0.0.1:9;   # 'server' inside upstream must not be touched
}
server {
    listen 127.0.0.1:$PORT;
    server_name cftest;
    default_type text/plain;
    location / { return 200 "ip=\$remote_addr cc=\$cf_country scheme=\$cf_scheme ray=\$cf_ray cf=\$cf_is_cloudflare\n"; }
    location /.well-known/acme-challenge/ { return 200 "acme\n"; }
}
server
{
    listen 127.0.0.1:18081;
    server_name cftest2;
    return 204;
}
EOF
ln -sf "$SITE" /etc/nginx/sites-enabled/cftest
cp "$SITE" "$FX/site.orig"
check "test site loads" nginx -t
nginx -s reload
sleep 1
eq "real-ip has all ranges" "$(grep -c '^set_real_ip_from' /etc/nginx/cloudflare/real-ip.conf)" 5

# ---------------------------------------------------------------------------
section "enable / real IP / trusted headers"
check "enable --lock" "$CFN" enable cftest --lock -q
eq "includes in both server blocks" "$(grep -c 'managed-by: cf-nginx' "$SITE")" 4
eq "upstream block untouched" "$(sed -n '/^upstream/,/^}/p' "$SITE" | grep -c include || true)" 0
cp "$SITE" "$FX/site.enabled"
check "enable idempotent" "$CFN" enable cftest --lock -q
check "enable twice = same file" cmp "$SITE" "$FX/site.enabled"
eq "visitor IP restored" "$(body -H 'CF-Connecting-IP: 198.51.100.7' -H 'CF-IPCountry: DE' -H 'CF-Visitor: {"scheme":"https"}' -H 'CF-Ray: 8a1b2c3d4e5f6789-AMS')" \
   "ip=198.51.100.7 cc=DE scheme=https ray=8a1b2c3d4e5f6789-AMS cf=1"
eq "bad country header dropped" "$(body -H 'CF-IPCountry: DE;evil')" "ip=127.0.0.1 cc= scheme=http ray= cf=1"

# ---------------------------------------------------------------------------
section "origin lock (requests not from Cloudflare)"
printf '173.245.48.0/20\n103.21.244.0/22\n104.16.0.0/13\n' > "$FX/v4"
check "update --force to non-loopback list" "$CFN" update --force -q
eq "direct request blocked" "$(get)" 403
eq "spoofed CF headers ignored" "$(get -H 'CF-Connecting-IP: 1.2.3.4')" 403
eq "acme challenge bypasses lock" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/.well-known/acme-challenge/x")" 200
sed -i 's|^ORIGIN_LOCK_ALLOW=.*|ORIGIN_LOCK_ALLOW="127.0.0.1"|' /etc/cf-nginx/cf-nginx.conf
check "update with allowlist" "$CFN" update -q
eq "allowlisted IP passes, spoofed headers stripped" "$(body -H 'CF-Connecting-IP: 1.2.3.4' -H 'CF-IPCountry: DE')" \
   "ip=127.0.0.1 cc= scheme=http ray= cf=0"

# ---------------------------------------------------------------------------
section "update safety"
cp -a /etc/nginx/cloudflare "$FX/cf.before"
printf '173.245.48.0/20\n0.0.0.0/0\n104.16.0.0/13\n' > "$FX/v4"
check_not "poisoned list rejected" "$CFN" update -q
check "snippets unchanged after bad list" diff -r /etc/nginx/cloudflare "$FX/cf.before"
printf '173.245.48.0/20\n' > "$FX/v4"
check_not "too-short list rejected" "$CFN" update -q
for i in $(seq 1 10); do echo "10.$i.0.0/16"; done > "$FX/v4"
"$CFN" update --force -q
printf '10.1.0.0/16\n10.2.0.0/16\n10.3.0.0/16\n' > "$FX/v4"
check_not "large shrink refused" "$CFN" update -q
printf '173.245.48.0/20\n103.21.244.0/22\n104.16.0.0/13\n' > "$FX/v4"
check "--force accepts shrink" "$CFN" update --force -q
rm -f "$FX/v4"
check_not "unreachable source exits non-zero" "$CFN" update -q
check "cache kept when unreachable" test -s /var/lib/cf-nginx/ips-v4.txt
check "nginx still valid" nginx -t
printf '173.245.48.0/20\n103.21.244.0/22\n104.16.0.0/13\n' > "$FX/v4"
check "unchanged update is a no-op" bash -c "'$CFN' update | grep -q 'already up to date'"

# ---------------------------------------------------------------------------
section "rollback on invalid site edit"
cat > /etc/nginx/sites-available/cfbad <<EOF
server {
    listen 127.0.0.1:18082;
    real_ip_header X-Forwarded-For;
}
EOF
cp /etc/nginx/sites-available/cfbad "$FX/bad.orig"
ln -sf /etc/nginx/sites-available/cfbad /etc/nginx/sites-enabled/cfbad
check_not "enable fails on conflicting directive" "$CFN" enable cfbad -q
check "conflicting site restored byte-for-byte" cmp /etc/nginx/sites-available/cfbad "$FX/bad.orig"
check "nginx -t still ok" nginx -t
rm -f /etc/nginx/sites-enabled/cfbad /etc/nginx/sites-available/cfbad

# ---------------------------------------------------------------------------
section "disable / global real IP"
check "disable" "$CFN" disable cftest -q
check "disable restores original file" cmp "$SITE" "$FX/site.orig"
printf '127.0.0.0/8\n173.245.48.0/20\n103.21.244.0/22\n' > "$FX/v4"
"$CFN" update --force -q
check "global-real-ip on" "$CFN" global-real-ip on -q
eq "global real IP works" "$(body -H 'CF-Connecting-IP: 203.0.113.9')" "ip=203.0.113.9 cc= scheme=http ray= cf=1"
check "global-real-ip off" "$CFN" global-real-ip off -q
eq "global real IP off" "$(body -H 'CF-Connecting-IP: 203.0.113.9')" "ip=127.0.0.1 cc= scheme=http ray= cf=1"

# ---------------------------------------------------------------------------
section "migration from cf-nginx 1.x"
awk '/server_name cftest;/ { print; print "    # BEGIN CLOUDFLARE IPS - DO NOT EDIT MANUALLY"; print "    set_real_ip_from 103.21.244.0/22;"; print "    real_ip_header CF-Connecting-IP;"; print "    # END CLOUDFLARE IPS"; next } { print }' \
    "$FX/site.orig" > "$SITE"
echo cftest > /var/lib/cf-nginx/enabled_sites
check "setup migrates" "$CFN" setup -q
check_not "legacy block removed" grep -q 'BEGIN CLOUDFLARE IPS' "$SITE"
check "include added" grep -q 'cloudflare/real-ip.conf; # managed-by: cf-nginx' "$SITE"
check "legacy list archived" test -f /var/lib/cf-nginx/enabled_sites.migrated
eq "migrated site restores IP" "$(body -H 'CF-Connecting-IP: 203.0.113.10')" "ip=203.0.113.10 cc= scheme=http ray= cf=1"

# ---------------------------------------------------------------------------
section "config parsing is not code execution"
# shellcheck disable=SC2016
echo 'NGINX_BIN=$(touch /tmp/cf-nginx-pwned)' >> /etc/cf-nginx/cf-nginx.conf
"$CFN" status >/dev/null 2>&1 || true
check_not "no command substitution from config" test -e /tmp/cf-nginx-pwned
sed -i '$d' /etc/cf-nginx/cf-nginx.conf

# ---------------------------------------------------------------------------
section "uninstall"
check_not "uninstall refuses while config uses \$cf_ vars" "$CFN" uninstall -q
check "nginx still valid after refused uninstall" nginx -t
sed -i 's/ cc=\$cf_country scheme=\$cf_scheme ray=\$cf_ray cf=\$cf_is_cloudflare//' "$SITE" "$FX/site.orig"
check "uninstall" "$CFN" uninstall -q
check "site restored" cmp "$SITE" "$FX/site.orig"
check_not "hook removed" test -e /etc/nginx/conf.d/00-cloudflare.conf
check_not "snippets removed" test -e /etc/nginx/cloudflare
check "nginx -t ok after uninstall" nginx -t
check "uninstall idempotent" "$CFN" uninstall -q

rm -f /etc/nginx/sites-enabled/cftest "$SITE"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
