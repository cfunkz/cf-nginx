# cf-nginx

Manage Cloudflare IP ranges in NGINX. One command, works with SSL.

## Install

```bash
git clone https://github.com/cfunkz/cf-nginx.git
cd cf-nginx
sudo dpkg -i cf-nginx.deb
```

## Usage

For interactive prompts:
```bash
sudo cf-nginx
```

For single command:
```bash
sudo cf-nginx enable yoursite.com
```

Asks if you want SSL (y/n), adds Cloudflare IPs, tests config, reloads NGINX.

## What it does

Adds Cloudflare IP directives to your NGINX config:

```nginx
# BEGIN CLOUDFLARE IPS - DO NOT EDIT MANUALLY
set_real_ip_from 103.21.244.0/22;
# ... all Cloudflare IPv4 and IPv6 ranges
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
# END CLOUDFLARE IPS
```

Works with HTTP and HTTPS. Updates all server blocks.

## Auto-updates

Checks Cloudflare's API daily at 3am and updates configs automatically.

```bash
systemctl status cf-nginx.timer     # Check status
sudo cf-nginx update                # Force update now
```

## Commands

```bash
sudo cf-nginx enable site.com       # Enable CF IPs
sudo cf-nginx disable site.com      # Disable CF IPs
sudo cf-nginx-validate site.com     # Check config
sudo cf-nginx status                # Show enabled sites
sudo cf-nginx list                  # Show CF IP ranges
```

## Troubleshooting

Check what went wrong:

```bash
sudo nginx -t                       # Test config
sudo cf-nginx-validate site.com     # Validate setup
journalctl -u cf-nginx -n 50        # View logs
```

Backups: `/etc/nginx/sites-available/*.bak-*`

## Build from source

```bash
tar -xzf cf-nginx-source.tar.gz
cd cf-nginx/
nano usr/bin/cf-nginx
cd ..
dpkg-deb --build cf-nginx
sudo dpkg -i cf-nginx.deb
```

## Requirements

- NGINX
- curl, jq
- systemd
- certbot (optional, for SSL)

## License

MIT
