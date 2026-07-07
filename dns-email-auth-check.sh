#!/usr/bin/env bash

set -euo pipefail

TARGET_DOMAIN="${1:?error: missing target domain. usage: $0 <domain_name>}"

for cmd in dig grep; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: required dependency '$cmd' is missing." >&2
        exit 1
    fi
done

echo "checking MX records..."

MX_RECORDS=$(dig +short MX "${TARGET_DOMAIN}")

if [ -z "$MX_RECORDS" ]; then
    echo "[-] STATUS: CRITICAL - No MX records discovered."
    echo "    This domain cannot receive inbound email, which highly degrades sender trust."
else
    # rfc 5321 validation: ensure no mx record points directly to a raw ip address
    if echo "$MX_RECORDS" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "[-] STATUS: CRITICAL - RFC Violation: MX record points directly to a raw IP address!"
        echo "    Mail servers will drop or deprioritize delivery to this domain."
        echo "$MX_RECORDS" | sed 's/^/    /'
    else
        echo "[+] STATUS: MX records are active and point to valid hostnames."
    fi
fi
echo "--------------------------------------------------"


# spf record something something idk

echo "checking DNS deliv for: ${TARGET_DOMAIN}"
echo "--------------------------------------------------"

RAW_TXT_RECORDS=$(dig +short TXT "${TARGET_DOMAIN}" | tr -d '"')
SPF_RECORDS=$(echo "$RAW_TXT_RECORDS" | grep "v=spf1" || true)

if [ -z "$SPF_RECORDS" ]; then
    echo "[-] STATUS: CRITICAL - no SPF record found for ${TARGET_DOMAIN}"
    echo "    emails sent from this domain will fail basic auth filters."
else
    # count records using the locally cached data
    SPF_COUNT=$(echo "$SPF_RECORDS" | wc -l)

    if [ "$SPF_COUNT" -gt 1 ]; then
        echo "[-] STATUS: CRITICAL - multiple SPF records detected (${SPF_COUNT})!"
        echo "    RFC Violation: mail servers will completely invalidate SPF evaluation."
        echo "$SPF_RECORDS" | sed 's/^/    / '
    else
        echo "[+] STATUS: single SPF record detected"
        echo "    Raw: ${SPF_RECORDS}"

        # evaluate policy strength without relying on rigid line-endings
        if echo "$SPF_RECORDS" | grep -qE "\+all([[:space:]]|$)"; then
            echo "    [-] CRITICAL SECURITY VULNERABILITY: '+all' opens an authorized relay!"
        elif echo "$SPF_RECORDS" | grep -qE "\~all([[:space:]]|$)"; then
            echo "    Policy Strength: SoftFail (~all) - Acceptable, but risks landing in spam depending on DMARC."
        elif echo "$SPF_RECORDS" | grep -qE "\-all([[:space:]]|$)"; then
            echo "    Policy Strength: HardFail (-all) - Strict enforcement active."
        else
            echo "    Policy Strength: Neutral (?all) or Missing fallback modifier."
        fi

        # evaluate the 10-dns-lookup limit (rfc 7208)
        # count root mechanisms that require external dns queries
        LOOKUP_COUNT=0

        # tokenize the spf record by spaces and loop through mechanisms
        for token in $SPF_RECORDS; do
            case "$token" in
                include:*|a|a:*|mx|mx:*|ptr|ptr:*|exists:*|redirect=*)
                    LOOKUP_COUNT=$((LOOKUP_COUNT + 1))
                    ;;
            esac
        done

        echo "    DNS Lookup Load: ${LOOKUP_COUNT}/10 mechanisms in root record."

        if [ "$LOOKUP_COUNT" -gt 10 ]; then
            echo "    [-] STATUS: CRITICAL - Root SPF record exceeds the 10-DNS-lookup limit!"
            echo "        Mail servers will return a PermError and ignore this record completely."
        elif [ "$LOOKUP_COUNT" -gt 7 ]; then
            echo "    [!] WARN: high lookup count (${LOOKUP_COUNT})."
            echo "        nested 'include' statements inside these providers could easily push this over 10."
        else
            echo "    [+] Status: lookup budget is well within safe limits at the root level."
        fi
    fi
fi
echo "--------------------------------------------------"


# allow providing a known selector as the second script argument
TARGET_SELECTOR="${2:-}"

check_dkim() {
    local sel="$1"
    local record
    
    # query dns and look for the mandatory p= tag, ignoring case
    # paste flattens potential multi-line text chunk splits from dig
    record=$(dig +short TXT "${sel}._domainkey.${TARGET_DOMAIN}" | tr -d '"' | paste -sd ' ' -)
    
    if [[ -n "$record" && "$record" =~ "p=" ]]; then
        echo "[+] DKIM Public Key Found [Selector: ${sel}]"
        echo "    Record: ${record}"
        
        # extract the base64 string from the p= tag to measure key length
        local p_value
        p_value=$(echo "$record" | sed -n 's/.*p=\([^;]*\).*/\1/p' | tr -d '[:space:]')
        local key_len=${#p_value}
        
        # 1024-bit keys are ~172 chars; 2048-bit keys are ~392 chars
        if [ "$key_len" -lt 200 ]; then
            echo "    [!] WARN: Key appears to be 1024-bit (weak). Modern standards require 2048-bit."
        else
            echo "    [+] Key strength looks secure (likely 2048-bit or higher)."
        fi
        return 0
    fi
    return 1
}

echo "Analyzing DKIM Status..."
echo "--------------------------------------------------"

if [ -n "${TARGET_SELECTOR}" ]; then
    # if the engineer provided the specific selector, check only that
    check_dkim "${TARGET_SELECTOR}" || echo "[-] ERROR: Specified selector '${TARGET_SELECTOR}' not found."
else
    # fallback to standard industry defaults if analyzing blindly
    echo "[INFO] No selector provided. Running fallback scan for common vectors..."
    
    SELECTORS=("default" "s1" "s2" "mail" "k1" "sendgrid" "mandrill")
    
    # check mx records efficiently using grep -i
    MX_LOOKUP=$(dig +short MX "${TARGET_DOMAIN}")
    if echo "$MX_LOOKUP" | grep -iq "google"; then
        SELECTORS+=("google")
    fi
    if echo "$MX_LOOKUP" | grep -iq "outlook"; then
        SELECTORS+=("selector1" "selector2")
    fi

    DKIM_FOUND=0
    for selector in "${SELECTORS[@]}"; do
        if check_dkim "$selector"; then
            DKIM_FOUND=1
        fi
    done

    # fix: changed -e to -eq for accurate integer testing
    if [ "$DKIM_FOUND" -eq 0 ]; then
        echo "[-] NOTICE: No default infrastructure DKIM keys discovered."
        echo "    To audit thoroughly, extract the 's=' tag from an inbound email header."
    fi
fi
echo "--------------------------------------------------"


# dmarc policy analysis

echo "checking DMARC record..."

# query the explicit _dmarc subdomain frame and flatten any multi-line split anomalies
DMARC_RECORD=$(dig +short TXT "_dmarc.${TARGET_DOMAIN}" | tr -d '"' | paste -sd ' ' -)

if [ -z "${DMARC_RECORD}" ]; then
    echo "[-] STATUS: CRITICAL - No DMARC record found for ${TARGET_DOMAIN}!"
    echo "    Your domain has zero protection against direct identity theft and spoofing."
else
    echo "[+] STATUS: DMARC Record Detected"
    echo "    Payload: ${DMARC_RECORD}"

    # rfc 7489 requirement: version tag must be present, uppercase, and at the start
    if [[ ! "${DMARC_RECORD}" =~ ^v=DMARC1 ]]; then
        echo "[-] STATUS: CRITICAL - Invalid DMARC header prefix."
        echo "    RFC Violation: Record must begin strictly with case-sensitive 'v=DMARC1'."
    else
        # extract the core policy tag value using word boundaries to avoid sp= collisions
        # handles optional spaces around the equal sign allowed by the specification
        POLICY=$(echo "${DMARC_RECORD}" | grep -oP "\bp\s*=\s*[a-zA-Z]+" | tr -d ' ' || true)

        case "${POLICY}" in
            "p=reject")
                echo "[+] Policy Enforcement: Reject (p=reject) - Unauthenticated emails dropped."
                ;;
            "p=quarantine")
                echo "[+] Policy Enforcement: Quarantine (p=quarantine) - Unauthenticated emails sent to spam."
                ;;
            "p=none")
                echo "[-] WARN: Monitoring Mode Only (p=none)."
                echo "    Security Risk: Spoofing is monitored but not blocked by receiving servers."
                ;;
            *)
                echo "[-] STATUS: CRITICAL - Missing or corrupt 'p=' tag in DMARC record."
                ;;
        esac

        # check for subdomain specific overrides (sp=)
        if echo "${DMARC_RECORD}" | grep -qP "\bsp\s*=\s*"; then
            SUB_POLICY=$(echo "${DMARC_RECORD}" | grep -oP "\bsp\s*=\s*[a-zA-Z]+" | tr -d ' ' || true)
            echo "    Subdomain Policy: Explicitly set to ${SUB_POLICY#sp=}."
        fi

        # verify presence of the aggregate reporting loop (rua)
        if echo "${DMARC_RECORD}" | grep -qP "\brua\s*=\s*"; then
            echo "[+] Reporting Route: Active. XML aggregate logs are tracking."
        else
            echo "[-] WARN: Missing 'rua=' tag. You are blind to active spoofing volume attacks."
        fi
    fi
fi
echo "--------------------------------------------------"

echo "checking modern transit security protocols..."

# query specific subdomains for security policies
MTA_STS_RECORD=$(dig +short TXT "_mta-sts.${TARGET_DOMAIN}" | tr -d '"' || true)
TLS_RPT_RECORD=$(dig +short TXT "_smtp._tls.${TARGET_DOMAIN}" | tr -d '"' || true)

if [ -n "$MTA_STS_RECORD" ]; then
    echo "[+] MTA-STS: Configured"
    echo "    Payload: ${MTA_STS_RECORD}"
else
    echo "[-] NOTICE: MTA-STS not configured. Inbound mail transport cannot enforce strict TLS."
fi

if [ -n "$TLS_RPT_RECORD" ]; then
    echo "[+] TLS-RPT: Configured"
    echo "    Payload: ${TLS_RPT_RECORD}"
else
    echo "[-] NOTICE: TLS Reporting (TLS-RPT) missing. You will not receive transport failure telemetry."
fi
echo "--------------------------------------------------"