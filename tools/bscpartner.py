#!/usr/bin/env python3
"""
bscpartner.py - a minimal BSC (bisync) point-to-point partner that talks
to the MVS 3.8J program BSCPOC through a Hercules 2703 line mapped onto
a TCP socket.

It speaks the same tiny subset of BSC that BSCPOC does:

    bidder                receiver
    ------                --------
    ENQ            ->
                   <-     ACK0
    STX text ETX   ->
                   <-     ACK1
    EOT            ->

By default this program plays the RESPONDER: it first lets the mainframe
bid and send a block, then bids itself and sends a block back.  That is
the exact mirror image of what BSCPOC does.

Everything on the wire is EBCDIC (cp037).

Examples
--------
    # Hercules is listening (lport=3781 in the device statement)
    python bscpartner.py --connect 127.0.0.1:3781

    # Hercules dials out to us instead (rhost=/rport= in the statement)
    python bscpartner.py --listen 3781

    # No mainframe needed - prove the framing works, locally
    python bscpartner.py --selftest
"""

import argparse
import socket
import sys
import threading
import time

# --- BSC control characters, EBCDIC -----------------------------------
SOH = 0x01
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
WACK = bytes([DLE, 0x6B])
RVI = bytes([DLE, 0x7C])

POLL_SLICE = 0.5                   # keeps ctrl-C responsive, see _fill

SYNC_BYTES = (SYN, LPAD, TPAD, 0x00)

# Bytes that may legitimately start a frame.  Used to shake off the
# trailing block check characters, which the adapter may or may not put
# on the wire depending on the emulation.
FRAME_STARTERS = (SYN, LPAD, TPAD, 0x00, ENQ, EOT, NAK, DLE, STX, SOH)


class BscError(Exception):
    pass


class BscTimeout(BscError):
    pass


class Frame:
    """One decoded BSC element."""

    def __init__(self, kind, text=b"", raw=b""):
        self.kind = kind          # ENQ EOT NAK ACK0 ACK1 WACK RVI TEXT ?
        self.text = text          # payload, for TEXT frames
        self.raw = raw

    def __repr__(self):
        if self.kind == "TEXT":
            return "<TEXT %r>" % (self.text.decode("cp037"),)
        return "<%s>" % self.kind


class BscLine:
    """A BSC endpoint riding on a stream socket."""

    def __init__(self, sock, timeout=60.0, trace=True):
        self.sock = sock
        self.timeout = timeout
        self.trace = trace
        self.buf = bytearray()

    # -- low level -----------------------------------------------------

    def _log(self, direction, data, note=""):
        if not self.trace:
            return
        hexs = " ".join("%02X" % b for b in data[:32])
        if len(data) > 32:
            hexs += " ..."
        print("%s %-52s %s" % (direction, hexs, note), flush=True)

    def _send(self, payload, note=""):
        frame = bytes([SYN, SYN]) + payload
        self._log("TX", frame, note)
        self.sock.sendall(frame)

    def _fill(self, deadline):
        """Wait for inbound bytes, in short slices so ctrl-C still works.

        Python raises KeyboardInterrupt only between bytecodes, so one
        long blocking recv swallows the interrupt until it expires.
        """
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BscTimeout("timed out waiting for the line")
            self.sock.settimeout(min(POLL_SLICE, remaining))
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                raise BscError("the line was closed by the other end")
            self.buf.extend(chunk)
            return

    def _strip_sync(self):
        n = 0
        while n < len(self.buf) and self.buf[n] in SYNC_BYTES:
            n += 1
        del self.buf[:n]

    def _drop_bcc(self):
        """Discard up to two trailing block check bytes after a block.

        We cannot ask whether the emulation put a BCC on the wire, so we
        drop leading bytes that could not possibly start a frame.  A CRC
        byte that happens to collide with a control character is the one
        case this heuristic gets wrong.
        """
        for _ in range(2):
            if self.buf and self.buf[0] not in FRAME_STARTERS:
                del self.buf[:1]
            else:
                break

    # -- framing -------------------------------------------------------

    def _parse(self):
        """Pull one frame out of self.buf, or return None if incomplete."""
        self._strip_sync()
        if not self.buf:
            return None
        b0 = self.buf[0]

        if b0 == DLE:
            if len(self.buf) < 2:
                return None
            pair = bytes(self.buf[:2])
            del self.buf[:2]
            kind = {ACK0: "ACK0", ACK1: "ACK1",
                    WACK: "WACK", RVI: "RVI"}.get(pair, "DLE?")
            return Frame(kind, raw=pair)

        if b0 in (ENQ, EOT, NAK):
            del self.buf[:1]
            return Frame({ENQ: "ENQ", EOT: "EOT", NAK: "NAK"}[b0],
                         raw=bytes([b0]))

        if b0 in (STX, SOH):
            for i in range(1, len(self.buf)):
                if self.buf[i] in (ETX, ETB):
                    body = bytes(self.buf[1:i])
                    raw = bytes(self.buf[:i + 1])
                    del self.buf[:i + 1]
                    self._drop_bcc()
                    return Frame("TEXT", text=body, raw=raw)
            return None                      # terminator not here yet

        # Something we do not understand - throw the byte away so we do
        # not wedge, and say so.
        stray = self.buf[0]
        del self.buf[:1]
        return Frame("?", raw=bytes([stray]))

    def recv_frame(self, expect=None, timeout=None):
        deadline = time.monotonic() + (timeout or self.timeout)
        while True:
            frame = self._parse()
            if frame is not None:
                self._log("RX", frame.raw, repr(frame))
                if expect and frame.kind != expect:
                    raise BscError("expected %s but got %r" % (expect, frame))
                return frame
            self._fill(deadline)

    # -- protocol elements ---------------------------------------------

    def send_enq(self):
        self._send(bytes([ENQ]), "ENQ - bid for the line")

    def send_eot(self):
        self._send(bytes([EOT]), "EOT - end of transmission")

    def send_ack0(self):
        self._send(ACK0, "ACK0")

    def send_ack1(self):
        self._send(ACK1, "ACK1")

    def send_nak(self):
        self._send(bytes([NAK]), "NAK")

    def send_text(self, text):
        data = text.encode("cp037") if isinstance(text, str) else text
        self._send(bytes([STX]) + data + bytes([ETX]), "STX text ETX")

    # -- the two halves of a conversation ------------------------------

    def transmit(self, text):
        """Bid for the line, send one block, end the transmission."""
        self.send_enq()
        self.recv_frame(expect="ACK0")
        self.send_text(text)
        self.recv_frame(expect="ACK1")
        self.send_eot()

    def receive(self):
        """Let the other end bid, take one block, acknowledge it."""
        self.recv_frame(expect="ENQ")
        self.send_ack0()
        frame = self.recv_frame(expect="TEXT")
        self.send_ack1()
        self.recv_frame(expect="EOT")
        return frame.text.decode("cp037")


def converse(line, role, text):
    if role == "responder":
        got = line.receive()
        print("\n*** received from the mainframe: %r\n" % got, flush=True)
        line.transmit(text)
    else:
        line.transmit(text)
        got = line.receive()
        print("\n*** received from the mainframe: %r\n" % got, flush=True)
    return got


# --- plumbing ---------------------------------------------------------

def open_connect(target):
    host, _, port = target.rpartition(":")
    sock = socket.create_connection((host or "127.0.0.1", int(port)))
    print("connected to %s:%s" % (host or "127.0.0.1", port), flush=True)
    return sock


def open_listen(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("", int(port)))
    srv.listen(1)
    print("listening on port %s ..." % port, flush=True)
    sock, peer = srv.accept()
    srv.close()
    print("connection from %s:%s" % peer, flush=True)
    return sock


def selftest():
    """Run a responder and an initiator against each other in process."""
    a, b = socket.socketpair()
    results = {}

    def responder():
        try:
            line = BscLine(a, timeout=10.0, trace=False)
            results["mainframe_side"] = converse(
                line, "responder", "HELLO FROM THE TCP PARTNER")
        except Exception as exc:               # noqa: BLE001
            results["error_a"] = exc

    thread = threading.Thread(target=responder)
    thread.start()
    try:
        line = BscLine(b, timeout=10.0, trace=True)
        results["partner_side"] = converse(
            line, "initiator", "HELLO FROM MVS 3.8J - BSCPOC BLOCK 001")
    except Exception as exc:                   # noqa: BLE001
        results["error_b"] = exc
    thread.join(15)
    a.close()
    b.close()

    ok = (results.get("mainframe_side") == "HELLO FROM MVS 3.8J - BSCPOC"
          " BLOCK 001"
          and results.get("partner_side") == "HELLO FROM THE TCP PARTNER"
          and "error_a" not in results and "error_b" not in results)
    print("\nselftest results: %r" % (results,))
    print("selftest: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    grp = ap.add_mutually_exclusive_group()
    grp.add_argument("--connect", metavar="HOST:PORT",
                     help="connect to a Hercules line that is listening")
    grp.add_argument("--listen", metavar="PORT",
                     help="listen for a Hercules line that dials out")
    grp.add_argument("--selftest", action="store_true",
                     help="exercise the framing locally, no mainframe")
    ap.add_argument("--role", choices=("responder", "initiator"),
                    default="responder",
                    help="responder (default) mirrors BSCPOC: receive "
                         "first, then transmit")
    ap.add_argument("--text", default="HELLO FROM THE TCP PARTNER",
                    help="the block to send to the mainframe")
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="seconds to wait for each inbound frame")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if args.listen:
        sock = open_listen(args.listen)
    else:
        sock = open_connect(args.connect or "127.0.0.1:3781")

    line = BscLine(sock, timeout=args.timeout)
    try:
        converse(line, args.role, args.text)
        print("conversation completed normally")
        return 0
    except BscError as exc:
        print("BSC error: %s" % exc, file=sys.stderr)
        return 1
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
