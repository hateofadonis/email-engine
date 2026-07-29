#!/usr/bin/env bash
set -euo pipefail

# enforce strict environment variables. fail immediately if missing.
desec_token="${desec_token:?missing desec_token in environment}"
domain="${domain:?missing domain in environment}"
aws_hostname="${aws_hostname:?missing aws_hostname in environment}"
proxy_ip="${proxy_ip:?missing proxy_ip in environment}"
dkim_key="${dkim_key:?missing dkim_key in environment}"

# sanitize input. strip trailing dots to prevent fqdn syntax errors.
aws_hostname="${aws_hostname%.}"
domain="${domain%.}"

# handle dkim 255-character chunking limit for 2048-bit rsa keys.
# desec requires txt records to be wrapped in literal double quotes.
if [[ ${#dkim_key} -gt 200 ]]; then
    dkim_record="\"v=DKIM1; k=rsa; p=${dkim_key:0:200}\" \"${dkim_key:200}\""
else
    dkim_record="\"v=DKIM1; k=rsa; p=${dkim_key}\""
fi

echo "building idempotent patch payload via jq..."

# safely construct json payload using jq to prevent injection bugs.
payload=$(jq -n -c \
    --arg domain "$domain" \
    --arg mx_target "10 ${aws_hostname}." \
    --arg proxy "$proxy_ip" \
    --arg dkim "$dkim_record" \
    '[
        {
            "subname": "",
            "type": "MX",
            "ttl": 3600,
            "records": [$mx_target]
        },
        {
            "subname": "",
            "type": "TXT",
            "ttl": 3600,
            "records": [
                "\"v=spf1 mx a:" + $domain + " ~all\"",
                "\"v=DMARC1; p=reject; rua=mailto:admin@" + $domain + ";\""
            ]
        },
        {
            "subname": "mail._domainkey",
            "type": "TXT",
            "ttl": 3600,
            "records": [$dkim]
        },
        {
            "subname": "emailtracking",
            "type": "CNAME",
            "ttl": 3600,
            "records": ["open.sleadtrack.com."]
        },
        {
            "subname": "inst",
            "type": "CNAME",
            "ttl": 3600,
            "records": ["prox.itrackly.com."]
        }
    ]'
)

echo "pushing state to desec api..."

# use patch instead of put to preserve existing records (idempotency).
response=$(curl -s -w "%{http_code}" -X PATCH "https://desec.io/api/v1/domains/${domain}/rrsets/" \
    -H "Authorization: Token ${desec_token}" \
    -H "Content-Type: application/json" \
    -d "$payload")

http_status="${response:${#response}-3}"
body="${response:0:${#response}-3}"

if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
    echo "dns cluster provisioned successfully."
    exit 0
else
    echo "api failure. http status: $http_status" >&2
    echo "response: $body" >&2
    exit 1
fi