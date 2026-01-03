```bash
#!/bin/bash
set -euo pipefail

# Production ELK Stack - Environment Setup Script
echo "========================================="
echo "ELK Stack Environment Setup"
echo "========================================="

# Check prerequisites
command -v ansible >/dev/null 2>&1 || { echo "Ansible required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Python3 required"; exit 1; }

# Create directory structure
echo "[1/6] Creating directories..."
mkdir -p {certs,backups,logs,tmp}
mkdir -p certs/{ca,elasticsearch,logstash,kibana}

# Install Python dependencies
echo "[2/6] Installing Python packages..."
pip3 install -r requirements.txt

# Install Ansible collections
echo "[3/6] Installing Ansible collections..."
ansible-galaxy collection install -r requirements.yml

# Verify inventory
echo "[4/6] Verifying inventory..."
if [ ! -f inventory/production/hosts.ini ]; then
    echo "ERROR: Production inventory not found"
    exit 1
fi

# Create vault password file
echo "[5/6] Setting up vault..."
if [ ! -f .vault_pass ]; then
    read -sp "Enter vault password: " vault_pass
    echo "$vault_pass" > .vault_pass
    chmod 600 .vault_pass
    echo ""
fi

# Test connectivity
echo "[6/6] Testing connectivity..."
ansible all -i inventory/production/hosts.ini -m ping || {
    echo "WARNING: Some hosts unreachable"
}

echo "========================================="
echo "Setup complete!"
echo "========================================="
echo "Next steps:"
echo "1. Edit inventory/production/hosts.ini"
echo "2. Configure group_vars/vault.yml"
echo "3. Run: ansible-playbook playbooks/site.yml"
```