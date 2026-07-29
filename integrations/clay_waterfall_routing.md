# data enrichment & validation waterfall
**pipeline objective:** sanitize raw b2b leads and minimize api verification costs through strategic waterfall routing.

## 1. data sanitization (pre-verification)
raw data from apollo/zoominfo is notoriously dirty. sending dirty names to smtp relays increases spam scores. we clean the data in clay before passing it to the validation waterfall.

**first name normalization (javascript):**
naive `.toupper()` functions break on complex names. this regex handles hyphens and apostrophes natively.
```javascript
// normalizes "jean-luc", "O'CONNOR", and "mary jane"
return rawName.toLowerCase().replace(/(?:^|[\s-'])\w/g, match => match.toUpperCase());
```

**company suffix stripping (regex):**
raw databases often include trailing commas or periods (e.g., "acme llc,"). this regex strips the suffix while absorbing trailing punctuation.
```javascript
// strips "inc", "llc", "co", "ltd" ignoring case and trailing symbols
return rawCompany.replace(/\s+(Inc|LLC|Co|Ltd|Incorporated)[^\w]*$/gi, '').trim();
```

## 2. validation waterfall routing
do not blindly trust a single verification provider. route based on cost and accuracy.

**tier 1: hunter.io (bulk screening)**
- `valid` -> push to instantly.ai.
- `invalid` -> drop lead.
- `accept_all` / `unknown` -> pass to tier 2.

**tier 2: zerobounce (smtp handshake)**
- `valid` -> push to instantly.ai.
- `invalid` -> drop lead.
- `catch-all` -> pass to tier 3 (scrubby). 
*(warning: do not trust zerobounce "valid" responses on catch-all domains. smtp handshakes on catch-alls yield high false positives. route all catch-alls to tier 3).*

**tier 3: scrubby (silent burner injection)**
- `deliverable` -> push to instantly.ai.
- `bounced` -> drop lead.
