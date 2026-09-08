#!/usr/bin/env python3
"""
fetchpartner.py - the remote partner for the MVS BSC file-fetch application.

Connects to a Hercules commadpt BSC line over TCP, waits for transmissions
from the MVS started task, and answers them:

    HEL  ->  DAT00Hello
    GET  ->  one DAT block per line of the file, then EOF00
             or ERR04 if the file is not there

Everything on the wire is EBCDIC (cp037) inside BSC framing.

    transmission := ENQ  block [block ...]  EOT
    block        := STX msgid(3) status(2) data(0..133) ETB|ETX

ETB marks a block with more to follow, ETX the last one. Acknowledgements
alternate: ACK0 answers the ENQ bid, then ACK1, ACK0, ACK1 ... for the
successive blocks.

Examples
--------
    python fetchpartner.py --host 192.168.1.168 --port 3781 \
           --listen 13781 --fdir ./files

Give it both ways in and it takes whichever connects first. Neither is
reliable alone: commadpt calls out when BTAM enables the line, but BTAM
does not always issue an ENABLE, so listening only can wait for ever; and
dialling in is refused while the line is not enabled, so dialling only
races the started task. --host/--port is lport on the attach, --listen is
rport.

It keeps running: if the line is not there yet, or goes away when the
started task closes it, it waits and picks it up again. Ctrl-C to stop.

    # no mainframe needed - drives both sides against each other
    python fetchpartner.py --selftest
"""

import argparse
import os
import socket
import sys
import threading
import time

# --- BSC control characters, EBCDIC ------------------------------------
STX = 0x02
ETX = 0x03
DLE = 0x10
ETB = 0x26
ENQ = 0x2D
SYN = 0x32
EOT = 0x37
NAK = 0x3D
LPAD = 0x55
TPAD = 0xFF

ACK0 = bytes([DLE, 0x70])
ACK1 = bytes([DLE, 0x61])

SYNC_BYTES = (SYN, LPAD, TPAD, 0x00)
FRAME_STARTERS = (SYN, LPAD, TPAD, 0x00, ENQ, EOT, NAK, DLE, STX)

# --- application protocol ----------------------------------------------
MSGID_LEN = 3
STATUS_LEN = 2
MAX_DATA = 133                     # a print line; longer input is truncated

POLL_SLICE = 0.5                   # keeps ctrl-C responsive, see _fill
RETRY_DELAY = 15.0                 # matches the started task's cycle time

ST_OK = "00"
ST_NOFILE = "04"
ST_BADCMD = "08"
ST_OTHER = "16"


class ProtocolError(Exception):
    pass


class Block:
    """One text block: a 3-character message id, a 2-digit status, data."""

    def __init__(self, msgid, status, data=""):
        self.msgid = msgid
        self.status = status
        self.data = data

    def to_bytes(self):
        text = "%-3.3s%-2.2s%s" % (self.msgid, self.status,
                                   self.data[:MAX_DATA])
        return text.encode("cp037", errors="replace")

    @classmethod
    def from_bytes(cls, raw):
        text = raw.decode("cp037", errors="replace")
        if len(text) < MSGID_LEN + STATUS_LEN:
            raise ProtocolError("short block: %r" % text)
        return cls(text[:MSGID_LEN],
                   text[MSGID_LEN:MSGID_LEN + STATUS_LEN],
                   text[MSGID_LEN + STATUS_LEN:])

    def __repr__(self):
        return "<%s%s %r>" % (self.msgid, self.status, self.data)


class BscLink:
    """BSC framing on a stream socket."""

    def __init__(self, sock, timeout=120.0, trace=True, idle_timeout=None):
        self.sock = sock
        self.timeout = timeout          # a stall mid-transmission is a fault
        self.idle_timeout = idle_timeout    # None = idle indefinitely
        self.trace = trace
        self.buf = bytearray()
        self.closed = False

    # -- tracing --------------------------------------------------------

    def _log(self, direction, data, note=""):
        if not self.trace or not data:
            return
        hexs = " ".join("%02X" % b for b in data[:24])
        if len(data) > 24:
            hexs += " ..."
        print("%s %-76s %s" % (direction, hexs, note),
              file=sys.stderr, flush=True)

    # -- raw i/o --------------------------------------------------------

    def _send(self, payload, note=""):
        frame = bytes([SYN, SYN]) + payload
        self._log("TX", frame, note)
        self.sock.sendall(frame)

    def _fill(self, deadline):
        """Wait for inbound bytes, in short slices.

        The wait is taken in POLL_SLICE chunks rather than one long
        recv. Python can only raise KeyboardInterrupt between bytecodes,
        so a single blocking recv with a two minute timeout makes ctrl-C
        appear to hang - which matters here because the started task
        leaves the line idle between cycles.
        """
        if self.closed:
            raise ProtocolError("the line was closed by the other end")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProtocolError("timed out waiting for the line")
            self.sock.settimeout(min(POLL_SLICE, remaining))
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue                   # slice expired, go round again
            except OSError as exc:
                self.closed = True
                raise ProtocolError("line error: %s" % exc)
            if not chunk:
                self.closed = True
                raise ProtocolError("the line was closed by the other end")
            self.buf.extend(chunk)
            return

    def _strip_sync(self):
        n = 0
        while n < len(self.buf) and self.buf[n] in SYNC_BYTES:
            n += 1
        del self.buf[:n]

    def _drop_bcc(self):
        """Discard up to two block-check bytes after a block.

        We cannot ask whether the emulation puts a BCC on the wire, so
        drop leading bytes that could not start a frame.
        """
        for _ in range(2):
            if self.buf and self.buf[0] not in FRAME_STARTERS:
                del self.buf[:1]
            else:
                break

    # -- element framing ------------------------------------------------

    def _parse(self):
        """Pull one BSC element out of the buffer, or None if incomplete.

        Returns ('ENQ'|'EOT'|'NAK'|'ACK0'|'ACK1'|'DLE?', None) or
        ('BLOCK', (raw_payload, terminator))."""
        self._strip_sync()
        if not self.buf:
            return None
        b0 = self.buf[0]

        if b0 == DLE:
            if len(self.buf) < 2:
                return None
            pair = bytes(self.buf[:2])
            del self.buf[:2]
            kind = {ACK0: "ACK0", ACK1: "ACK1"}.get(pair, "DLE?")
            return (kind, None)

        if b0 in (ENQ, EOT, NAK):
            del self.buf[:1]
            return ({ENQ: "ENQ", EOT: "EOT", NAK: "NAK"}[b0], None)

        if b0 == STX:
            for i in range(1, len(self.buf)):
                if self.buf[i] in (ETX, ETB):
                    payload = bytes(self.buf[1:i])
                    term = self.buf[i]
                    del self.buf[:i + 1]
                    self._drop_bcc()
                    return ("BLOCK", (payload, term))
            return None

        stray = self.buf[0]
        del self.buf[:1]
        return ("JUNK", stray)

    def recv_element(self, timeout=None):
        if timeout is None:
            timeout = self.timeout
        deadline = time.monotonic() + timeout
        while True:
            got = self._parse()
            if got is not None:
                kind, extra = got
                if kind == "BLOCK":
                    self._log("RX", bytes([STX]) + extra[0] + bytes([extra[1]]),
                              repr(Block.from_bytes(extra[0])))
                else:
                    self._log("RX", b"", "")
                    if self.trace:
                        print("RX %-76s <%s>" % ("", kind),
                              file=sys.stderr, flush=True)
                return kind, extra
            self._fill(deadline)

    # -- transmissions --------------------------------------------------

    def recv_transmission(self, timeout=None):
        """Take a full ENQ / blocks / EOT transmission, acknowledging.

        Waiting for the opening ENQ uses idle_timeout, which defaults to
        forever: being idle is normal, the started task only bids once a
        cycle. And the socket runs to commadpt, not to MVS, so it stays
        up even if the started task is cancelled or crashes - there is
        nothing to detect and nothing to reconnect.

        Everything after the bid uses the ordinary timeout, because a
        stall part way through a transmission is a real fault.
        """
        idle = self.idle_timeout
        if idle is None:
            idle = float("inf")
        kind, _ = self.recv_element(idle)
        while kind == "EOT":                       # stray EOT, keep waiting
            kind, _ = self.recv_element(idle)
        if kind != "ENQ":
            raise ProtocolError("expected ENQ to start a transmission, got %s"
                                % kind)
        self._send(ACK0, "ACK0 - bid accepted")

        blocks = []
        expect_ack1 = True
        while True:
            kind, extra = self.recv_element(timeout)
            if kind == "BLOCK":
                payload, term = extra
                blocks.append(Block.from_bytes(payload))
                self._send(ACK1 if expect_ack1 else ACK0,
                           "ACK1" if expect_ack1 else "ACK0")
                expect_ack1 = not expect_ack1
                continue
            if kind == "EOT":
                return blocks
            raise ProtocolError("unexpected %s inside a transmission" % kind)

    def send_transmission(self, blocks, timeout=None):
        """Bid for the line, send the blocks, end the transmission."""
        self._send(bytes([ENQ]), "ENQ - bid for the line")
        kind, _ = self.recv_element(timeout)
        if kind != "ACK0":
            raise ProtocolError("expected ACK0 to our bid, got %s" % kind)

        expect_ack1 = True
        for n, blk in enumerate(blocks):
            last = (n == len(blocks) - 1)
            term = ETX if last else ETB
            self._send(bytes([STX]) + blk.to_bytes() + bytes([term]),
                       "%r %s" % (blk, "ETX" if last else "ETB"))
            kind, _ = self.recv_element(timeout)
            want = "ACK1" if expect_ack1 else "ACK0"
            if kind != want:
                raise ProtocolError("expected %s for block %d, got %s"
                                    % (want, n + 1, kind))
            expect_ack1 = not expect_ack1

        self._send(bytes([EOT]), "EOT - end of transmission")


# --- command handling --------------------------------------------------

def safe_name(name):
    """A filename from the wire must not escape --fdir."""
    name = name.strip()
    if not name:
        return None
    if os.path.sep in name or "/" in name or "\\" in name:
        return None
    if name in (".", "..") or name.startswith("."):
        return None
    return name


def handle_hel(_blocks, _fdir):
    print("HEL received from MVS", file=sys.stderr, flush=True)
    return [Block("DAT", ST_OK, "Hello")]


def handle_get(blocks, fdir):
    raw = blocks[0].data.strip()
    name = safe_name(raw)
    if name is None:
        print("GET %r - rejected, not a plain file name" % raw,
              file=sys.stderr, flush=True)
        return [Block("ERR", ST_OTHER, "invalid file name %s" % raw[:100])]

    path = os.path.join(fdir, name)
    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError as exc:
        print("GET %s - open failed: %s" % (name, exc.strerror),
              file=sys.stderr, flush=True)
        return [Block("ERR", ST_NOFILE, "file %s not found" % name[:110])]

    print("GET %s - opened" % name, file=sys.stderr, flush=True)
    out = []
    truncated = 0
    with fh:
        for line in fh:
            line = line.rstrip("\r\n")
            if len(line) > MAX_DATA:
                truncated += 1
                line = line[:MAX_DATA]
            out.append(Block("DAT", ST_OK, line))
    out.append(Block("EOF", ST_OK))
    if truncated:
        print("GET %s - %d line(s) truncated to %d characters"
              % (name, truncated, MAX_DATA), file=sys.stderr, flush=True)
    print("GET %s - complete, %d line(s)" % (name, len(out) - 1),
          file=sys.stderr, flush=True)
    return out


HANDLERS = {"HEL": handle_hel, "GET": handle_get}


def serve(link, fdir):
    """One transmission in, one transmission out, forever."""
    while True:
        blocks = link.recv_transmission()
        if not blocks:
            print("empty transmission ignored", file=sys.stderr, flush=True)
            continue
        msgid = blocks[0].msgid
        handler = HANDLERS.get(msgid)
        if handler is None:
            print("unknown command %r" % msgid, file=sys.stderr, flush=True)
            reply = [Block("ERR", ST_BADCMD, "unknown command %s" % msgid)]
        else:
            reply = handler(blocks, fdir)
        link.send_transmission(reply)


# --- self test ---------------------------------------------------------

def selftest():
    import tempfile

    tmp = tempfile.mkdtemp(prefix="fetchpartner")
    with open(os.path.join(tmp, "REPORT.TXT"), "w") as fh:
        fh.write("FIRST LINE\nSECOND LINE\nTHIRD LINE\n")

    a, b = socket.socketpair()
    results = {}

    def partner():
        link = BscLink(a, timeout=10.0, trace=False)
        try:
            serve(link, tmp)
        except (ProtocolError, OSError) as exc:
            results["partner_ended"] = str(exc)

    thread = threading.Thread(target=partner, daemon=True)
    thread.start()

    mvs = BscLink(b, timeout=10.0, trace=True)

    def ask(block):
        mvs.send_transmission([block])
        return mvs.recv_transmission()

    try:
        results["hel"] = ask(Block("HEL", ST_OK))
        results["get_ok"] = ask(Block("GET", ST_OK, "REPORT.TXT"))
        results["get_missing"] = ask(Block("GET", ST_OK, "NOSUCH.TXT"))
        results["get_evil"] = ask(Block("GET", ST_OK, "../etc/passwd"))
        results["bad_cmd"] = ask(Block("XXX", ST_OK))
    except ProtocolError as exc:
        results["error"] = str(exc)

    a.close()
    b.close()

    def shape(key):
        return [(x.msgid, x.status, x.data) for x in results.get(key, [])]

    checks = [
        ("HEL answered", shape("hel") == [("DAT", "00", "Hello")]),
        ("GET returns 3 DAT + EOF",
         shape("get_ok") == [("DAT", "00", "FIRST LINE"),
                             ("DAT", "00", "SECOND LINE"),
                             ("DAT", "00", "THIRD LINE"),
                             ("EOF", "00", "")]),
        ("missing file -> ERR04",
         [x[:2] for x in shape("get_missing")] == [("ERR", "04")]),
        ("path traversal refused",
         [x[:2] for x in shape("get_evil")] == [("ERR", "16")]),
        ("unknown command -> ERR08",
         [x[:2] for x in shape("bad_cmd")] == [("ERR", "08")]),
        ("no protocol errors", "error" not in results),
    ]
    print()
    ok = True
    for name, passed in checks:
        print("  %-28s %s" % (name, "ok" if passed else "FAIL"))
        ok = ok and passed
    print("\nselftest: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# --- plumbing ----------------------------------------------------------

def nap(seconds):
    """Sleep, in short slices, so ctrl-C is noticed promptly."""
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(POLL_SLICE, remaining))


def make_acceptor(port):
    """Listen for Hercules to call us.

    commadpt places an outgoing call when BTAM issues the ENABLE at OPEN
    time, using the rhost/rport on the attach. Listening here means the
    connection is established by the act of opening the line, rather than
    depending on the partner having dialled in first - which is the race
    that leaves the started task bidding into a line with no peer.
    """
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("", int(port)))
    srv.listen(1)
    print("listening on port %s for Hercules to call in" % port,
          file=sys.stderr, flush=True)
    return srv


def establish(srv, host, port, delay):
    """Get a connection to the line, whichever way it arrives first.

    Two things can create it and neither is reliable on its own:

      * commadpt places an outgoing call when BTAM issues the ENABLE at
        OPEN time - but BTAM does not always issue an ENABLE, so waiting
        only to be called can wait for ever.
      * dialling in to lport works, but is refused when the line is not
        enabled, so dialling only is a race against the started task.

    So do both at once: poll the listener and retry the dial, and take
    whichever comes good. Both are polled in short slices, which keeps
    ctrl-C responsive.
    """
    waiting = False
    while True:
        # has Hercules called us?
        if srv is not None:
            srv.settimeout(POLL_SLICE)
            try:
                sock, peer = srv.accept()
            except socket.timeout:
                pass
            except OSError as exc:
                print("listener error: %s" % exc, file=sys.stderr,
                      flush=True)
            else:
                sock.settimeout(None)
                print("call in from %s:%s" % peer, file=sys.stderr,
                      flush=True)
                return sock

        # can we call Hercules?
        if host and port:
            try:
                sock = socket.create_connection((host, port), timeout=2)
            except OSError:
                pass                       # refused or unreachable, fine
            else:
                sock.settimeout(None)
                print("dialled out to %s:%s" % (host, port),
                      file=sys.stderr, flush=True)
                return sock

        if not waiting:
            how = []
            if srv is not None:
                how.append("listening")
            if host and port:
                how.append("dialling %s:%s" % (host, port))
            print("waiting for the line - %s" % " and ".join(how),
                  file=sys.stderr, flush=True)
            waiting = True

        if srv is None:
            nap(delay)          # nothing to poll, so pace the dialling


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", help="host or IP of the Hercules BSC line")
    ap.add_argument("--port", type=int, help="TCP port of the BSC line")
    ap.add_argument("--listen", type=int, metavar="PORT",
                    help="also accept a call from Hercules on this port. "
                         "Use the rport from the attach command; commadpt "
                         "calls out when BTAM enables the line. Best given "
                         "alongside --host/--port so either route works")
    ap.add_argument("--fdir", default=".",
                    help="directory holding the files MVS may GET")
    ap.add_argument("--retry-delay", type=float, default=RETRY_DELAY,
                    metavar="SECONDS",
                    help="wait this long before retrying a failed or lost "
                         "connection (default %g, matching the started "
                         "task)" % RETRY_DELAY)
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="seconds to wait for an element part way through "
                         "a transmission, where a stall is a real fault "
                         "(default 120)")
    ap.add_argument("--idle-timeout", type=float, default=None,
                    metavar="SECONDS",
                    help="give up and reconnect after this long with no "
                         "transmission at all. Off by default: the socket "
                         "runs to Hercules, not to MVS, so it stays up even "
                         "if the started task stops, and waiting quietly is "
                         "the right thing to do")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the hex trace")
    ap.add_argument("--selftest", action="store_true",
                    help="drive both sides locally, no mainframe needed")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if not args.listen and not (args.host and args.port):
        ap.error("give --listen and/or --host with --port "
                 "(or use --selftest). Giving all three is best: it "
                 "takes whichever connection comes good first")
    if not os.path.isdir(args.fdir):
        ap.error("--fdir %s is not a directory" % args.fdir)

    print("serving files from %s" % os.path.abspath(args.fdir),
          file=sys.stderr, flush=True)
    srv = make_acceptor(args.listen) if args.listen else None
    try:
        while True:
            sock = establish(srv, args.host, args.port, args.retry_delay)
            link = BscLink(sock, timeout=args.timeout,
                           trace=not args.quiet,
                           idle_timeout=args.idle_timeout)
            try:
                serve(link, args.fdir)
            except ProtocolError as exc:
                print("line ended: %s" % exc, file=sys.stderr, flush=True)
            finally:
                try:
                    sock.close()
                except OSError:
                    pass
    except KeyboardInterrupt:
        print(file=sys.stderr)
        print("interrupted - closing the line", file=sys.stderr)
        return 0
    finally:
        if srv is not None:
            try:
                srv.close()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
