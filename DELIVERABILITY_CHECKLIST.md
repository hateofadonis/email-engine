# Enterprise Email Deliverability & Compliance Checklist
my engineering process for high-volume outbound infrastructure hardening.

## Phase 1: DNS & Transport Discovery
* map domain MX records to verify inbound routing paths.
* check host compliance to ensure zero MX nodes resolve directly to raw IP blocks (RFC 5321).
* query subdomains to validate MTA-STS and TLS-RPT transit encryption policies.

## Phase 2: SPF Integrity Hardening
* parse root TXT frames to ensure only a single valid `v=spf1` record exists.
* calculate root mechanism lookup weight to ensure compliance with the RFC 7208 10-DNS-lookup limit.
* remove any global fallback targets (`+all`) and configure strict modifiers (`~all` or `-all`).

## Phase 3: Cryptographic Alignment & Platform Hooking
* scan common and provider-specific infrastructure selectors for active public keys.
* measure public key base64 string length to verify minimum 2048-bit cryptographic strength.
* configure custom CNAME records for dedicated link tracking on outbound send platforms (Instantly/Smartlead).

## Phase 4: DMARC Policy Scaling Execution
* deploy the `_dmarc` TXT record ensuring proper `v=DMARC1` formatting.
* implement an active `rua=` tag to route XML aggregate volume reports.
* transition DMARC policy modifiers progressively through staging phases (`p=none` -> `p=quarantine` -> `p=reject`).
