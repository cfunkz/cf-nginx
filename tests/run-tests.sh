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
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy   # all requests are local

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
section "unit: domain / URL validation"
for d in example.com a.b.example.co.uk '*.example.com' xn--bcher-kva.example home.arpa nas.lan 1password.com; do
    check "domain ok $d" valid_domain "$d"
done
for d in localhost 'exa mple.com' example.com. .example.com 'a*.example.com' '*.*.example.com' 'example.com;' \
         1.2.3.4 -a.example.com a-.example.com a_b.example.com ../etc.com EXAMPLE.COM 'a.com}' 'a..com' '*.com'; do
    check_not "domain reject $d" valid_domain "$d"
done
for u in http://127.0.0.1:3000 https://backend.lan:8443/app "http://[::1]:8080" http://unix:/run/app.sock; do
    check "proxy ok $u" valid_proxy_url "$u"
done
for u in 'http://127.0.0.1:3000;' 'http://x/$host' 'http://a b' ftp://x 'http://x}' 'http://x;return 200' ''; do
    check_not "proxy reject '$u'" valid_proxy_url "$u"
done
check_not "root /etc rejected" valid_root_dir /etc/nginx
check_not "root with .. rejected" valid_root_dir /var/www/../../etc
printf '{"success":true,"errors":[],"result":{"id":"1","certificate":"-----BEGIN CERTIFICATE-----\\nQUJD\\/REVG\\n-----END CERTIFICATE-----\\n","hostnames":["a.test"]}}' > "$FX/api.json"
eq "Origin CA response parsed" "$(cf_json_certificate "$FX/api.json")" $'-----BEGIN CERTIFICATE-----\nQUJD/REVG\n-----END CERTIFICATE-----'

# ---------------------------------------------------------------------------
section "domains: certificate checks"
sed -i 's|^ORIGIN_LOCK_ALLOW=.*|ORIGIN_LOCK_ALLOW=|' /etc/cf-nginx/cf-nginx.conf
"$CFN" update -q
chmod 0755 "$FX"
mkdir -p "$FX/www"; echo hello > "$FX/www/index.html"; chmod -R a+rX "$FX/www"
ss() { # key cert host
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 30 \
        -subj "/CN=$3" -addext "subjectAltName=DNS:$3,DNS:www.$3" -keyout "$1" -out "$2" >/dev/null 2>&1
}
ss "$FX/pub.key" "$FX/pub.crt" pub.test
ss "$FX/other.key" "$FX/other.crt" other.test
openssl req -x509 -newkey rsa:1024 -nodes -sha256 -days 30 -subj /CN=pub.test -addext subjectAltName=DNS:pub.test \
    -keyout "$FX/weak.key" -out "$FX/weak.crt" >/dev/null 2>&1
openssl pkey -in "$FX/pub.key" -aes256 -passout pass:secret -out "$FX/enc.key" 2>/dev/null
PUBARGS=(--public --proxy "http://127.0.0.1:$PORT")
check_not "mismatched key rejected" "$CFN" domain add pub.test "${PUBARGS[@]}" --cert "$FX/pub.crt" --key "$FX/other.key" -q
check_not "cert for another host rejected" "$CFN" domain add pub.test "${PUBARGS[@]}" --cert "$FX/other.crt" --key "$FX/other.key" -q
check_not "alias not covered rejected" "$CFN" domain add pub.test --alias api.pub.test "${PUBARGS[@]}" --cert "$FX/pub.crt" --key "$FX/pub.key" -q
check_not "RSA-1024 rejected" "$CFN" domain add pub.test "${PUBARGS[@]}" --cert "$FX/weak.crt" --key "$FX/weak.key" -q
check_not "encrypted key rejected" "$CFN" domain add pub.test "${PUBARGS[@]}" --cert "$FX/pub.crt" --key "$FX/enc.key" -q
check_not "nginx injection in --proxy rejected" "$CFN" domain add pub.test --public --proxy 'http://127.0.0.1:1;}' --cert "$FX/pub.crt" --key "$FX/pub.key" -q
check_not "mode is required" "$CFN" domain add pub.test --proxy http://127.0.0.1:1 --cert "$FX/pub.crt" --key "$FX/pub.key" -q
check_not "--allow 0.0.0.0/0 rejected" "$CFN" domain add lan.test --local --self-signed --root "$FX/www" --allow 0.0.0.0/0 -q
check_not "nothing written after rejections" test -e /etc/nginx/sites-available/pub.test.conf
echo 'server { listen 127.0.0.1:18099; server_name taken.test; return 204; }' > /etc/nginx/sites-available/taken.test.conf
check_not "refuses to overwrite a hand-written site" "$CFN" domain add taken.test --local --self-signed --root "$FX/www" -q
rm -f /etc/nginx/sites-available/taken.test.conf

# ---------------------------------------------------------------------------
section "domains: public (VPS behind Cloudflare)"
check "add public domain" "$CFN" domain add pub.test --alias www.pub.test "${PUBARGS[@]}" --cert "$FX/pub.crt" --key "$FX/pub.key" --hsts -q
check "site enabled" test -L /etc/nginx/sites-enabled/pub.test.conf
eq "key is 0600 root" "$(stat -c '%a %U' /etc/cf-nginx/certs/pub.test/key.pem)" "600 root"
eq "cert dir is 0700" "$(stat -c '%a' /etc/cf-nginx/certs/pub.test)" 700
check "origin lock included" grep -q 'cloudflare/origin-lock.conf' /etc/nginx/sites-available/pub.test.conf
sget() { sleep 0.7; curl -sk -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1/" "${@:2}"; }
eq "https via Cloudflare edge works" "$(sget pub.test)" 200
eq "alias works" "$(sget www.pub.test)" 200
check "HSTS + nosniff sent" bash -c "curl -sk -D- -o /dev/null --resolve pub.test:443:127.0.0.1 https://pub.test/ | grep -qi 'strict-transport-security' && curl -sk -D- -o /dev/null --resolve pub.test:443:127.0.0.1 https://pub.test/ | grep -qi 'x-content-type-options: nosniff'"
check_not "no nginx version leaked" bash -c "curl -sk -D- -o /dev/null --resolve pub.test:443:127.0.0.1 https://pub.test/ | grep -qi '^server: nginx/'"
eq "http redirects to https" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: pub.test' http://127.0.0.1/)" 301
check_not "TLS 1.1 refused" curl -sk --tls-max 1.1 --resolve pub.test:443:127.0.0.1 https://pub.test/
check "TLS catch-all installed" test -f /etc/nginx/conf.d/00-cf-nginx-default-tls.conf
check_not "unknown SNI gets no certificate" curl -sk --resolve nope.test:443:127.0.0.1 https://nope.test/
printf '173.245.48.0/20\n103.21.244.0/22\n104.16.0.0/13\n' > "$FX/v4"
"$CFN" update --force -q
eq "non-Cloudflare client blocked on https" "$(sget pub.test)" 403
printf '127.0.0.0/8\n173.245.48.0/20\n103.21.244.0/22\n' > "$FX/v4"
"$CFN" update --force -q
check "re-run without cert reuses the stored one" "$CFN" domain add pub.test --alias www.pub.test --public --root "$FX/www" -q
eq "re-run switched to static root" "$(sleep 0.7; curl -sk --resolve pub.test:443:127.0.0.1 https://pub.test/)" hello
check "dotfiles denied" bash -c "sleep 0.5; [ \"\$(curl -sk -o /dev/null -w '%{http_code}' --resolve pub.test:443:127.0.0.1 https://pub.test/.env)\" = 403 ]"

# ---------------------------------------------------------------------------
section "domains: local (homelab)"
check "add local domain (self-signed)" "$CFN" domain add nas.lan --local --self-signed --root "$FX/www" -q
eq "LAN client allowed" "$(sleep 0.7; curl -sk --resolve nas.lan:443:127.0.0.1 https://nas.lan/)" hello
check "self-signed cert covers name" bash -c "openssl x509 -in /etc/cf-nginx/certs/nas.lan/cert.pem -noout -checkhost nas.lan | grep -q 'does match'"
check_not "no origin lock on local sites" grep -q origin-lock /etc/nginx/sites-available/nas.lan.conf
check "restrict to another subnet" "$CFN" domain add nas.lan --local --root "$FX/www" --allow 192.168.50.0/24 -q
eq "client outside --allow denied" "$(sget nas.lan)" 403

# ---------------------------------------------------------------------------
section "domains: tunnel (cloudflared)"
check "add tunnel domain" "$CFN" domain add tun.test --tunnel --port 18090 --root "$FX/www" -q
check "listens on loopback only" bash -c "grep 'listen' /etc/nginx/sites-available/tun.test.conf | grep -vq '127.0.0.1\\|\\[::1\\]' && exit 1 || exit 0"
eq "tunnel origin serves" "$(sleep 0.7; curl -s -H 'Host: tun.test' -H 'CF-Connecting-IP: 198.51.100.77' http://127.0.0.1:18090/)" hello
sleep 0.5
check "visitor IP from tunnel logged" grep -q '^198.51.100.77 ' /var/log/nginx/tun.test.access.log
check_not "tunnel rejects --cert" "$CFN" domain add tun.test --tunnel --root "$FX/www" --self-signed -q

# ---------------------------------------------------------------------------
section "domains: csr, list, status, remove"
check "csr" bash -c "'$CFN' domain csr csr.test | grep -q 'BEGIN CERTIFICATE REQUEST'"
eq "csr key is 0600" "$(stat -c '%a' /etc/cf-nginx/certs/csr.test/key.pem)" 600
check "list shows domains" bash -c "'$CFN' domain list | grep -q '^pub.test .*public'"
check "status ok with domains" "$CFN" status
check "remove local domain" "$CFN" domain remove nas.lan -q
check_not "local site file gone" test -e /etc/nginx/sites-available/nas.lan.conf
check "keys kept by default" test -f /etc/cf-nginx/certs/nas.lan/key.pem
check "remove public domain + keys" "$CFN" domain remove pub.test --delete-keys -q
check_not "keys deleted" test -e /etc/cf-nginx/certs/pub.test
check_not "catch-all removed with last public domain" test -e /etc/nginx/conf.d/00-cf-nginx-default-tls.conf
check "nginx -t ok after removals" nginx -t

# ---------------------------------------------------------------------------
section "uninstall"
check_not "uninstall refuses while config uses \$cf_ vars" "$CFN" uninstall -q
check "nginx still valid after refused uninstall" nginx -t
sed -i 's/ cc=\$cf_country scheme=\$cf_scheme ray=\$cf_ray cf=\$cf_is_cloudflare//' "$SITE" "$FX/site.orig"
check "uninstall" "$CFN" uninstall -q
check_not "tunnel domain disabled by uninstall" test -e /etc/nginx/sites-enabled/tun.test.conf
check "site restored" cmp "$SITE" "$FX/site.orig"
check_not "hook removed" test -e /etc/nginx/conf.d/00-cloudflare.conf
check_not "snippets removed" test -e /etc/nginx/cloudflare
check "nginx -t ok after uninstall" nginx -t
check "uninstall idempotent" "$CFN" uninstall -q

rm -f /etc/nginx/sites-enabled/cftest "$SITE"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
