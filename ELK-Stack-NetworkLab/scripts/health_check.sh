#!/bin/bash
set -euo pipefail

# ELK Stack Health Check Script
# Usage: ./health_check.sh [elasticsearch_host] [username] [password]

# Configuration
ES_HOST="${1:-https://localhost:9200}"
ES_USER="${2:-elastic}"
ES_PASS="${3}"
KIBANA_HOST="${KIBANA_HOST:-https://localhost:5601}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

print_header() {
    echo "========================================="
    echo "$1"
    echo "========================================="
}

check_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((CHECKS_PASSED++))
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((CHECKS_FAILED++))
}

check_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
    ((CHECKS_WARNING++))
}

# Check if password is provided
if [ -z "${ES_PASS}" ]; then
    echo "Error: Password required"
    echo "Usage: $0 [es_host] [username] password"
    exit 1
fi

print_header "ELK Stack Health Check - $(date)"

# 1. Elasticsearch Cluster Health
print_header "1. Cluster Health"
CLUSTER_HEALTH=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cluster/health" 2>/dev/null)

if [ $? -eq 0 ]; then
    STATUS=$(echo "$CLUSTER_HEALTH" | jq -r '.status')
    NUM_NODES=$(echo "$CLUSTER_HEALTH" | jq -r '.number_of_nodes')
    ACTIVE_SHARDS=$(echo "$CLUSTER_HEALTH" | jq -r '.active_shards')
    RELOCATING=$(echo "$CLUSTER_HEALTH" | jq -r '.relocating_shards')
    INITIALIZING=$(echo "$CLUSTER_HEALTH" | jq -r '.initializing_shards')
    UNASSIGNED=$(echo "$CLUSTER_HEALTH" | jq -r '.unassigned_shards')
    
    echo "Cluster Status: $STATUS"
    echo "Nodes: $NUM_NODES"
    echo "Active Shards: $ACTIVE_SHARDS"
    echo "Relocating: $RELOCATING"
    echo "Initializing: $INITIALIZING"
    echo "Unassigned: $UNASSIGNED"
    
    if [ "$STATUS" = "green" ]; then
        check_pass "Cluster status is GREEN"
    elif [ "$STATUS" = "yellow" ]; then
        check_warn "Cluster status is YELLOW"
    else
        check_fail "Cluster status is RED"
    fi
    
    if [ "$NUM_NODES" -ge 3 ]; then
        check_pass "Sufficient nodes ($NUM_NODES)"
    else
        check_fail "Insufficient nodes ($NUM_NODES < 3)"
    fi
    
    if [ "$UNASSIGNED" -eq 0 ]; then
        check_pass "No unassigned shards"
    else
        check_fail "$UNASSIGNED unassigned shards detected"
    fi
else
    check_fail "Cannot connect to Elasticsearch"
fi

# 2. Node Roles
print_header "2. Node Roles"
NODES=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cat/nodes?format=json" 2>/dev/null)

if [ $? -eq 0 ]; then
    MASTER_COUNT=$(echo "$NODES" | jq '[.[] | select(.["node.role"] | contains("m"))] | length')
    DATA_COUNT=$(echo "$NODES" | jq '[.[] | select(.["node.role"] | contains("d"))] | length')
    INGEST_COUNT=$(echo "$NODES" | jq '[.[] | select(.["node.role"] | contains("i"))] | length')
    
    echo "Master nodes: $MASTER_COUNT"
    echo "Data nodes: $DATA_COUNT"
    echo "Ingest nodes: $INGEST_COUNT"
    
    if [ "$MASTER_COUNT" -ge 3 ]; then
        check_pass "Sufficient master nodes ($MASTER_COUNT)"
    else
        check_fail "Insufficient master nodes ($MASTER_COUNT < 3)"
    fi
    
    if [ "$DATA_COUNT" -ge 3 ]; then
        check_pass "Sufficient data nodes ($DATA_COUNT)"
    else
        check_warn "Limited data nodes ($DATA_COUNT)"
    fi
else
    check_fail "Cannot retrieve node information"
fi

# 3. Index Health
print_header "3. Index Health"
INDICES=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cat/indices?format=json" 2>/dev/null)

if [ $? -eq 0 ]; then
    TOTAL_INDICES=$(echo "$INDICES" | jq '. | length')
    RED_INDICES=$(echo "$INDICES" | jq '[.[] | select(.health == "red")] | length')
    YELLOW_INDICES=$(echo "$INDICES" | jq '[.[] | select(.health == "yellow")] | length')
    
    echo "Total indices: $TOTAL_INDICES"
    echo "Red indices: $RED_INDICES"
    echo "Yellow indices: $YELLOW_INDICES"
    
    if [ "$RED_INDICES" -eq 0 ]; then
        check_pass "No RED indices"
    else
        check_fail "$RED_INDICES RED indices detected"
        echo "$INDICES" | jq -r '.[] | select(.health == "red") | .index'
    fi
    
    if [ "$YELLOW_INDICES" -eq 0 ]; then
        check_pass "No YELLOW indices"
    else
        check_warn "$YELLOW_INDICES YELLOW indices detected"
    fi
else
    check_fail "Cannot retrieve index information"
fi

# 4. Disk Usage
print_header "4. Disk Usage"
ALLOCATION=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cat/allocation?format=json" 2>/dev/null)

if [ $? -eq 0 ]; then
    HIGH_DISK=$(echo "$ALLOCATION" | jq -r '.[] | select(.["disk.percent"] != null) | select((.["disk.percent"] | tonumber) > 85) | .node + ": " + .["disk.percent"] + "%"')
    
    if [ -z "$HIGH_DISK" ]; then
        check_pass "All nodes have sufficient disk space"
    else
        check_warn "High disk usage detected:"
        echo "$HIGH_DISK"
    fi
    
    echo "$ALLOCATION" | jq -r '.[] | select(.node != null) | .node + ": " + .["disk.percent"] + "% (" + .["disk.used"] + " / " + .["disk.total"] + ")"'
else
    check_fail "Cannot retrieve disk allocation"
fi

# 5. Heap Usage
print_header "5. Heap Usage"
HEAP=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cat/nodes?format=json&h=name,heap.percent,heap.current,heap.max" 2>/dev/null)

if [ $? -eq 0 ]; then
    HIGH_HEAP=$(echo "$HEAP" | jq -r '.[] | select(.["heap.percent"] != null) | select((.["heap.percent"] | tonumber) > 85) | .name + ": " + .["heap.percent"] + "%"')
    
    if [ -z "$HIGH_HEAP" ]; then
        check_pass "All nodes have healthy heap usage"
    else
        check_warn "High heap usage detected:"
        echo "$HIGH_HEAP"
    fi
    
    echo "$HEAP" | jq -r '.[] | .name + ": " + .["heap.percent"] + "% (" + .["heap.current"] + " / " + .["heap.max"] + ")"'
else
    check_fail "Cannot retrieve heap information"
fi

# 6. Pending Tasks
print_header "6. Pending Tasks"
PENDING=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_cluster/pending_tasks" 2>/dev/null | jq '.tasks | length')

if [ $? -eq 0 ]; then
    echo "Pending tasks: $PENDING"
    if [ "$PENDING" -eq 0 ]; then
        check_pass "No pending cluster tasks"
    elif [ "$PENDING" -lt 10 ]; then
        check_warn "$PENDING pending tasks (normal during updates)"
    else
        check_fail "$PENDING pending tasks (investigate)"
    fi
else
    check_fail "Cannot retrieve pending tasks"
fi

# 7. Kibana Status
print_header "7. Kibana Status"
KIBANA_STATUS=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${KIBANA_HOST}/api/status" 2>/dev/null)

if [ $? -eq 0 ]; then
    KB_STATUS=$(echo "$KIBANA_STATUS" | jq -r '.status.overall.state')
    echo "Kibana status: $KB_STATUS"
    
    if [ "$KB_STATUS" = "green" ]; then
        check_pass "Kibana is healthy"
    elif [ "$KB_STATUS" = "yellow" ]; then
        check_warn "Kibana status is YELLOW"
    else
        check_fail "Kibana status is $KB_STATUS"
    fi
else
    check_warn "Cannot connect to Kibana (may be expected if not installed)"
fi

# 8. ILM Policies
print_header "8. ILM Policies"
ILM=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/_ilm/policy" 2>/dev/null)

if [ $? -eq 0 ]; then
    POLICY_COUNT=$(echo "$ILM" | jq '. | keys | length')
    echo "ILM policies configured: $POLICY_COUNT"
    
    if echo "$ILM" | jq -e '.["syslog-policy"]' >/dev/null 2>&1; then
        check_pass "syslog-policy exists"
    else
        check_warn "syslog-policy not found"
    fi
else
    check_fail "Cannot retrieve ILM policies"
fi

# 9. Recent Errors (Last 5 minutes)
print_header "9. Recent Critical Logs"
RECENT_ERRORS=$(curl -sk -u "${ES_USER}:${ES_PASS}" \
    "${ES_HOST}/syslog-*/_search?size=5" \
    -H 'Content-Type: application/json' \
    -d '{
      "query": {
        "bool": {
          "must": [
            {"range": {"@timestamp": {"gte": "now-5m"}}},
            {"terms": {"severity": [0, 1, 2, 3]}}
          ]
        }
      },
      "sort": [{"@timestamp": "desc"}]
    }' 2>/dev/null)

if [ $? -eq 0 ]; then
    ERROR_COUNT=$(echo "$RECENT_ERRORS" | jq '.hits.total.value')
    echo "Critical events (last 5 min): $ERROR_COUNT"
    
    if [ "$ERROR_COUNT" -eq 0 ]; then
        check_pass "No recent critical events"
    elif [ "$ERROR_COUNT" -lt 10 ]; then
        check_warn "$ERROR_COUNT critical events in last 5 minutes"
    else
        check_fail "$ERROR_COUNT critical events in last 5 minutes"
        echo "Sample events:"
        echo "$RECENT_ERRORS" | jq -r '.hits.hits[] | "  - " + (._source.syslog_hostname // "unknown") + ": " + (._source.mnemonic // .message[0:80])'
    fi
else
    check_warn "Cannot query for recent errors (indices may not exist yet)"
fi

# 10. Logstash Status (if accessible)
print_header "10. Logstash Status"
for LOGSTASH in logstash-01 logstash-02; do
    LS_STATUS=$(curl -s "http://${LOGSTASH}:9600/_node/stats/pipeline" 2>/dev/null || echo "")
    
    if [ -n "$LS_STATUS" ]; then
        IN=$(echo "$LS_STATUS" | jq -r '.pipelines.main.events.in // 0')
        OUT=$(echo "$LS_STATUS" | jq -r '.pipelines.main.events.out // 0')
        FILTERED=$(echo "$LS_STATUS" | jq -r '.pipelines.main.events.filtered // 0')
        
        echo "${LOGSTASH}: in=$IN, filtered=$FILTERED, out=$OUT"
        check_pass "$LOGSTASH is processing events"
    else
        check_warn "$LOGSTASH not accessible (may be expected)"
    fi
done

# Summary
print_header "Health Check Summary"
echo -e "${GREEN}Passed: $CHECKS_PASSED${NC}"
echo -e "${YELLOW}Warnings: $CHECKS_WARNING${NC}"
echo -e "${RED}Failed: $CHECKS_FAILED${NC}"
echo ""

if [ $CHECKS_FAILED -eq 0 ] && [ $CHECKS_WARNING -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed - cluster is healthy!${NC}"
    exit 0
elif [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${YELLOW}⚠ Some warnings detected - review recommended${NC}"
    exit 0
else
    echo -e "${RED}✗ Critical issues detected - immediate action required${NC}"
    exit 1
fi
