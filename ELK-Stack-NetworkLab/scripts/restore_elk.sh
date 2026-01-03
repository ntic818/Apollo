#!/bin/bash
set -euo pipefail

# ELK Stack Restore Script
# Usage: ./restore_elk.sh [snapshot_name]

# Configuration
ES_HOST="${ES_HOST:-https://localhost:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-backup_repository}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
if [ -z "${ES_PASS}" ]; then
    log_error "Password required"
    echo "Usage: ES_PASS=your_password $0 [snapshot_name]"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

echo "========================================="
echo "ELK Stack Restore Utility"
echo "========================================="
echo ""

# List available snapshots if no snapshot specified
if [ $# -eq 0 ]; then
    log_info "Fetching available snapshots..."
    
    SNAPSHOTS=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
        "${ES_HOST}/_snapshot/${SNAPSHOT_REPO}/_all" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "Failed to connect to Elasticsearch"
        exit 1
    fi
    
    SNAPSHOT_COUNT=$(echo "$SNAPSHOTS" | jq '.snapshots | length')
    
    if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
        log_error "No snapshots found in repository: $SNAPSHOT_REPO"
        exit 1
    fi
    
    echo ""
    echo "Available Snapshots:"
    echo "========================================="
    echo "$SNAPSHOTS" | jq -r '.snapshots[] | 
        "Name: " + .snapshot + "
  State: " + .state + "
  Start: " + .start_time + "
  Indices: " + (.indices | length | tostring) + "
  Shards: " + (.shards.successful | tostring) + "/" + (.shards.total | tostring) + "
  Duration: " + (.duration_in_millis/1000 | tostring) + "s
"'
    
    echo ""
    echo "Usage: ES_PASS=your_password $0 <snapshot_name>"
    exit 0
fi

SNAPSHOT_NAME="$1"

log_info "Restore snapshot: $SNAPSHOT_NAME"
echo ""

# Step 1: Verify snapshot exists
log_info "Step 1: Verifying snapshot..."
SNAPSHOT_INFO=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}" 2>/dev/null)

if [ $? -ne 0 ]; then
    log_error "Failed to retrieve snapshot information"
    exit 1
fi

SNAPSHOT_STATE=$(echo "$SNAPSHOT_INFO" | jq -r '.snapshots[0].state')

if [ "$SNAPSHOT_STATE" != "SUCCESS" ]; then
    log_error "Snapshot state is: $SNAPSHOT_STATE (expected: SUCCESS)"
    exit 1
fi

log_success "Snapshot verified: $SNAPSHOT_STATE"

INDICES=$(echo "$SNAPSHOT_INFO" | jq -r '.snapshots[0].indices[]' | wc -l)
log_info "Snapshot contains $INDICES indices"
echo ""

# Step 2: Show restore options
echo "Restore Options:"
echo "========================================="
echo "1. Full restore (all indices)"
echo "2. Selective restore (choose indices)"
echo "3. Restore specific index pattern"
echo "4. Cancel"
echo ""
read -p "Select option [1-4]: " RESTORE_OPTION

case $RESTORE_OPTION in
    1)
        INDICES_TO_RESTORE="*"
        ;;
    2)
        echo ""
        echo "Available indices in snapshot:"
        echo "$SNAPSHOT_INFO" | jq -r '.snapshots[0].indices[]' | nl
        echo ""
        read -p "Enter index numbers (comma-separated): " INDEX_NUMBERS
        
        INDICES_TO_RESTORE=""
        for NUM in $(echo $INDEX_NUMBERS | tr ',' ' '); do
            INDEX=$(echo "$SNAPSHOT_INFO" | jq -r ".snapshots[0].indices[$((NUM-1))]")
            if [ -n "$INDICES_TO_RESTORE" ]; then
                INDICES_TO_RESTORE="${INDICES_TO_RESTORE},${INDEX}"
            else
                INDICES_TO_RESTORE="${INDEX}"
            fi
        done
        ;;
    3)
        echo ""
        read -p "Enter index pattern (e.g., syslog-*): " INDICES_TO_RESTORE
        ;;
    4)
        log_info "Restore cancelled"
        exit 0
        ;;
    *)
        log_error "Invalid option"
        exit 1
        ;;
esac

log_info "Will restore: $INDICES_TO_RESTORE"
echo ""

# Step 3: Confirm action
echo "⚠️  WARNING: This will restore indices from snapshot"
echo "   Existing indices with the same name will be closed and replaced"
echo ""
read -p "Are you sure you want to continue? [yes/no]: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Restore cancelled"
    exit 0
fi

# Step 4: Close existing indices (if they exist)
if [ "$INDICES_TO_RESTORE" != "*" ]; then
    log_info "Step 2: Checking for existing indices..."
    
    for INDEX in $(echo "$INDICES_TO_RESTORE" | tr ',' ' '); do
        INDEX_EXISTS=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
            "${ES_HOST}/${INDEX}" -w "%{http_code}" -o /dev/null 2>/dev/null)
        
        if [ "$INDEX_EXISTS" = "200" ]; then
            log_warn "Closing existing index: $INDEX"
            curl -sk -X POST -u "${ES_USER}:${ES_PASS}" \
                "${ES_HOST}/${INDEX}/_close" >/dev/null 2>&1
        fi
    done
    echo ""
fi

# Step 5: Start restore
log_info "Step 3: Starting restore operation..."

RESTORE_BODY=$(cat <<EOF
{
  "indices": "${INDICES_TO_RESTORE}",
  "ignore_unavailable": true,
  "include_global_state": false,
  "rename_pattern": "(.+)",
  "rename_replacement": "\$1",
  "include_aliases": true
}
EOF
)

RESTORE_RESPONSE=$(curl -sk -X POST -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}/_restore?wait_for_completion=false" \
    -H 'Content-Type: application/json' \
    -d "$RESTORE_BODY" 2>/dev/null)

if [ $? -ne 0 ]; then
    log_error "Failed to initiate restore"
    exit 1
fi

ACCEPTED=$(echo "$RESTORE_RESPONSE" | jq -r '.accepted')

if [ "$ACCEPTED" != "true" ]; then
    log_error "Restore was not accepted by Elasticsearch"
    echo "$RESTORE_RESPONSE" | jq '.'
    exit 1
fi

log_success "Restore initiated successfully"
echo ""

# Step 6: Monitor restore progress
log_info "Step 4: Monitoring restore progress..."
echo ""

while true; do
    RECOVERY=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
        "${ES_HOST}/_recovery?active_only=true" 2>/dev/null)
    
    ACTIVE_RECOVERIES=$(echo "$RECOVERY" | jq 'to_entries | length')
    
    if [ "$ACTIVE_RECOVERIES" -eq 0 ]; then
        log_success "Restore completed!"
        break
    fi
    
    echo -ne "\rActive recoveries: $ACTIVE_RECOVERIES   "
    sleep 5
done

echo ""
echo ""

# Step 7: Verify restored indices
log_info "Step 5: Verifying restored indices..."

if [ "$INDICES_TO_RESTORE" = "*" ]; then
    CHECK_PATTERN="*"
else
    CHECK_PATTERN=$(echo "$INDICES_TO_RESTORE" | sed 's/,/,/g')
fi

RESTORED_INDICES=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cat/indices/${CHECK_PATTERN}?v&h=index,health,status,docs.count" 2>/dev/null)

echo ""
echo "Restored Indices:"
echo "========================================="
echo "$RESTORED_INDICES"
echo ""

# Check for any red indices
RED_INDICES=$(echo "$RESTORED_INDICES" | grep -c "red" || true)

if [ "$RED_INDICES" -gt 0 ]; then
    log_warn "$RED_INDICES indices are in RED state"
    log_warn "You may need to allocate shards manually"
else
    log_success "All restored indices are healthy"
fi

# Step 8: Summary
echo ""
echo "========================================="
echo "Restore Summary"
echo "========================================="
echo "Snapshot: $SNAPSHOT_NAME"
echo "Repository: $SNAPSHOT_REPO"
echo "Indices restored: $(echo "$RESTORED_INDICES" | tail -n +2 | wc -l)"
echo "Status: Complete"
echo ""

log_info "Restore process finished!"

# Optional: Run health check
echo ""
read -p "Run cluster health check? [yes/no]: " RUN_HEALTH

if [ "$RUN_HEALTH" = "yes" ]; then
    if [ -f "$(dirname $0)/health_check.sh" ]; then
        bash "$(dirname $0)/health_check.sh" "$ES_HOST" "$ES_USER" "$ES_PASS"
    else
        log_warn "health_check.sh not found in scripts directory"
    fi
fi

exit 0
