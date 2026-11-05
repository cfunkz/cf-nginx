# cf-nginx

**A Cloudflare add-on for the nginx you already run.** On Debian and Ubuntu it detects your nginx install and gives you ready-made include snippets for the usual Cloudflare tasks: restoring the real visitor IP, passing trusted `CF-*` headers to your app, accepting traffic only from Cloudflare, Authenticated Origin Pulls (mTLS), and optional UFW firewall rules. Cloudflare's IP ranges are refreshed every day. Each update is validated, tested with `nginx -t`, and rolled back automatically if anything fails.

```bash
sudo cf-nginx setup                       # once, after install
sudo cf-nginx enable example.com --lock   # real visitor IPs + only allow Cloudflare

# or create a new, hardened HTTPS site for a domain (public VPS, homelab, or Cloudflare Tunnel)
sudo cf-nginx domain add example.com --public --origin-ca --proxy http://127.0.0.1:3000
sudo cf-nginx domain add nas.home.arpa --local --self-signed --proxy http://127.0.0.1:5000
```

## Why

Running nginx behind Cloudflare without this leaves you with three problems:

* **Every request shows a Cloudflare IP.** Logs, rate limits, `allow`/`deny` rules and fail2ban all see the Cloudflare edge instead of the visitor.
* **Anyone can spoof `CF-Connecting-IP` or `CF-IPCountry`** by connecting to your origin directly.
* **The IP list changes.** Hard-coding it means it slowly goes stale.

cf-nginx keeps one generated, validated copy of the list and gives you snippets that only trust Cloudflare headers when the connection really came from Cloudflare.

## Install

Requirements: Debian 11+ or Ubuntu 20.04+, nginx (distro or nginx.org packages), bash, curl. You need `ufw` only for firewall sync, and `openssl` only for Authenticated Origin Pulls and `cf-nginx domain`.

**From source (zip or git):**

```bash
sudo ./install.sh            # installs to /usr/local and runs `cf-nginx setup`
```

**As a .deb (prebuilt, from GitHub Releases):**

```bash
wget -O /tmp/cf-nginx_all.deb https://github.com/cfunkz/cf-nginx/releases/latest/download/cf-nginx_all.deb
sudo apt install /tmp/cf-nginx_all.deb
```

**As a .deb (build it yourself):**

```bash
make deb                     # -> dist/cf-nginx_2.0.0_all.deb
sudo apt install ./dist/cf-nginx_2.0.0_all.deb
```

Both methods are idempotent, so running them again upgrades in place. Upgrading from cf-nginx 1.x migrates enabled sites and UFW rules automatically (see [Upgrading from 1.x](#upgrading-from-1x)).

## What setup does

1. Finds nginx (`nginx -V`) and its config directory, and checks for the realip module.
2. Downloads `https://www.cloudflare.com/ips-v4` and `ips-v6`, then validates every entry (details under [Security](#security-and-safety)). If the download fails on first install, it uses a bundled list instead and replaces it on the next successful download.
3. Writes the snippets to `/etc/nginx/cloudflare/` and a one-line hook, `/etc/nginx/conf.d/00-cloudflare.conf`, that loads the shared variables into `http {}`.
4. Runs `nginx -t`, reloads nginx, and schedules a daily refresh (systemd timer `cf-nginx-update.timer`, or `/etc/cron.d/cf-nginx` without systemd).

After setup your sites behave exactly as before. Nothing changes until you include a snippet or run `cf-nginx enable`.

## Usage

### Domains: new sites in one command

`cf-nginx domain add` writes a complete, hardened TLS site for a domain, installs its key and certificate, runs `nginx -t` (rolling back on failure) and reloads. Pick where the site lives:

```bash
# Public VPS behind Cloudflare: Cloudflare Origin CA cert issued via the API, only Cloudflare may connect
export CF_API_TOKEN=...    # token with Zone > SSL and Certificates > Edit (or use --token-file, or you'll be prompted)
sudo -E cf-nginx domain add example.com --alias www.example.com --public --origin-ca --proxy http://127.0.0.1:3000

# Homelab / LAN: only private networks may connect
sudo cf-nginx domain add nas.home.arpa --local --self-signed --proxy http://127.0.0.1:5000
sudo cf-nginx domain add jellyfin.example.com --local --cert fullchain.pem --key privkey.pem --proxy http://127.0.0.1:8096

# Cloudflare Tunnel (cloudflared on this host): loopback only, no open ports at all
sudo cf-nginx domain add app.example.com --tunnel --port 8080 --proxy http://127.0.0.1:3000
```

| Mode | Who can connect | Certificate | Good for |
| --- | --- | --- | --- |
| `--public` | Cloudflare edges only (`origin-lock.conf`), plus `ORIGIN_LOCK_ALLOW` | `--origin-ca` (recommended), `--cert/--key`, or `--self-signed` with SSL mode *Full* | A VPS with a public IP |
| `--local` | `127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ::1 fc00::/7 fe80::/10`, or your `--allow` list | `--cert/--key` (e.g. Let's Encrypt via DNS-01), or `--self-signed` | A homelab with LAN DNS |
| `--tunnel` | Only `cloudflared` on the same host (listens on 127.0.0.1) | None needed: Cloudflare terminates TLS | Home servers with no open ports |

Serve with `--proxy URL` (an app; WebSockets work) or `--root DIR` (static files; dotfiles like `.git` and `.env` are denied). Other options: `--alias NAME` (repeatable), `--hsts`, `--origin-pull` (public, after `cf-nginx origin-pull on`), `--max-body 64m`, `--allow CIDR` and `--listen IP` (local), `--port N` (tunnel).

**Bring your own key.** `sudo cf-nginx domain csr example.com` creates a private key on the server and prints a CSR. Paste it into Cloudflare (SSL/TLS → Origin Server → Create Certificate → *Use my private key and CSR*) or any CA, then run `domain add ... --cert cert.pem`; the stored key is used. Without any certificate option, `domain add` asks you to paste the certificate and key (the key is read hidden).

**What gets checked and generated:**

* The certificate must parse, not be expired, match the private key and cover every hostname. RSA keys under 2048 bits, MD5/SHA-1 signatures and passphrase-protected keys are refused. You get a warning when a certificate expires within 30 days, and `cf-nginx status` flags any that expire within 14 days. A Cloudflare Origin CA cert used outside `--public` gets a warning, because browsers only trust it through Cloudflare.
* Keys live in `/etc/cf-nginx/certs/<domain>/` (directory 0700, key 0600, root only). With `--origin-ca` the key is generated on the server and only the CSR is sent; the API token is read from the environment, a file or a hidden prompt, never from the command line, and is not stored.
* TLS 1.2 and 1.3 only, AEAD ciphers with forward secrecy, no session tickets, no session cache when client certificates are verified (CVE-2025-23419), `server_tokens off`, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, and HSTS with `--hsts`. HTTP redirects to HTTPS.
* For public domains, a catch-all `default_server` on 443 with `ssl_reject_handshake on` means scanning your IP reveals no hostnames or certificates (needs nginx 1.19.4+; skipped if you already have a 443 `default_server`).
* Domain names, upstream URLs and paths are strictly validated, so nothing can inject nginx directives. cf-nginx never overwrites a site file it did not create.

```bash
sudo cf-nginx domain list                      # domains, modes, certificate expiry
sudo cf-nginx domain add example.com --public --root /var/www/example   # re-run to change; keeps the cert
sudo cf-nginx domain remove example.com        # keeps keys; add --delete-keys to remove them
```

On a public VPS, also run `sudo ufw allow OpenSSH && sudo cf-nginx ufw on` so the firewall only lets Cloudflare reach ports 80 and 443. cf-nginx hardens the configuration it writes, but it can't patch nginx itself, so keep nginx updated (`unattended-upgrades` on Debian/Ubuntu).

### Per site (automatic)

```bash
sudo cf-nginx enable example.com                  # real visitor IP
sudo cf-nginx enable example.com --lock           # + reject non-Cloudflare traffic
sudo cf-nginx enable example.com --origin-pull    # + mTLS (after `cf-nginx origin-pull on`)
sudo cf-nginx disable example.com                 # remove everything cf-nginx added
```

`<site>` is a file name in `sites-available/` or `conf.d/`, or a path to any config file. `enable` adds one marked line per feature to the top of every top-level `server {}` block:

```nginx
server {
    include /etc/nginx/cloudflare/real-ip.conf; # managed-by: cf-nginx
    include /etc/nginx/cloudflare/origin-lock.conf; # managed-by: cf-nginx
    listen 443 ssl;
    server_name example.com;
    ...
}
```

The file is backed up to `/var/lib/cf-nginx/backups/` (the last 10 copies are kept) and replaced atomically with its owner and mode preserved. If `nginx -t` then fails, the original is restored. `disable` restores the file byte for byte. Running `enable` twice has the same effect as running it once.

### Global real IP

```bash
sudo cf-nginx global-real-ip on     # every server block, at http level
```

### Manual includes

Run `cf-nginx snippets` for the full list. Each snippet can go wherever nginx allows its directives:

| Snippet | Context | What it does |
| --- | --- | --- |
| `real-ip.conf` | http, server, location | `set_real_ip_from` for every Cloudflare range plus `real_ip_header CF-Connecting-IP` |
| `origin-lock.conf` | server, location | Returns 403 to anything that isn't Cloudflare or `ORIGIN_LOCK_ALLOW`. ACME HTTP-01 challenges bypass the lock by default. |
| `proxy-headers.conf` | location with `proxy_pass` | `X-Real-IP`, `X-Forwarded-For/Proto/Host`, and only *trusted* `CF-Connecting-IP`, `CF-IPCountry`, `CF-Ray`, `CF-Visitor` |
| `fastcgi-params.conf` | location with `fastcgi_pass` | The same for PHP-FPM, including the correct `HTTPS` value behind Flexible SSL. Include it after `fastcgi_params`. |
| `origin-pull.conf` | server with `listen 443 ssl` | Authenticated Origin Pulls: `ssl_verify_client` against Cloudflare's CA |
| `ips-v4.txt`, `ips-v6.txt` | — | Plain lists for your own tooling (nftables, scripts) |

Example reverse proxy:

```nginx
server {
    include /etc/nginx/cloudflare/real-ip.conf;
    include /etc/nginx/cloudflare/origin-lock.conf;
    listen 443 ssl;
    server_name app.example.com;

    access_log /var/log/nginx/app.access.log cloudflare;   # log format with CF-Ray + country

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        include /etc/nginx/cloudflare/proxy-headers.conf;
    }
}
```

> nginx gotcha: a `proxy_set_header` inside a block stops *all* `proxy_set_header` lines from outer blocks being inherited. Include `proxy-headers.conf` in the same block as your other `proxy_set_header` lines.

### Variables

These are defined once in `http.conf` and usable anywhere:

| Variable | Value |
| --- | --- |
| `$cf_is_cloudflare` | `1` if the TCP peer is a Cloudflare edge |
| `$cf_connecting_ip` | Visitor IP sent by Cloudflare (empty if the request didn't come through Cloudflare) |
| `$cf_country` | `CF-IPCountry`, e.g. `US`, or `T1` for Tor (empty if the request didn't come through Cloudflare) |
| `$cf_ray` | `CF-Ray` ID |
| `$cf_scheme` | `http`/`https` the visitor used to reach Cloudflare |
| `$cf_https` | `on` when `$cf_scheme` is https |
| `$cf_origin_allowed` | `1` for Cloudflare or `ORIGIN_LOCK_ALLOW` |

```nginx
if ($cf_country = "T1") { return 403; }           # block Tor
```

### Firewall (UFW)

```bash
sudo ufw allow OpenSSH          # do this first!
sudo cf-nginx ufw on            # allow 80,443/tcp only from Cloudflare
sudo ufw default deny incoming && sudo ufw enable
```

The sync is diff-based. New rules are added before stale ones are removed, so there is never a window with no rules. Only rules cf-nginx created (tracked in `/var/lib/cf-nginx/ufw-rules`) are ever deleted. `cf-nginx ufw off` removes them all. Ports are set with `UFW_PORTS`.

### Authenticated Origin Pulls

```bash
sudo cf-nginx origin-pull on                     # downloads + verifies Cloudflare's CA
sudo cf-nginx enable example.com --origin-pull
```

Then turn on *Authenticated Origin Pulls* in the Cloudflare dashboard (SSL/TLS → Origin Server).

### Status and updates

```bash
sudo cf-nginx status            # health check; exits non-zero if something needs attention
sudo cf-nginx update            # refresh now
sudo cf-nginx ips               # print current ranges
journalctl -u cf-nginx-update   # logs (or: grep cf-nginx /var/log/syslog for cron)
```

`update` exits `0` on success, `1` if nginx rejected the new config (it is rolled back), and `2` if a download failed and the last known good list was kept. Use these codes for monitoring.

## Configuration

`/etc/cf-nginx/cf-nginx.conf` uses `KEY=value` lines. It is **parsed, never executed**. Run `sudo cf-nginx update` after editing.

| Key | Default | |
| --- | --- | --- |
| `IPS_V4_URL` / `IPS_V6_URL` | cloudflare.com/ips-v4, -v6 | `https://`, or `file://` for a local mirror |
| `ENABLE_IPV6` | `yes` | |
| `GLOBAL_REAL_IP` | `no` | Use `cf-nginx global-real-ip on\|off` |
| `REAL_IP_HEADER` | `CF-Connecting-IP` | |
| `ORIGIN_LOCK_ALLOW` | `127.0.0.1 ::1` | Extra IPs/CIDRs allowed through `origin-lock.conf` (monitoring, office) |
| `ORIGIN_LOCK_STATUS` | `403` | Any 4xx; `444` closes the connection |
| `ORIGIN_LOCK_ACME_BYPASS` | `yes` | Let `/.well-known/acme-challenge/` through for certbot HTTP-01 |
| `ORIGIN_PULL_CA` | `no` | Use `cf-nginx origin-pull on\|off` |
| `UFW_SYNC` / `UFW_PORTS` | `no` / `80,443` | Use `cf-nginx ufw on\|off` |
| `MAX_SHRINK_PERCENT` | `50` | Refuse an update if a list shrinks by more than this |
| `NGINX_BIN` / `NGINX_CONF_DIR` | auto | Override detection (e.g. source builds) |

## Security and safety

* **Strict validation of downloaded lists.** Downloads are HTTPS-only (TLS 1.2+, no redirect to plain HTTP) with a size cap and timeouts. Every line must be a canonical IPv4 CIDR (/8 to /32) or IPv6 CIDR (/16 to /128), with no `0.0.0.0/0`, no junk, and no nginx syntax. A list with too few or too many entries, or one that shrinks by more than half, is rejected. A failed download never empties your config: the last good list is kept.
* **Atomic changes with automatic rollback.** New snippets are staged, swapped in by rename, checked with `nginx -t`, and only then reloaded. On failure the previous files are restored and nginx is not reloaded. If an update would change nothing, cf-nginx doesn't reload nginx at all.
* **Pre-flight check.** cf-nginx refuses to touch anything while your existing nginx config is already invalid, so it never takes the blame for, or masks, an unrelated error.
* **Spoof-proof headers.** `CF-*` headers and `CF-Visitor` scheme are trusted only when `$realip_remote_addr` is a Cloudflare edge. Anyone else's values become empty and are not forwarded.
* **Minimal footprint.** Site files only ever get marked `include` lines. Backups live in `/var/lib/cf-nginx/backups/` rather than in `sites-available/`, where nginx could load them by accident. Concurrent runs are serialised with `flock`.
* **Hardened systemd unit** (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, ...), with a randomised daily run time so fleets don't all hit Cloudflare at once.

## Uninstall

```bash
sudo ./install.sh --uninstall      # or --purge to also delete config + state
sudo apt remove cf-nginx           # .deb  (apt purge removes config + state)
```

Uninstall removes the includes from every site, the hook, the snippets, the UFW rules and the timer, then reloads nginx. If you have hand-written references to cf-nginx snippets or `$cf_*` variables, uninstall stops and lists them, so it never leaves nginx unable to start.

## Upgrading from 1.x

1.x pasted IP blocks (`# BEGIN CLOUDFLARE IPS ... # END CLOUDFLARE IPS`) into your site files. When you install 2.x (via `.deb` upgrade, or after removing the old package), `setup` replaces those blocks with a single `include` line, carries over your UFW setting with the old rules swapped for managed ones, and removes the old `cf-nginx.timer`. Old `*.bak-*` files in `sites-available/` are reported but not deleted. Review and remove them yourself.

The interactive menu and `cf-nginx-validate` are gone. Use `cf-nginx status` and `cf-nginx enable/disable` instead.

## Development

```bash
make lint      # shellcheck
make test      # integration tests against a real nginx (container/VM only: edits /etc/nginx)
make deb       # build dist/cf-nginx_<version>_all.deb
make dist      # deb + source zip
```
## License

Apache-2.0
