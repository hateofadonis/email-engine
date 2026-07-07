# lab report: DNS before/after failure simulation
recreating and remediating critical deliverability vulnerabilities in an isolated environment.

## 1. the isolated sandbox architecture
testing real-world DNS failures on production domains is unsafe and expensive. to simulate complex record collisions, we built an isolated local DNS sandbox on a Debian VM using `dnsmasq` to intercept local loopback queries:

```text
[dns-email-auth-check.sh] ──> [dig] ──> [dnsmasq (Port 53)] ──> [configs/dnsmasq.conf]
```

the local nameserver is configured via `configs/dnsmasq.conf` to bind strictly to `127.0.0.1:53` and override resolution records for our mock target domain `brokendomain.local`.

---

## 2. failure scenario 1: multiple SPF record collision
RFC 7208 strictly states a domain must not publish more than one SPF record. doing so completely invalidates SPF evaluation, causing receiving servers to return a `PermError` [1].

### the before state (failure)
we configured the local `dnsmasq` sandbox to return two independent SPF TXT records for `brokendomain.local`:
```text
txt-record=brokendomain.local,"v=spf1 include:_spf.google.com ~all"
txt-record=brokendomain.local,"v=spf1 include:sendgrid.net -all"
```

running our local audit script against the sandbox triggered the critical warning:
```text
[-] STATUS: CRITICAL - Multiple SPF records detected (2)!
    RFC Violation: Mail servers will completely invalidate SPF evaluation.
```

### the remediation (after state)
to fix this failure, we merged the two records into a single, unified text record containing both sending authorized domains:
```text
txt-record=brokendomain.local,"v=spf1 include:_spf.google.com include:sendgrid.net ~all"
```
we re-ran the script, verifying that the collision warning dropped and the SPF status flipped to green.

---

## 3. failure scenario 2: exceeding the 10-DNS-lookup limit
RFC 7208 enforces a strict limit of 10 recursive DNS lookups on the receiving server to prevent denial-of-service (DoS) amplification attacks. if a record requires more than 10 nested queries, verification fails with a `PermError` [1].

### the before state (failure)
we uncommented the long inclusion chain inside `configs/dnsmasq.conf` to publish a highly bloated SPF record:
```text
txt-record=brokendomain.local,"v=spf1 include:1.com include:2.com include:3.com include:4.com include:5.com include:6.com include:7.com include:8.com include:9.com include:10.com include:11.com ~all"
```

running our audit script parsed the tokens and triggered the lookup limit warning:
```text
    DNS Lookup Load: 11/10 mechanisms in root record.
    [-] STATUS: CRITICAL - Root SPF record exceeds the 10-DNS-lookup limit!
        Mail servers will return a PermError and ignore this record completely.
```

### the remediation (after state)
to resolve the lookup bloat, we optimized the record by:
1.  removing unneeded third-party include domains.
2.  flattening dynamic lookups into static IP blocks (using `ip4:x.x.x.x/24` or `ip6:` mechanisms which do not require DNS queries and cost 0 lookups against the budget).

```text
txt-record=brokendomain.local,"v=spf1 ip4:192.0.2.0/24 include:_spf.google.com ~all"
```
re-running the audit script confirmed the lookup load dropped to `1/10`, safely clearing the verification gates.
