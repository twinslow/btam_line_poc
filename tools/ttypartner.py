#!/usr/bin/env python3
"""
ttypartner.py - the terminal end of an async TTY line, for talking to the
MVS 3.8J program ASYPOC through a Hercules 2703 line mapped onto a TCP
socket.

Plain telnet works too. This exists because it shows the raw bytes in
both directions, which is the thing you actually need to see: whether the
emulated line is handing the mainframe ASCII or EBCDIC, and what it does
with line endings.

Examples
--------
    # interactive, with a hex trace of everything
    python ttypartner.py --connect 192.168.1.168:3782

    # scripted, for a repeatable run
    python ttypartner.py --connect 192.168.1.168:3782 \\
        --script "HELLO MAINFRAME" "SECOND LINE" BYE

    # no mainframe needed - exercise the line handling locally
    python ttypartner.py --selftest
"""

import argparse
import socket
import sys
import threading
import time

CR = 0x0D
LF = 0x0A


def hexdump(data, limit=32):
    hexs = " ".join("%02X" % b for b in data[:limit])
    if len(data) > limit:
        hexs += " ..."
    return hexs


def printable(data, encoding):
    try:
        text = data.decode(encoding, errors="replace")
    except LookupError:
        text = repr(data)
    return "".join(c if 0x20 <= ord(c) < 0x7F else "." for c in text)


class TtyLine:
    """A dumb terminal on the end of a stream socket."""

    def __init__(self, sock, encoding="ascii", trace=True, eol=b"\r\n"):
        self.sock = sock
        self.encoding = encoding
        self.trace = trace
        self.eol = eol
        self.buf = bytearray()
        self.closed = False        # peer hung up - a normal way to end

    def _log(self, direction, data):
        if self.trace and data:
            print("%s %-50s |%s|" % (direction, hexdump(data),
                                     printable(data, self.encoding)),
                  flush=True)

    def send_line(self, text):
        data = text.encode(self.encoding, errors="replace") + self.eol
        self._log("TX", data)
        self.sock.sendall(data)

    def recv_some(self, timeout=5.0):
        """Read whatever has arrived within the timeout. May be partial.

        A clean close by the far end is not an error - ASYPOC hangs up
        after BYE - so it sets .closed and returns nothing."""
        if self.closed:
            return b""
        self.sock.settimeout(timeout)
        try:
            chunk = self.sock.recv(4096)
        except socket.timeout:
            return b""
        except OSError:
            self.closed = True
            return b""
        if not chunk:
            self.closed = True
            return b""
        self._log("RX", chunk)
        self.buf.extend(chunk)
        return chunk

    def recv_until_quiet(self, timeout=5.0, quiet=0.4):
        """Collect output until the line goes quiet - the usual way to
        pick up a prompt, which has no line ending after it."""
        deadline = time.monotonic() + timeout
        got = bytearray()
        while time.monotonic() < deadline:
            chunk = self.recv_some(quiet)
            if chunk:
                got.extend(chunk)
                deadline = time.monotonic() + quiet
            elif self.closed or got:
                break
        return bytes(got)

    def lines(self, data):
        """Split a chunk into complete lines, tolerating CR, LF or CRLF."""
        text = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        return [l for l in text.split(b"\n") if l]


def run_script(line, script):
    banner = line.recv_until_quiet()
    for chunk in line.lines(banner):
        print("   <<", printable(chunk, line.encoding), flush=True)

    for text in script:
        print("   >>", text, flush=True)
        line.send_line(text)
        reply = line.recv_until_quiet()
        for chunk in line.lines(reply):
            print("   <<", printable(chunk, line.encoding), flush=True)
        if text.strip().upper() == "BYE" or line.closed:
            break
    return 0


def run_interactive(line):
    print("connected - type lines, or BYE to finish. ctrl-C to bail out.\n",
          flush=True)
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            line.recv_some(0.5)
            if line.closed:
                print()
                print("(the line was closed by the far end)", flush=True)
                stop.set()
                return

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    try:
        for text in sys.stdin:
            if stop.is_set():
                break
            line.send_line(text.rstrip("\r\n"))
            if text.strip().upper() == "BYE":
                time.sleep(1.0)
                break
    except KeyboardInterrupt:
        pass
    stop.set()
    thread.join(2)
    return 0


# --- a stand-in for ASYPOC, so the tool can be tested with no mainframe --

def fake_asypoc(sock, encoding="ascii"):
    """Mimics what ASYPOC puts on the line: greeting, prompt, echo,
    ending on BYE."""
    def put(s):
        sock.sendall(s.encode(encoding))

    put("ASYPOC ON MVS 3.8J - ASYNC TTY LINE PROOF OF CONCEPT\r\n")
    put("TYPE A LINE AND PRESS ENTER.  TYPE BYE TO FINISH.\r\n")
    buf = bytearray()
    for _ in range(10):
        put("> ")
        while b"\r" not in buf and b"\n" not in buf:
            sock.settimeout(5.0)
            chunk = sock.recv(256)
            if not chunk:
                return
            buf.extend(chunk)
        raw = bytes(buf).replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        text, _, rest = raw.partition(b"\n")
        buf = bytearray(rest)
        word = text.decode(encoding, errors="replace").strip()
        if word.upper() == "BYE":
            put("ASYPOC SIGNING OFF.  GOODBYE.\r\n")
            return
        put("YOU SAID: %s\r\n" % word)


def selftest():
    a, b = socket.socketpair()
    errors = {}

    def server():
        try:
            fake_asypoc(a)
        except Exception as exc:                # noqa: BLE001
            errors["server"] = exc
        finally:
            try:
                a.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    thread = threading.Thread(target=server)
    thread.start()

    captured = []
    line = TtyLine(b, trace=True)
    original = line._log

    def spy(direction, data):
        if direction == "RX" and data:
            captured.append(data)
        original(direction, data)
    line._log = spy

    try:
        run_script(line, ["HELLO MAINFRAME", "SECOND LINE", "BYE"])
    except Exception as exc:                    # noqa: BLE001
        errors["client"] = exc
    thread.join(10)
    a.close()
    b.close()

    blob = b"".join(captured)
    ok = (not errors
          and b"ASYPOC ON MVS 3.8J" in blob
          and b"YOU SAID: HELLO MAINFRAME" in blob
          and b"YOU SAID: SECOND LINE" in blob
          and b"GOODBYE" in blob)
    if errors:
        print("\nerrors: %r" % errors)
    print("\nselftest: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# --- plumbing ---------------------------------------------------------

def open_connect(target):
    host, _, port = target.rpartition(":")
    host = host or "127.0.0.1"
    sock = socket.create_connection((host, int(port)))
    print("connected to %s:%s" % (host, port), flush=True)
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


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    grp = ap.add_mutually_exclusive_group()
    grp.add_argument("--connect", metavar="HOST:PORT",
                     help="connect to a Hercules line that is listening")
    grp.add_argument("--listen", metavar="PORT",
                     help="listen for a Hercules line that dials out")
    grp.add_argument("--selftest", action="store_true",
                     help="exercise the line handling locally")
    ap.add_argument("--script", nargs="*", metavar="LINE",
                    help="send these lines instead of going interactive")
    ap.add_argument("--encoding", default="ascii",
                    help="wire encoding: ascii (default) or cp037 if the "
                         "emulator is passing EBCDIC straight through")
    ap.add_argument("--eol", default="crlf", choices=("crlf", "cr", "lf"),
                    help="line ending to send (default crlf)")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the hex trace")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    eol = {"crlf": b"\r\n", "cr": b"\r", "lf": b"\n"}[args.eol]
    sock = (open_listen(args.listen) if args.listen
            else open_connect(args.connect or "127.0.0.1:3782"))
    line = TtyLine(sock, encoding=args.encoding, trace=not args.quiet,
                   eol=eol)
    try:
        if args.script:
            return run_script(line, args.script)
        return run_interactive(line)
    except (ConnectionError, OSError) as exc:
        print("line error: %s" % exc, file=sys.stderr)
        return 1
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
