#!/usr/bin/env bash
set -euo pipefail

input_leads="${1:-raw_leads.json}"
state_file=".processed_leads.state"
touch "$state_file"

# enforce dependencies and environment variables
command -v jq >/dev/null 2>&1 || { echo "[-] jq is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[-] curl is required." >&2; exit 1; }

hunter_key="${hunter_key:?missing hunter_key in environment}"
instantly_key="${instantly_key:?missing instantly_key in environment}"

echo "starting lead ingestion and validation pipeline..."

# bottleneck fix: parse the entire json file once and stream it natively into bash as tsv.
# this drops subprocess overhead from O(N*3) to O(1).
jq -r '.[] | [.email, .first_name, .company_name] | @tsv' "$input_leads" | while IFS=$'\t' read -r raw_email raw_first raw_company; do
    
    # 1. state tracking (idempotency)
    # if the script crashes, it won't re-process and burn api credits for leads already verified.
    if grep -q -x "$raw_email" "$state_file" 2>/dev/null; then
        echo "[-] skipping $raw_email (already processed)"
        continue
    fi

    echo "[+] processing: $raw_email"

    # 2. cross-platform sanitization
    # stripped gnu sed \U. used posix-compliant awk to capitalize names safely on macos/linux.
    sanitized_name="$(echo "$raw_first" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
    
    # stripped corporate suffixes safely, accounting for trailing punctuation (e.g., "Acme LLC,")
    sanitized_company="$(echo "$raw_company" | sed -E 's/[[:space:]]+(Inc|LLC|Co|Ltd|Incorporated)[^a-zA-Z0-9]*$//i')"

    # 3. api rate limit handling (exponential backoff)
    max_retries=5
    retry_count=0
    backoff_sleep=2

    while [[ $retry_count -lt $max_retries ]]; do
        http_status=$(curl -s -o /dev/null -w "%{http_code}" "https://api.hunter.io/v2/email-verifier?email=${raw_email}&api_key=${hunter_key}")
        
        if [[ "$http_status" == "429" ]]; then
            echo "[-] 429 rate limit hit. backing off for ${backoff_sleep}s..."
            sleep "$backoff_sleep"
            backoff_sleep=$((backoff_sleep * 2))
            ((retry_count++))
        elif [[ "$http_status" == "200" || "$http_status" == "201" ]]; then
            break
        else
            echo "[-] hunter api failure (HTTP $http_status). dropping lead."
            continue 2 # skip to next lead in the main loop
        fi
    done

    if [[ $retry_count -eq $max_retries ]]; then
        echo "[-] max retries exceeded for $raw_email. skipping."
        continue
    fi

    # 4. safe json payload construction
    # dropped brittle bash string interpolation. use jq to guarantee valid json escaping.
    payload=$(jq -n -c \
        --arg email "$raw_email" \
        --arg firstName "$sanitized_name" \
        --arg companyName "$sanitized_company" \
        '{
            "leads": [
                {
                    "email": $email,
                    "firstName": $firstName,
                    "companyName": $companyName
                }
            ]
        }'
    )

    # 5. campaign injection via rest api
    inject_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.instantly.ai/api/v1/lead/add" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${instantly_key}" \
        -d "$payload")

    if [[ "$inject_status" -ge 200 && "$inject_status" -lt 300 ]]; then
        echo "[+] lead successfully injected."
        # log to state file only upon complete success
        echo "$raw_email" >> "$state_file"
    else
        echo "[-] injection failed (HTTP $inject_status)."
    fi

done

echo "pipeline run finished."