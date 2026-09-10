# Log-Only Metadata (`log_data`)

## Overview

`log_data` is an opaque, free-form metadata string that an application can attach
to a message at submission time. It is intended purely for logging and
correlation purposes:

- It is written to **all access logs**: the smsbox submit log, the bearerbox
  `Sent SMS` / `Receive DLR` (and FAILED/REJECTED/EXPIRED) log lines.
- It is stored in DLR storage together with the delivery-report entry, so when
  the operator's DLR arrives (possibly hours later), the original metadata is
  restored and logged on the `Receive DLR` line.
- It is **never sent to the upstream operator SMSC**. No SMSC driver (SMPP,
  HTTP, EMI, ...) reads this field, so it cannot appear in any PDU or request
  sent to the operator.

This is different from the existing `meta-data` parameter: values placed in the
`?smpp?` group of `meta-data` are converted into SMPP TLVs and **are** sent to
the operator. Use `log_data` for anything that must stay internal (order IDs,
tenant IDs, campaign IDs, internal trace IDs, etc.).

The value is a single string. If you need multiple keys, encode them yourself
(for example `order=123;tenant=acme` or a compact JSON string). Avoid newlines,
since the value is printed into single-line access logs.

---

## Submitting with log_data

### 1. HTTP sendsms (smsbox), GET

Add the `log-data` CGI parameter (URL-encoded):

```text
http://smsbox:13013/cgi-bin/sendsms?username=tester&password=foobar
    &from=12345&to=919800000000&text=Hello
    &dlr-mask=31&dlr-url=http://myapp/dlr%3Ftype=%25d
    &log-data=order%3D123%3Btenant%3Dacme
```

### 2. HTTP sendsms (smsbox), POST

Send the metadata in the `X-Kannel-Log-Data` request header:

```text
POST /cgi-bin/sendsms HTTP/1.1
Host: smsbox:13013
Content-Type: text/plain
X-Kannel-From: 12345
X-Kannel-To: 919800000000
X-Kannel-DLR-Mask: 31
X-Kannel-DLR-Url: http://myapp/dlr?type=%d
X-Kannel-Log-Data: order=123;tenant=acme

Hello
```

For XML POST (`Content-Type: text/xml`), use the `log-data` element under
`/message/submit`:

```xml
<message>
  <submit>
    <from><number>12345</number></from>
    <to><number>919800000000</number></to>
    <log-data>order=123;tenant=acme</log-data>
  </submit>
</message>
```

### 3. SMPP submit via opensmppbox

The ESME sends the metadata as an optional TLV on `submit_sm`. Two pieces of
configuration are required.

First, define the TLV so opensmppbox can decode it (pick any tag from the
reserved/vendor range that your client uses):

```text
group = smpp-tlv
name = log_data
tag = 0x1600
type = octetstring
length = 256
smsc-id =
```

Then tell opensmppbox which TLV carries the log-only metadata:

```text
group = opensmppbox
opensmppbox-id = smppbox
...
log-data-tlv = log_data
```

At ingress, opensmppbox copies the TLV value into the message's `log_data`
field and **removes it from the SMPP meta-data group**, so it can never be
re-emitted as a TLV towards the operator SMSC.

TLVs other than the one named by `log-data-tlv` keep their normal behaviour
(forwarded to the operator via the `?smpp?` meta-data group).

### 4. SQL insert via sqlbox

Add a `log_data` column to your insert table (and log table, if you want it
recorded there). For existing installations:

```sql
ALTER TABLE send_sms ADD COLUMN log_data TEXT;
ALTER TABLE sent_sms ADD COLUMN log_data TEXT;
```

Then simply populate the column when inserting the outbound message:

```sql
INSERT INTO send_sms (momt, sender, receiver, msgdata, sms_type,
                      dlr_mask, dlr_url, log_data)
VALUES ('MT', '12345', '919800000000', 'Hello', 2,
        31, 'http://myapp/dlr?type=%d', 'order=123;tenant=acme');
```

Freshly created tables (auto-created by sqlbox) already contain the column.
The column must be present in all sqlbox drivers' tables (MySQL, PostgreSQL,
SQLite, SQLite3, Oracle, MSSQL, SDB); for the Redis sqlbox driver the value is
the JSON key `log_data`.

---

## DLR storage configuration

To have the metadata restored (and logged) when the operator DLR arrives, add
the optional `field-log-data` directive to your `dlr-db` group:

```text
group = dlr-db
id = mydlr
table = dlr
field-smsc = smsc
field-timestamp = ts
field-destination = destination
field-source = source
field-service = service
field-url = url
field-mask = mask
field-status = status
field-boxc-id = boxc
field-binfo = binfo
field-log-data = log_data
```

- **redis**: `log_data` becomes an extra field in the DLR hash. No schema
  change needed; entries written before the upgrade simply restore an empty
  value.
- **mysql / pgsql / oracle / mssql / sqlite3 / sdb / cassandra**: add the
  column first:

  ```sql
  ALTER TABLE dlr ADD COLUMN log_data VARCHAR(255) NULL;
  ```

- **internal** (in-memory) and **spool** (file-based): no configuration
  needed; the value is stored automatically.

If `field-log-data` is omitted, DB-backed DLR storage behaves exactly as
before and the `Receive DLR` log line will show an empty `LOGDATA`.

---

## Log output

### Bearerbox access log (default format)

The default bearerbox access-log line gains a `[LOGDATA:...]` token:

```text
2026-09-10 10:15:02 Sent SMS [SMSC:op1] [SVC:tester] [ACT:] [BINF:] [FID:8f3a01]
    [META:] [LOGDATA:order=123;tenant=acme] [from:12345] [to:919800000000]
    [flags:-1:0:-1:-1:31] [msg:5:Hello] [udh:0:]

2026-09-10 10:15:41 Receive DLR [SMSC:op1] [SVC:tester] [ACT:] [BINF:] [FID:8f3a01]
    [META:?smpp?] [LOGDATA:order=123;tenant=acme] [from:12345] [to:919800000000]
    [flags:-1:0:-1:-1:1] [msg:22:id:8f3a01 stat:DELIVRD] [udh:0:]
```

### Bearerbox custom access-log-format

A new escape `%E` expands to the message's `log_data`:

```text
group = core
...
access-log-format = "%t %l [SMSC:%i] [FID:%F] [LOGDATA:%E] [from:%p] [to:%P] [msg:%b]"
```

### smsbox access log

The submit lines include the metadata as well:

```text
2026-09-10 10:15:01 send-SMS request added - sender:tester:12345 ...
    request: 'Hello' [LOGDATA:order=123;tenant=acme]
```

---

## Upgrade and compatibility notes

- Adding the `log_data` field changes the inter-box wire protocol (smsbox,
  bearerbox, opensmppbox, sqlbox) and the on-disk message store format.
  **Rebuild and restart all boxes together**, and drain the bearerbox store
  (`store-file` / `store-dir`) before upgrading, or old queued messages will
  fail to unpack.
- DLR entries written by the old version have no stored metadata; their DLRs
  log an empty `LOGDATA`. New entries are unaffected.
- The parameter is entirely optional at every interface; messages submitted
  without it behave exactly as before.

## Privacy / non-leak guarantee

`log_data` is read only by logging code (`bb_alog.c`, smsbox access log), DLR
storage, and sqlbox's own tables. It is not referenced by any `gw/smsc/*`
driver, is not exported as an SMPP TLV, and is not substituted into HTTP SMSC
URLs. The only way it leaves the gateway is through your own log files and
databases.
