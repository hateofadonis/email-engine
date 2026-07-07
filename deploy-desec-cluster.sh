#!/usr/bin/env bash

set -euo pipefail

# need curl to hit deSEC API. check now.
for cmd in curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: utility '$cmd' is missing. install it." >&2
        exit 1
    fi
done

# replace these with your actual parameters or export them in your env
API_TOKEN="your_desec_api_token_here"
DOMAIN="your_domain.dedyn.io"
AWS_IP="your_aws_public_ip"
AWS_HOSTNAME="your_aws_ec2_hostname"
PROXY_IP="your_proxy_endpoint_ip"

# pull your generated dkim key from container and paste here
DKIM_KEY="v=DKIM1; h=sha256; k=rsa; p=your_base64_public_key_string"

echo "compiling JSON payloads..."
echo "targeting deSEC API for: ${DOMAIN}"

# literal quotes around variables are needed because deSEC API is strict with JSON string structures
JSON_PAYLOAD=$(cat <<EOF
[
  {
    "subname": "",
    "type": "A",
    "ttl": 3600,
    "records": ["${PROXY_IP}"]
  },
  {
    "subname": "",
    "type": "TXT",
    "ttl": 3600,
    "records": ["\"v=spf1 mx ip4:${AWS_IP} ~all\""]
  },
  {
    "subname": "_dmarc",
    "type": "TXT",
    "ttl": 3600,
    "records": ["\"v=DMARC1; p=none; rua=mailto:telemetry@${DOMAIN}\""]
  },
  {
    "subname": "mail._domainkey",
    "type": "TXT",
    "ttl": 3600,
    "records": ["\"${DKIM_KEY}\""]
  },
  {
    "subname": "",
    "type": "MX",
    "ttl": 3600,
    "records": ["10 ${AWS_HOSTNAME}."]
  },
  {
    "subname": "inst",
    "type": "CNAME",
    "ttl": 3600,
    "records": ["prox.itrackly.com."]
  },
  {
    "subname": "emailtracking",
    "type": "CNAME",
    "ttl": 3600,
    "records": ["open.sleadtrack.com."]
  }
]
EOF
)

echo "sending PUT request to deSEC API..."

RESPONSE=$(curl -s -w "%{http_code}" -X PUT "https://desec.io/api/v1/domains/${DOMAIN}/rrsets/" \
    -H "Authorization: Token ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${JSON_PAYLOAD}")

# extract response elements
HTTP_STATUS="${RESPONSE:${#RESPONSE}-3}"
BODY="${RESPONSE:0:${#RESPONSE}-3}"

if [ "${HTTP_STATUS}" -eq 200 ] || [ "${HTTP_STATUS}" -eq 201 ]; then
    echo "[+] infrastructure provisioned successfully (HTTP ${HTTP_STATUS})."
else
    echo "[-] ERROR: deSEC API rejected payload (HTTP ${HTTP_STATUS})."
    echo "    details: ${BODY}"
    exit 1
fi