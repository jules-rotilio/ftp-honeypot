# ftp-honeypot

A tiny, low-interaction **FTP honeypot** for Debian. It listens on TCP **21**, pretends to be an FTP server, logs every connection and every username/password tried, and **never** lets anyone in.

Paired with **fail2ban**, any IP that touches port 21 is banned on **all ports** of the server. Nothing legitimate ever talks to this port, so every hit is a scanner or a bot.

```
attacker ──► :21 honeypot.py ──► /var/log/ftp-honeypot/ftp-honeypot.log
                                          │
                                       fail2ban ──► nftables: ban IP on all ports
```

## Features

- **Single file, no dependencies.** Plain Python 3 standard library (`asyncio`), about 130 lines you can read in five minutes.
- **IPv4 and IPv6.**
- **Not root.** Runs as a dedicated system user. Its only privilege is `CAP_NET_BIND_SERVICE` (binding port 21), inside a heavily sandboxed systemd unit.
- **Brute-force friendly logging.** Captures `USER`/`PASS` pairs and any other command, as one JSON object per line.
- **Resource limits.** Max concurrent sessions, max commands per session, idle timeout, and a 2 s delay on each password attempt.
- **Auto-ban.** One connection = 1 day ban on every port. Repeat offenders get 2 d, 4 d… up to 4 weeks.
- **Safe defaults.** The installer whitelists loopback and your LAN (IPv4 and IPv6) so you can't lock yourself out.

## Requirements

- Debian 13 "trixie" (Debian 12 and Ubuntu should work too)
- systemd
- root access
- Port 21 free (no vsftpd/proftpd/pure-ftpd running)

The installer pulls in `python3`, `logrotate`, `fail2ban` and `nftables` with `apt`.

## Install

```bash
git clone https://github.com/<you>/ftp-honeypot.git
cd ftp-honeypot
sudo ./install.sh
```

If you ever connect to the server from **outside** your LAN (a VPS, your phone on 4G, work…), whitelist those addresses so a test doesn't ban you:

```bash
sudo ./install.sh --ignore "203.0.113.10 2001:db8:1234::/48"
```

Other options:

| Command | What it does |
|---|---|
| `sudo ./install.sh` | Install honeypot + fail2ban jail, auto-whitelist your LAN |
| `sudo ./install.sh --ignore "IP NET …"` | Also whitelist these IPs / CIDR networks |
| `sudo ./install.sh --no-fail2ban` | Honeypot and logging only, no banning |
| `sudo ./install.sh --uninstall` | Remove everything (logs are kept) |

Re-running the installer is safe; it updates files in place.

### Behind a home router

If the server sits behind your internet box, **forward TCP 21** from the router to the server's LAN IP. Some boxes run their own FTP/file-sharing service on 21 (the Freebox does), so turn that off first. If your ISP puts you behind CGNAT, inbound IPv4 won't reach you; ask for a full-stack IPv4 address or rely on IPv6.

## Usage

```bash
# live log
tail -f /var/log/ftp-honeypot/ftp-honeypot.log

# most tried passwords
grep '"login"' /var/log/ftp-honeypot/ftp-honeypot.log | python3 -c '
import sys, json, collections
c = collections.Counter(json.loads(l).get("password") for l in sys.stdin)
for p, n in c.most_common(20): print(n, p)'

# service status / journal
systemctl status ftp-honeypot
journalctl -u ftp-honeypot -f

# who is banned, unban someone
fail2ban-client status ftp-honeypot
fail2ban-client set ftp-honeypot unbanip 203.0.113.7
```

### Log format

One JSON object per line, timestamps in UTC:

```json
{"ts": "2026-10-11T16:28:46Z", "event": "connect", "src": "203.0.113.7", "sport": 55998}
{"ts": "2026-10-11T16:28:46Z", "event": "login", "src": "203.0.113.7", "user": "admin", "password": "hunter2"}
{"ts": "2026-10-11T16:28:48Z", "event": "cmd", "src": "203.0.113.7", "cmd": "LIST"}
{"ts": "2026-10-11T16:28:48Z", "event": "disconnect", "src": "203.0.113.7"}
```

Logs rotate weekly and 8 weeks are kept (`/etc/logrotate.d/ftp-honeypot`).

## Configuration

| What | Where |
|---|---|
| Port, banner, log path, max sessions | `Environment=` lines in `/etc/systemd/system/ftp-honeypot.service`, then `systemctl daemon-reload && systemctl restart ftp-honeypot` |
| Ban time, whitelist (`ignoreip`) | `/etc/fail2ban/jail.d/ftp-honeypot.conf`, then `systemctl reload fail2ban` |
| What counts as a hit | `/etc/fail2ban/filter.d/ftp-honeypot.conf` |

To ban on failed **logins** only instead of any connection, change the filter's `failregex` to match `"event": "login"`.

## Testing it

From a machine that is **whitelisted** (otherwise you'll ban yourself):

```bash
nc <server-ip> 21
USER admin
PASS test
QUIT
```

You should see the attempt in the log, and no ban. To check banning without risk, look at `fail2ban-client status ftp-honeypot` after a few hours online: the internet scans port 21 constantly.

## Security notes

- The honeypot never accepts a login, never opens a data connection and never touches the filesystem except its own log file.
- Input is capped at 512 bytes per line and 20 commands per session, and everything is JSON-escaped before logging. A forged `"event": "connect"` string sent by an attacker does **not** trigger the fail2ban filter.
- The systemd unit uses `ProtectSystem=strict`, `NoNewPrivileges`, a syscall filter, memory/task limits, and more. `systemd-analyze security ftp-honeypot` shows the score.
- Keep your **real** services (SSH…) hardened anyway. This is an early-warning and noise-reduction tool, not a firewall.

## Files

```
honeypot.py                          the honeypot
install.sh                           installer / uninstaller
systemd/ftp-honeypot.service         systemd unit
fail2ban/filter.d/ftp-honeypot.conf  fail2ban filter
fail2ban/jail.d/ftp-honeypot.conf    fail2ban jail (whitelist filled in by install.sh)
logrotate/ftp-honeypot               log rotation
```
