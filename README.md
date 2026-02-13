# cf-nginx

Manage Cloudflare IP ranges in NGINX with automatic daily updates.

## Install

```bash
wget https://github.com/cfunkz/cf-nginx/releases/download/v1.0.1/cf-nginx.deb
sudo dpkg -i cf-nginx.deb
```

## Quick Start

```bash
# Interactive menu
sudo cf-nginx

# Or single command
sudo cf-nginx enable yoursite.com
```

## Features

- **Auto-updates NGINX daily** - Fetches latest CF IPs at 3am  
- **Auto-updates UFW (optional)** - Sync firewall rules automatically  
- **SSL detection** - Prompts for Let's Encrypt if needed  
- **Safe rollback** - Auto-restore on config errors  
- **Per-site control** - Enable/disable individually

## What It Adds

```nginx
server {
    server_name example.com;

    # BEGIN CLOUDFLARE IPS - DO NOT EDIT MANUALLY
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    # ... all Cloudflare IPv4 and IPv6 ranges
    
    real_ip_header CF-Connecting-IP;
    real_ip_recursive on;
    # END CLOUDFLARE IPS

    # Your config...
}
```

Works with both HTTP and HTTPS - updates all server blocks.

## Auto-Updates

**NGINX configs** - Enabled by default, runs daily at 3am  
**UFW firewall** - Optional, enable with: `sudo cf-nginx ufw-enable`

```bash
# Check auto-update status
systemctl status cf-nginx.timer

# Force update now
sudo cf-nginx update

# View logs
journalctl -u cf-nginx -n 50
```

## Commands

```bash
# Site management
sudo cf-nginx enable site.com       # Enable CF IPs
sudo cf-nginx disable site.com      # Disable CF IPs
sudo cf-nginx status                # Show enabled sites

# Updates
sudo cf-nginx update                # Update all (NGINX + UFW if enabled)

# UFW firewall
sudo cf-nginx ufw-enable            # Enable UFW auto-update
sudo cf-nginx ufw-disable           # Disable UFW auto-update

# Information
sudo cf-nginx list                  # Show CF IP ranges
sudo cf-nginx-validate site.com     # Validate config
```

## UFW Firewall

Enable automatic UFW updates:

```bash
sudo cf-nginx ufw-enable
```

Now Cloudflare IPs in UFW update automatically with NGINX daily.

**After enabling:**
```bash
sudo ufw allow 22/tcp              # Allow SSH first!
sudo ufw enable
sudo ufw default deny incoming
```

## Troubleshooting

```bash
# Test NGINX config
sudo nginx -t

# Validate CF setup
sudo cf-nginx-validate site.com

# Check logs
journalctl -u cf-nginx -n 50

# View backups
ls /etc/nginx/sites-available/*.bak-*
```

## Build from Source

```bash
tar -xzf cf-nginx-source.tar.gz
cd cf-nginx/
nano usr/bin/cf-nginx
cd ..
dpkg-deb --build cf-nginx
sudo dpkg -i cf-nginx.deb
```

## Configuration

Edit `/etc/cf-nginx/config`:

```bash
AUTO_UPDATE_NGINX=yes    # Auto-update NGINX configs
AUTO_UPDATE_UFW=no       # Auto-update UFW (or use ufw-enable command)
```

## Requirements

- NGINX
- curl, jq
- systemd
- certbot (optional, for SSL)
- ufw (optional, for firewall)

## License

MIT