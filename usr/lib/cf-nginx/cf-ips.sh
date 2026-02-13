#!/bin/bash
# cf-nginx core library

CONFIG_FILE="/etc/cf-nginx/config"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

CF_API_URL="${CF_API_URL:-https://api.cloudflare.com/client/v4/ips}"
DATA_DIR="${DATA_DIR:-/var/lib/cf-nginx}"
AUTO_UPDATE_NGINX="${AUTO_UPDATE_NGINX:-yes}"
AUTO_UPDATE_UFW="${AUTO_UPDATE_UFW:-no}"

IP_CACHE="$DATA_DIR/ips.json"
ENABLED_SITES="$DATA_DIR/enabled_sites"
UFW_ENABLED_FILE="$DATA_DIR/ufw_enabled"

mkdir -p "$DATA_DIR"
touch "$ENABLED_SITES"

fetch_cf_ips() {
    local temp_file
    temp_file=$(mktemp)
    
    if curl -s "$CF_API_URL" > "$temp_file" 2>/dev/null; then
        if jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$IP_CACHE"
            return 0
        fi
    fi
    
    rm -f "$temp_file"
    return 1
}

get_ipv4_ranges() {
    [[ ! -f "$IP_CACHE" ]] && fetch_cf_ips
    jq -r '.result.ipv4_cidrs[]' "$IP_CACHE" 2>/dev/null || true
}

get_ipv6_ranges() {
    [[ ! -f "$IP_CACHE" ]] && fetch_cf_ips
    jq -r '.result.ipv6_cidrs[]' "$IP_CACHE" 2>/dev/null || true
}

generate_cf_directives() {
    echo "    # BEGIN CLOUDFLARE IPS - DO NOT EDIT MANUALLY"
    while IFS= read -r ip; do
        echo "    set_real_ip_from $ip;"
    done < <(get_ipv4_ranges)
    while IFS= read -r ip; do
        echo "    set_real_ip_from $ip;"
    done < <(get_ipv6_ranges)
    echo ""
    echo "    real_ip_header CF-Connecting-IP;"
    echo "    real_ip_recursive on;"
    echo "    # END CLOUDFLARE IPS"
}

remove_cf_directives() {
    local config_file="$1"
    sed -i '/# BEGIN CLOUDFLARE IPS/,/# END CLOUDFLARE IPS/d' "$config_file"
}

update_nginx_site() {
    local site="$1"
    local config_file="/etc/nginx/sites-available/$site"
    
    [[ ! -f "$config_file" ]] && return 1
    
    cp "$config_file" "${config_file}.bak-$(date +%s)" || return 1
    remove_cf_directives "$config_file"
    
    local cf_block temp_file
    cf_block=$(mktemp)
    temp_file=$(mktemp)
    
    echo "" > "$cf_block"
    generate_cf_directives >> "$cf_block"
    echo "" >> "$cf_block"
    
    awk -v cf_file="$cf_block" '
    BEGIN {
        cf_content = ""
        while ((getline line < cf_file) > 0) {
            cf_content = cf_content line "\n"
        }
        close(cf_file)
        in_server = 0
        cf_inserted = 0
    }
    /^[[:space:]]*server[[:space:]]*\{/ || /^[[:space:]]*server[[:space:]]*$/ {
        print
        in_server = 1
        cf_inserted = 0
        next
    }
    in_server && /server_name/ && !/managed by Certbot/ && !cf_inserted {
        print
        printf "%s", cf_content
        cf_inserted = 1
        next
    }
    in_server && /^[[:space:]]*\}[[:space:]]*$/ {
        in_server = 0
        cf_inserted = 0
    }
    { print }
    ' "$config_file" > "$temp_file"
    
    rm -f "$cf_block"
    mv "$temp_file" "$config_file"
    
    if nginx -t 2>/dev/null; then
        return 0
    else
        local latest_backup
        latest_backup=$(ls -t "${config_file}.bak-"* 2>/dev/null | head -1)
        [[ -n "$latest_backup" ]] && mv "$latest_backup" "$config_file"
        return 1
    fi
}

update_all_nginx_sites() {
    local updated=0
    local failed=0
    
    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        if update_nginx_site "$site"; then
            updated=$((updated + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$ENABLED_SITES"
    
    if [[ $updated -gt 0 ]]; then
        systemctl reload nginx 2>/dev/null || true
    fi
    
    echo "NGINX: Updated $updated site(s), failed $failed"
    return 0
}

sync_ufw() {
    command -v ufw &>/dev/null || return 1
    
    ufw status numbered 2>/dev/null | grep "Cloudflare" | awk '{print $1}' | sed 's/\[//;s/\]//' | sort -rn | while read -r num; do
        echo "y" | ufw delete "$num" 2>/dev/null || true
    done
    
    while IFS= read -r ip; do
        ufw allow from "$ip" to any port 80 comment "Cloudflare" 2>/dev/null || true
        ufw allow from "$ip" to any port 443 comment "Cloudflare" 2>/dev/null || true
    done < <(get_ipv4_ranges)
    
    while IFS= read -r ip; do
        ufw allow from "$ip" to any port 80 comment "Cloudflare" 2>/dev/null || true
        ufw allow from "$ip" to any port 443 comment "Cloudflare" 2>/dev/null || true
    done < <(get_ipv6_ranges)
    
    return 0
}

enable_site() {
    local site="$1"
    grep -qx "$site" "$ENABLED_SITES" 2>/dev/null || echo "$site" >> "$ENABLED_SITES"
}

disable_site() {
    local site="$1"
    sed -i "/^${site}$/d" "$ENABLED_SITES"
}

is_enabled() {
    local site="$1"
    grep -qx "$site" "$ENABLED_SITES" 2>/dev/null
}

get_enabled_sites() {
    [[ -f "$ENABLED_SITES" ]] && cat "$ENABLED_SITES" || true
}

enable_ufw_autoupdate() {
    touch "$UFW_ENABLED_FILE"
    sed -i 's/^AUTO_UPDATE_UFW=.*/AUTO_UPDATE_UFW=yes/' "$CONFIG_FILE" 2>/dev/null || true
}

disable_ufw_autoupdate() {
    rm -f "$UFW_ENABLED_FILE"
    sed -i 's/^AUTO_UPDATE_UFW=.*/AUTO_UPDATE_UFW=no/' "$CONFIG_FILE" 2>/dev/null || true
}

is_ufw_autoupdate_enabled() {
    [[ -f "$UFW_ENABLED_FILE" ]] || [[ "$AUTO_UPDATE_UFW" == "yes" ]]
}

auto_update() {
    echo "[$(date)] Starting auto-update..."
    
    fetch_cf_ips || echo "[$(date)] Using cached IPs"
    
    if [[ "$AUTO_UPDATE_NGINX" == "yes" ]]; then
        echo "[$(date)] Updating NGINX..."
        update_all_nginx_sites
    fi
    
    if is_ufw_autoupdate_enabled; then
        echo "[$(date)] Updating UFW..."
        sync_ufw && echo "[$(date)] UFW updated" || echo "[$(date)] UFW update failed"
    fi
    
    echo "[$(date)] Auto-update complete"
}
