# hosting-dns.sh

Generate and verify the baseline DNS records for a web/mail hosting domain on a **myVesta** (or HestiaCP) server running **Exim**, when the domain's DNS is hosted **externally** (e.g. Hetzner DNS) instead of on the panel's own BIND.

Control panels like myVesta create the website, mailboxes and DKIM key locally, but if the zone lives on an external provider you have to copy every record by hand, and it is easy to get something wrong: a DKIM key that doesn't match the one Exim signs with, an SPF missing the IPv6, a TXT value longer than 255 characters pasted as a single string, a forgotten `_dmarc`. This script does it for you.

For a given domain it:

1. **Builds the full set of records** needed for hosting: web, FTP, mail, MX, SPF, DKIM, DMARC, CAA and mail-client autodiscovery (SRV).
2. **Reads the DKIM public key from the private key Exim actually uses**, so the published key always matches the signature.
3. **Checks every record against the domain's authoritative nameserver** and reports whether it is `OK`, missing, different, or duplicated.
4. **Writes a BIND zone file** you can import directly into Hetzner DNS (or any provider that accepts zone files).
5. **Checks the PTR (reverse DNS)** of the server IP.

It never changes your DNS: it only reads public DNS and prints/writes what should be there.

---

## Records generated

| Type  | Name                 | Value                                                        | Notes |
|-------|----------------------|--------------------------------------------------------------|-------|
| A     | `@`                  | server IPv4                                                  | |
| AAAA  | `@`                  | server IPv6                                                  | only if the server has IPv6 |
| CNAME | `www`                | `<domain>.`                                                  | |
| CNAME | `ftp`                | `<domain>.`                                                  | |
| A     | `mail`               | server IPv4                                                  | mail host, customizable with `--mx` |
| AAAA  | `mail`               | server IPv6                                                  | only if the server has IPv6 |
| CNAME | `webmail`            | `<domain>.`                                                  | |
| MX    | `@`                  | `10 mail.<domain>.`                                          | |
| SRV   | `_imaps._tcp`        | `0 1 993 mail.<domain>.`                                     | IMAP autodiscovery (RFC 6186) |
| SRV   | `_submission._tcp`   | `0 1 587 mail.<domain>.`                                     | SMTP submission autodiscovery |
| TXT   | `@`                  | `v=spf1 mx ip4:<IPv4> [ip6:<IPv6>] -all`                     | SPF |
| TXT   | `mail._domainkey`    | `v=DKIM1; k=rsa; p=<public key>`                             | DKIM, split into 250-char strings when > 255 |
| TXT   | `_dmarc`             | `v=DMARC1; p=quarantine; rua=mailto:postmaster@<domain>; adkim=r; aspf=r` | DMARC |
| CAA   | `@`                  | `0 issue "letsencrypt.org"`                                  | only this CA may issue certificates |

With `--no-mx` the mail records (`mail`, `webmail`, MX, SRV) are skipped and the `mx` mechanism is removed from SPF. SOA and NS records are left to the DNS provider.

The MX points to a host **inside the customer's domain** (`mail.<domain>`) rather than to the server hostname, so customers can use their own domain in mail clients and you can move them to another server by changing a single A record.

---

## Requirements

- Linux server with **Exim** and **myVesta** or **HestiaCP**
- DKIM key at `/etc/exim4/domains/<domain>/dkim.pem` (the default path used by both panels)
- `bash` 4+, `dig` (`dnsutils` / `bind9-dnsutils`), `openssl`
- Run as **root** (to read the DKIM private key and, with `--regen`, use the panel CLI)
- The server hostname (`hostname -f`) must resolve publicly: its A/AAAA records are used to determine the IPs (or set `IP4` / `IP6` manually)

---

## Installation

```bash
curl -O https://raw.githubusercontent.com/debiano82/vesta-dns-sync/main/hosting-dns.sh
install -m 700 hosting-dns.sh /root/hosting-dns.sh
```

---

## Usage

```
hosting-dns.sh <domain> [--mx <sub>] [--no-mx] [--regen [bits]]
```

| Option          | Description |
|-----------------|-------------|
| `<domain>`      | Domain to process (required). |
| `--mx <sub>`    | Subdomain used as mail host. Default: `mail` → `mail.<domain>`. |
| `--no-mx`       | Incoming mail is handled elsewhere (Google Workspace, Microsoft 365, another server). Skips MX, `mail`, `webmail` and SRV records; SPF authorizes only this server's IPs for outgoing mail. |
| `--regen [bits]`| Regenerates the domain's DKIM key through the panel CLI (`v-delete-mail-domain-dkim` + `v-add-mail-domain-dkim`) before generating records. Default 2048 bits. **The old key stops working immediately**: publish the new record right away. |

### Examples

```bash
# Default: everything, MX on mail.example.com, existing DKIM key
./hosting-dns.sh example.com

# New domain: create a fresh 2048-bit DKIM key, then generate the records
./hosting-dns.sh example.com --regen

# 4096-bit DKIM key
./hosting-dns.sh example.com --regen 4096

# Mail host on posta.example.com
./hosting-dns.sh example.com --mx posta

# Website on this server, mailboxes on another provider
./hosting-dns.sh example.com --no-mx

# Override defaults
SPF_ALL="~all" DMARC_POLICY=none ./hosting-dns.sh example.com
ZONE_DIR=. ./hosting-dns.sh example.com
```

---

## Configuration (environment variables)

| Variable       | Default                 | Description |
|----------------|-------------------------|-------------|
| `IP4`          | A record of `hostname -f` | Server IPv4. |
| `IP6`          | AAAA record of `hostname -f` | Server IPv6. Empty → no AAAA records and no `ip6:` in SPF. |
| `PUB_DNS`      | `1.1.1.1`               | Public resolver used to find the authoritative NS and the server IPs. Avoids answers from stale local zones on the panel's BIND. |
| `SELECTOR`     | `mail`                  | DKIM selector (myVesta/Hestia use `mail`). |
| `SPF_ALL`      | `-all`                  | SPF final qualifier (`-all` hard fail, `~all` soft fail). |
| `DMARC_POLICY` | `quarantine`            | `none`, `quarantine` or `reject`. |
| `DMARC_RUA`    | `postmaster@<domain>`   | Address receiving DMARC aggregate reports. |
| `CAA_CA`       | `letsencrypt.org`       | Certificate authority allowed by the CAA record. |
| `TTL`          | `300`                   | TTL written in the zone file. |
| `ZONE_DIR`     | `/root/dns-zones`       | Where the zone file is saved. |

---

## Output

```
================ example.com  (NS: hydrogen.ns.hetzner.com.) ================
TIPO   NOME                 VALORE
A      @                    203.0.113.10
                         -> OK
CNAME  www                  example.com.
                         -> OK
MX     @                    10 mail.example.com.
                         -> DIVERSO -> 5 mail.otherhost.com. (posta in arrivo oggi li')
TXT    mail._domainkey      "v=DKIM1; k=rsa; p=MIIBIjANBg..." "...IDAQAB"
                         -> DIVERSO dalla chiave di Exim [2048 bit]
...

PTR 203.0.113.10 -> webserver.example.net : OK
Record da sistemare: 2 / 14
File zona importabile su Hetzner: /root/dns-zones/example.com.zone
```

> Status messages are currently in Italian. Meaning:

| Status                          | Meaning |
|---------------------------------|---------|
| `OK`                            | The published record matches the expected value. |
| `ASSENTE`                       | Missing: create it. |
| `DIVERSO -> <value>`            | Different from expected; the current value is shown. |
| `N RECORD -> lasciane uno`      | N records found where only one is allowed (e.g. two SPF or two DKIM records): delete the extras. |
| `DIVERSO dalla chiave di Exim`  | The published DKIM key does not match the private key Exim signs with: **DKIM will fail**. |
| `CHIAVE OK (rimuovi s=mail)`    | The DKIM key matches but the record contains `s=mail`, which is invalid (`s=` is the service type and accepts only `email` or `*`): remove it. Counted as a record to fix. |
| `(posta in arrivo oggi li')`    | The current MX points elsewhere: changing it will redirect incoming mail to this server. |

For `www`, `ftp`, `mail` and `webmail` the check resolves the name (following CNAMEs) and verifies it ends on the server IP, so an equivalent A record instead of a CNAME is also reported as `OK`. If the name resolves to other or additional addresses, they are listed after `DIVERSO`.

The PTR check verifies that the reverse DNS of the server IPv4 matches `hostname -f`. The PTR is set at the IP owner (your hosting/VPS provider's panel), not in the domain zone.

### Zone file

Saved to `$ZONE_DIR/<domain>.zone`:

```zone
; example.com - generato 2026-11-08 19:09:39 da hosting-dns.sh (SOA/NS gestiti da Hetzner)
$ORIGIN example.com.
$TTL 300
@                        300 IN A     203.0.113.10
www                      300 IN CNAME example.com.
ftp                      300 IN CNAME example.com.
mail                     300 IN A     203.0.113.10
webmail                  300 IN CNAME example.com.
@                        300 IN MX    10 mail.example.com.
_imaps._tcp              300 IN SRV   0 1 993 mail.example.com.
_submission._tcp         300 IN SRV   0 1 587 mail.example.com.
@                        300 IN TXT   "v=spf1 mx ip4:203.0.113.10 -all"
mail._domainkey          300 IN TXT   "v=DKIM1; k=rsa; p=MIIBIj...(250 chars)" "...rest"
_dmarc                   300 IN TXT   "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com; adkim=r; aspf=r"
@                        300 IN CAA   0 issue "letsencrypt.org"
```

---

## Workflow for a new domain

1. In myVesta, create the web domain and the mail domain (enable DKIM, or use `--regen`).
2. Run the script:
   ```bash
   /root/hosting-dns.sh example.com --regen
   ```
3. In Hetzner DNS console: **Zone → Import zone file**, paste or upload `/root/dns-zones/example.com.zone`.
   Importing **adds** records, it does not delete existing ones: remove any record reported as `DIVERSO` or duplicated.
4. Wait for the TTL and run the script again until everything is `OK`.
5. Issue the Let's Encrypt certificates in myVesta (web domain + mail domain, so `mail.<domain>` is covered for IMAP/SMTP).
6. Send a test message to a Gmail address and check *Show original*: you should see `SPF: PASS`, `DKIM: PASS`, `DMARC: PASS`. [mail-tester.com](https://www.mail-tester.com) is useful too.

---

## Notes and caveats

- **DKIM and 255-char strings.** A 2048-bit key produces a TXT value of ~400 characters. DNS strings are limited to 255 characters, so the script splits the value into quoted chunks (`"..." "..."`). Resolvers concatenate them transparently. Hetzner does not split long values automatically.
- **Don't regenerate keys from the panel and from the script at random.** Each regeneration creates a new key; only the one in `/etc/exim4/domains/<domain>/dkim.pem` is used for signing. Always publish what the script prints.
- **External senders.** If the domain also sends through other services (Google Workspace, Microsoft 365, newsletters, CRMs), add their `include:` mechanisms to SPF manually; the script will then report SPF as `DIVERSO`, which is expected.
- **CAA locks certificate issuance.** The default `0 issue "letsencrypt.org"` means **only** Let's Encrypt can issue certificates for the domain. If the panel (or acme.sh) falls back to ZeroSSL, or the customer buys a certificate elsewhere, issuance fails with a CAA error. Set `CAA_CA` accordingly or add further `issue` records by hand.
- **DMARC policy.** `quarantine` is a sensible default once SPF and DKIM pass. For a domain with unknown senders start with `DMARC_POLICY=none` and read the reports.
- **Local zones.** If myVesta still has a local DNS zone for a domain whose DNS is external, delete it (`v-delete-dns-domain <user> <domain>`) or stop BIND if unused, to avoid inconsistencies.
- **Changing the MX moves incoming mail.** If the domain's mailboxes live elsewhere, use `--no-mx`.

---

## License

MIT
