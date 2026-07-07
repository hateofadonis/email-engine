# clay cascading waterfall enrichment & verification logic
low-cost reputation protection system for high-volume outbound databases.

## 1. the routing logic (the waterfall)
to minimize api costs while maintaining hard bounce rates strictly below 2%, we run leads through a sequential verification cascade:

step 1: run apollo raw email through hunter.io api ($0.01 per check).
  - if status is "deliverable" -> mark valid, push to campaign database.
  - if status is "undeliverable" -> mark invalid, drop record.
  - if status is "accept-all" (catch-all) -> route to step 2.

step 2: route catch-all leads to zerobounce api ($0.002 per check) for deep smtp handshake verification.
  - if status is "valid" -> mark valid, push to campaign.
  - if status is "invalid" -> drop record.
  - if status is "unknown" / "do_not_mail" -> route to step 3.

step 3: route remaining high-risk catch-alls to scrubby.ai ($0.03 per check) for live inbox interaction validation.
  - if verified -> mark valid, push to campaign.
  - if unverified -> drop record.

## 2. data cleaning formulas (clay / javascript equivalent)
clean mixed-case names and strip trailing corporate clutter before sending payload to the outreach api:

```javascript
// clean first name casing (e.g. jOHN -> John)
const rawName = lead.first_name;
const cleanName = rawName.charAt(0).toUpperCase() + rawName.slice(1).toLowerCase();

// strip corporate suffixes (e.g. Acme LLC -> Acme)
const rawCompany = lead.company_name;
const cleanCompany = rawCompany.replace(/\s+(Inc\.|LLC|Co\.|Ltd\.|Incorporated)$/gi, "");