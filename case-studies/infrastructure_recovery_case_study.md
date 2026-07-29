# sre post-mortem: dns limits & pipeline execution failures

## incident 01: rfc 7208 lookup exhaustion
**symptom:** outbound emails to google workspace tenants bouncing with `550 5.7.26` unauthenticated sender errors, despite spf records returning `pass` in basic testing.
**root cause analysis:** the client's spf record was overloaded with third-party marketing tools. `dig +short TXT` showed 8 mechanisms. however, this was a superficial count. evaluating the nested `include:` directives recursively revealed the true lookup load was 14, exceeding the hard rfc 10-lookup limit. receivers were dropping the connection with a `permerror`.
**remediation (v2 patch):** 
we rewrote `dns-email-auth-check.sh`. the v1 script only counted root mechanisms. the v2 release implements a recursive bash function to drill into `include` and `redirect` targets, providing an accurate, nested lookup count. to resolve the client's failure, we deployed a dynamic spf flattening proxy via desec.

## incident 02: api rate limit cascade (429s)
**symptom:** the `lead-ingest.sh` pipeline randomly dropped 30-40% of leads during bulk processing runs.
**root cause analysis:** the v1 bash script used a brute-force `while` loop that slammed the hunter.io api. when hunter returned an http 429 (too many requests), the script lacked state tracking, blindly interpreted the 429 as a failure, dropped the lead, and moved to the next. killing and restarting the script caused it to re-process the exact same leads, burning api credits.
**remediation (v2 patch):** 
we completely refactored `lead-ingest.sh`. the v2 pipeline processes the json matrix in O(1) space via `jq` streaming, implements a `.state` file for idempotency (allowing safe pipeline resumes), and wraps api calls in an exponential backoff loop to elegantly absorb 429s without dropping data.

## incident 03: deployment idempotency & execution policy
**symptom:** updating a client's mx record via the desec api accidentally wiped their existing a records, taking down their main website.
**root cause analysis:** the `deploy-desec-cluster.sh` script utilized a standard `PUT` request targeting the `/rrsets/` endpoint. we failed to realize the api treated `PUT` as an absolute overwrite rather than an append.
**remediation (v2 patch):** 
we transitioned the deployment script to use `PATCH`. additionally, we ripped out brittle bash string interpolation for payload construction and replaced it with strict `jq -n` mapping to prevent unescaped characters from panicking the api endpoint.