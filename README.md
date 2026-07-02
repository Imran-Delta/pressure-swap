# pressure-swap — Dynamic Emergency Swap Manager

A lightweight, PSI‑aware swap daemon that creates and removes emergency swap chunks on‑demand when your system is under extreme memory pressure.

## Features

- **Dynamic chunking** – adds/removes swap in fixed‑size chunks (default 512 MiB) to never waste disk space.
- **PSI‑aware removal** – waits until I/O and memory pressure subside before removing swap, preventing thrashing.
- **Btrfs‑safe** – automatically disables copy‑on‑write and compression on btrfs filesystems.
- **Configurable** – all thresholds, paths and logging are tuneable via `/etc/pressure-swap.conf`.
- **Low overhead** – runs every second via systemd timer or as a standalone daemon.
- **Real‑time dashboard** – a companion script (`pressure-swap-dashboard`) displays the current swap hierarchy and PSI metrics.

## How it works

1. Every second, the script reads `/proc/swaps` and `/proc/meminfo` to compute primary swap (or RAM) usage.
2. If usage **exceeds the add threshold** (default 90 %), a new swap chunk is created in `/pagefiles` (or a fallback directory).
3. If usage **falls below the remove threshold** (default 70 %) for a sustained period (default 30 s) **and** PSI pressure is low, chunks are removed one by one.
4. Emergency chunks always have a **lower priority** than normal swap, so they are only used as a last resort.

## Usage

The main script can be run manually (requires root):

```bash
# Run one check (like the systemd timer)
sudo pressure-swap.sh

# Dry run – see what would happen without changes
sudo pressure-swap.sh --dry-run

# Verbose output
sudo pressure-swap.sh -v

# Run as a standalone daemon (no systemd needed)
sudo pressure-swap.sh --loop

# Show help
pressure-swap.sh -h
```

Systemd timer

When installed, the timer fires every second:

```bash
systemctl enable --now pressure-swap.timer   # start and enable at boot
systemctl status pressure-swap.timer         # check timer status
journalctl -u pressure-swap.service -f       # follow the service log
```

Dashboard

Run the real‑time dashboard (any user):

```bash
pressure-swap-dashboard
```

Configuration

All settings are in /etc/pressure-swap.conf.
You can set thresholds, chunk size, maximum total emergency swap (with expressions like ram / 2), PSI limits, logging, and more.
The config file is fully commented with examples.

An alternative config path can be set via the environment variable PRESSURE_SWAP_CONFIG.

Requirements

· Linux kernel 5.10+ (for PSI; works without, using usage-only logic)
· Bash 4.0+
· systemd (optional – a --loop mode is available)
· coreutils, procps-ng, util-linux

License

zlib License – see LICENSE.