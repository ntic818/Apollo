```python
#!/usr/bin/env python3
"""
ELK Stack Deployment Validator
Performs comprehensive health checks across the stack
"""

import requests
import sys
import json
from urllib3.exceptions import InsecureRequestWarning
from typing import Dict, List, Tuple

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

class ELKValidator:
    def __init__(self, es_host: str, kibana_host: str, username: str, password: str):
        self.es_host = es_host
        self.kibana_host = kibana_host
        self.auth = (username, password)
        self.results = []

    def check_elasticsearch_cluster(self) -> bool:
        """Check Elasticsearch cluster health"""
        try:
            response = requests.get(
                f"{self.es_host}/_cluster/health",
                auth=self.auth,
                verify=False,
                timeout=10
            )
            data = response.json()
            
            status = data['status']
            self.results.append(("Cluster Health", status, status in ['yellow', 'green']))
            self.results.append(("Number of Nodes", data['number_of_nodes'], data['number_of_nodes'] >= 3))
            self.results.append(("Active Shards", data['active_shards'], data['active_shards'] > 0))
            
            return status in ['yellow', 'green']
        except Exception as e:
            self.results.append(("Elasticsearch Connection", str(e), False))
            return False

    def check_node_roles(self) -> bool:
        """Verify node roles are correctly assigned"""
        try:
            response = requests.get(
                f"{self.es_host}/_cat/nodes?format=json",
                auth=self.auth,
                verify=False,
                timeout=10
            )
            nodes = response.json()
            
            master_nodes = [n for n in nodes if 'm' in n['node.role']]
            data_nodes = [n for n in nodes if 'd' in n['node.role']]
            
            self.results.append(("Master Nodes", len(master_nodes), len(master_nodes) >= 3))
            self.results.append(("Data Nodes", len(data_nodes), len(data_nodes) >= 3))
            
            return len(master_nodes) >= 3 and len(data_nodes) >= 3
        except Exception as e:
            self.results.append(("Node Roles Check", str(e), False))
            return False

    def check_indices(self) -> bool:
        """Check index health"""
        try:
            response = requests.get(
                f"{self.es_host}/_cat/indices?format=json",
                auth=self.auth,
                verify=False,
                timeout=10
            )
            indices = response.json()
            
            red_indices = [i for i in indices if i['health'] == 'red']
            
            self.results.append(("Total Indices", len(indices), len(indices) > 0))
            self.results.append(("Red Indices", len(red_indices), len(red_indices) == 0))
            
            return len(red_indices) == 0
        except Exception as e:
            self.results.append(("Indices Check", str(e), False))
            return False

    def check_ilm_policies(self) -> bool:
        """Verify ILM policies exist"""
        try:
            response = requests.get(
                f"{self.es_host}/_ilm/policy",
                auth=self.auth,
                verify=False,
                timeout=10
            )
            policies = response.json()
            
            required_policies = ['syslog-policy', 'beats-policy']
            existing = [p for p in required_policies if p in policies]
            
            self.results.append(("ILM Policies", len(existing), len(existing) == len(required_policies)))
            
            return len(existing) == len(required_policies)
        except Exception as e:
            self.results.append(("ILM Policies Check", str(e), False))
            return False

    def check_kibana(self) -> bool:
        """Check Kibana status"""
        try:
            response = requests.get(
                f"{self.kibana_host}/api/status",
                auth=self.auth,
                verify=False,
                timeout=10
            )
            data = response.json()
            
            status = data['status']['overall']['state']
            self.results.append(("Kibana Status", status, status == 'green'))
            
            return status == 'green'
        except Exception as e:
            self.results.append(("Kibana Connection", str(e), False))
            return False

    def check_ml_jobs(self) -> bool:
        """Verify ML jobs are configured"""
        try:
            response = requests.get(
                f"{self.es_host}/_ml/anomaly_detectors",
                auth=self.auth,
                verify=False,
                timeout=10
            )
            data = response.json()
            
            job_count = data['count']
            self.results.append(("ML Jobs", job_count, job_count > 0))
            
            return job_count > 0
        except Exception as e:
            self.results.append(("ML Jobs Check", str(e), False))
            return False

    def run_all_checks(self) -> bool:
        """Run all validation checks"""
        print("=" * 60)
        print("ELK Stack Deployment Validation")
        print("=" * 60)
        
        checks = [
            self.check_elasticsearch_cluster,
            self.check_node_roles,
            self.check_indices,
            self.check_ilm_policies,
            self.check_kibana,
            self.check_ml_jobs
        ]
        
        all_passed = True
        for check in checks:
            try:
                passed = check()
                all_passed = all_passed and passed
            except Exception as e:
                print(f"Error in {check.__name__}: {e}")
                all_passed = False
        
        # Print results
        print("\nValidation Results:")
        print("-" * 60)
        for name, value, passed in self.results:
            status = "✓ PASS" if passed else "✗ FAIL"
            print(f"{name:30} {str(value):20} {status}")
        
        print("=" * 60)
        if all_passed:
            print("✓ All checks passed!")
            return True
        else:
            print("✗ Some checks failed. Please review.")
            return False

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Validate ELK Stack deployment')
    parser.add_argument('--es-host', default='https://localhost:9200', help='Elasticsearch host')
    parser.add_argument('--kibana-host', default='https://localhost:5601', help='Kibana host')
    parser.add_argument('--username', default='elastic', help='Username')
    parser.add_argument('--password', required=True, help='Password')
    
    args = parser.parse_args()
    
    validator = ELKValidator(args.es_host, args.kibana_host, args.username, args.password)
    
    if validator.run_all_checks():
        sys.exit(0)
    else:
        sys.exit(1)
```
