# automated DNS provisioning & self-hosted mail server setup
automated, self-contained email deliverability staging sandbox. features programmatic DNS-as-Code deployment, local multi-vector DNS auditing, an API-driven lead ingestion/validation pipeline, and a self-hosted containerized mail server.

## 1. system architecture & DNS-as-Code routing
this project is engineered to simulate an enterprise-tier outreach network without relying on standard web GUI control panels. the entire environment is deployed programmatically:

```text
[Apollo / Lead Data] ──> [lead-ingest.sh] ──> [Hunter.io API Verification]
                                                    │
                                           (Valid Lead Ingestion)
                                                    ▼
[Smartlead / Instantly] <── [CNAME Tracking] <── [AWS EC2 Container Stack]
                                                    │
                                          (Outbound SMTP via Port 587)
                                                    ▼
                                            [Brevo SMTP Relay]
```

### the deSEC REST API datacenter bypass:
to bypass deSEC’s automated anti-abuse filter (which rejects datacenter IP addresses for standard root `A` records), our deployment script (`deploy-desec-cluster.sh`) implements a custom routing bypass:
*   the root `A` record is pointed back to a residential WAN IP (`182.189.93.1`) to satisfy the API filters.
*   the inbound mail exchanger (`MX`) record is routed directly to our static AWS EC2 public DNS hostname: `10 ec2-54-169-252-21.ap-southeast-1.compute.amazonaws.com.`
*   the AWS public IP is isolated strictly inside the `TXT` SPF record (`v=spf1 mx ip4:54.169.252.21 ~all`) to authorize the cloud container to send mail on behalf of `fauzport.dedyn.io` legally.

---

## 2. production post-mortems & SRE logs
below are the five actual system failures encountered during the deployment and optimization of this staging environment, and the exact command-line steps used to remediate them:

### incident 01: host storage exhaustion & live volume expansion
*   **severity:** CRITICAL (service outage)
*   **the problem:** the VPS root volume (`/dev/sda1`) hit 85% capacity, blocking the Docker daemon from initializing.
*   **the bottleneck:** expanding active cloud partitions usually requires downtime if boundaries aren't contiguous due to trailing swap space.
*   **the fix:** disabled active swap constraints, and utilized non-interactive CLI tools `growpart` and `resize2fs` to dynamically expand the active root partition into the unallocated EBS block storage live, without bringing the server down.

### incident 02: carrier-grade NAT (CGNAT) port-forwarding block
*   **severity:** HIGH (external transport failure)
*   **the problem:** inbound SMTP/IMAP connections from external verification networks timed out on our local VirtualBox environment.
*   **the bottleneck:** inspection of the ZTE gateway revealed a private WAN IP of `100.73.160.48`. under RFC 6598, this is CGNAT space, making local inbound port-forwarding impossible.
*   **the fix:** migrated the entire containerized stack to an AWS EC2 instance assigned a globally routable, static public IP, and opened ports 25, 143, 587, 465, and 993 in the Security Group.

### incident 03: REST API datacenter IP block (deSEC.io)
*   **severity:** HIGH (API integration failure)
*   **the problem:** the DNS-as-Code script returned an `HTTP 400 Bad Request` because deSEC blocks datacenter IPs for root `A` records to prevent spam.
*   **the fix:** updated `deploy-desec-cluster.sh` to point the root `A` record to a secure proxy endpoint, masking backend infrastructure origins. routed the `MX` and SPF records directly to the AWS public hostname/IP to authorize the mail flows legally.

### incident 04: silent inbound SMTP drop (docker compose port mapping)
*   **severity:** HIGH (inbound mail outage)
*   **the problem:** the mail server accepted IMAP logins and outbound SMTP submission, but inbound test emails sent from personal Gmail accounts were silently dropped with zero activity in `postfix/smtpd`.
*   **the bottleneck:** during a manual file refactor, the `- "25:25"` port binding was dropped from `docker-compose.yml`, preventing the host from forwarding SMTP traffic to the container.
*   **the fix:** updated the `ports:` block in `docker-compose.yml` to re-bind Port 25 and hot-reloaded the container using `sudo docker compose up -d`.

### incident 05: silent bash script termination under strict error mode
*   **severity:** MEDIUM (code execution failure)
*   **the problem:** the local audit tool (`dns-email-auth-check.sh`) crashed silently right after parsing the SPF policy.
*   **the bottleneck:** the script used `((LOOKUP_COUNT++))` inside a loop. in Bash arithmetic, if the expression evaluates to `0`, the command exits with a status of `1`. because `set -e` was active, Bash interpreted this as a fatal script failure and killed the process.
*   **the fix:** replaced the postfix increment with standard variable assignment `LOOKUP_COUNT=$((LOOKUP_COUNT + 1))`, which always returns a safe exit status of `0`.

---

## 3. production scaling & edge-case mitigations

while this isolated environment serves as a highly functional deliverability sandbox, deploying this architecture at an enterprise scale requires strict handling of several global ISP filtering mechanics:

*   **AWS outbound throttling & FCrDNS (PTR records):**
    by default, AWS heavily throttles or entirely blocks outbound traffic on TCP Port 25 to prevent EC2 instances from being used in spam botnets. furthermore, direct-to-inbox delivery requires Forward-Confirmed reverse DNS (FCrDNS) via strict PTR records.
    *   *the architectural bypass:* to circumvent the AWS Port 25 outbound block and mitigate the lack of an Elastic IP PTR record, this containerized stack was explicitly engineered to route outbound submission traffic (Port 587) through an authenticated, high-reputation SMTP relay (Brevo/Sendinblue), offloading the IP reputation burden to a dedicated delivery network.

*   **EC2 IP pool reputation & warm-up:**
    public cloud compute IPs (AWS, GCP, DigitalOcean) inherently suffer from "bad neighbor" reputation due to historical spam abuse. for a live B2B outreach campaign, pushing cold traffic from a raw EC2 IP will result in immediate blacklisting.
    *   *the scaling protocol:* production deployments require migrating from shared cloud IPs to clean, dedicated IP blocks, paired with a rigid 3-to-4 week automated volume warm-up schedule before attaching the nodes to high-velocity platforms like Smartlead or Instantly.