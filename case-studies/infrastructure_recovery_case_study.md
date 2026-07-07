# case study: forensic mail header analysis & DMARC XML triage
reconstructing deliverability alignment and diagnosing forwarding failures.

## 1. raw email header forensics
during an active mail flow audit, a test message claiming to be from `admin@fauzport.dedyn.io` was flagged as unaligned by receiving servers. we extracted and analyzed the raw headers to isolate the mismatch:

```text
Delivered-To: recipient@gmail.com
Received: by 2002:a05:6808:812:: with SMTP id ...
ARC-Authentication-Results: i=1; mx.google.com;
       dkim=pass header.i=@fauzport.dedyn.io header.s=mail;
       spf=fail (google.com: domain of relay-service.net does not designate 198.51.100.12 as authorized sender) smtp.mailfrom=relay-service.net;
       dmarc=pass (p=none sp=none dis=none) header.from=fauzport.dedyn.io
Return-Path: <relay-service.net>
From: admin@fauzport.dedyn.io
```

### the diagnostic breakdown:
1.  **the visible sender (from):** `admin@fauzport.dedyn.io` (the domain we want to authenticate).
2.  **the envelope sender (return-path):** `relay-service.net` (the server that actually handed the mail over).
3.  **SPF evaluation:** failed alignment. SPF only validates the domain in the `Return-Path` (`relay-service.net`). because the visible `From` domain (`fauzport.dedyn.io`) does not match the `Return-Path` domain, SPF is unaligned.
4.  **DKIM evaluation:** passed alignment. the DKIM signature header (`header.i=@fauzport.dedyn.io`) matched the visible `From` domain, and the cryptographic hash verified cleanly against the `mail` selector public key.
5.  **DMARC result:** pass. under RFC 7489, DMARC only requires *either* SPF or DKIM to pass alignment. because DKIM aligned, the overall DMARC evaluation cleared.

---

## 2. DMARC XML aggregate report triage
we received an automated XML aggregate report (`rua` telemetry payload) from `google.com` inside our mail server storage. we parsed the raw record block to analyze an active deliverability failure:

```xml
<record>
  <row>
    <source_ip>198.51.100.12</source_ip>
    <count>1</count>
    <policy_evaluated>
      <disposition>none</disposition>
      <dkim>pass</dkim>
      <spf>fail</spf>
    </policy_evaluated>
  </row>
  <identifiers>
    <header_from>fauzport.dedyn.io</header_from>
  </identifiers>
  <auth_results>
    <dkim>
      <domain>fauzport.dedyn.io</domain>
      <result>pass</result>
      <selector>mail</selector>
    </dkim>
    <spf>
      <domain>forwarding-relay.net</domain>
      <result>pass</result>
    </spf>
  </auth_results>
</record>
```

### the forensic analysis:
*   **the source IP (`198.51.100.12`):** belongs to an external mailing list relay (`forwarding-relay.net`), not our AWS EC2 container.
*   **why SPF failed:** the relay forwarded the email. when Google's MTA checked SPF, it verified the relay's IP against `forwarding-relay.net` (which passed), but because that domain doesn't match the visible `header_from` (`fauzport.dedyn.io`), SPF alignment failed.
*   **why DKIM saved it:** the cryptographic DKIM signature survived the forward relay. the signature was verified against the `mail` selector on `fauzport.dedyn.io` and passed.
*   **the mitigation plan:** because forwarders frequently break SPF alignment, this case study proves why we must configure **both** SPF and DKIM. if we relied strictly on SPF, forwarded emails would fail DMARC and get dropped once we transition our policy to `p=reject`.
```

---

### File 4: `docs/dns_failure_lab.md`
This document details how your local `dnsmasq` configuration and the `dig` mock script are deployed together to trigger and resolve the failures you screenshotted [1].

1.  Create a directory named `docs` in your `email-auth-cluster` folder [1].
2.  Create a new file named `dns_failure_lab.md` inside it [1].
3.  Paste this clean, systems-focused markdown:

```markdown
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
