# ELK Stack Security Hardening Guide

## Table of Contents
1. [Security Overview](#security-overview)
2. [Operating System Hardening](#operating-system-hardening)
3. [Network Security](#network-security)
4. [Elasticsearch Security](#elasticsearch-security)
5. [Logstash Security](#logstash-security)
6. [Kibana Security](#kibana-security)
7. [Access Control & Authentication](#access-control--authentication)
8. [Audit Logging](#audit-logging)
9. [Security Monitoring](#security-monitoring)
10. [Compliance](#compliance)

---

## Security Overview

This guide implements **defense-in-depth** security for the ELK Stack NetworkLab deployment, following industry best practices and compliance requirements (SOC 2, PCI-DSS, GDPR).

**Security Layers**:
1. Operating System hardening
2. Network segmentation & firewalls
3. Encryption (at rest & in transit)
4. Authentication & authorization
5. Audit logging
6. Security monitoring & alerting

**Security Posture**: **High**
- ✅ TLS 1.3 everywhere
- ✅ Certificate-based authentication
- ✅ Role-Based Access Control (RBAC)
- ✅ Comprehensive audit logging
- ✅ Regular security updates

---

## Operating System Hardening

### 1. Minimal Installation

**Ubuntu 22.04 LTS - Server (no GUI)**:
```bash
# Install only required packages
apt-get install -y openssh-server ufw fail2ban auditd aide

# Remove unnecessary packages
apt-get purge -y telnet rsh-client

# Disable unnecessary services
systemctl disable bluetooth.service
systemctl disable cups.service
```

### 2. User Account Security

```bash
# Lock root account (use sudo instead)
passwd -l root

# Create dedicated elasticsearch user (already done by package)
# Ensure no direct login
usermod -s /usr/sbin/nologin elasticsearch

# Remove unnecessary users
userdel -r games lp news uucp
```

### 3. SSH Hardening

**`/etc/ssh/sshd_config`**:
```bash
# Disable root login
PermitRootLogin no

# Use key-based authentication only
PasswordAuthentication no
PubkeyAuthentication yes

# Disable empty passwords
PermitEmptyPasswords no

# Limit SSH to specific users
AllowUsers ansible-user ops-team

# Change default port (optional, security through obscurity)
Port 2222

# Disable X11 forwarding
X11Forwarding no

# Use strong ciphers only
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Restart SSH
systemctl restart sshd
```

### 4. Firewall Configuration

**UFW (Uncomplicated Firewall)**:
```bash
# Enable UFW
ufw --force enable

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (from bastion only)
ufw allow from 10.0.0.10 to any port 22 proto tcp

# Allow Elasticsearch (inter-cluster only)
ufw allow from 10.0.1.0/24 to any port 9200 proto tcp
ufw allow from 10.0.1.0/24 to any port 9300 proto tcp

# Allow Kibana (from load balancer only)
ufw allow from 10.0.1.71 to any port 5601 proto tcp
ufw allow from 10.0.1.72 to any port 5601 proto tcp

# Allow Logstash syslog (from network devices)
ufw allow from 10.0.2.0/24 to any port 514 proto udp
ufw allow from 10.0.2.0/24 to any port 514 proto tcp

# Logging
ufw logging on

# Check status
ufw status verbose
```

### 5. Fail2Ban Configuration

**`/etc/fail2ban/jail.local`**:
```ini
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = security@yourdomain.com

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log

[elasticsearch]
enabled = true
port = 9200
logpath = /var/log/elasticsearch/*_access.log
maxretry = 10
```

**Restart fail2ban**:
```bash
systemctl enable fail2ban
systemctl restart fail2ban
```

### 6. System Auditing

**Auditd Configuration** (`/etc/audit/rules.d/elk.rules`):
```bash
# Monitor Elasticsearch configuration changes
-w /etc/elasticsearch/ -p wa -k elasticsearch_config

# Monitor data directory
-w /var/lib/elasticsearch/ -p wa -k elasticsearch_data

# Monitor certificate changes
-w /etc/elasticsearch/certs/ -p wa -k elasticsearch_certs

# Monitor user changes
-w /etc/passwd -p wa -k user_modifications
-w /etc/shadow -p wa -k user_modifications
-w /etc/group -p wa -k user_modifications

# Monitor sudo usage
-w /etc/sudoers -p wa -k sudoers_changes

# Reload auditd rules
augenrules --load
```

### 7. File Integrity Monitoring

**AIDE (Advanced Intrusion Detection Environment)**:
```bash
# Initialize database
aide --init

# Move database
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# Run daily checks (add to cron)
echo "0 2 * * * root /usr/bin/aide --check | mail -s 'AIDE Report' security@yourdomain.com" >> /etc/crontab

# Manual check
aide --check
```

---

## Network Security

### 1. Network Segmentation

**VLAN Strategy**:
```
Management Network (VLAN 10): 10.0.1.0/24
  - ELK cluster nodes
  - Bastion/jump hosts
  - Monitoring servers

Production Network (VLAN 20): 10.0.2.0/24
  - Network devices (sources)
  - Syslog generators

Storage Network (VLAN 30): 10.0.3.0/24 (optional)
  - NFS/iSCSI for backups
  - S3 gateway
```

**Firewall Rules Between VLANs**:
```
VLAN 20 → VLAN 10:
  - Allow: TCP 514 (Logstash syslog)
  - Allow: UDP 514 (Logstash syslog)
  - Allow: TCP 5044 (Beats)
  - Deny: All other

VLAN 10 → VLAN 20:
  - Allow: ICMP (for monitoring)
  - Allow: TCP 22 (SSH from bastion only)
  - Deny: All other

VLAN 10 → VLAN 30:
  - Allow: NFS, iSCSI (backup traffic)
  - Deny: All other
```

### 2. TLS/SSL Configuration

**Certificate Hierarchy**:
```
CA Certificate (ca-cert.pem)
├── Elasticsearch Nodes (elk-*.pem)
├── Logstash Nodes (logstash-*.pem)
└── Kibana Nodes (kibana-*.pem)
```

**TLS Best Practices**:
```yaml
# Force TLS 1.3 only (or TLS 1.2 minimum)
xpack.security.http.ssl.supported_protocols: ["TLSv1.3", "TLSv1.2"]

# Use strong ciphers only
xpack.security.http.ssl.cipher_suites:
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256

# Certificate validation
xpack.security.transport.ssl.verification_mode: full
```

**Certificate Renewal**:
```bash
# Check certificate expiration
openssl x509 -in /etc/elasticsearch/certs/node-cert.pem -noout -dates

# Set up renewal (90 days before expiry)
# Add to cron or use certbot for Let's Encrypt
```

### 3. VPN/Bastion Access

**Bastion Host Configuration**:
```bash
# Only allow SSH from corporate VPN
ufw allow from 172.16.0.0/16 to any port 22

# Force MFA for bastion access
# Configure using Google Authenticator or Duo

# SSH jump configuration (~/.ssh/config)
Host elk-*
  ProxyJump bastion.yourdomain.com
  User ops-user
```

---

## Elasticsearch Security

### 1. Enable X-Pack Security

**`elasticsearch.yml`**:
```yaml
xpack.security.enabled: true
xpack.security.enrollment.enabled: false  # Disable auto-enrollment

# HTTP SSL
xpack.security.http.ssl:
  enabled: true
  certificate: /etc/elasticsearch/certs/node-cert.pem
  key: /etc/elasticsearch/certs/node-key.pem
  certificate_authorities: /etc/elasticsearch/certs/ca-cert.pem
  client_authentication: optional  # or 'required' for strict mutual TLS

# Transport SSL (inter-node)
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  certificate: /etc/elasticsearch/certs/node-cert.pem
  key: /etc/elasticsearch/certs/node-key.pem
  certificate_authorities: /etc/elasticsearch/certs/ca-cert.pem
```

### 2. Password Policy

**Set strong passwords**:
```bash
# Generate strong passwords
openssl rand -base64 32

# Set passwords
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic --batch
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system --batch
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u logstash_system --batch

# Store in Ansible Vault
ansible-vault edit group_vars/vault.yml
```

**Password Requirements**:
- Minimum 16 characters
- Include uppercase, lowercase, numbers, symbols
- No dictionary words
- Rotate every 90 days

### 3. Role-Based Access Control (RBAC)

**Create Custom Roles**:
```bash
# Read-only analyst role
curl -X POST "https://localhost:9200/_security/role/log_analyst" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["syslog-*", "beats-*"],
      "privileges": ["read", "view_index_metadata"],
      "field_security": {
        "grant": ["*"],
        "except": ["sensitive_field"]
      }
    }
  ]
}'

# Security analyst with additional permissions
curl -X POST "https://localhost:9200/_security/role/security_analyst" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "cluster": ["monitor", "manage_ml"],
  "indices": [
    {
      "names": ["syslog-*", "beats-*", ".ml-*"],
      "privileges": ["read", "write", "view_index_metadata", "manage"]
    }
  ],
  "applications": [
    {
      "application": "kibana-.kibana",
      "privileges": ["feature_ml.all", "feature_dashboard.all"],
      "resources": ["*"]
    }
  ]
}'

# Network engineer (full access to syslog data)
curl -X POST "https://localhost:9200/_security/role/network_engineer" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "cluster": ["monitor", "manage_index_templates", "manage_ilm"],
  "indices": [
    {
      "names": ["syslog-*"],
      "privileges": ["all"]
    }
  ]
}'
```

**Create Users with Roles**:
```bash
curl -X POST "https://localhost:9200/_security/user/john.doe" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "password": "SecurePassword123!",
  "roles": ["log_analyst"],
  "full_name": "John Doe",
  "email": "john.doe@yourdomain.com"
}'
```

### 4. API Key Management

**Create API keys for applications**:
```bash
# Create API key with limited permissions
curl -X POST "https://localhost:9200/_security/api_key" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "name": "monitoring-app-key",
  "role_descriptors": {
    "monitoring": {
      "cluster": ["monitor"],
      "indices": [
        {
          "names": [".monitoring-*"],
          "privileges": ["read"]
        }
      ]
    }
  },
  "expiration": "30d"
}'

# List API keys
curl -X GET "https://localhost:9200/_security/api_key" \
  -u elastic:${ES_PASSWORD}

# Revoke API key
curl -X DELETE "https://localhost:9200/_security/api_key" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "ids": ["API_KEY_ID"]
}'
```

### 5. IP Filtering

**Restrict access by IP** (`elasticsearch.yml`):
```yaml
xpack.security.http.filter:
  allow: ["10.0.1.0/24", "10.0.2.0/24"]
  deny: "_all"
```

---

## Logstash Security

### 1. Secure Elasticsearch Output

**`/etc/logstash/conf.d/99-output.conf`**:
```ruby
output {
  elasticsearch {
    hosts => ["https://elk-ingest-01:9200", "https://elk-ingest-02:9200"]
    
    # Authentication
    user => "logstash_writer"
    password => "${LOGSTASH_ES_PASSWORD}"  # Use environment variable
    
    # TLS
    ssl => true
    cacert => "/etc/logstash/certs/ca-cert.pem"
    ssl_certificate_verification => true
    
    # Index security
    index => "syslog-%{+YYYY.MM.dd}"
    
    # Connection security
    http_compression => true
  }
}
```

### 2. Input Security

**Syslog with TLS**:
```ruby
input {
  syslog {
    port => 6514
    type => "syslog"
    
    # TLS configuration
    ssl_enabled => true
    ssl_cert => "/etc/logstash/certs/logstash-cert.pem"
    ssl_key => "/etc/logstash/certs/logstash-key.pem"
    ssl_verify => false  # Set to true if network devices support client certs
  }
}
```

### 3. Keystore for Secrets

```bash
# Create keystore
/usr/share/logstash/bin/logstash-keystore create

# Add secret
echo "your_password" | /usr/share/logstash/bin/logstash-keystore add LOGSTASH_ES_PASSWORD

# List keys
/usr/share/logstash/bin/logstash-keystore list

# Use in config: ${LOGSTASH_ES_PASSWORD}
```

---

## Kibana Security

### 1. Kibana Configuration

**`/etc/kibana/kibana.yml`**:
```yaml
# Elasticsearch connection security
elasticsearch.hosts: ["https://elk-ingest-01:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_ES_PASSWORD}"  # Use keystore
elasticsearch.ssl:
  certificateAuthorities: ["/etc/kibana/certs/ca-cert.pem"]
  verificationMode: full

# Server SSL
server.ssl:
  enabled: true
  certificate: /etc/kibana/certs/kibana.crt
  key: /etc/kibana/certs/kibana.key

# Security features
xpack.security.enabled: true
xpack.security.session.idleTimeout: "8h"
xpack.security.session.lifespan: "30d"

# Encryption keys (32-character random strings)
xpack.security.encryptionKey: "${KIBANA_ENCRYPTION_KEY}"
xpack.encryptedSavedObjects.encryptionKey: "${KIBANA_SO_KEY}"
xpack.reporting.encryptionKey: "${KIBANA_REPORTING_KEY}"

# Content Security Policy
csp.strict: true

# Disable telemetry
telemetry.enabled: false
telemetry.optIn: false
```

### 2. Space-Based Isolation

**Create isolated spaces for teams**:
```bash
# Network Operations space
curl -X POST "https://localhost:5601/api/spaces/space" \
  -u elastic:${ES_PASSWORD} -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d '
{
  "id": "network-ops",
  "name": "Network Operations",
  "description": "Network monitoring and troubleshooting",
  "disabledFeatures": ["ml", "apm"]
}'

# Security Operations space
curl -X POST "https://localhost:5601/api/spaces/space" \
  -u elastic:${ES_PASSWORD} -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d '
{
  "id": "security-ops",
  "name": "Security Operations",
  "description": "Security incident response",
  "disabledFeatures": ["canvas", "maps"]
}'
```

### 3. Session Security

```yaml
# Kibana.yml
xpack.security.session:
  idleTimeout: "8h"
  lifespan: "30d"
  cleanupInterval: "1h"

# Force logout on browser close
xpack.security.session.keepAliveTimeout: null
```

---

## Access Control & Authentication

### 1. LDAP/Active Directory Integration

**`elasticsearch.yml`**:
```yaml
xpack.security.authc.realms.ldap.ldap1:
  order: 0
  url: "ldaps://ldap.yourdomain.com:636"
  bind_dn: "cn=elasticsvc,ou=services,dc=yourdomain,dc=com"
  bind_password: "${LDAP_BIND_PASSWORD}"
  user_search:
    base_dn: "ou=users,dc=yourdomain,dc=com"
    filter: "(cn={0})"
  group_search:
    base_dn: "ou=groups,dc=yourdomain,dc=com"
  files:
    role_mapping: "/etc/elasticsearch/role_mapping.yml"
  unmapped_groups_as_roles: false
```

**Role Mapping** (`/etc/elasticsearch/role_mapping.yml`):
```yaml
log_analyst:
  - "cn=Log Analysts,ou=groups,dc=yourdomain,dc=com"

security_analyst:
  - "cn=Security Team,ou=groups,dc=yourdomain,dc=com"

network_engineer:
  - "cn=Network Engineers,ou=groups,dc=yourdomain,dc=com"

superuser:
  - "cn=ELK Admins,ou=groups,dc=yourdomain,dc=com"
```

### 2. SAML/SSO Integration

**For enterprise SSO** (Okta, Azure AD, Google Workspace):
```yaml
# elasticsearch.yml
xpack.security.authc.realms.saml.saml1:
  order: 2
  idp.metadata.path: saml/idp-metadata.xml
  idp.entity_id: "https://yourdomain.okta.com"
  sp.entity_id: "https://kibana.yourdomain.com/"
  sp.acs: "https://kibana.yourdomain.com/api/security/saml/callback"
  sp.logout: "https://kibana.yourdomain.com/logout"
  attributes.principal: "nameid"
  attributes.groups: "groups"
```

---

## Audit Logging

### 1. Enable Elasticsearch Audit Logging

**`elasticsearch.yml`**:
```yaml
xpack.security.audit.enabled: true

# What to log
xpack.security.audit.logfile.events.include:
  - access_denied
  - access_granted
  - anonymous_access_denied
  - authentication_failed
  - authentication_success
  - connection_denied
  - connection_granted
  - tampered_request
  - run_as_denied
  - run_as_granted

# Exclude noisy events
xpack.security.audit.logfile.events.exclude:
  - system_access_granted

# Log to file and index
xpack.security.audit.outputs: [logfile, index]

# Indexing settings
xpack.security.audit.index.bulk_size: 1000
xpack.security.audit.index.flush_interval: 1s
```

**Audit Log Location**: `/var/log/elasticsearch/*_audit.json`

### 2. Query Audit Logs

```bash
# Search audit logs
curl -X GET "https://localhost:9200/.security_audit*/_search?pretty" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "query": {
    "bool": {
      "must": [
        {"match": {"event.type": "authentication_failed"}},
        {"range": {"@timestamp": {"gte": "now-1h"}}}
      ]
    }
  },
  "sort": [{"@timestamp": "desc"}]
}'
```

---

## Security Monitoring

### 1. Failed Login Alerts

**Create Kibana alert rule**:
```bash
curl -X POST "https://localhost:5601/api/alerting/rule" \
  -u elastic:${ES_PASSWORD} -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d '
{
  "name": "Failed Logins Threshold",
  "rule_type_id": ".index-threshold",
  "params": {
    "index": [".security_audit*"],
    "timeField": "@timestamp",
    "aggType": "count",
    "groupBy": "top",
    "termField": "user.name",
    "termSize": 10,
    "timeWindowSize": 15,
    "timeWindowUnit": "m",
    "thresholdComparator": ">",
    "threshold": [10],
    "filterQuery": "event.type:authentication_failed"
  },
  "schedule": {"interval": "5m"},
  "actions": []
}'
```

### 2. Privilege Escalation Detection

```bash
# Monitor for role changes
curl -X GET "https://localhost:9200/.security_audit*/_search?pretty" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "query": {
    "bool": {
      "should": [
        {"match": {"event.action": "put_role"}},
        {"match": {"event.action": "put_user"}},
        {"match": {"event.action": "change_password"}}
      ]
    }
  }
}'
```

---

## Compliance

### 1. PCI-DSS Requirements

- ✅ Encryption in transit (TLS 1.2+)
- ✅ Encryption at rest (optional via ES encryption)
- ✅ Strong access control (RBAC)
- ✅ Audit logging (all access tracked)
- ✅ Regular security updates
- ✅ Password policy enforcement
- ✅ Session timeout (8 hours)

### 2. GDPR Data Protection

**Personal Data Handling**:
```bash
# Anonymize IP addresses in logs
filter {
  mutate {
    # Replace last octet with 0
    gsub => ["source_ip", "\.\d+$", ".0"]
  }
}

# Set data retention (90 days max for PII)
# Configured in ILM policy
```

**Right to be Forgotten**:
```bash
# Delete user's data
curl -X POST "https://localhost:9200/syslog-*/_delete_by_query" \
  -u elastic:${ES_PASSWORD} -H 'Content-Type: application/json' -d '
{
  "query": {
    "term": {"user_id": "user_123"}
  }
}'
```

---

## Security Checklist

Before Production:

- [ ] All passwords changed from defaults
- [ ] TLS enabled for all communication
- [ ] Certificates issued by internal CA (not self-signed)
- [ ] UFW/firewall enabled on all nodes
- [ ] Fail2ban configured
- [ ] SSH hardened (key-only, no root)
- [ ] Audit logging enabled
- [ ] File integrity monitoring (AIDE) configured
- [ ] RBAC roles created for all user types
- [ ] LDAP/SAML authentication configured
- [ ] API keys for automation (no passwords in scripts)
- [ ] Audit log retention 1+ year
- [ ] Security monitoring dashboards created
- [ ] Failed login alerts configured
- [ ] Incident response plan documented
- [ ] Security training completed for ops team
- [ ] Vulnerability scanning scheduled
- [ ] Penetration testing completed
- [ ] Compliance requirements verified

---

**Document Version**: 1.0  
**Last Updated**: January 2026  
**Next Security Review**: Quarterly
**Compliance Audits**: Annual
