# ELK Stack NetworkLab - Operations Runbook

## Table of Contents
1. [Daily Operations](#daily-operations)
2. [Incident Response](#incident-response)
3. [Common Tasks](#common-tasks)
4. [Troubleshooting Procedures](#troubleshooting-procedures)
5. [Maintenance Windows](#maintenance-windows)
6. [Emergency Contacts](#emergency-contacts)

---

## Daily Operations

### Morning Health Check (09:00 UTC)

#### Step 1: Verify Cluster Health
```bash
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_cluster/health?pretty

# Expected: status = "green" or "yellow"
# RED status requires immediate attention
```

**Success Criteria**:
- `status`: green (ideal) or yellow (acceptable)
- `number_of_nodes`: 12 (all nodes present)
- `active_shards` > 0
- `unassigned_shards`: 0

#### Step 2: Check Node Status
```bash
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_cat/nodes?v

# Verify all nodes appear with correct roles
```

**Look For**:
- All 12 nodes listed
- CPU and heap usage < 80%
- No asterisk (*) next to node names (indicates master)

#### Step 3: Verify Ingestion Rate
```bash
# Check Logstash processing
curl http://logstash-01:9600/_node/stats/pipelines?pretty

# Check Elasticsearch ingestion
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_nodes/stats/indices/indexing?pretty
```

**Expected Values**:
- Logstash `events.in` > 0 (logs being received)
- Logstash `events.out` ≈ `events.in` (no blockage)
- Elasticsearch indexing rate: 10,000-50,000 docs/sec

#### Step 4: Review Kibana Dashboards
1. Open https://kibana.yourdomain.com
2. Navigate to **Stack Monitoring**
3. Check for any alerts or warnings
4. Review "Network Operations Dashboard"

#### Step 5: Check Recent Logs
```bash
# View last 100 syslog entries
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/syslog-*/_search?pretty \
  -H 'Content-Type: application/json' \
  -d '{"size": 100, "sort": [{"@timestamp": "desc"}]}'
```

---

## Incident Response

### P1: Cluster RED Status

**Symptoms**:
- Cluster health API returns `status: "red"`
- Data loss or unavailability

**Immediate Actions** (within 15 minutes):

1. **Identify Missing/Failed Nodes**
```bash
# Check which nodes are down
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_cat/nodes?v

# Compare with expected node count (12 total)
```

2. **Check System Resources**
```bash
# SSH to affected node
ssh elk-data-hot-01

# Check disk space
df -h /var/lib/elasticsearch

# Check memory
free -h

# Check Elasticsearch logs
sudo journalctl -u elasticsearch -n 100 --no-pager
```

3. **Identify Unassigned Shards**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_cat/shards?v | grep UNASSIGNED
```

4. **Attempt Shard Reallocation**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  -X POST https://elk-ingest-01:9200/_cluster/reroute?retry_failed=true
```

5. **Escalate if Not Resolved in 30 Minutes**
   - Contact: Senior SRE Team
   - Slack: #elk-critical-incidents
   - Phone: On-call rotation

---

### P2: High Heap Usage (>85%)

**Symptoms**:
- JVM heap > 85%
- Slow query performance
- Frequent garbage collection

**Actions**:

1. **Identify Affected Node**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_nodes/stats | jq '.nodes[] | {name: .name, heap_percent: .jvm.mem.heap_used_percent}'
```

2. **Check for Memory-Intensive Queries**
```bash
# List running tasks
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_tasks?detailed=true&actions=*search*
```

3. **Cancel Long-Running Queries**
```bash
# Cancel task by ID
curl -k -u elastic:${ES_PASSWORD} \
  -X POST https://elk-ingest-01:9200/_tasks/{task_id}/_cancel
```

4. **Clear Fielddata Cache (if necessary)**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  -X POST https://elk-ingest-01:9200/_cache/clear?fielddata=true
```

5. **Restart Node (last resort)**
```bash
ssh elk-data-hot-01
sudo systemctl restart elasticsearch
```

---

### P3: Logstash Not Processing

**Symptoms**:
- No new logs in Elasticsearch
- Logstash `events.out` = 0

**Actions**:

1. **Check Logstash Service**
```bash
ssh logstash-01
sudo systemctl status logstash
sudo journalctl -u logstash -n 50 --no-pager
```

2. **Verify Network Connectivity**
```bash
# Test syslog port
nc -zv logstash-01 514

# Test Elasticsearch connection
curl -k https://elk-ingest-01:9200/_cluster/health
```

3. **Check Pipeline Configuration**
```bash
# Validate configuration
sudo /usr/share/logstash/bin/logstash \
  --config.test_and_exit \
  -f /etc/logstash/conf.d/
```

4. **Review Dead Letter Queue**
```bash
ls -lh /var/lib/logstash/dead_letter_queue/
```

5. **Restart Logstash**
```bash
sudo systemctl restart logstash
```

---

## Common Tasks

### Add New Network Device

**Time Required**: 15 minutes

1. **Update Ansible Inventory**
```bash
vim inventory/production/hosts.ini

# Add under [network_devices]
new-switch-01 ansible_host=10.0.2.23 ansible_network_os=ios device_type=switch
```

2. **Configure Device Syslog**
```bash
ansible-playbook playbooks/network_devices.yml \
  --limit new-switch-01
```

3. **Verify Logs Received**
```bash
# Wait 5 minutes, then check
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/syslog-*/_search?q=syslog_hostname:new-switch-01
```

---

### Reindex Old Data

**Time Required**: 1-4 hours (depending on data volume)

1. **Create New Index**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  -X PUT https://elk-ingest-01:9200/syslog-reindex \
  -H 'Content-Type: application/json' \
  -d @elasticsearch/index_templates/syslog_template.json
```

2. **Start Reindex Operation**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  -X POST https://elk-ingest-01:9200/_reindex \
  -H 'Content-Type: application/json' \
  -d '{
    "source": {"index": "syslog-2024.01.*"},
    "dest": {"index": "syslog-reindex"}
  }'
```

3. **Monitor Progress**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_tasks?detailed=true&actions=*reindex
```

---

### Scale Data Nodes

**Time Required**: 30-60 minutes

#### Add New Data Node

1. **Provision Server**
   - Meets hardware requirements (8 vCPU, 32GB RAM)
   - Network connectivity configured

2. **Update Inventory**
```bash
vim inventory/production/hosts.ini

# Add to [elk_data_hot]
elk-data-hot-04 ansible_host=10.0.1.24 elasticsearch_node_roles=['data_hot','data_content']
```

3. **Deploy Node**
```bash
ansible-playbook playbooks/elk_cluster.yml \
  --limit elk-data-hot-04
```

4. **Verify Node Joined Cluster**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_cat/nodes?v | grep hot-04
```

5. **Rebalance Shards (automatic, but can force)**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  -X POST https://elk-ingest-01:9200/_cluster/reroute
```

#### Remove Data Node

1. **Exclude Node from Allocation**
```bash
curl -k -u elastic:${ES_PASSWORD} \
  -X PUT https://elk-ingest-01:9200/_cluster/settings \
  -H 'Content-Type: application/json' \
  -d '{
    "persistent": {
      "cluster.routing.allocation.exclude._name": "elk-data-hot-04"
    }
  }'
```

2. **Monitor Shard Migration**
```bash
watch -n 5 'curl -sk -u elastic:${ES_PASSWORD} \
  https://elk-ingest-01:9200/_cat/shards | grep hot-04'
```

3. **Stop Elasticsearch on Node**
```bash
ssh elk-data-hot-04
sudo systemctl stop elasticsearch
```

4. **Remove from Inventory**
```bash
vim
