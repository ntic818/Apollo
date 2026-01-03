# ELK Stack Performance Tuning Guide

## Table of Contents
1. [Overview](#overview)
2. [Elasticsearch Tuning](#elasticsearch-tuning)
3. [Logstash Optimization](#logstash-optimization)
4. [Kibana Performance](#kibana-performance)
5. [Operating System Tuning](#operating-system-tuning)
6. [Monitoring Performance](#monitoring-performance)

---

## Overview

This guide provides performance tuning recommendations for the ELK Stack NetworkLab deployment. Proper tuning can improve:
- Indexing throughput (docs/second)
- Query response time
- Resource utilization
- System stability

**Default Performance Targets**:
- Indexing rate: 10,000-50,000 docs/sec
- Query latency (p95): < 1 second
- JVM heap usage: 60-80% (steady state)
- CPU utilization: 50-70% (under load)

---

## Elasticsearch Tuning

### 1. JVM Heap Sizing

**Rule**: Set heap to 50% of available RAM, max 31GB

```bash
# /etc/elasticsearch/jvm.options.d/custom.options
-Xms16g
-Xmx16g  # Same as Xms for heap stability
```

**Why 31GB limit?**: 
- Above 32GB, compressed object pointers (compressed oops) are disabled
- Memory efficiency drops dramatically
- Better to scale horizontally than exceed 31GB heap

**Heap Sizing Guidelines**:
| Node RAM | Heap Size | Reasoning |
|----------|-----------|-----------|
| 8 GB | 4 GB | 50% rule |
| 16 GB | 8 GB | 50% rule |
| 32 GB | 16 GB | 50% rule |
| 64 GB | 31 GB | Max compressed oops |
| 128 GB | 31 GB | Scale horizontally instead |

### 2. Thread Pool Configuration

```yaml
# elasticsearch.yml
thread_pool:
  write:
    size: 30  # Number of CPU cores + 1
    queue_size: 10000  # Prevent rejection under load
  search:
    size: 30  # (CPU cores / 2) + 1
    queue_size: 10000
```

**Monitor thread pool rejections**:
```bash
curl -X GET "https://localhost:9200/_nodes/stats/thread_pool?pretty" | grep rejected
```

### 3. Index Settings Optimization

**For High Ingest Rate** (`syslog-*` indices):
```json
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1,
    "refresh_interval": "30s",
    "index": {
      "translog": {
        "durability": "async",
        "sync_interval": "30s",
        "flush_threshold_size": "1gb"
      },
      "merge": {
        "scheduler": {
          "max_thread_count": 1
        }
      }
    }
  }
}
```

**Key Settings Explained**:
- `refresh_interval: "30s"` → Delay searchability for better indexing performance
- `translog.durability: "async"` → Don't fsync every operation (5-30s data loss risk)
- `flush_threshold_size: "1gb"` → Less frequent flushes

### 4. Bulk Indexing Best Practices

```bash
# Optimal bulk size: 5-15 MB per request
# Test to find your sweet spot

# Before bulk loading, temporarily:
curl -X PUT "https://localhost:9200/syslog-*/_settings" \
  -H 'Content-Type: application/json' -d '
{
  "index": {
    "number_of_replicas": 0,
    "refresh_interval": "-1"
  }
}'

# Run bulk load...

# After bulk loading, restore:
curl -X PUT "https://localhost:9200/syslog-*/_settings" \
  -H 'Content-Type: application/json' -d '
{
  "index": {
    "number_of_replicas": 1,
    "refresh_interval": "30s"
  }
}'

# Force merge to reduce segments
curl -X POST "https://localhost:9200/syslog-*/_forcemerge?max_num_segments=1"
```

### 5. Query Performance Tuning

**Use Filters Instead of Queries** (when possible):
```json
// ❌ Slower (scores every document)
{"query": {"match": {"severity": "critical"}}}

// ✅ Faster (uses cache)
{"query": {"bool": {"filter": [{"term": {"severity": "critical"}}]}}}
```

**Enable Query Cache**:
```yaml
# elasticsearch.yml
indices.queries.cache.size: 10%  # % of heap
```

**Fielddata Cache** (for aggregations):
```yaml
indices.fielddata.cache.size: 25%  # % of heap
```

### 6. Shard Sizing Strategy

**Rule of Thumb**:
- Shard size: 20-50 GB (ideal: 30 GB)
- Max shards per node: 20 per GB of heap

**Calculate Optimal Shards**:
```
Daily Log Volume: 100 GB/day
Retention: 90 days
Total Data: 9 TB

Hot Tier (7 days): 700 GB
Shards needed: 700 GB / 30 GB = ~23 shards

Use 3 primary shards with daily rollover at 50 GB
```

**Monitor Shard Distribution**:
```bash
curl -X GET "https://localhost:9200/_cat/shards?v&h=index,shard,prirep,state,docs,store,node" | sort
```

### 7. Circuit Breaker Tuning

**Prevent OOM errors**:
```yaml
# elasticsearch.yml
indices.breaker.total.limit: 70%  # % of heap
indices.breaker.fielddata.limit: 40%
indices.breaker.request.limit: 40%
```

### 8. Disable Features You Don't Use

```yaml
# elasticsearch.yml
# Disable expensive features if not needed
xpack.watcher.enabled: false  # If not using alerting
xpack.graph.enabled: false    # If not using graph exploration
```

---

## Logstash Optimization

### 1. Pipeline Configuration

```yaml
# /etc/logstash/logstash.yml
pipeline:
  workers: 8  # Number of CPU cores
  batch:
    size: 1000  # Events per batch (tune: 125-1000)
    delay: 50   # Max ms to wait for batch to fill
  
# Increase queue size for bursty traffic
queue:
  type: persisted
  max_bytes: 8gb  # Disk-based queue
  checkpoint.writes: 1024
```

**Performance Testing**:
```bash
# Monitor pipeline performance
curl -X GET "http://localhost:9600/_node/stats/pipelines?pretty"

# Key metrics:
# - events.in vs events.out (should be close)
# - events.duration_in_millis (processing time)
# - queue.events (queue depth - should stay low)
```

### 2. Filter Optimization

**❌ Slow: Multiple conditional blocks**
```ruby
filter {
  if [type] == "syslog" {
    grok { ... }
  }
  if [type] == "syslog" {
    mutate { ... }
  }
  if [type] == "syslog" {
    date { ... }
  }
}
```

**✅ Fast: Single conditional with multiple filters**
```ruby
filter {
  if [type] == "syslog" {
    grok { ... }
    mutate { ... }
    date { ... }
  }
}
```

**Use `tag_on_failure` Instead of Conditionals**:
```ruby
filter {
  grok {
    match => { "message" => "%{SYSLOGLINE}" }
    tag_on_failure => ["_grokparsefailure"]
  }
  
  # Only process successfully parsed events
  if "_grokparsefailure" not in [tags] {
    # ... further processing
  }
}
```

### 3. Output Tuning

```ruby
output {
  elasticsearch {
    hosts => ["https://elk-ingest-01:9200", "https://elk-ingest-02:9200"]
    
    # Bulk settings
    bulk_path => "/_bulk"
    flush_size => 1000      # Events per bulk request
    idle_flush_time => 5    # Seconds before forcing flush
    
    # Connection pooling
    pool_max => 10
    pool_max_per_route => 2
    
    # Retry on failure
    retry_on_conflict => 3
  }
}
```

### 4. Java Heap Sizing

```bash
# /etc/logstash/jvm.options
-Xms4g
-Xmx4g  # Match Xms

# Rule: 25-50% of available RAM, max 8GB
```

---

## Kibana Performance

### 1. Query Optimization

**Avoid Wildcards at Start of Search**:
```
# ❌ Slow
*error*

# ✅ Fast
error*
```

**Use Time Filters**:
- Always include time range filters (default: last 15 minutes)
- Kibana queries without time filters scan all data

### 2. Dashboard Optimization

**Reduce Panel Count**:
- Max 10-15 panels per dashboard
- Split complex dashboards into multiple pages

**Use Saved Searches**:
- Define searches once, reuse in multiple visualizations
- Reduces redundant queries

**Disable Auto-Refresh**:
- Set refresh to "Off" when not actively monitoring
- Saves query load

### 3. Index Pattern Best Practices

**Use Specific Patterns**:
```
❌ Slow:  *
✅ Fast:  syslog-*
```

**Exclude Unnecessary Fields**:
- In index pattern settings, exclude rarely-used fields from fielddata
- Reduces memory usage

---

## Operating System Tuning

### 1. Disable Swap

```bash
# Temporarily
sudo swapoff -a

# Permanently
sudo vim /etc/fstab  # Comment out swap line
```

**Why**: Swapping Elasticsearch causes severe performance degradation

### 2. Increase File Descriptors

```bash
# Check current limit
ulimit -n

# Set in /etc/security/limits.conf
elasticsearch soft nofile 65536
elasticsearch hard nofile 65536

# Verify after restart
sudo -u elasticsearch bash -c 'ulimit -n'
```

### 3. Virtual Memory Settings

```bash
# /etc/sysctl.conf
vm.max_map_count=262144
vm.swappiness=1  # Avoid swap unless absolutely necessary

# Apply
sudo sysctl -p
```

### 4. Disk I/O Scheduler

**For SSDs**:
```bash
echo noop | sudo tee /sys/block/sda/queue/scheduler

# Make permanent in /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="elevator=noop"
sudo update-grub
```

**For HDDs**: Use `deadline` scheduler

---

## Monitoring Performance

### 1. Key Metrics to Track

**Elasticsearch**:
```bash
# Cluster health
GET /_cluster/health

# Node stats
GET /_nodes/stats

# Index stats
GET /syslog-*/_stats

# Thread pool stats
GET /_nodes/stats/thread_pool
```

**Critical Metrics**:
| Metric | Threshold | Action |
|--------|-----------|--------|
| JVM Heap | > 85% | Investigate memory leaks |
| CPU | > 90% | Add nodes or optimize queries |
| Disk | > 85% | Expand storage or reduce retention |
| Query latency (p95) | > 5s | Optimize queries or add replicas |
| Indexing rate | Decreasing | Check for bottlenecks |

### 2. Slow Log Configuration

```yaml
# elasticsearch.yml
index.search.slowlog.threshold.query.warn: 5s
index.search.slowlog.threshold.query.info: 2s
index.search.slowlog.threshold.fetch.warn: 1s

index.indexing.slowlog.threshold.index.warn: 5s
index.indexing.slowlog.threshold.index.info: 2s
```

**View slow logs**:
```bash
tail -f /var/log/elasticsearch/*_index_search_slowlog.log
```

---

## Performance Testing

### Load Testing Elasticsearch

**Using `esrally`**:
```bash
# Install
pip3 install esrally

# Run benchmark
esrally race --track=geonames --target-hosts=elk-ingest-01:9200 --client-options="use_ssl:true,verify_certs:false"
```

### Logstash Load Testing

```bash
# Generate test load
for i in {1..10000}; do
  echo "<134>Jan 3 12:00:00 test-device TEST: Load test message $i" | nc -u logstash-01 514
done

# Monitor throughput
watch -n 1 'curl -s http://logstash-01:9600/_node/stats/pipelines | jq ".pipelines.main.events"'
```

---

## Troubleshooting Performance Issues

### High JVM Heap Usage

**Diagnosis**:
```bash
# Heap dump
jmap -dump:live,format=b,file=/tmp/heap.hprof $(pgrep -f elasticsearch)

# Analyze with Eclipse MAT or similar tool
```

**Common Causes**:
1. Too many shards
2. Large fielddata cache (aggregations on high-cardinality fields)
3. Memory leak in plugin
4. Insufficient heap size

### Slow Indexing

**Check**:
```bash
# Indexing stats
curl -X GET "https://localhost:9200/_nodes/stats/indices/indexing?pretty"

# Look for:
# - index_total (should be increasing)
# - index_time_in_millis (should be reasonable)
# - throttle_time_in_millis (should be low)
```

**Common Fixes**:
1. Increase `refresh_interval`
2. Reduce `number_of_replicas` during bulk load
3. Use `async` translog
4. Add more data nodes

### Slow Queries

**Identify slow queries**:
```bash
# Enable profile API
curl -X GET "https://localhost:9200/syslog-*/_search?pretty" \
  -H 'Content-Type: application/json' -d '
{
  "profile": true,
  "query": { ... }
}'
```

**Common Fixes**:
1. Add filters to reduce dataset
2. Use more specific index patterns
3. Cache frequent queries
4. Add more replicas for read-heavy workloads

---

## Performance Checklist

Before Going to Production:

- [ ] JVM heap set to 50% RAM (max 31GB)
- [ ] Swap disabled
- [ ] `vm.max_map_count` set to 262144
- [ ] File descriptors set to 65536
- [ ] `refresh_interval` set to 30s for high-ingest indices
- [ ] Thread pools sized appropriately
- [ ] Bulk requests sized at 5-15 MB
- [ ] Slow log thresholds configured
- [ ] Monitoring dashboards created
- [ ] Load testing completed
- [ ] Performance baselines documented

---

**Document Version**: 1.0  
**Last Updated**: January 2026  
**Next Review**: Quarterly or after major version upgrade
