# Backup and Restore Procedures for ELK Stack

## Introduction
This document provides step-by-step instructions for backing up and restoring the ELK Stack, focusing on Elasticsearch snapshots and restoring data.

## Backup Procedure

### 1. **Configure Snapshot Repository**
- Set up a snapshot repository in Elasticsearch (using either a filesystem or S3 bucket).
```bash
curl -X PUT "https://elk-ingest-01:9200/_snapshot/backup_repository" -H 'Content-Type: application/json' -u elastic:$PASSWORD -d '{
  "type": "fs",
  "settings": {
    "location": "/mnt/backup"
  }
}'
