#!/usr/bin/env bash

## Author: Tommy Miland (@tmiland) - Copyright (c) 2021

#------------------------------------------------------------------------------#
#
# MIT License
#
# Copyright (c) 2020 Tommy Miland
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#------------------------------------------------------------------------------#

readonly INI_FILE="/etc/openpanel/openadmin/config/admin.ini"
readonly BACKUP_DIR="/tmp/cf_dns_backups"
readonly ZONE_DIR="/etc/bind/zones"

# Check if the file exists
if [ ! -f "$INI_FILE" ]; then
    echo "Error! $INI_FILE not found."
    exit 1
fi

START_TIME=$(date +%s)

# Read values from [CLOUDFLARE] section
CF_SECTION=$(awk '/\[CLOUDFLARE\]/{flag=1;next}/\[/{flag=0}flag' "$INI_FILE")

EMAIL=$(echo "$CF_SECTION" | grep -E '^cf_email=' | cut -d'=' -f2 | xargs)
KEY=$(echo "$CF_SECTION" | grep -E '^cf_key=' | cut -d'=' -f2 | xargs)
PROXIED=$(echo "$CF_SECTION" | grep -E '^cf_proxy=' | cut -d'=' -f2 | xargs)

if [[ -z "$EMAIL" || -z "$KEY" || -z "$PROXIED" ]]; then
    echo "Skipping: Cloudflare external DNS server is not configured."
    exit 0
fi

mkdir -p "$BACKUP_DIR"

# Get list of zone files
ZONE_FILES=("$ZONE_DIR"/*.zone)
TOTAL=${#ZONE_FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
    echo "No .zone files found in $ZONE_DIR"
    exit 0
fi

# Counter
COUNTER=0

for FILE in "${ZONE_FILES[@]}"; do
    ((COUNTER++))
    DOMAIN=$(basename "$FILE" .zone)
    echo ""
    echo "[$COUNTER/$TOTAL] Processing domain: $DOMAIN"

    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="${BACKUP_DIR}/${DOMAIN}_${TIMESTAMP}.bak"

    # 1. Get Zone ID from Cloudflare
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
        echo "Error! Could not fetch Zone ID for $DOMAIN, skipping..."
        continue
    fi

    echo "Zone ID: $ZONE_ID"

    # 2. Backup current DNS records
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/export" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        -H "Content-Type: application/json" > "$BACKUP_FILE"

    echo "Backed up current DNS records to $BACKUP_FILE"

    # 3. Delete all existing DNS records
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?per_page=500" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        -H "Content-Type: application/json" | jq -r '.result[].id' | while read id; do
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${id}" \
            -H "X-Auth-Email: ${EMAIL}" \
            -H "X-Auth-Key: ${KEY}" \
            -H "Content-Type: application/json"
    done

    # 4. Upload the BIND file
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/import" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        --form "file=@${FILE}" \
        --form "proxied=$PROXIED"

    echo "Imported BIND file for $DOMAIN"
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

ELAPSED_HMS=$(printf '%02d:%02d:%02d' $((ELAPSED/3600)) $(( (ELAPSED%3600)/60 )) $((ELAPSED%60)))

echo ""
echo "All $TOTAL domains processed."
echo "Total time: $ELAPSED_HMS (HH:MM:SS)"
