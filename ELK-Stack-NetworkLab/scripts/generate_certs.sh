```bash
#!/bin/bash
set -euo pipefail

# Certificate Generation Script
CERT_DIR="certs"
DAYS=3650

echo "Generating certificates for ELK Stack..."

# Create CA
openssl genrsa -out ${CERT_DIR}/ca/ca-key.pem 4096
openssl req -new -x509 -days ${DAYS} -key ${CERT_DIR}/ca/ca-key.pem \
    -out ${CERT_DIR}/ca/ca-cert.pem \
    -subj "/CN=ELK-CA/O=NetworkLab/C=US"

echo "CA certificate generated ✓"

# Function to generate node certificate
generate_cert() {
    local name=$1
    local type=$2
    local ip=$3
    
    # Generate private key
    openssl genrsa -out ${CERT_DIR}/${type}/${name}-key.pem 2048
    
    # Generate CSR
    openssl req -new -key ${CERT_DIR}/${type}/${name}-key.pem \
        -out ${CERT_DIR}/${type}/${name}.csr \
        -subj "/CN=${name}/O=NetworkLab/C=US"
    
    # Create SAN config
    cat > ${CERT_DIR}/${type}/${name}-san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${name}
DNS.2 = localhost
IP.1 = ${ip}
IP.2 = 127.0.0.1
EOF
    
    # Sign certificate
    openssl x509 -req -days ${DAYS} \
        -in ${CERT_DIR}/${type}/${name}.csr \
        -CA ${CERT_DIR}/ca/ca-cert.pem \
        -CAkey ${CERT_DIR}/ca/ca-key.pem \
        -CAcreateserial \
        -out ${CERT_DIR}/${type}/${name}-cert.pem \
        -extensions v3_req \
        -extfile ${CERT_DIR}/${type}/${name}-san.cnf
    
    # Cleanup
    rm ${CERT_DIR}/${type}/${name}.csr ${CERT_DIR}/${type}/${name}-san.cnf
    
    echo "Certificate for ${name} generated ✓"
}

# Generate certificates for each node type
while IFS=',' read -r name type ip; do
    generate_cert "$name" "$type" "$ip"
done < <(cat <<EOF
elk-master-01,elasticsearch,10.0.1.11
elk-master-02,elasticsearch,10.0.1.12
elk-master-03,elasticsearch,10.0.1.13
elk-data-hot-01,elasticsearch,10.0.1.21
elk-data-hot-02,elasticsearch,10.0.1.22
elk-data-hot-03,elasticsearch,10.0.1.23
elk-ingest-01,elasticsearch,10.0.1.41
elk-ingest-02,elasticsearch,10.0.1.42
logstash-01,logstash,10.0.1.51
logstash-02,logstash,10.0.1.52
kibana-01,kibana,10.0.1.61
kibana-02,kibana,10.0.1.62
EOF
)

echo "All certificates generated successfully!"
```
