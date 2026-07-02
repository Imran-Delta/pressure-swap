#!/usr/bin/env bash
# pressure-swap.sh – Dynamic, pressure‑driven emergency swap management.
# Runs as a oneshot (for systemd) or daemon loop.
# Supports expressions for MIN/MAX swap, btrfs safety, PSI‑aware removal,
# dry‑run, verbose, and more.

set -uo pipefail

# ─── Defaults (overridden by /etc/pressure-swap.conf) ─────────────────
SWAP_DIR="/pagefiles"
SWAP_DIR_FALLBACK="/tmp"        # fallback directory if SWAP_DIR can't be created
PREFIX="emergency_chunk"
CHUNK_SIZE_MB=512
MIN_SWAP_MB=0
MAX_SWAP_MB=0
MAX_CHUNKS=0
MIN_FREE_SPACE_MB=1042
ADD_THRESHOLD_PCT=90
REMOVE_THRESHOLD_PCT=70
SWAP_PRIORITY=-50
ADD_STABILITY_SECS=0            # WARNING: >0 increases OOM risk
REMOVE_STABILITY_SECS=30
MEM_PSI_SOME_THRESHOLD=2.0
IO_PSI_SOME_THRESHOLD=5.0
LOGFILE="/var/log/pressure-swap.log"
LOG_MAX_SIZE=$((10*1024*1024))
HEARTBEAT_INTERVAL_SECS=30
LOCKFILE="/run/pressure-swap.lock"
STATE_COUNTER_FILE="/run/pressure-swap-remove-counter"
VERBOSE=false
LOOP_INTERVAL_SECS=1
SWAP_DEVICES=""                 # space-separated list of primary devices

# ─── Source user config (if present) ─────────────────────────────────
if [[ -n "${PRESSURE_SWAP_CONFIG:-}" ]]; then
    if [[ -f "$PRESSURE_SWAP_CONFIG" ]]; then
        source "$PRESSURE_SWAP_CONFIG"
    fi
elif [[ -f /etc/pressure-swap.conf ]]; then
    source /etc/pressure-swap.conf
fi

# ─── Helper functions ────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOGFILE"
    if [[ "$VERBOSE" == true || "$1" == "ERROR:"* ]]; then
        echo "$msg" >&2
    fi
}

verbose_log() {
    if [[ "$VERBOSE" == true ]]; then
        log "$@"
    fi
}

rotate_log() {
    if [[ -f "$LOGFILE" ]]; then
        local size
        size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        if (( size > LOG_MAX_SIZE )); then
            tail -c 1048576 "$LOGFILE" > "${LOGFILE}.tmp"
            mv "${LOGFILE}.tmp" "$LOGFILE"
            log "Log rotated (truncated to last 1 MiB)."
        fi
    fi
}

# Evaluate an expression string containing total_swap/ram
evaluate_expr() {
    local expr="$1"
    local total_swap_mb="$2"
    local ram_mb="$3"
    local cleaned

    # Replace tokens
    cleaned="${expr//total_swap/$total_swap_mb}"
    cleaned="${cleaned//ram/$ram_mb}"
    # Remove spaces
    cleaned="${cleaned// /}"
    # Safety: allow only digits, operators, parentheses
    if [[ "$cleaned" =~ ^[0-9+\-*/()]+$ ]]; then
        echo $(( cleaned ))
    else
        log "WARNING: Invalid expression '$expr'. Defaulting to 0."
        echo 0
    fi
}

is_btrfs() {
    local dir="$1"
    [[ $(stat -f -c %T "$dir" 2>/dev/null) == "btrfs" ]]
}

# ─── Argument parsing ─────────────────────────────────────────────────
MODE="oneshot"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --loop) MODE="loop"; shift ;;
        --oneshot) MODE="oneshot"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: pressure-swap.sh [--oneshot|--loop] [--dry-run] [-v] [-h]

Modes:
  --oneshot    Run once and exit (default, for systemd timer).
  --loop       Run in a continuous loop (interval from config).

Options:
  --dry-run    Simulate actions, do not modify swap.
  -v, --verbose Show detailed output.
  -h, --help   This message.
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Root check (unless dry-run or help already handled)
if [[ "$EUID" != 0 && "$DRY_RUN" == false ]]; then
    echo "ERROR: Must run as root (or use --dry-run)." >&2
    exit 1
fi

# ─── Lock (only if not dry-run, but we can still simulate locking) ───
if [[ "$DRY_RUN" == false ]]; then
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        log "Another instance running. Exiting."
        exit 0
    fi
    trap 'log "Script terminating (lock released)."' EXIT
fi

# ─── Main logic function (run once) ───────────────────────────────────
run_once() {
    rotate_log

    # ── Pre-flight: SWAP_DIR ──
    if [[ ! -d "$SWAP_DIR" ]]; then
        if ! mkdir -p "$SWAP_DIR" 2>/dev/null; then
            if [[ -n "$SWAP_DIR_FALLBACK" ]]; then
                log "WARNING: Cannot create $SWAP_DIR, falling back to $SWAP_DIR_FALLBACK"
                SWAP_DIR="$SWAP_DIR_FALLBACK"
                mkdir -p "$SWAP_DIR" || { log "ERROR: Fallback directory creation failed."; exit 1; }
            else
                log "ERROR: Cannot create $SWAP_DIR and no fallback set. Exiting."
                exit 1
            fi
        fi
    fi
    if ! touch "$SWAP_DIR/.write_test" 2>/dev/null; then
        log "ERROR: $SWAP_DIR is not writable. Exiting."
        exit 1
    else
        rm -f "$SWAP_DIR/.write_test"
    fi

    # ── Gather swap data ──
    declare -a primary_paths=()
    declare -a emergency_paths=()
    declare -A swap_size_kb=()
    declare -A swap_used_kb=()

    while read -r path type size used prio; do
        if [[ "$path" == "$SWAP_DIR/$PREFIX"_* ]]; then
            emergency_paths+=("$path")
        else
            # If SWAP_DEVICES is set, only include those
            if [[ -n "$SWAP_DEVICES" ]]; then
                for dev in $SWAP_DEVICES; do
                    if [[ "$path" == "$dev" ]]; then
                        primary_paths+=("$path")
                        break
                    fi
                done
            else
                primary_paths+=("$path")
            fi
        fi
        swap_size_kb["$path"]=$size
        swap_used_kb["$path"]=$used
    done < <(tail -n +2 /proc/swaps 2>/dev/null || true)

    primary_swap_kb=0
    primary_used_kb=0
    for p in "${primary_paths[@]}"; do
        primary_swap_kb=$(( primary_swap_kb + swap_size_kb["$p"] ))
        primary_used_kb=$(( primary_used_kb + swap_used_kb["$p"] ))
    done

    emergency_total_kb=0
    for p in "${emergency_paths[@]}"; do
        emergency_total_kb=$(( emergency_total_kb + swap_size_kb["$p"] ))
    done

    # ── Compute pressure metric ──
    if (( primary_swap_kb > 0 )); then
        usage_pct=$(( 100 * primary_used_kb / primary_swap_kb ))
        metric_name="swap"
    else
        mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        if (( mem_total > 0 )); then
            usage_pct=$(( 100 * (mem_total - mem_avail) / mem_total ))
        else
            usage_pct=0
        fi
        metric_name="RAM"
    fi
    verbose_log "Pressure: ${usage_pct}% (${metric_name})"

    # ── Free space on SWAP_DIR (MiB) ──
    free_space_kb=$(df --output=avail -B1 "$SWAP_DIR" 2>/dev/null | tail -1)
    free_space_kb=${free_space_kb:-0}
    free_space_mb=$(( free_space_kb / 1024 ))
    verbose_log "Free space on swap dir: ${free_space_mb} MiB"

    # ── Evaluate MIN/MAX expressions ──
    total_swap_mb=$(( primary_swap_kb / 1024 ))
    ram_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    if [[ "$MIN_SWAP_MB" =~ ^[0-9]+$ ]]; then
        min_swap_mb_val=$MIN_SWAP_MB
    else
        min_swap_mb_val=$(evaluate_expr "$MIN_SWAP_MB" "$total_swap_mb" "$ram_mb")
    fi
    if [[ "$MAX_SWAP_MB" =~ ^[0-9]+$ ]]; then
        max_swap_mb_val=$MAX_SWAP_MB
    else
        max_swap_mb_val=$(evaluate_expr "$MAX_SWAP_MB" "$total_swap_mb" "$ram_mb")
    fi
    verbose_log "MIN_SWAP=$min_swap_mb_val MiB, MAX_SWAP=$max_swap_mb_val MiB"

    # ── Heartbeat ──
    heartbeat_file="/run/pressure-swap-last-heartbeat"
    last_hb=0
    [[ -f "$heartbeat_file" ]] && last_hb=$(<"$heartbeat_file")
    now=$(date +%s)
    if (( now - last_hb >= HEARTBEAT_INTERVAL_SECS )); then
        log "Heartbeat: ${metric_name}=${usage_pct}%, emergency=${#emergency_paths[@]} chunks ($((emergency_total_kb/1024)) MiB), free=${free_space_mb} MiB"
        echo "$now" > "$heartbeat_file"
    fi

    # ── Addition logic (with optional stability) ──
    if (( usage_pct >= ADD_THRESHOLD_PCT )); then
        if (( ADD_STABILITY_SECS > 0 )); then
            add_counter_file="/run/pressure-swap-add-counter"
            add_counter=0
            [[ -f "$add_counter_file" ]] && add_counter=$(<"$add_counter_file")
            add_counter=$(( add_counter + 1 ))
            echo "$add_counter" > "$add_counter_file"
            if (( add_counter < ADD_STABILITY_SECS )); then
                verbose_log "Add pressure sustained for ${add_counter}s (need ${ADD_STABILITY_SECS}s)"
                return
            fi
        fi
        # Reset add counter if we're going to evaluate addition
        [[ -f /run/pressure-swap-add-counter ]] && rm -f /run/pressure-swap-add-counter

        # Check caps
        new_chunk_kb=$(( CHUNK_SIZE_MB * 1024 ))
        if (( max_swap_mb_val > 0 && emergency_total_kb + new_chunk_kb > max_swap_mb_val * 1024 )); then
            verbose_log "Not adding: would exceed MAX_SWAP_MB ($max_swap_mb_val MiB)"
            return
        fi
        if (( MAX_SWAP_MB == 0 && MAX_CHUNKS > 0 && ${#emergency_paths[@]} >= MAX_CHUNKS )); then
            verbose_log "Not adding: already at MAX_CHUNKS ($MAX_CHUNKS)"
            return
        fi
        if (( free_space_mb - CHUNK_SIZE_MB <= MIN_FREE_SPACE_MB )); then
            verbose_log "Not adding: free space would drop to or below ${MIN_FREE_SPACE_MB} MiB"
            return
        fi

        if [[ "$DRY_RUN" == true ]]; then
            log "DRY-RUN: would add a ${CHUNK_SIZE_MB} MiB chunk."
            return
        fi

        # Create chunk
        next_idx=0
        if (( ${#emergency_paths[@]} > 0 )); then
            last=$(printf '%s\n' "${emergency_paths[@]}" | sort | tail -1)
            last_num="${last##*_}"
            if [[ "$last_num" =~ ^[0-9]+$ ]]; then
                next_idx=$(( last_num + 1 ))
            else
                next_idx=${#emergency_paths[@]}
            fi
        fi
        chunk_file="${SWAP_DIR}/${PREFIX}_${next_idx}"
        log "Adding chunk: $chunk_file (${CHUNK_SIZE_MB} MiB)"

        touch "$chunk_file"
        if is_btrfs "$SWAP_DIR"; then
            chattr -c "$chunk_file" 2>/dev/null || true
            chattr +C "$chunk_file" 2>/dev/null || true
        fi
        if fallocate -l "${new_chunk_kb}K" "$chunk_file" 2>/dev/null; then
            :
        else
            dd if=/dev/zero of="$chunk_file" bs=1M count="$CHUNK_SIZE_MB" status=none
        fi
        chmod 600 "$chunk_file"
        mkswap "$chunk_file" >/dev/null 2>&1
        if swapon -p "$SWAP_PRIORITY" "$chunk_file"; then
            log "Chunk activated."
        else
            log "ERROR: swapon failed, removing file."
            rm -f "$chunk_file"
        fi

    # ── Removal logic (with PSI and sustained low) ──
    elif (( usage_pct <= REMOVE_THRESHOLD_PCT )); then
        # Reset add stability counter if pressure is low
        [[ -f /run/pressure-swap-add-counter ]] && rm -f /run/pressure-swap-add-counter

        # Sustained low counter
        remove_counter=0
        [[ -f "$STATE_COUNTER_FILE" ]] && remove_counter=$(<"$STATE_COUNTER_FILE")
        remove_counter=$(( remove_counter + 1 ))
        echo "$remove_counter" > "$STATE_COUNTER_FILE"

        if (( remove_counter >= REMOVE_STABILITY_SECS )); then
            # PSI check
            mem_psi=0; io_psi=0
            if [[ -f /proc/pressure/memory ]]; then
                mem_psi=$(grep -o 'avg60=[0-9.]*' /proc/pressure/memory 2>/dev/null | head -1 | cut -d= -f2 || echo 0)
            fi
            if [[ -f /proc/pressure/io ]]; then
                io_psi=$(grep -o 'avg60=[0-9.]*' /proc/pressure/io 2>/dev/null | head -1 | cut -d= -f2 || echo 0)
            fi
            mem_psi="${mem_psi:-0}"; io_psi="${io_psi:-0}"

            if awk -v mem="$mem_psi" -v memt="$MEM_PSI_SOME_THRESHOLD" \
                   -v io="$io_psi" -v iot="$IO_PSI_SOME_THRESHOLD" \
                   'BEGIN { if (mem >= memt || io >= iot) exit 1; exit 0 }'; then
                if (( ${#emergency_paths[@]} > 0 )); then
                    mapfile -t sorted < <(printf '%s\n' "${emergency_paths[@]}" | sort)
                    target="${sorted[0]}"
                    target_kb=${swap_size_kb["$target"]}
                    if (( min_swap_mb_val > 0 && emergency_total_kb - target_kb < min_swap_mb_val * 1024 )); then
                        log "Skipping removal: would drop below MIN_SWAP ($min_swap_mb_val MiB)."
                    else
                        if [[ "$DRY_RUN" == true ]]; then
                            log "DRY-RUN: would remove $target."
                        else
                            log "Attempting removal of $target"
                            if swapoff "$target" 2>/dev/null; then
                                rm -f "$target"
                                log "Removed chunk: $target"
                            else
                                log "WARNING: swapoff failed, leaving $target."
                            fi
                        fi
                    fi
                fi
            else
                log "Skipping removal: PSI too high (mem=$mem_psi, io=$io_psi)."
            fi
            # Reset counter after attempt
            echo 0 > "$STATE_COUNTER_FILE"
        fi
    else
        # Between thresholds – reset both counters
        [[ -f "$STATE_COUNTER_FILE" ]] && echo 0 > "$STATE_COUNTER_FILE"
        [[ -f /run/pressure-swap-add-counter ]] && rm -f /run/pressure-swap-add-counter
    fi

    # Cleanup stale files (only in non-dry-run)
    if [[ "$DRY_RUN" == false ]]; then
        for f in "$SWAP_DIR"/${PREFIX}_*; do
            [[ -f "$f" ]] || continue
            local found=0
            for active in "${emergency_paths[@]}"; do
                [[ "$f" == "$active" ]] && found=1 && break
            done
            if (( ! found )); then
                rm -f "$f"
                log "Removed stale file: $f"
            fi
        done
    fi
}

# ─── Execution ────────────────────────────────────────────────────────
if [[ "$MODE" == "loop" ]]; then
    log "Starting pressure-swap in daemon mode (interval=${LOOP_INTERVAL_SECS}s)."
    while true; do
        run_once
        sleep "$LOOP_INTERVAL_SECS"
    done
else
    run_once
fi