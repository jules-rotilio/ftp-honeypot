#!/usr/bin/env python3
"""
ftp-honeypot - a tiny, low-interaction FTP honeypot.

It listens on TCP 21 (IPv4 and IPv6), pretends to be an FTP server,
logs every connection, command and credential attempt as one JSON line,
and never lets anyone log in.

Configuration (environment variables, set them in the systemd unit):
  HONEYPOT_PORT     port to listen on            (default: 21)
  HONEYPOT_LOG      path of the JSON log file    (default: /var/log/ftp-honeypot/ftp-honeypot.log)
  HONEYPOT_BANNER   greeting sent to clients     (default: a ProFTPD-looking banner)
  HONEYPOT_MAX_CONN max simultaneous sessions    (default: 100)
  HONEYPOT_MAX_LOG_MB  log size above which only connections are logged,
                       not commands/credentials (default: 200)
"""

import asyncio
import datetime
import json
import os
import sys

PORT = int(os.environ.get("HONEYPOT_PORT", "21"))
LOG = os.environ.get("HONEYPOT_LOG", "/var/log/ftp-honeypot/ftp-honeypot.log")
BANNER = os.environ.get("HONEYPOT_BANNER", "220 ProFTPD 1.3.8 Server (Debian) ready.")
MAX_CONN = int(os.environ.get("HONEYPOT_MAX_CONN", "100"))
MAX_LOG = int(os.environ.get("HONEYPOT_MAX_LOG_MB", "200")) * 1024 * 1024

MAX_LINE = 512        # bytes kept from each command
READ_LIMIT = 4096     # longest line accepted from a client; longer = hang up
MAX_COMMANDS = 20     # commands per session before we hang up
IDLE_TIMEOUT = 30     # seconds without a command before we hang up
FAIL_DELAY = 2        # seconds to wait before answering a password (slows brute force)

_slots = asyncio.Semaphore(MAX_CONN)


def log(event: str, src: str, **fields) -> None:
    """Write one JSON line. 'ts', 'event' and 'src' always come first (fail2ban relies on it)."""
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        "src": src,
    }
    record.update(fields)
    line = json.dumps(record, ensure_ascii=True)
    # Disk-fill guard: past MAX_LOG, keep only "connect" lines (what fail2ban
    # needs to ban) and drop the details until logrotate shrinks the file.
    if event != "connect":
        try:
            if os.path.getsize(LOG) > MAX_LOG:
                return
        except OSError:
            pass
    try:
        with open(LOG, "a", encoding="ascii") as f:
            f.write(line + "\n")
    except OSError as exc:
        print(f"cannot write log: {exc}", file=sys.stderr)
    print(line, flush=True)  # also goes to the journal (size-capped by journald)


def clean(raw: bytes) -> str:
    return raw[:MAX_LINE].decode("utf-8", errors="replace").strip()


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername") or ("?", 0)
    ip, port = peer[0], peer[1]
    if ip.startswith("::ffff:"):
        ip = ip[7:]

    if _slots.locked():
        writer.close()
        return

    async with _slots:
        log("connect", ip, sport=port)
        user = None
        try:
            writer.write((BANNER + "\r\n").encode())
            await writer.drain()

            for _ in range(MAX_COMMANDS):
                raw = await asyncio.wait_for(reader.readline(), timeout=IDLE_TIMEOUT)
                if not raw:
                    break
                cmd = clean(raw)
                verb, _, arg = cmd.partition(" ")
                verb = verb.upper()

                if verb == "USER":
                    user = arg
                    reply = "331 Password required for {}.".format(arg[:64] or "anonymous")
                elif verb == "PASS":
                    log("login", ip, user=user, password=arg)
                    await asyncio.sleep(FAIL_DELAY)
                    reply = "530 Login incorrect."
                elif verb == "QUIT":
                    writer.write(b"221 Goodbye.\r\n")
                    await writer.drain()
                    break
                elif verb in ("SYST",):
                    reply = "215 UNIX Type: L8"
                elif verb in ("FEAT", "AUTH"):
                    reply = "502 Command not implemented."
                else:
                    log("cmd", ip, cmd=cmd)
                    reply = "530 Please login with USER and PASS."

                writer.write((reply + "\r\n").encode("utf-8", errors="replace"))
                await writer.drain()
        except (ValueError, asyncio.LimitOverrunError, asyncio.IncompleteReadError):
            # Line longer than READ_LIMIT (readline raises ValueError): hang up.
            log("cmd", ip, cmd="<line longer than %d bytes, connection closed>" % READ_LIMIT)
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
            log("disconnect", ip)


async def main() -> None:
    # host=None binds every interface, IPv4 and IPv6.
    server = await asyncio.start_server(handle, host=None, port=PORT, reuse_address=True,
                                        limit=READ_LIMIT)
    addrs = ", ".join(str(s.getsockname()[:2]) for s in server.sockets)
    print(f"ftp-honeypot listening on {addrs}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
