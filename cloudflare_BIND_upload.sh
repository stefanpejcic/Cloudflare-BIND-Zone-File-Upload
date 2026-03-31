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
readonly CF_API="https://api.cloudflare.com/client/v4"

die() { echo "Error! $*" >&2; exit 1; }

cf_get() {
    curl -s -X GET "${CF_API}$1" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        -H "Content-Type: application/json"
}

cf_delete() {
    curl -s -X DELETE "${CF_API}$1" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        -H "Content-Type: application/json"
}

cf_import() {
    curl -s -X POST "${CF_API}/zones/$1/dns_records/import" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        --form "file=@$2" \
        --form "proxied=${PROXIED}"
}

check_success() {
    # $1 = JSON response, $2 = label for error message
    local success
    success=$(echo "$1" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
        local errors
        errors=$(echo "$1" | jq -c '.errors')
        echo "  Warning: $2 failed — $errors" >&2
        return 1
    fi
    return 0
}

# CONFIG
[[ -f "$INI_FILE" ]] || die "$INI_FILE not found."

CF_SECTION=$(awk '/\[CLOUDFLARE\]/{flag=1;next}/\[/{flag=0}flag' "$INI_FILE")

EMAIL=$(echo  "$CF_SECTION" | awk -F= '/^cf_email=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
KEY=$(echo    "$CF_SECTION" | awk -F= '/^cf_key=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
PROXIED=$(echo "$CF_SECTION" | awk -F= '/^cf_proxy=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')

[[ -z "$EMAIL"   ]] && { echo "Skipping: Cloudflare external DNS server is not configured." ; exit 0; }
[[ -z "$KEY"     ]] && { echo "Skipping: Cloudflare external DNS server is not configured." ; exit 0; }
[[ -z "$PROXIED" ]] && { echo "Skipping: Cloudflare external DNS server is not configured." ; exit 0; }

if [[ "$PROXIED" != "true" && "$PROXIED" != "false" ]]; then
    die "cf_proxy must be 'true' or 'false', got: '$PROXIED'"
fi

mkdir -p "$BACKUP_DIR" || die "Cannot create backup directory $BACKUP_DIR"

# GET ZONES
shopt -s nullglob
ZONE_FILES=("$ZONE_DIR"/*.zone)
shopt -u nullglob

TOTAL=${#ZONE_FILES[@]}
if [[ $TOTAL -eq 0 ]]; then
    echo "No .zone files found in $ZONE_DIR"
    exit 0
fi

# MAIN
START_TIME=$(date +%s)
COUNTER=0
ERRORS=0

for FILE in "${ZONE_FILES[@]}"; do
    ((COUNTER++))
    DOMAIN=$(basename "$FILE" .zone)
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="${BACKUP_DIR}/${DOMAIN}_${TIMESTAMP}.bak"

    echo ""
    echo "[$COUNTER/$TOTAL] Processing domain: $DOMAIN"

    # 1. Get Zone ID
    ZONE_RESP=$(cf_get "/zones?name=${DOMAIN}")
    ZONE_ID=$(echo "$ZONE_RESP" | jq -r '.result[0].id')

    if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
        echo "  Error: Could not fetch Zone ID for $DOMAIN — skipping."
        ((ERRORS++))
        continue
    fi
    echo "  Zone ID: $ZONE_ID"

    # 2. Backup
    BACKUP_CONTENT=$(cf_get "/zones/${ZONE_ID}/dns_records/export")
    if [[ -z "$BACKUP_CONTENT" ]]; then
        echo "  Error: Backup returned empty response for $DOMAIN — skipping (records NOT deleted)."
        ((ERRORS++))
        continue
    fi
    echo "$BACKUP_CONTENT" > "$BACKUP_FILE"
    echo "  Backed up DNS records → $BACKUP_FILE"

    # 3. Delete all existing DNS records
    RECORDS_RESP=$(cf_get "/zones/${ZONE_ID}/dns_records?per_page=500")
    mapfile -t RECORD_IDS < <(echo "$RECORDS_RESP" | jq -r '.result[].id')

    echo "  Deleting ${#RECORD_IDS[@]} existing record(s)..."
    for id in "${RECORD_IDS[@]}"; do
        DEL_RESP=$(cf_delete "/zones/${ZONE_ID}/dns_records/${id}")
        if ! check_success "$DEL_RESP" "delete record $id"; then
            ((ERRORS++))
        fi
        sleep 0.05   # CF rate limit (1200 req/5 min)
    done

    # 4. Import BIND zone file
    IMPORT_RESP=$(cf_import "$ZONE_ID" "$FILE")
    if check_success "$IMPORT_RESP" "import zone file"; then
        ADDED=$(echo "$IMPORT_RESP"   | jq -r '.result.recs_added   // 0')
        SKIPPED=$(echo "$IMPORT_RESP" | jq -r '.result.recs_skipped // 0')
        echo "  Imported $FILE — added: $ADDED, skipped: $SKIPPED"
    else
        ((ERRORS++))
    fi
done

# SUMMARY
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_HMS=$(printf '%02d:%02d:%02d' $((ELAPSED/3600)) $(( (ELAPSED%3600)/60 )) $((ELAPSED%60)))

echo ""
echo "Processed $COUNTER/$TOTAL domain(s) — $ERRORS error(s)."
echo "Total time: $ELAPSED_HMS (HH:MM:SS)"

[[ $ERRORS -gt 0 ]] && exit 1 || exit 0
