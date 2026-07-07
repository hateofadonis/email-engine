#!/usr/bin/env bash

set -euo pipefail

# check for utilities. we need curl and jq or we go home.
for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[-] ERROR: utility '$cmd' is missing. install it." >&2
        exit 1
    fi
done

# place your live keys here when deploying. keeps placeholders for github.
outreach_api_key="your_instantly_or_smartlead_api_key_here"
verify_api_key="your_hunter_io_api_key_here"
campaign_id="your_campaign_uuid_here"

# adjusted to read from the root directory directly
input_leads="raw_leads.json"

if [ ! -f "$input_leads" ]; then
    echo "[-] ERROR: input data file '$input_leads' is missing." >&2
    exit 1
fi

echo "starting lead ingestion and validation pipeline..."
echo "--------------------------------------------------"

# read raw json array and parse line-by-line using jq
jq -c '.[]' "$input_leads" | while read -r lead; do
    raw_email=$(echo "$lead" | jq -r '.email')
    raw_first=$(echo "$lead" | jq -r '.first_name')
    raw_company=$(echo "$lead" | jq -r '.company_name')

    # check basic email syntax before wasting API requests
    if [[ ! "$raw_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "[-] ERROR: '${raw_email}' is syntactically invalid. dropping record."
        echo "--------------------------------------------------"
        continue
    fi

    # clean name casing. standardizes jOHN or john to John.
    first_clean=$(echo "$raw_first" | tr '[:upper:]' '[:lower:]' | sed 's/./\U&/')

    # strip trailing corporate noise so mail mergers look human
    company_clean=$(echo "$raw_company" | sed -E 's/\s+(Inc\.|LLC|Co\.|L\.L\.C\.|Incorporated|Ltd\.)$//gi')

    echo "[+] processing: ${raw_email}"
    echo "    sanitized name: ${first_clean}"
    echo "    sanitized company: ${company_clean}"

    # sandbox mode fallback to save live API credits
    if [ "$verify_api_key" == "your_hunter_io_api_key_here" ]; then
        echo "    [sandbox] simulating Hunter.io verification..."
        if [[ "$raw_email" == *"fake"* || "$raw_email" == *"test"* ]]; then
            verify_status="undeliverable"
        else
            verify_status="deliverable"
        fi
    else
        # live API check
        verify_status=$(curl -s "https://api.hunter.io/v2/email-verifier?email=${raw_email}&api_key=${verify_api_key}" | jq -r '.data.result || "invalid"')
    fi

    if [ "$verify_status" == "deliverable" ] || [ "$verify_status" == "valid" ]; then
        echo "    [+] deliverability verified: ${verify_status}."
        
        # compile the outreach payload JSON string
        outreach_payload=$(cat <<EOF
{
  "api_key": "${outreach_api_key}",
  "campaign_id": "${campaign_id}",
  "lead": {
    "email": "${raw_email}",
    "first_name": "${first_clean}",
    "company_name": "${company_clean}"
  }
}
EOF
)

        # sandbox mode check for outreach campaign insertion
        if [ "$outreach_api_key" == "your_instantly_or_smartlead_api_key_here" ]; then
            echo "    [sandbox] simulating campaign injection..."
            response_code=200
        else
            # live production REST API push
            response_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.instantly.ai/v1/lead/add" \
                -H "Content-Type: application/json" \
                -d "$outreach_payload")
        fi

        if [ "$response_code" -eq 200 ] || [ "$response_code" -eq 201 ]; then
            echo "    [+] lead successfully injected into campaign database (HTTP ${response_code})."
        else
            echo "    [-] ERROR: outreach API rejected lead payload (HTTP ${response_code})."
        fi
    else
        echo "    [-] WARN: address failed verification check (${verify_status}). dropping lead."
    fi
    echo "--------------------------------------------------"
    sleep 0.5
done

echo "pipeline run finished."