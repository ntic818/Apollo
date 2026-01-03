```bash
#!/bin/bash
set -euo pipefail

# ELK Stack Backup Script
ES_HOST="${ES_HOST:-https://localhost:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-backup_repository}"
SNAPSHOT_NAME="snapshot_$(date +%Y%m%d_%H%M%S)"

echo "Starting ELK backup: ${SNAPSHOT_NAME}"

# Create snapshot
curl -k -X PUT "${ES_HOST}/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}?wait_for_completion=false" \
  -u "${ES_USER}:${ES_PASS}" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": true,
    "metadata": {
      "taken_by": "backup_script",
      "taken_because": "scheduled_backup"
    }
  }'

echo "Backup initiated: ${SNAPSHOT_NAME}"

# Monitor snapshot progress
while true; do
  STATUS=$(curl -sk "${ES_HOST}/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}" \
    -u "${ES_USER}:${ES_PASS}" | jq -r '.snapshots[0].state')
  
  if [ "$STATUS" == "SUCCESS" ]; then
    echo "Backup completed successfully!"
    break
  elif [ "$STATUS" == "FAILED" ]; then
    echo "Backup failed!"
    exit 1
  else
    echo "Backup in progress... ($STATUS)"
    sleep 30
  fi
done

# List snapshots
echo "Available snapshots:"
curl -sk "${ES_HOST}/_snapshot/${SNAPSHOT_REPO}/_all" \
  -u "${ES_USER}:${ES_PASS}" | jq '.snapshots[] | {name: .snapshot, state: .state, start_time: .start_time}'
```

---