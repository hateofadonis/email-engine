#!/usr/bin/env bash
set -euo pipefail

domain="${1:-}"
if [[ -z "$domain" ]]; then
    echo "usage: $0 <domain>" >&2
    exit 1
fi

echo "checking spf for $domain..."

# anchored regex (^"v=spf1) prevents false positives from unrelated txt records.
# dig +short wraps txt results in quotes, so we match the quote.
spf_records=$(dig +short TXT "$domain" | grep -iE '^"v=spf1' || true)
spf_count=$(echo "$spf_records" | grep -c . || true)

if [[ "$spf_count" -eq 0 ]]; then
    echo "[-] critical: no spf record found."
elif [[ "$spf_count" -gt 1 ]]; then
    echo "[-] critical: multiple spf records detected ($spf_count). rfc violation."
    exit 1
fi

# recursive function to accurately calculate rfc 7208 dns lookup limits.
evaluate_spf_lookups() {
    local target="$1"
    local depth="${2:-0}"
    
    # prevent infinite loops in malformed cyclic spf records.
    if [[ "$depth" -gt 10 ]]; then
        echo 0
        return
    fi

    local record
    record=$(dig +short TXT "$target" | grep -iE '^"v=spf1' | tr -d '"' || true)
    if [[ -z "$record" ]]; then
        echo 0
        return
    fi

    local lookups=0
    
    # count local dns-querying mechanisms (a, mx, ptr, exists, include, redirect).
    local local_lookups
    local_lookups=$(echo "$record" | grep -oEi '\b(include:|a|a:|mx|mx:|ptr|ptr:|exists:|redirect=)' | wc -l || true)
    lookups=$((lookups + local_lookups))

    # recursively evaluate nested includes and redirects.
    for inc in $(echo "$record" | grep -oEi '\b(include:|redirect=)[^ ]+' | cut -d: -f2 | cut -d= -f2); do
        local child_lookups
        child_lookups=$(evaluate_spf_lookups "$inc" $((depth + 1)))
        lookups=$((lookups + child_lookups))
    done

    echo "$lookups"
}

total_spf_lookups=$(evaluate_spf_lookups "$domain")
echo "[+] total recursive spf lookups: $total_spf_lookups/10"
if [[ "$total_spf_lookups" -gt 10 ]]; then
    echo "[-] critical: spf lookup limit exceeded. email will fail strict alignment."
fi

echo "checking dmarc..."
dmarc_record=$(dig +short TXT "_dmarc.$domain" | grep -iE '^"v=DMARC1' | tr -d '"' || true)
if [[ -z "$dmarc_record" ]]; then
    echo "[-] critical: no dmarc record found."
else
    # posix-compliant sed parsing. dropped gnu grep -P.
    dmarc_policy=$(echo "$dmarc_record" | sed -n 's/.*p=\([^; ]*\).*/\1/p')
    echo "[+] dmarc policy: p=$dmarc_policy"
fi

echo "checking dkim (fallback scan)..."
dkim_record=""
for selector in "google" "selector1" "default" "s1" "mail"; do
    dkim_test=$(dig +short TXT "${selector}._domainkey.${domain}" | grep -iE '^"v=DKIM1' | tr -d '"' || true)
    if [[ -n "$dkim_test" ]]; then
        dkim_record="$dkim_test"
        echo "[+] dkim record found on selector: $selector"
        break
    fi
done

if [[ -n "$dkim_record" ]]; then
    # parse the k= and p= tags to determine cryptographic strength.
    dkim_k_tag=$(echo "$dkim_record" | sed -n 's/.*k=\([^; ]*\).*/\1/p' | tr '[A-Z]' '[a-z]')
    dkim_p_tag=$(echo "$dkim_record" | sed -n 's/.*p=\([^; ]*\).*/\1/p')
    
    if [[ "$dkim_k_tag" == "ed25519" ]]; then
        echo "[+] dkim crypto: ed25519 (modern, secure short key)."
    else
        # fallback to string length check only if rsa (or implied rsa).
        if [[ ${#dkim_p_tag} -lt 200 ]]; then
            echo "[-] warning: dkim key length is short. likely weak 1024-bit rsa."
        else
            echo "[+] dkim crypto: rsa (key length secure, likely 2048-bit)."
        fi
    fi
else
    echo "[-] notice: no default dkim keys discovered on common selectors."
fi