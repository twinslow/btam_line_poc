# BTAM on TK5 — what the assembler told us

> **A note on the excerpts.** Several blocks below are quoted directly from
> IBM macro source in `SYS1.MACLIB` — the `DFTRMLST` and `TWAIT` prototypes
> and fragments of their validation logic, and a few lines of a `READ`/`WRITE`
> expansion. They are reproduced only as evidence for the findings recorded
> here. **They are IBM's, not mine, and the MIT licence on this repository
> does not extend to them.** Each is marked where it appears. Everything
> else — the findings, tables, analysis and all code in this repository — is
> my own work.

Findings established by assembling probe decks on the real system (TK5RES,
`IFOX00` / Assembler F). These are facts about *this* BTAM level, not
recollections from a manual.

## BTAM is genned

`SYS1.MACLIB` on TK5RES contains the BTAM macros. `DFTRMLST` resolves,
and `DCB DSORG=CX` expands to a full 100-byte BTAM line-group DCB with a
BTAM INTERFACE section — `LERB`, `MODE`, `MAS,CODE`, 26 bytes of control
characters — not a stub.

Still unproven: that the BTAM *modules* are in the system libraries. Only
an `OPEN` of a `DSORG=CX` DCB settles that.

## DCB for a BSC line group

Accepted without complaint:

```
LINEDCB  DCB   DSORG=CX,MACRF=(R,W),DEVD=BS,DDNAME=BSCLINE,BFTEK=S,     X
               LERB=LERBLK
```

- `BFTEK=S` → `BL1'01000000'` at DCB+X'20'.
- `LERB=` is valid; generates `A(addr)` at DCB+X'34'.
- `CPRI=E` → **`IHB050 CPRI OPERAND INCONSISTENT-IGNORED`**. Presumably
  only meaningful alongside dynamic buffering (`BFTEK=D`). Drop it, or
  pair it with the right `BFTEK`.
- Omitting `EROPT` → **`IHB254 EROPT NOT SPECIFIED-PRESET TO C`**,
  generating `BL1'00001000'` at DCB+X'21'. Code it explicitly. Valid
  values not yet known.

Confirmed offsets (also validate the EXCP program's open test):

| Offset | Field |
| --- | --- |
| X'1A' | `DSORG` — `BL2'0001000000000000'` is CX |
| X'20' | BFTEK / BFLN / HIARCHY |
| X'21' | BTAM EROPT code |
| X'22' | BTAM buffer count |
| X'28' (40) | DDNAME |
| X'30' (48) | OFLGS — the byte `TM LINEDCB+48,X'10'` tests |
| X'34' | LERB |
| X'38' | MODE |
| X'39' | MAS, CODE |
| X'3A' | control characters, 26 bytes |

## READ / WRITE operand order — settled

My guess had area/length after the terminal list. It is the other way
round. Mapping the probe's operands to the fields the macro built:

```
         READ  DECB1,TI,LINEDCB,TLOPEN,AREA,80
                                 ^      ^    ^
                                 |      |    +-- landed in TERMINAL LIST
                                 |      +------- landed in LENGTH
                                 +-------------- landed in AREA ADDRESS
```

So the real format is:

```
         READ  decb,type,dcb,area,length,termlist,linenumber
         WRITE decb,type,dcb,area,length,termlist,linenumber
```

A seventh operand is required — omitting it gives
**`IHB001 LINE NUMBER OPERAND REQ'D-NOT SPECIFIED`**. That is the relative
line number within the line group.

### DECB layout the macro builds

`CNOP 0,4` then `BAL 1,*+44`, so the complete block is 40 bytes. The probe
aborted after 24, so the last 16 are still unmapped.

| Offset | Field |
| --- | --- |
| +0 | ECB |
| +4 | `BL1` flags |
| +5 | `AL1` type field |
| +6 | `AL2` length |
| +8 | DCB address |
| +12 | area address |
| +16 | error info field address |
| +20 | terminal list address |
| +24…+39 | not yet seen |

### Operation type codes — complete

Measured by assembling every candidate with `PRINT GEN` and reading the
type-field byte out of the expansion:

| Type | READ | WRITE |
| --- | --- | --- |
| `TI` | 1 | 2 |
| `TT` | 3 | 4 |
| `TV` | 5 | 6 |
| `TP` | 7 | — |
| `TS` | 9 | — |
| `TR` | — | 10 |
| `TQ` | 21 | — |
| `TC` | — | 28 |

**Trap: an unrecognised op type is accepted silently.** `WRITE TB` drew no
diagnostic at all and generated **type field 0**. There is no MNOTE to
catch a typo'd or wrong-for-this-line mnemonic — it assembles clean and
misbehaves at run time. Check the type byte in the expansion.

### DECB layout — complete

The earlier gap at +24 is filled:

| Offset | Field |
| --- | --- |
| +0 | ECB |
| +4 | flags (`BL1`) |
| +5 | type field |
| +6 | length (`AL2`) |
| +8 | DCB address |
| +12 | area address |
| +16 | error info field address |
| +20 | terminal list address |
| +24 | line number (`AL2`) |
| +26 | response field (`AL2`) |
| +28 | TP-op code (`AL1`) |
| +29 | error status (`AL1`) |
| +30 | CSW status (`AL2`) |
| +32 | current address list pointer |
| +36 | current address poll pointer |

40 bytes, matching the `BAL 1,*+44`.

### What the macro emits after the DECB

*The block below is excerpted from IBM macro source in `SYS1.MACLIB`. It is quoted as evidence, is not my work, and is not covered by this repository's MIT licence.*

```
         L     15,DCB+48          LOAD RDWRT ROUT ADDR
         NI    4(1),X'F7'
         BALR  14,15
```

Three things follow from this:

- BTAM's read/write routine address lives in the low three bytes of
  `DCB+48`. `DCBOFLGS` is the high byte there, ignored in 24-bit
  addressing — so `TM DCB+48,X'10'` remains a valid open test.
- The macro clears a flag in `DECB+4` but **does not clear the ECB**, so a
  reused DECB needs an explicit `XC DECB(4),DECB` before reissuing.
- The DECB is assembled data, not built at execution, so the area and
  length can be planted at `DECB+12` and `DECB+6` at run time.

## `DFTRMLST` — settled from the macro source

Prototype (reading through IEBPTPCH's column grouping):

*The block below is excerpted from IBM macro source in `SYS1.MACLIB`. It is quoted as evidence, is not my work, and is not covered by this repository's MIT licence.*

```
&NAME    DFTRMLST &TYPE,&PAR1,&PAR2,&PAR3,&PAR4,&PAR5,&PAR6,&PAR7
```

Positional: type first, then up to seven operands. The valid `&TYPE`
values, taken from the macro's own `AIF` chain:

`BSCLST` · `WTTALST` · `WTLIST` · `SWLST` · `IDLST` · `DIALST` ·
`OPENLST` · `WRAPLST` · `SSALST` · `SSAWLST` · `AUTOLST` · `AUTOWLST`

So `OPENLST` and `WRAPLST` *were* valid all along. The probe failed on
this line, near the top of the macro:

*The block below is excerpted from IBM macro source in `SYS1.MACLIB`. It is quoted as evidence, is not my work, and is not covered by this repository's MIT licence.*

```
         AIF   (N'&SYSLIST LT 2).ERR4
.ERR4    MNOTE 12,'*** IHB002 INVALID OPERAND SPECIFIED-&PAR1'
```

Fewer than two positional operands is an immediate `IHB002` — exactly the
message a bare `DFTRMLST` produces, which is why the negative result told
us nothing. (`ONETERM` genuinely is not a type.)

### What OPENLST builds

*The block below is excerpted from IBM macro source in `SYS1.MACLIB`. It is quoted as evidence, is not my work, and is not covered by this repository's MIT licence.*

```
.OPEN    AIF   ('&TYPE' NE 'OPENLST' AND '&TYPE' NE 'WRAPLST').SSA
&NAME    DS    0X
&SUM     SETA  N'&PAR1                 NUMBER OF ENTRIES
.LOOP    DC    X'&PAR1(&CTR)'          TERMINAL LIST ENTRY
         AIF   ('&CTR' EQ '&SUM').LAST
         DC    AL1(&ID)                PROCEDURE FLAGS
```

`&PAR1` is a **sublist**: `DFTRMLST OPENLST,(entry1,entry2,…)`. Each entry
is emitted as raw hex followed by a procedure-flag byte counting from 1;
the final entry's flag has X'80' added to mark end of list. So

```
TRMLST   DFTRMLST OPENLST,(0000)
```

generates `X'0000'` then `X'81'`.

## `TWAIT` — settled from the macro source

*The block below is excerpted from IBM macro source in `SYS1.MACLIB`. It is quoted as evidence, is not my work, and is not covered by this repository's MIT licence.*

```
&NAME    TWAIT &RREG,&TERMTST,ECBLIST=
```

- `&RREG` **must** be register notation `(r)` — checked for leading `(`
  and trailing `)`, else `IHB079`. The macro substitutes it straight into
  `LA &RREG,0(15)`, relying on the assembler evaluating `(2)` as an
  absolute expression.
- `&TERMTST` optional; if coded it must be the literal word `TERMTST`.
- `ECBLIST=` required, exactly one operand (`IHB080` otherwise). Takes a
  symbol or a register `(2)`–`(12)`.

The expansion walks the ECB list testing `TM 0(15),X'40'` for a completed
ECB and `TM 0(1),X'80'` for end of list, issuing a standard
`WAIT (0),ECBLIST=(1)` when nothing is ready. On completion it loads
`&RREG` with the completed ECB's address and returns the list byte-offset
in R15.

So the ECB list is the ordinary OS format — fullwords pointing at ECBs,
high-order bit set on the last entry:

```
WECBL    DC    X'80',AL3(WDECB)
```

Since a DECB's first word *is* its ECB, `WAIT ECB=WDECB` is an equally
valid way to wait on a single outstanding operation.

## `DEVD=` — `WT` assembles, but does not drive a `tele2` line

Eight candidates assembled with `DEVD=BS` as a control. Only one other was
accepted:

| `DEVD=` | Result |
| --- | --- |
| `BS` | accepted (control — binary synchronous) |
| **`WT`** | **accepted — World Trade Telegraph Adapter, the start-stop one** |
| `TT` `TW` `WU` `AT` `LT` `ST` | `IHB060 ... INVALID CODE FOR DEVD WITH DSORG=CX-IGNORED` |

`WT` is **World Trade Telegraph Adapter**, and that turns out to matter.
The probe proved only that the macro *accepts* the operand — it could not
prove the operand matches the emulated hardware, and it does not.

Run against Hercules `lnctl=tele2` at 0684, BTAM's OPEN for `DEVD=WT`
issues:

```
ccw 2F000000 60400001    DISABLE, command-chained
ccw 13000000 20400001    X'13'  -> stat 0E00, sense 80 = CMDREJ
```

Hercules command-rejects X'13'. OPEN still completes and sets `DCBOFLGS`,
but no channel activity follows for the first `WRITE` — the ECB is never
posted and `TWAIT` waits forever. `lnctl=tele2` emulates Terminal Control
Type II for a TWX/TTY, not a WTTA, so it has no X'13'.

For contrast, the working EXCP program `ASYPOC` uses only X'27', X'01',
X'06'+X'02' and X'2F', all of which commadpt implements.

**So BTAM cannot currently drive the async line.**

### `DEVD` has exactly three values, and none of them fits

The manual lists `BS`, `WT` and `LD`, and a sweep of terminal-type
mnemonics confirmed it — `TWX`, `WTTA`, `BSC`, `2741`, `2740`, `1050`,
`1030`, `1060`, `2260`, `2265`, `2848`, `83B3`, `115A`, `AUDIO`, `TTY`,
`TEL2`, `TELE2` and `IBM1` were all rejected with `IHB060`. `DEVD` names
the adapter category, not the terminal model.

| Value | Meaning | Fit for a Hercules `tele2` line |
| --- | --- | --- |
| `BS` | binary synchronous | wrong — not a BSC line |
| `WT` | World Trade Telegraph Adapter | the only start-stop one; OPEN issues X'13', which commadpt rejects |
| `LD` | locally attached | wrong — this is a remote 2703 line |

### `DEVD` is not optional

An invalid or absent `DEVD` does not fall back to a sane default. The
macro emits the LERB and then simply stops:

| | `DEVD=BS` | `DEVD` invalid |
| --- | --- | --- |
| device section | `ORG *+20` | 20 bytes of DASD interface |
| BTAM interface | LERB, MODE, MAS/CODE, 26 control chars, reserved | LERB, then nothing |
| DCB length | 100 bytes | 56 bytes |

A 56-byte DCB with no control-character table would let BTAM write past
the end of itself, so omitting `DEVD` is not a workaround.

### The full `DEVD` picture

Three DCBs expanded side by side settle it:

| DCB | device section | BTAM interface | length |
| --- | --- | --- | --- |
| no `DEVD` | `ORG *+20` | LERB only | 56 |
| `DEVD=WT` | `ORG *+16` | LERB only | 56 |
| `DEVD=LD` | `ORG *+20` | LERB only | 56 |
| `DEVD=BS` | `ORG *+20` | LERB, MODE, MAS/CODE, 26 control chars, reserved | 100 |
| invalid value | DASD interface (`FDAD,DVTBL`) | LERB only | 56 |

**A 56-byte DCB is normal.** An earlier note here warned that a truncated
interface would let BTAM write past the end of the DCB — that was wrong.
The full 100 bytes are exclusive to `DEVD=BS`, and only because the
26-byte table holds the *BSC* control characters. Line types without one
are legitimately short.

**Omitting `DEVD` is a recognised line group**, not a fallback: the macro
emits `ORG *+20` rather than the direct-access interface an invalid value
gets. It is also distinct from `WT`, which uses a 16-byte adapter section.

### The X'13' is unconditional — BTAM cannot open a commadpt line

Removing `DEVD` did **not** change the OPEN sequence. BTAM issues the same
two-CCW chain regardless:

```
ccw 2F000000 60400001    DISABLE, command-chained
ccw 13000000 20400001    X'13'  -> stat 0E00, sense 80 = CMDREJ
```

So X'13' is part of BTAM's line-group conditioning for `DSORG=CX` in
general, not something `WT` asked for. commadpt logs `CCW exec - entry
code 13` and falls through to its default, which sets command reject.

OPEN still completes and sets `DCBOFLGS`, so the program reports the line
open — but no channel program is ever started for the first `WRITE`. The
ECB is never posted and `TWAIT` waits forever. Nothing about the message
data (line endings, translation, op type) is reachable from here; the
failure is upstream of any data transfer.

**This predicts `BSCPOCB` fails identically on the BSC line**, since the
OPEN path is the same. Untested, and the cleanest way to confirm that the
problem is BTAM-versus-commadpt rather than anything async-specific.

### What X'13' is — and why this is a Hercules bug

From the 2703 component description: X'13' is one of a group of **standard
2702 commands that the 2703 accepts and treats as an I/O No-Op**, present
only so that channel programs written for a 2702 keep working. On the 2702
a SAD command selects the line adapter; a 2703 has no use for it and
swallows it.

BTAM issues one at OPEN because it supports both controllers. Real
hardware would accept and ignore it. commadpt has no case for it, falls to
its default, and answers command reject — so BTAM concludes the line
cannot be conditioned and never starts I/O.

That makes this an emulation gap rather than a BTAM or program problem:
commadpt rejects a command the device it emulates is documented to accept.

### The fix

Add the 2702-compatibility commands to commadpt's CCW dispatch as no-ops,
mirroring whatever the existing X'03' NOP case sets for `unitstat` and
`residual`. Cover the whole documented group, not only X'13' — BTAM
issues that one at OPEN, but others in the family may appear elsewhere in
the line handling and would fail identically.

This is worth reporting upstream to SDL Hyperion; the manual's wording is
explicit that these are accepted commands.

### Line endings are not the problem

CR+LF outbound and `eol=0D iskip=0A` inbound are proven correct on this
line by `ASYPOC`, which drives it successfully with exactly that pairing.

### Still open

- **Whether `TI` is the right op type for start-stop**, or whether it
  wants `TP` or `TS`. All are valid mnemonics; only running will say.
  Remember an unrecognised mnemonic assembles silently as type 0.
- **Where BTAM posts the received length** — narrowed to the response
  field at DECB+26 and the CSW status at DECB+30. `ASYPOCB` dumps the
  whole 40-byte DECB after each read.
- The BSC semantics questions above (`WRITE TI` doing the bid, STX/ETX
  framing) remain untested.
