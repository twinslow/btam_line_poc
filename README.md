# Line I/O proofs of concept for MVS 3.8J

Four S/370 assembler programs (Assembler F / ASMF) that drive IBM 2703
communication lines under Hercules / SDL Hyperion, where each line is
mapped onto a TCP socket. Two lines — a BSC (bisync) line and an
asynchronous start-stop TTY line — each done twice, once with EXCP and
hand-built channel programs and once with BTAM.

Plus a Python partner for each line that speaks the other end of the
conversation and traces every byte in hex.

## The programs

| Source | Line | Access method | Status |
| --- | --- | --- | --- |
| [`src/BSCPOC.asm`](src/BSCPOC.asm) | BSC, 0090 | EXCP | **works** |
| [`src/ASYPOC.asm`](src/ASYPOC.asm) | async TTY, 0684 | EXCP | **works** |
| [`src/BSCPOCB.asm`](src/BSCPOCB.asm) | BSC, 0090 | BTAM | **works** |
| [`src/ASYPOCB.asm`](src/ASYPOCB.asm) | async TTY, 0684 | BTAM | **does not work** — see below |

**`BSCPOC`** — point-to-point contention BSC with no BTAM involved. It runs
the line discipline itself: bids for the line with ENQ, waits for ACK0,
sends one `STX … ETX` text block, waits for ACK1, sends EOT, then turns the
line around and receives a block the same way. All I/O is EXCP against a
hand-built IOB with one-CCW channel programs for Enable, Write, Read and
Disable — the same approach HASP/JES2 uses for its own BSC RJE lines.

**`ASYPOC`** — an interactive session on the start-stop line. It greets you,
prompts, reads a typed line, shows it in the job log as hex and text, echoes
it back, and ends on `BYE` or after ten turns. Async has no line discipline
to speak of, so what is left is `WRITE`, `PREPARE` chained into `READ`, and
the question of what code the bytes are in — see [bit-reversed
ASCII](#the-async-line-carries-bit-reversed-ascii).

**`BSCPOCB`** — the same conversation as `BSCPOC`, with BTAM running the
line discipline: `WRITE TI` to bid and send, `WRITE TR` for the EOT,
`READ TI` to take the partner's block, `READ TT` for their EOT. No CCWs and
no IOB. About a third shorter than the EXCP version.

**`ASYPOCB`** — the same conversation as `ASYPOC`, via BTAM `READ`/`WRITE`.

A run of `BSCPOCB` confirmed three things that were assumptions when it was
written: `WRITE TI` performs the whole bid itself (ENQ, ACK0, block, ACK1
— the partner saw all of it from that one macro); the message area carries
its own STX/ETX, because BTAM does not frame the block; and the `OPENLST`
entry is a placeholder that is never transmitted.

`ASYPOCB` assembles clean and opens the line, but cannot transmit — see the
next section.

## Why `ASYPOCB` does not work

It assembles clean and OPEN succeeds, but the first `WRITE` never starts any
I/O — no channel program appears in the Hercules trace, the ECB is never
posted, and `TWAIT` waits forever.

**BTAM itself is fine on this system.** `BSCPOCB` drives the BSC line at
0090 correctly, so this is something about the start-stop line rather than
about BTAM or about the macro coding.

What is observed: OPEN issues a two-CCW channel program and Hercules
command-rejects the second one.

```
ccw 2F000000 60400001    Disable, command-chained  -> stat 0C00, fine
ccw 13000000 20400001    X'13'                     -> stat 0E00, sense 80 = CMDREJ
```

X'13' is one of a group of standard 2702 commands that a real 2703 accepts
and treats as an I/O No-Op, present so channel programs written for a 2702
keep working. Hercules `commadpt.c` has no case for it — it logs `CCW exec
- entry code 13`, falls through to its default and rejects the command.

**This is not proven to be the cause.** `BSCPOCB` may well issue the same
X'13' at OPEN and survive it, in which case the rejection is a red herring
and the async failure is something else. Running `BSCPOCB` with the CCW
trace on and comparing its OPEN sequence would settle that, and is the
obvious next step.

Other candidates, not yet eliminated:

- **The op type.** `ASYPOCB` uses `TI` on both the `READ` and the `WRITE`.
  It is a valid mnemonic, but `TP` and `TS` also exist and start-stop may
  want one of those. Note an unrecognised mnemonic assembles silently as
  type 0, so any substitution needs checking against the type-code table in
  [docs/btam-notes.md](docs/btam-notes.md).
- **The DCB has no control-character table.** No `DEVD` value describes an
  ordinary remote start-stop line — the three available are `BS` (bisync),
  `WT` (World Trade Telegraph Adapter) and `LD` (locally attached). Only
  `DEVD=BS` generates the 26-byte control-character table, and that holds
  the BSC characters. It is possible this BTAM was genned without start-stop
  terminal support at all.

If the X'13' does turn out to be the blocker, the fix is on the Hercules
side: add the 2702-compatibility commands to commadpt's CCW dispatch as
no-ops, mirroring the existing X'03' NOP case. Not attempted here — no
Hercules build environment on this machine.

## The lines

Both are 2703s. The device address has to agree in three places: the
Hercules statement, the MVS I/O gen, and the DD card.

| | BSC | async TTY |
| --- | --- | --- |
| Address | 0090 | 0684 |
| Port | 3781 | 3782 |
| Config | [`hercules/bscline.conf`](hercules/bscline.conf) | [`hercules/ttyline.conf`](hercules/ttyline.conf) |
| DD name | `BSCLINE` | `TTYLINE` |

```bash
attach 0090 2703 lnctl=bsc dial=no lhost=192.168.1.168 lport=3781 rhost=192.168.1.168 rport=13781 rto=30000 pto=3000
```

```bash
attach 0684 2703 lnctl=tele2 dial=no lhost=192.168.1.168 lport=3782 rhost=192.168.1.168 rport=13782 term=tty eol=0D iskip=0A uctrans=yes rto=60000 pto=3000
```

**Hercules requires both the local and the remote host/port when
`dial=no`.** That reads backwards — `dial=no` suggests there is no remote
endpoint to name — but omit either pair and the attach will not work.

Check the device from the Hercules console with `devlist`, and from MVS
with `D U,,,090,1` or `D U,,,684,1`. If MVS does not know the address, no
amount of Hercules configuration will help; it needs to be in the I/O gen
as a 2703.

## Building and running

`make-deck.sh` concatenates the JCL skeletons and the assembler sources into
submit-ready card decks:

```bash
./make-deck.sh
```

| Deck | Runs |
| --- | --- |
| `jcl/BSCPOC.jcl` | assemble, link, go — BSC EXCP |
| `jcl/ASYPOC.jcl` | assemble, link, go — async EXCP |
| `jcl/BSCPOCB.jcl` | assemble, link, go — BSC BTAM |
| `jcl/ASYPOCB.jcl` | assemble, link, go — async BTAM |

Start the partner before or just after submitting; the GO step waits.

```bash
python tools/bscpartner.py --connect 192.168.1.168:3781
python tools/ttypartner.py --connect 192.168.1.168:3782
```

Both partners also run standalone against an in-process stand-in, no
mainframe needed, which is how their framing was checked:

```bash
python tools/bscpartner.py --selftest
python tools/ttypartner.py --selftest
```

## The BSC conversation

Point-to-point contention, no multipoint polling, no transparent mode, one
block each way:

```
   MVS / BSCPOC                        bscpartner.py
   ------------                        -------------
   ENQ                       ->                          bid for the line
                             <-        ACK0
   STX  HELLO FROM MVS  ETX  ->                          one text block
                             <-        ACK1
   EOT                       ->                          done sending
                             <-        ENQ               partner bids
   ACK0                      ->
                             <-        STX HELLO... ETX
   ACK1                      ->
                             <-        EOT
```

Each side waits for an acknowledgement before sending the next element, so
elements never coalesce into one TCP segment — which keeps the "one Read
CCW per frame" assumption in the assembler honest.

The block check character is generated by the adapter, so it is not in the
buffer handed to the channel; the partner discards up to two unrecognisable
bytes after a block in case the emulation puts one on the wire.

## The async line carries bit-reversed ASCII

This is the trap on the start-stop line, and it cost a run to find. A
start-stop line shifts each character out **low-order bit first**, so the
byte the 2703 wants in storage is the mirror image of the ASCII code.
Measured on the wire: `ASYPOC` wrote plain ASCII `A` = X'41' and the
terminal saw X'02' — X'41' reversed and masked to seven bits.

Inbound the same reversal applies, and the top bit of the character is an
even parity bit, which lands in bit 0 after reversal:

```
    wire 12  reverse -> 48  &7F -> 'H'   parity 0
    wire A3  reverse -> C5  &7F -> 'E'   parity 1
    wire B1  reverse -> 8D  &7F -> CR    parity 1
```

The translate tables in `ASYPOC` and `ASYPOCB` are generated from code page
037 and then bit reversed, so `EBC2ASC` holds `reverse(ascii)` and
`ASC2EBC` is indexed by the wire byte and masks the parity bit off. EBCDIC
CR X'0D' still goes out as the correct line code and arrives back as EBCDIC
X'0D', so line-end stripping is unaffected.

CR+LF outbound and `eol=0D iskip=0A` inbound are the proven pairing.

The `PARM.GO=` switch is a diagnostic: `'Y'` (default) applies the tables,
`'N'` passes bytes through untouched. Raw bytes are dumped under
`ASYPOC 900 RAW=` before any translation either way.

## Utility decks

Not part of the POCs — these established the BTAM facts, and are kept so the
findings can be re-derived rather than taken on trust.

| Deck | Question it answered |
| --- | --- |
| `jcl/BTAMSYN.jcl` | BTAM macro operand formats — `READ`/`WRITE` order, `TWAIT`, DECB layout |
| `jcl/BTAMMAC.jcl` | prints `DFTRMLST` and `TWAIT` source out of `SYS1.MACLIB` |
| `jcl/BTAMTTY.jcl` | start-stop `DEVD=` and the op-type codes |
| `jcl/BTAMDEV.jcl` | sweep of `DEVD=` terminal-type mnemonics — all rejected |
| `jcl/BTAMLD.jcl` | whether `DEVD=LD` generates a complete BTAM interface |
| `jcl/BTAMNOD.jcl` | whether omitting `DEVD` gives a recognised line group |

[docs/btam-notes.md](docs/btam-notes.md) records what each proved, and how.
Everything in there came from assembling on the real system or reading macro
source — none of it is from memory.

## Licence

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Tony Winslow.

### Third-party material

[docs/btam-notes.md](docs/btam-notes.md) quotes a small number of short
excerpts from IBM macro source in `SYS1.MACLIB` — the `DFTRMLST` and `TWAIT`
prototypes, fragments of their validation logic, and a few lines of a
`READ`/`WRITE` expansion — reproduced as evidence for the findings recorded
there. **Those excerpts are IBM's and the MIT licence does not extend to
them.** Each is marked where it appears, and the file carries a note at the
top saying so.

Everything else in this repository — the assembler programs, the JCL, the
Python partners, the Hercules configurations and all the analysis — is
original work and is covered by the licence.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| `BSCPOC 012` / `ASYPOC 012`, RC=12 | the DD card; is the address genned and online |
| Job hangs at `BSCPOC 020` / `ASYPOC 020` | nothing has connected to the socket yet |
| `900 I/O ERROR` then a hex dump | ECB code, sense 0-1, CSW status, residual — in that order |
| `BSCPOC 980` | the Read returned only pad/SYN; usually an `rto=` timeout |
| `BSCPOC 032` / `042` | partner answered, but not with ACK — the hex dump above shows what arrived |
| `ASYPOC 900 RAW=` shows nothing like your text | translation; try `PARM.GO='N'` and compare |
| `ASYPOCB` stops after `015 LINE GROUP IS OPEN` | unresolved — see above. `BSCPOCB` on the BSC line does work |
| Partner prints `expected X but got Y` | the two sides are out of step; restart both |
