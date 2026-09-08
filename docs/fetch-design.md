# BSC file-fetch application — design and staging

An MVS started task reads a VSAM control file, fetches the named files from
a remote partner over a BSC line, and prints each one to JES2.

```
   VSAM KSDS                MVS STC                 Linux partner
   control file    <----->  BSCFTCH    <--BSC-->    fetchpartner.py
                              |
                              +--> DYNALLOC SYSOUT --> JES2 class A
```

## Status

| Component | State |
| --- | --- |
| `tools/fetchpartner.py` | **written and self-tested** |
| `jcl/DEFCTL.jcl` — define + load the KSDS | **blocked** — the catalog owns no suitable volume |
| `jcl/VSAMCHK.jcl` — which volumes does the catalog own | **written**, run this first |
| `jcl/DEFSPACE.jcl` — give the catalog a volume + data space | **written**, only if VSAMCHK shows none |
| `jcl/APPPROBE.jcl` — macro availability probe | **run** — VSAM, DYNALLOC and the command interface are all available |
| `jcl/COMMAC.jcl` — `IEZCOM`/`IEZCIB` expansion | **run** — layout confirmed |
| `src/BSCFTCH.asm` — the started task | **stage 1 running reliably**; stage 2 written, not yet assembled |

## The control file

KSDS, key 30 bytes at offset 0, record 60 bytes.

| Offset | Length | Field |
| --- | --- | --- |
| 0 | 30 | file id — the name requested from the partner |
| 30 | 1 | status: `I` in progress, `C` complete, `D` logically deleted |
| 31 | 29 | reserved |

Only `I` records are processed. A record becomes `C` after its file has
been successfully written to SYSOUT.

## Line protocol

Non-switched point-to-point BSC. A transmission is:

```
transmission := ENQ  block [block ...]  EOT
block        := STX msgid(3) status(2) data(0..133) ETB|ETX
```

`ETB` terminates a block with more to follow, `ETX` the last block of the
transmission. Acknowledgements alternate — `ACK0` answers the `ENQ` bid,
then `ACK1`, `ACK0`, `ACK1` … for successive blocks.

Everything is EBCDIC. `BSCPOCB` established that BTAM does **not** frame
the block, so the message area carries its own STX/ETX.

### Message ids

| Id | Direction | Meaning |
| --- | --- | --- |
| `HEL` | MVS → partner | hello / are you there |
| `GET` | MVS → partner | fetch the file named in the data area |
| `DAT` | partner → MVS | one line of file data (or the hello reply) |
| `EOF` | partner → MVS | the `GET` is complete |
| `ERR` | partner → MVS | the command failed |

### Status codes

| Code | Meaning |
| --- | --- |
| `00` | no error |
| `04` | the file does not exist |
| `08` | invalid command; more in the data area |
| `16` | other error; more may be in the data area |

### Exchanges

```
MVS  ENQ  STX HEL00                    ETX  EOT
part ENQ  STX DAT00Hello               ETX  EOT

MVS  ENQ  STX GET00REPORT.TXT          ETX  EOT
part ENQ  STX DAT00FIRST LINE          ETB
          STX DAT00SECOND LINE         ETB
          STX EOF00                    ETX  EOT

part ENQ  STX ERR04file X.Y not found  ETX  EOT
```

Data is capped at 133 characters — a print line. The partner truncates
longer input lines and says so on stderr.

## The started task

```
  handle MVS STOP via the command interface (EXTRACT / QEDIT)
  loop until stopped:
      open the BSC line
      send HEL, expect DAT00
      if the partner answered:  run the process loop
      close the line
      wait 15 seconds
```

Process loop:

```
  open the VSAM control file
  for each record:
      if status is not 'I': skip
      allocate a temporary PS dataset          (DYNALLOC)
      send GET <key>
      receive DAT blocks, writing each to the temp dataset,
          until EOF (success) or ERR (abandon this record)
      on EOF:  reopen the temp dataset for input,
               allocate SYSOUT class A         (DYNALLOC)
               copy the data across, close and free
               update the control record to 'C'
  close the control file
```

## Staging

The reason this is staged rather than written in one pass: the STC needs
three subsystems this project has never touched — VSAM, dynamic allocation
and the command interface — on top of BTAM, which is verified. Writing all
of it before knowing whether those macros even exist here would produce
failures in several places at once.

**Stage 0 — probe. Done.** `jcl/APPPROBE.jcl` asked whether `ACB`, `RPL`,
`GET RPL=`, `PUT RPL=`, `SHOWCB`, `MODCB`, `TESTCB`, `GENCB`, `DYNALLOC`,
`EXTRACT`, `QEDIT`, `STIMER` and the mapping macros `IEFZB4D0`,
`IEFZB4D2`, `IEZCOM`, `IEZCIB` resolve, and what shape their operands are.
All of them are present; only `QEDIT`'s `ORIGIN=` operand needed
correcting. See Gotchas below.

**Stage 1 — the shell. Done.** Started task that runs, answers an MVS `STOP`,
opens the BSC line, exchanges `HEL`/`DAT00` with the partner, and loops on
the 15-second retry. Needs: BTAM (verified), `EXTRACT`/`QEDIT`, `STIMER`.
Testable on its own against `fetchpartner.py`.

**Stage 2 — the control file. Written.** VSAM open, sequential browse with
`OPTCD=(KEY,SEQ,UPD)`, and `PUT` to mark a record `C`. It also runs the
full `GET` conversation — multi-block `DAT` replies via `READ TT`, ending
on `EOF` or `ERR` — but counts and discards the data rather than writing
it anywhere. That leaves only the dataset plumbing for stage 3.

**Stage 3 — the data path.** Add `DYNALLOC` for the temp dataset and the
SYSOUT dataset, the QSAM writes and the copy to JES2.

**Stage 4 — integration and the error paths**: `ERR` responses, partner
absent, line failures mid-transfer, restart behaviour.

Each stage is independently runnable, which matters because the only way
anything has been confirmed in this project is by running it.

## Running the partner: give it both routes

```
python tools/fetchpartner.py --host 192.168.1.168 --port 3781        --listen 13781 --fdir ./files
```

`--host`/`--port` is **lport** on the attach; `--listen` is **rport**. The
partner polls both and takes whichever connects first.

**Neither route works reliably on its own.** commadpt places an outgoing
call when BTAM issues the ENABLE at OPEN time — seen in a Hercules trace:

```
COMM: CCW exec - entry code 27          ENABLE
HHC01005W outgoing call failed during ENABLE command:
          ... the target machine actively refused it.
```

but **BTAM does not always issue an ENABLE**, so listening alone can wait
indefinitely. Conversely a dial-in is refused while the line is not
enabled, so dialling alone races the started task. Doing both removes the
race in either direction.

### Why this only started biting at stage 2

The ENABLE behaviour has always been there, so it is not what changed.
What changed is **how long the line is held open**.

Stage 1 opened the line, exchanged `HEL`/`DAT00` and closed — a fraction of
a second, then shut for 15 seconds. A partner restart almost always landed
while the line was closed, and the next open started clean.

Stage 2 holds the line open across the whole process loop: the VSAM open,
the browse, a `GET` per `I` record, the VSAM close. A disconnect is now far
more likely to land while the line is open, which is what leaves commadpt
in the state where the following write never completes.

Confirmed by experiment: with every control record set to `C` the process
loop finds nothing to do, the line is held open about as briefly as at
stage 1, and the hang could not be reproduced.

## Waiting on BTAM: `IOWAIT`, not `TWAIT`

`TWAIT` is a thin BTAM wrapper over the ordinary MVS `WAIT` — it scans an
ECB list and tells you which entry completed. Like `WAIT`, it has **no
timeout**, and there is a state this line reaches where waiting is
hopeless: if the ENABLE fails during OPEN, `DCBOFLGS` is still set, but
BTAM then accepts the `WRITE` and **never starts a channel program**. The
Hercules trace shows no CCW at all after the OPEN. Nothing will ever post
that ECB, so the task waits until the job wait limit and only CANCEL
recovers it.

`IOWAIT` (ours, not a macro) waits on the operation ECB *and* a timer ECB
together, using `STIMER REAL` with a small exit that posts the timer. If
the timer wins, the cycle is abandoned, the line closed, and the next
cycle starts fresh — which is what lets it recover unattended once the
partner returns.

Two limits, because they are different kinds of wait:

| Entry | Limit | Used for |
| --- | --- | --- |
| `IOWAITS` | 5s | bids — `WRITE TI`, `WRITE TR`. Quick on a healthy line, so a dead line is found fast |
| `IOWAIT` | 30s | receives — the partner has to open a file and start sending |

`TIMEXIT` runs asynchronously under an **IRB** (Interruption Request
Block), queued on the TCB ahead of the program's PRB. It does not inherit
the program's base registers, so it builds its own from R15 and picks the
ECB address out of a constant sitting immediately behind it.

### Detecting the failed ENABLE — not possible from the LERB

There is no DCB bit for it: the ENABLE failure is a device error handled
by ERP, not an OPEN failure, so OPEN legitimately reports success. The
LERB was the remaining candidate, and it was tried and ruled out.

Two consecutive cycles were logged with **byte-for-byte identical** LERBs
at OPEN time — one then failed on the bid, the other succeeded:

```
12.59.04  024 LINE GROUP IS OPEN      <- cycle failed, 940 five seconds later
          HEX=0000000000000000000009000900000000000000000000
12.59.25  024 LINE GROUP IS OPEN      <- cycle succeeded
          HEX=0000000000000000000009000900000000000000000000
```

The reason is visible in the rest of the log. Byte 10 went
`09 -> 09 -> 0D -> 11`, rising by four on each *successful* cycle — the
four BTAM operations a good cycle performs. Byte 12 stopped at `09` after
the first failure. These are **cumulative statistics counters**, the same
family as `TRANS/DC/IR/TO` in the `IEC801I` threshold messages, and being
read at OPEN they describe the *previous* cycle.

So the bid timeout in `IOWAITS` is the detection mechanism, and the only
thing left of the LERB diagnostic is `CHKLERB`, which is silent unless the
fence has been overwritten. Observed usage is about 13 bytes, so 64 is
ample.

**The LERB length was a guess** — originally 16 bytes, with the hello
block immediately behind it, so an oversized LERB would have corrupted the
message being transmitted. It is now 64 bytes followed by a `*LERBEND*`
fence. The real length is in GC27-6980.

## Gotchas found on this system

- **`IEZCOM` and `IEZCIB` live in `SYS1.AMODGEN`**, not `SYS1.MACLIB`.
  The assembly needs both on SYSLIB.
- **Neither macro generates a DSECT.** `IEZCOM` emits `COMLIST EQU *`
  followed by bare `DS` statements, and `IEZCIB` says so in its own
  comments: *"A DSECT CARD SHOULD PRECEDE MACRO CALL. USING ON CIBNEXT
  GIVES ADDRESSABILITY FOR ALL SYMBOLS."* Supply your own DSECT card, or
  the fields land in whatever location counter is current — they resolve
  cleanly and address the wrong storage.
- **`QEDIT ORIGIN=` must not be register 1.** The macro builds its own
  parameter list there. A symbol or another register is fine.
- Verified layout: `COMAREA` +0 `COMECBPT`, +4 `COMCIBPT`.
  `CIBAREA` +0 `CIBNEXT`, +4 `CIBVERB`, +5 `CIBLEN`, +14 `CIBDATLN`,
  +16 `CIBDATA`. Verbs `CIBSTART` X'04', `CIBMODFY` X'44',
  `CIBSTOP` X'40', `CIBMOUNT` X'0C'.

## VSAM on MVS 3.8 — catalogs own volumes

`DEFINE CLUSTER` failed with `IDC3033I VOLUME RECORD NOT FOUND IN CATALOG`,
VSAM catalog return code 248.

This release uses **VSAM catalogs**, not the ICF catalogs of later systems.
A catalog has to *own* a volume before anything can be cataloged there, and
ownership is a volume record created by `DEFINE SPACE`. Clusters are then
suballocated out of a VSAM data space on that owned volume. It is not a
shortage of DASD space — it is that no catalog knows about the volume.

Order of work:

1. `jcl/VSAMCHK.jcl` — `LISTCAT SPACE ALL` shows which volumes the catalog
   owns and what data spaces are on them. If one has room, just point
   `DEFCTL` at it.
2. `jcl/DEFSPACE.jcl` — otherwise, `DEFINE SPACE` claims a volume and puts
   a data space on it. Needs a DD card for the volume, tied to the command
   by `FILE()`.
3. `jcl/DEFCTL.jcl` — define and load the cluster.

## Decisions made where the spec was ambiguous

- The spec glosses `HEL` as "command sent from MVS started task to fetch
  file data", which is `GET`'s description. Treated `HEL` as the hello,
  per the partner-behaviour section.
- Multi-block replies use `ETB` on every block but the last, which gets
  `ETX`. The spec allows either without saying when.
- A `GET` whose data area is not a plain filename — anything containing a
  path separator, or starting with a dot — is refused with `ERR16` rather
  than being opened. `--fdir` is meant to bound what the partner will
  serve, and without this it does not.
- The temp dataset is allocated per record and freed after printing, so a
  failure part-way through one file cannot contaminate the next.
