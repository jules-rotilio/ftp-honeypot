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
- **Auto-ban.** One connection = 1 month ban on every port. Repeat offenders get 2, 4, 8 months, then 1 year. Ban history is kept for a year, so bans survive reboots.
- **Explicit whitelist.** Only loopback is whitelisted by default. Add your LAN with `--ignore-local` and any other address with `--ignore`, so you can't lock yourself out.

## Requirements

- Debian 13 "trixie" (Debian 12 and Ubuntu should work too)
- systemd
- root access
- Port 21 free (no vsftpd/proftpd/pure-ftpd running)

The installer pulls in `python3`, `logrotate`, `fail2ban` and `nftables` with `apt`.

## Install

```bash
git clone https://github.com/jules-rotilio/ftp-honeypot.git
cd ftp-honeypot
sudo ./install.sh
```

By default **only loopback** is whitelisted: any other machine that touches port 21, including your own PC on the LAN, gets banned. Whitelist what you use before testing:

```bash
# your whole local network (auto-detected, IPv4 and IPv6)
sudo ./install.sh --ignore-local

# specific addresses: a VPS, your phone on 4G, work…
sudo ./install.sh --ignore "203.0.113.10 2001:db8:1234::/48"

# both
sudo ./install.sh --ignore-local --ignore "203.0.113.10"
```

Other options:

| Command | What it does |
|---|---|
| `sudo ./install.sh` | Install honeypot + fail2ban jail, whitelist loopback only |
| `sudo ./install.sh --ignore-local` | Also whitelist your local networks (auto-detected) |
| `sudo ./install.sh --ignore "IP NET …"` | Also whitelist these IPs / CIDR networks (can be repeated) |
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
```

### Managing bans

`ftp-honeypot-bans` (installed in `/usr/local/sbin`) lists the banned IPs with how long each ban has left, shows what an IP did (credentials and commands it tried), and unbans:

```bash
sudo ftp-honeypot-bans                       # interactive menu
sudo ftp-honeypot-bans list                  # banned IPs, since / until / time left / password attempts
sudo ftp-honeypot-bans show 203.0.113.7      # what that IP did
sudo ftp-honeypot-bans unban 203.0.113.7     # one or more IPs
sudo ftp-honeypot-bans unban-all             # everyone (asks first)
```

In the menu, `u 1 3 5-7` unbans by list number, and `s 2` shows details for entry 2.

Unbanning lifts the current ban but fail2ban still remembers the IP: if it comes back, its next ban is the longer, doubled one.

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
| How long ban history is kept (`dbpurgeage`, must be ≥ `bantime.maxtime`) | `/etc/fail2ban/fail2ban.d/ftp-honeypot.conf`, then `systemctl restart fail2ban` |
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
ftp-honeypot-bans                    view / unban banned IPs (installed in /usr/local/sbin)
systemd/ftp-honeypot.service         systemd unit
fail2ban/filter.d/ftp-honeypot.conf  fail2ban filter
fail2ban/jail.d/ftp-honeypot.conf    fail2ban jail (whitelist filled in by install.sh)
fail2ban/fail2ban.d/ftp-honeypot.conf  fail2ban server setting: keep ban history 1 year
logrotate/ftp-honeypot               log rotation
```
