# Changelog

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
