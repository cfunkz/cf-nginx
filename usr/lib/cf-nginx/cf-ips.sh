#!/bin/bash
# Cloudflare NGINX IP updater library

CF_API_URL="https://api.cloudflare.com/client/v4/ips"
CACHE_DIR="/var/lib/cf-nginx"
IP_CACHE="$CACHE_DIR/ips.json"
ENABLED_SITES="$CACHE_DIR/enabled_sites"

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"
touch "$ENABLED_SITES"

# Fetch Cloudflare IPs from API
fetch_cf_ips() {
    local temp_file=$(mktemp)
    
    if curl -s "$CF_API_URL" > "$temp_file"; then
        if jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$IP_CACHE"
            echo "✅ Fetched latest Cloudflare IPs"
            return 0
        fi
    fi
    
    rm -f "$temp_file"
    echo "⚠️  Failed to fetch Cloudflare IPs, using cache"
    return 1
}

# Get IPv4 ranges
get_ipv4_ranges() {
    if [[ ! -f "$IP_CACHE" ]]; then
        fetch_cf_ips
    fi
    jq -r '.result.ipv4_cidrs[]' "$IP_CACHE" 2>/dev/null
}

# Get IPv6 ranges
get_ipv6_ranges() {
    if [[ ! -f "$IP_CACHE" ]]; then
        fetch_cf_ips
    fi
    jq -r '.result.ipv6_cidrs[]' "$IP_CACHE" 2>/dev/null
}

# Generate set_real_ip_from directives
generate_real_ip_directives() {
    while IFS= read -r ip; do
        echo "    set_real_ip_from $ip;"
    done < <(get_ipv4_ranges)
    
    echo ""
    
    while IFS= read -r ip; do
        echo "    set_real_ip_from $ip;"
    done < <(get_ipv6_ranges)
    
    echo ""
    echo "    real_ip_header CF-Connecting-IP;"
    echo "    real_ip_recursive on;"
}

# Check if site has CF support enabled
is_cf_enabled() {
    local site="$1"
    grep -q "^$site$" "$ENABLED_SITES" 2>/dev/null
}

# Add site to enabled list
enable_site() {
    local site="$1"
    if ! is_cf_enabled "$site"; then
        echo "$site" >> "$ENABLED_SITES"
    fi
}

# Remove site from enabled list
disable_site() {
    local site="$1"
    sed -i "/^$site$/d" "$ENABLED_SITES"
}

# Get list of enabled sites
get_enabled_sites() {
    cat "$ENABLED_SITES" 2>/dev/null
}


# Remove CF directives from config
remove_cf_directives() {
    local config_file="$1"
    
    # Use markers to safely remove CF blocks
    sed -i '/# BEGIN CLOUDFLARE IPS - DO NOT EDIT MANUALLY/,/# END CLOUDFLARE IPS/d' "$config_file"
}

# Update all enabled sites
update_all_sites() {
    fetch_cf_ips
    
    echo "Updating all enabled sites with latest CF IPs..."
    echo ""
    
    local updated=0
    local failed=0
    
    while IFS= read -r site; do
        echo "Updating: $site"
        local config_file="/etc/nginx/sites-available/$site"
        
        if [[ ! -f "$config_file" ]]; then
            echo "  ⚠️  Config not found, skipping"
            ((failed++))
            continue
        fi
        
        # Remove old CF directives
        remove_cf_directives "$config_file"
        
        # Generate new CF directives
        local cf_directives=$(mktemp)
        echo "" > "$cf_directives"
        echo "    # BEGIN CLOUDFLARE IPS - DO NOT EDIT MANUALLY" >> "$cf_directives"
        generate_real_ip_directives >> "$cf_directives"
        echo "    # END CLOUDFLARE IPS" >> "$cf_directives"
        echo "" >> "$cf_directives"
        
        # Insert directives
        local temp_file=$(mktemp)
        awk -v cf_file="$cf_directives" '
        BEGIN {
            cf_content = ""
            while ((getline line < cf_file) > 0) {
                cf_content = cf_content line "\n"
            }
            close(cf_file)
            in_server = 0
            cf_inserted = 0
        }
        /^[[:space:]]*server[[:space:]]*{/ || /^[[:space:]]*server[[:space:]]*$/ {
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
        in_server && /^[[:space:]]*}[[:space:]]*$/ {
            in_server = 0
            cf_inserted = 0
        }
        { print }
        ' "$config_file" > "$temp_file"
        
        rm -f "$cf_directives"
        cp "$config_file" "${config_file}.bak-$(date +%s)"
        mv "$temp_file" "$config_file"
        
        if nginx -t 2>&1 | grep -q "successful"; then
            echo "  ✅ Updated"
            ((updated++))
        else
            echo "  ❌ Failed, restored backup"
            local latest_backup=$(ls -t "${config_file}.bak-"* 2>/dev/null | head -1)
            [[ -n "$latest_backup" ]] && mv "$latest_backup" "$config_file"
            ((failed++))
        fi
    done < <(get_enabled_sites)
    
    if [[ $updated -gt 0 ]]; then
        echo ""
        echo "🔄 Reloading NGINX..."
        systemctl reload nginx
        echo "✅ Updated $updated site(s)"
    fi
    
    if [[ $failed -gt 0 ]]; then
        echo "⚠️  Failed to update $failed site(s)"
    fi
}

# Check for IP changes
check_for_updates() {
    local old_hash=""
    local new_hash=""
    
    if [[ -f "$IP_CACHE" ]]; then
        old_hash=$(md5sum "$IP_CACHE" | cut -d' ' -f1)
    fi
    
    fetch_cf_ips
    
    if [[ -f "$IP_CACHE" ]]; then
        new_hash=$(md5sum "$IP_CACHE" | cut -d' ' -f1)
    fi
    
    if [[ "$old_hash" != "$new_hash" ]]; then
        echo "🔄 Cloudflare IP ranges changed"
        return 0
    else
        echo "✅ No changes detected"
        return 1
    fi
}
