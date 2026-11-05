# Changelog

## Unreleased

- New `cf-nginx domain add|csr|remove|list`: one command per domain generates a hardened TLS site in one of three modes:
  - `--public` (VPS behind Cloudflare): origin locked to Cloudflare, real visitor IPs, optional Authenticated Origin Pulls, HTTP→HTTPS redirect.
  - `--local` (homelab/LAN): only private networks (or `--allow` CIDRs) may connect, optional `--listen` on one LAN IP.
  - `--tunnel` (cloudflared): plain HTTP on loopback only, no open ports, visitor IP from the tunnel.
- Certificates from `--origin-ca` (15-year Cloudflare Origin CA cert issued through the API; key generated on the server, token never on the command line), `--cert/--key`, `domain csr`, an interactive paste, or `--self-signed`.
- Every certificate is checked before use: not expired, matches the key, covers every hostname, no RSA < 2048, no MD5/SHA-1, no passphrase-protected keys. Keys are stored in `/etc/cf-nginx/certs/<domain>/` (0700, key 0600).
- Generated sites use TLS 1.2/1.3 with AEAD ciphers only, no session tickets, no session cache with client certs (CVE-2025-23419), `server_tokens off`, security headers, optional HSTS, and deny dotfiles for static roots.
- Public domains add a TLS catch-all (`ssl_reject_handshake`) so scanning the origin IP reveals no hostnames or certificates.
- `status` reports domain certificates that are missing or expire within 14 days; `uninstall` disables generated domain sites.
- `http.conf` now defines `$cf_conn_upgrade` for WebSocket proxying.

## 2.0.0

Complete rewrite.

- Generated include snippets in `/etc/nginx/cloudflare/` instead of pasting IP blocks into site files.
- New snippets: `origin-lock.conf`, `proxy-headers.conf`, `fastcgi-params.conf`, `origin-pull.conf` (Authenticated Origin Pulls), `cloudflare` log format, and `$cf_*` variables that only trust headers from real Cloudflare edges.
- `global-real-ip on|off` for http-level real IP restoration.
- Strict validation of downloaded IP lists (CIDR syntax, prefix limits, size and shrink checks); last good list kept on failure; bundled seed list for offline first install.
- Atomic file swaps, `nginx -t` before every reload, automatic rollback, no reload when nothing changed, `flock` against concurrent runs.
- Site edits limited to marked `include` lines, with backups outside the nginx config tree.
- UFW sync is diff-based and only touches rules cf-nginx created.
- Config file is parsed, not sourced.
- Hardened systemd timer with randomised start; cron fallback without systemd.
- `install.sh` (idempotent install/upgrade/uninstall/purge) and a `.deb` builder.
- Automatic migration from 1.x sites, UFW rules and units.
- Integration test suite and CI.
- Removed: interactive menu, `cf-nginx-validate`, certbot prompt, jq dependency.

## 1.0.1

- UFW support.

## 1.0.0

- Initial release.
