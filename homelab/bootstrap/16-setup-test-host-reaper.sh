#!/usr/bin/env bash
# 16-setup-test-host-reaper.sh -- Install the test-environment reaper on the
# Proxmox test host pvetest (192.168.1.252)
#
# Runs on: the Proxmox test host itself (NOT inside a container)
# Prereq: none
#
# pvetest is disposable infrastructure that agents use to build throwaway VMs
# and containers. Without a reaper those environments accumulate, and the next
# agent inherits someone else's half-configured box instead of building a clean
# one. This installs an hourly sweep that destroys abandoned environments.
#
# Installs:
#   - /usr/local/sbin/aimee-reaper       the sweep itself (systemd timer, hourly)
#   - /usr/local/bin/aimee-keepalive     agent-facing: renew a lease
#   - /usr/local/bin/aimee-reap-status   agent-facing: time left on both clocks
#   - /etc/aimee-reaper.conf             all tunable parameters
#   - /root/AGENTS.md (+ CLAUDE.md link) the host policy agents read
#
# A guest survives only if it passes BOTH clocks, and is destroyed on either:
#   liveness  no measurable activity for TTL  -> it is not doing any work
#   lease     TTL since creation or keepalive -> nobody claims to want it
# So a long-running test survives on its own activity, while a leased but
# stalled environment is still reclaimed. A lease is not immortality.
#
# Idempotent: safe to re-run. Re-running overwrites the scripts and policy but
# preserves live lease and activity state under /var/lib/aimee-reaper.

set -euo pipefail

CONF=/etc/aimee-reaper.conf
REAPER=/usr/local/sbin/aimee-reaper
KEEPALIVE=/usr/local/bin/aimee-keepalive
STATUS=/usr/local/bin/aimee-reap-status
POLICY=/root/AGENTS.md
STATE_DIR=/var/lib/aimee-reaper
LOG=/var/log/aimee-reaper.log

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------

prechecks() {
    info "Running prechecks"
    command -v qm    >/dev/null || err "qm not found -- this is not a Proxmox host"
    command -v pct   >/dev/null || err "pct not found -- this is not a Proxmox host"
    command -v pvesh >/dev/null || err "pvesh not found -- needed to sample guest activity"
    command -v perl  >/dev/null || err "perl not found -- needed to parse pvesh JSON"

    # Guard against installing a destructive sweep on a host that holds real
    # workloads. pvetest is expected to be disposable; anywhere else, insist.
    local host; host=$(hostname)
    if [[ $host != pvetest && ${FORCE:-0} != 1 ]]; then
        err "hostname is '$host', not 'pvetest'. This installs a DESTRUCTIVE hourly sweep that destroys every VM and CT it finds. Re-run with FORCE=1 only if this host really is disposable test infrastructure."
    fi
    info "Prechecks passed"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

install_config() {
    info "Installing $CONF"
    cat > "$CONF" <<'CONFEOF'
# /etc/aimee-reaper.conf — shared configuration for the .252 test-environment reaper.
# Sourced by aimee-reaper, aimee-keepalive and aimee-reap-status, so every tool
# agrees on the parameters. Change a value here and all three follow.

# How long a test environment may live without proof it is still wanted.
REAP_TTL_HOURS=4

# "Measurable activity" threshold. Between two consecutive reaper runs a guest
# must move at least this many bytes (disk read + disk write + net in + net out)
# to count as active. Below it, the guest is treated as idle.
REAP_ACTIVITY_BYTES=$((10 * 1024 * 1024))

REAP_LOG=/var/log/aimee-reaper.log
REAP_STATE_DIR=/var/lib/aimee-reaper
REAP_LEASE_DIR=/var/lib/aimee-reaper/leases
REAP_ACTIVITY_DIR=/var/lib/aimee-reaper/activity

# Filesystem roots swept for abandoned scratch. Only the immediate children of
# each root are considered; the roots themselves are never removed.
REAP_ROOTS=(/tmp /var/tmp /opt /srv /root)

# Baseline entries that are never reaped, matched by basename. Globs allowed.
# These are the host's own furniture, not test litter.
REAP_KEEP_root=('AGENTS.md' 'CLAUDE.md' '.bashrc' '.profile' '.forward' '.ssh')
REAP_KEEP_tmp=('.font-unix' '.ICE-unix' '.X11-unix' '.XIM-unix' 'systemd-private-*')
REAP_KEEP_var_tmp=('pve-reserved-ports' 'systemd-private-*')
REAP_KEEP_opt=()
REAP_KEEP_srv=()

# VMIDs/CTIDs the reaper must never touch. Normally empty: on this host every
# guest is disposable test data. Add an ID here only for deliberate fixtures.
REAP_PROTECTED_VMIDS=()
CONFEOF
    chmod 0644 "$CONF"
}

# ---------------------------------------------------------------------------
# The reaper
# ---------------------------------------------------------------------------

install_reaper() {
    info "Installing $REAPER"
    cat > "$REAPER" <<'REAPEREOF'
#!/usr/bin/env bash
# aimee-reaper — reclaim abandoned test environments on test host .252 (pvetest).
#
# A guest (VM or CT) survives a run only if it passes BOTH clocks:
#   liveness : measurable activity within TTL   (it is actually doing work)
#   lease    : creation or keepalive within TTL (someone says they still want it)
# Failing either one gets it destroyed. A long-running test survives on its own
# activity; a leased-but-stalled environment is still reclaimed.
#
# Scratch paths are swept on mtime, which is their activity signal, plus lease.
#
# Managed by infrastructure/homelab/bootstrap/16-setup-test-host-reaper.sh.
# Usage: aimee-reaper [--dry-run]
set -uo pipefail

CONF=/etc/aimee-reaper.conf
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"

TTL_HOURS="${REAP_TTL_HOURS:-4}"
ACT_BYTES="${REAP_ACTIVITY_BYTES:-10485760}"
LOG="${REAP_LOG:-/var/log/aimee-reaper.log}"
LEASE_DIR="${REAP_LEASE_DIR:-/var/lib/aimee-reaper/leases}"
ACT_DIR="${REAP_ACTIVITY_DIR:-/var/lib/aimee-reaper/activity}"

TTL_SEC=$(( TTL_HOURS * 3600 ))
NOW=$(date +%s)
NODE=$(hostname)

APPLY=1
for a in "$@"; do [[ $a == --dry-run ]] && APPLY=0; done

mkdir -p "$LEASE_DIR" "$ACT_DIR"
log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

reaped=0; kept=0

# ---------------------------------------------------------------- helpers ---

mtime_of() { [[ -e $1 ]] && stat -c %Y -- "$1" || echo 0; }

# Stable, reversible-by-lookup key. The lease/activity file CONTENT records the
# real target, so pruning never has to decode the key back into a path.
path_key() { printf 'path-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }

is_protected() {
   local id=$1 p
   for p in ${REAP_PROTECTED_VMIDS[@]+"${REAP_PROTECTED_VMIDS[@]}"}; do
      [[ -n $p && $p == "$id" ]] && return 0
   done
   return 1
}

keep_patterns() {
   case $1 in
      /root)    printf '%s\n' ${REAP_KEEP_root[@]+"${REAP_KEEP_root[@]}"} ;;
      /tmp)     printf '%s\n' ${REAP_KEEP_tmp[@]+"${REAP_KEEP_tmp[@]}"} ;;
      /var/tmp) printf '%s\n' ${REAP_KEEP_var_tmp[@]+"${REAP_KEEP_var_tmp[@]}"} ;;
      /opt)     printf '%s\n' ${REAP_KEEP_opt[@]+"${REAP_KEEP_opt[@]}"} ;;
      /srv)     printf '%s\n' ${REAP_KEEP_srv[@]+"${REAP_KEEP_srv[@]}"} ;;
   esac
}

# Cumulative transferred bytes for a running guest; -1 when it is not running.
guest_counters() {
   local kind=$1 id=$2 json
   json=$(pvesh get "/nodes/$NODE/$kind/$id/status/current" --output-format json 2>/dev/null) || return 1
   # perl, not python: PVE cannot run without perl, so this dependency is free.
   printf '%s' "$json" | perl -MJSON::PP -0777 -ne '
      my $d = eval { decode_json($_) } or exit 1;
      if (($d->{status} // "") ne "running") { print -1; exit 0 }
      my $s = 0; $s += ($d->{$_} // 0) for qw(diskread diskwrite netin netout);
      printf "%.0f", $s;
   ' 2>/dev/null
}

# Creation time: prefer the ctime PVE records in the guest config, else mtime.
guest_born() {
   local conf=$1 ct
   ct=$(grep -o 'ctime=[0-9]\+' -- "$conf" 2>/dev/null | head -1 | cut -d= -f2)
   [[ -n $ct ]] && { printf '%s' "$ct"; return; }
   mtime_of "$conf"
}

# Refresh the activity stamp for a key; echo the resulting last-activity epoch.
track_activity() {
   local key=$1 born=$2 cur=$3
   local tot="$ACT_DIR/$key.total" seen="$ACT_DIR/$key.seen" prev

   [[ -f $seen ]] || touch -d "@$born" -- "$seen"   # anchor liveness at birth

   if [[ $cur == -1 ]]; then                        # stopped: cannot be active
      rm -f -- "$tot"
      mtime_of "$seen"; return
   fi
   prev=$(cat -- "$tot" 2>/dev/null || true)
   printf '%s' "$cur" >"$tot"
   if [[ -n $prev ]] && (( cur - prev >= ACT_BYTES )); then
      touch -- "$seen"
   fi
   mtime_of "$seen"
}

destroy_guest() {
   local kind=$1 id=$2 why=$3 key=$4 tool rc
   [[ $kind == qemu ]] && tool=qm || tool=pct

   if (( ! APPLY )); then
      log "WOULD REAP $tool/$id ($why)"; return
   fi

   "$tool" stop "$id" --skiplock >/dev/null 2>&1
   for _ in {1..15}; do
      [[ $("$tool" status "$id" 2>/dev/null) == *stopped* ]] && break
      sleep 2
   done

   if [[ $tool == qm ]]; then
      qm destroy "$id" --purge --destroy-unreferenced-disks 1 --skiplock >>"$LOG" 2>&1
   else
      pct destroy "$id" --purge --force >>"$LOG" 2>&1
   fi
   rc=$?

   if (( rc == 0 )); then
      log "REAPED $tool/$id ($why)"
      rm -f -- "$LEASE_DIR/$key" "$ACT_DIR/$key.total" "$ACT_DIR/$key.seen"
      reaped=$(( reaped + 1 ))
   else
      log "FAILED to reap $tool/$id ($why) rc=$rc — resource still present, see errors above"
   fi
}

# ----------------------------------------------------------------- guests ---

sweep_guests() {
   local kind=$1 dir=$2 pfx=$3
   local conf id born cur lastact lease anchor key idle age
   for conf in "$dir"/*.conf; do
      [[ -e $conf ]] || continue
      id=$(basename -- "$conf" .conf)
      [[ $id =~ ^[0-9]+$ ]] || continue
      key="$pfx-$id"

      if is_protected "$id"; then
         log "KEEP $pfx/$id (protected by REAP_PROTECTED_VMIDS)"
         kept=$(( kept + 1 )); continue
      fi

      born=$(guest_born "$conf")
      cur=$(guest_counters "$kind" "$id") || cur=-1
      [[ -z $cur ]] && cur=-1
      lastact=$(track_activity "$key" "$born" "$cur")
      lease=$(mtime_of "$LEASE_DIR/$key")

      anchor=$born; (( lease > anchor )) && anchor=$lease
      idle=$(( NOW - lastact )); age=$(( NOW - anchor ))

      if (( idle > TTL_SEC )); then
         destroy_guest "$kind" "$id" "idle ${idle}s > ${TTL_SEC}s" "$key"
      elif (( age > TTL_SEC )); then
         destroy_guest "$kind" "$id" "no renewal for ${age}s > ${TTL_SEC}s" "$key"
      else
         log "KEEP $pfx/$id (idle ${idle}s, age ${age}s, ttl ${TTL_SEC}s)"
         kept=$(( kept + 1 ))
      fi
   done
}

# ----------------------------------------------------------- scratch paths ---

sweep_paths() {
   local root path base pat skip key lease anchor mt quiet
   local -a keep
   for root in ${REAP_ROOTS[@]+"${REAP_ROOTS[@]}"}; do
      [[ -d $root ]] || continue
      mapfile -t keep < <(keep_patterns "$root")

      while IFS= read -r -d '' path; do
         base=$(basename -- "$path")

         skip=0
         for pat in ${keep[@]+"${keep[@]}"}; do
            [[ -n $pat && $base == $pat ]] && { skip=1; break; }
         done
         (( skip )) && continue

         # Never act on anything that is not a proper child of this root.
         case $path in
            "$root"/?*) : ;;
            *) log "GUARD refusing suspicious path '$path'"; continue ;;
         esac

         key=$(path_key "$path")
         mt=$(mtime_of "$path")
         lease=$(mtime_of "$LEASE_DIR/$key")
         anchor=$mt; (( lease > anchor )) && anchor=$lease
         quiet=$(( NOW - anchor ))

         if (( quiet > TTL_SEC )); then
            if (( ! APPLY )); then
               log "WOULD REAP path $path (quiet ${quiet}s)"
            elif rm -rf -- "$path"; then
               log "REAPED path $path (quiet ${quiet}s)"
               rm -f -- "$LEASE_DIR/$key"
               reaped=$(( reaped + 1 ))
            else
               log "FAILED to reap path $path — resource still present"
            fi
         else
            kept=$(( kept + 1 ))
         fi
      done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
   done
}

# ------------------------------------------------------------------- prune ---
# Drop lease/activity state whose target no longer exists. Path leases record
# their target as file content, so no key decoding is involved.

prune_state() {
   local f key target
   for f in "$LEASE_DIR"/* "$ACT_DIR"/*; do
      [[ -e $f ]] || continue
      key=$(basename -- "$f"); key=${key%.total}; key=${key%.seen}
      case $key in
         vm-*)   [[ -e /etc/pve/qemu-server/${key#vm-}.conf ]] || rm -f -- "$f" ;;
         ct-*)   [[ -e /etc/pve/lxc/${key#ct-}.conf ]]        || rm -f -- "$f" ;;
         path-*) target=$(head -1 -- "$f" 2>/dev/null || true)
                 [[ -n $target && -e $target ]] || rm -f -- "$f" ;;
      esac
   done
}

# -------------------------------------------------------------------- main ---

log "--- run start (ttl=${TTL_HOURS}h activity>=${ACT_BYTES}B apply=${APPLY}) ---"
sweep_guests qemu /etc/pve/qemu-server vm
sweep_guests lxc  /etc/pve/lxc         ct
sweep_paths
prune_state
log "--- run end: reaped=${reaped} kept=${kept} ---"
REAPEREOF
    chmod 0755 "$REAPER"
}

# ---------------------------------------------------------------------------
# Agent-facing commands
# ---------------------------------------------------------------------------

install_agent_commands() {
    info "Installing $KEEPALIVE"
    cat > "$KEEPALIVE" <<'KEEPEOF'
#!/usr/bin/env bash
# aimee-keepalive — tell the reaper you are still using a test environment.
#
# Renewing slides the lease clock forward by a full TTL from NOW. Renew at any
# point and you get another full window; renewing at 3h into a 4h TTL gives the
# environment until 7h. There is no cap on how many times you may renew.
#
# IMPORTANT: a lease does NOT make an environment immortal. The reaper applies
# two clocks and destroys on either. Renewing satisfies the lease clock only;
# if the guest shows no measurable activity for a full TTL it is reaped anyway.
# Keep your test actually doing work, or accept that an idle box goes away.
#
# Usage:
#   aimee-keepalive vm:101 ct:200 /tmp/my-scratch
#   aimee-keepalive 101                 # numeric ID, auto-detected
set -uo pipefail

CONF=/etc/aimee-reaper.conf
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"

TTL_HOURS="${REAP_TTL_HOURS:-4}"
LEASE_DIR="${REAP_LEASE_DIR:-/var/lib/aimee-reaper/leases}"
LOG="${REAP_LOG:-/var/log/aimee-reaper.log}"
TTL_SEC=$(( TTL_HOURS * 3600 ))

if (( $# == 0 )); then
   sed -n '2,20p' "$0" | sed 's/^# \?//'
   exit 2
fi

mkdir -p "$LEASE_DIR"
path_key() { printf 'path-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }

rc=0
for target in "$@"; do
   key=""; label=""; content=""

   case $target in
      vm:*) id=${target#vm:}
            [[ -e /etc/pve/qemu-server/$id.conf ]] || { echo "no such VM: $id" >&2; rc=1; continue; }
            key="vm-$id"; label="vm/$id"; content="vm:$id" ;;
      ct:*) id=${target#ct:}
            [[ -e /etc/pve/lxc/$id.conf ]] || { echo "no such CT: $id" >&2; rc=1; continue; }
            key="ct-$id"; label="ct/$id"; content="ct:$id" ;;
      /*)   [[ -e $target ]] || { echo "no such path: $target" >&2; rc=1; continue; }
            key=$(path_key "$target"); label="path $target"; content="$target" ;;
      [0-9]*)
            if [[ -e /etc/pve/qemu-server/$target.conf ]]; then
               key="vm-$target"; label="vm/$target"; content="vm:$target"
            elif [[ -e /etc/pve/lxc/$target.conf ]]; then
               key="ct-$target"; label="ct/$target"; content="ct:$target"
            else
               echo "no such guest: $target" >&2; rc=1; continue
            fi ;;
      *)    echo "unrecognised target '$target' (use vm:ID, ct:ID, an absolute path, or a numeric ID)" >&2
            rc=1; continue ;;
   esac

   printf '%s\n' "$content" >"$LEASE_DIR/$key"
   deadline=$(date -d "@$(( $(date +%s) + TTL_SEC ))" '+%Y-%m-%d %H:%M:%S')
   printf '%s renewed — lease clock now expires %s (still reaped sooner if idle %sh)\n' \
      "$label" "$deadline" "$TTL_HOURS"
   printf '%s KEEPALIVE %s by uid=%s deadline=%s\n' "$(date -Is)" "$label" "$(id -u)" "$deadline" >>"$LOG"
done
exit $rc
KEEPEOF
    chmod 0755 "$KEEPALIVE"

    info "Installing $STATUS"
    cat > "$STATUS" <<'STATUSEOF'
#!/usr/bin/env bash
# aimee-reap-status — show every reapable thing on this host and how long it has.
# Read-only: it never mutates lease or activity state.
set -uo pipefail

CONF=/etc/aimee-reaper.conf
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"

TTL_HOURS="${REAP_TTL_HOURS:-4}"
LEASE_DIR="${REAP_LEASE_DIR:-/var/lib/aimee-reaper/leases}"
ACT_DIR="${REAP_ACTIVITY_DIR:-/var/lib/aimee-reaper/activity}"
TTL_SEC=$(( TTL_HOURS * 3600 ))
NOW=$(date +%s)

mtime_of() { [[ -e $1 ]] && stat -c %Y -- "$1" || echo 0; }
path_key() { printf 'path-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }

keep_patterns() {
   case $1 in
      /root)    printf '%s\n' ${REAP_KEEP_root[@]+"${REAP_KEEP_root[@]}"} ;;
      /tmp)     printf '%s\n' ${REAP_KEEP_tmp[@]+"${REAP_KEEP_tmp[@]}"} ;;
      /var/tmp) printf '%s\n' ${REAP_KEEP_var_tmp[@]+"${REAP_KEEP_var_tmp[@]}"} ;;
      /opt)     printf '%s\n' ${REAP_KEEP_opt[@]+"${REAP_KEEP_opt[@]}"} ;;
      /srv)     printf '%s\n' ${REAP_KEEP_srv[@]+"${REAP_KEEP_srv[@]}"} ;;
   esac
}

dur() {  # seconds -> compact human form
   local s=$1
   (( s < 0 )) && { printf 'overdue'; return; }
   printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

printf 'TTL %sh — a thing dies when EITHER clock runs out.\n\n' "$TTL_HOURS"
printf '%-10s %-10s %-10s %s\n' TARGET IDLE-LEFT LEASE-LEFT DETAIL

found=0
for spec in "qemu /etc/pve/qemu-server vm" "lxc /etc/pve/lxc ct"; do
   read -r _kind dir pfx <<<"$spec"
   for conf in "$dir"/*.conf; do
      [[ -e $conf ]] || continue
      id=$(basename -- "$conf" .conf)
      [[ $id =~ ^[0-9]+$ ]] || continue
      key="$pfx-$id"
      born=$(grep -o 'ctime=[0-9]\+' -- "$conf" 2>/dev/null | head -1 | cut -d= -f2)
      [[ -n $born ]] || born=$(mtime_of "$conf")
      lastact=$(mtime_of "$ACT_DIR/$key.seen"); (( lastact == 0 )) && lastact=$born
      lease=$(mtime_of "$LEASE_DIR/$key")
      anchor=$born; (( lease > anchor )) && anchor=$lease
      printf '%-10s %-10s %-10s %s\n' "$pfx/$id" \
         "$(dur $(( TTL_SEC - (NOW - lastact) )))" \
         "$(dur $(( TTL_SEC - (NOW - anchor) )))" \
         "$( [[ $lease -gt 0 ]] && echo 'leased' || echo 'no lease' )"
      found=$(( found + 1 ))
   done
done

for root in ${REAP_ROOTS[@]+"${REAP_ROOTS[@]}"}; do
   [[ -d $root ]] || continue
   mapfile -t keep < <(keep_patterns "$root")
   while IFS= read -r -d '' path; do
      base=$(basename -- "$path"); skip=0
      for pat in ${keep[@]+"${keep[@]}"}; do
         [[ -n $pat && $base == $pat ]] && { skip=1; break; }
      done
      (( skip )) && continue
      key=$(path_key "$path")
      mt=$(mtime_of "$path"); lease=$(mtime_of "$LEASE_DIR/$key")
      anchor=$mt; (( lease > anchor )) && anchor=$lease
      printf '%-10s %-10s %-10s %s\n' 'path' '-' \
         "$(dur $(( TTL_SEC - (NOW - anchor) )))" "$path"
      found=$(( found + 1 ))
   done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
done

(( found == 0 )) && printf '\n(host is clean — nothing reapable)\n'
printf '\nRenew with: aimee-keepalive vm:ID | ct:ID | /abs/path\nLog: %s\n' "${REAP_LOG:-/var/log/aimee-reaper.log}"
STATUSEOF
    chmod 0755 "$STATUS"
}

# ---------------------------------------------------------------------------
# Host policy
# ---------------------------------------------------------------------------

install_policy() {
    info "Installing $POLICY"
    cat > "$POLICY" <<'POLICYEOF'
# Test Host .252 Rules

## Mandatory cleanup

This host is temporary test infrastructure. If you create an environment or any
resource in order to test something, you **MUST clean it up before the task is
considered complete**.

- Arrange cleanup before starting the test (for example, with a teardown step or
  an exit trap) so it also runs after failures and interruptions.
- Remove everything the test created, including working directories, containers
  or VMs, images, volumes, networks, services, processes, packages, databases,
  users, caches, configuration, state, and temporary files.
- Verify that the created resources are gone after cleanup. A successful test
  does not waive this requirement.
- Clean up only resources created by your test. Never use broad process-kill or
  deletion patterns that could affect resources you do not own. Track and stop
  only your own PIDs and resources.
- If cleanup cannot be completed, do not report the task as finished. Report the
  exact remaining resources and the reason they could not be removed, and record
  them in `/var/log/aimee-reaper.log` so host operators can see them.

## Always build a fresh environment

**Never adopt an environment you find already running here.** Anything you did
not create yourself is, by definition, someone else's litter or a leftover that
is already on death row — it may be destroyed underneath you at any moment, mid
test, with no warning. Create your own VM, container, or working directory,
use it, and destroy it when you are done.

## The reaper

A sweep runs **every hour** (`aimee-reaper.timer`) and destroys abandoned test
environments. It applies **two independent clocks** to every VM and container,
and destroys the guest when **either** one runs out:

| Clock | Runs out after | Reset by |
|---|---|---|
| **Liveness** | 4h with no measurable activity | the guest actually doing work |
| **Lease** | 4h since creation or last renewal | `aimee-keepalive` |

"Measurable activity" means at least **10 MiB** of combined disk read + disk
write + network in + network out between two consecutive hourly samples. A
stopped guest is never active. Because the sweep is hourly, an abandoned guest
dies within **4–5 hours**.

Scratch paths under `/tmp`, `/var/tmp`, `/opt`, `/srv` and `/root` are swept on
the same 4h clock, using file mtime as their activity signal.

### Extending a long-running test

Renewing slides the lease clock a **full 4h from the moment you renew**, so
renewing at 3h buys you until 7h. There is **no cap** on renewals — long-running
tests are explicitly allowed, provided you keep renewing.

    aimee-keepalive vm:101          # a VM
    aimee-keepalive ct:200          # a container
    aimee-keepalive /tmp/my-build   # a scratch directory
    aimee-keepalive 101             # numeric ID, auto-detected

Renew on a comfortable margin — every 2h for a 4h TTL — so a slow step never
straddles the deadline. In a long test, renew from the test loop itself:

    while :; do aimee-keepalive vm:101; sleep 7200; done &

**A lease is not immortality.** It resets the lease clock only. If your guest
sits idle for 4h it is destroyed regardless of how recently you renewed, because
an idle box is indistinguishable from an abandoned one. Keep the work running,
or let it go.

### Seeing what is at risk

    aimee-reap-status               # everything reapable, with time left on both clocks

Never disable the timer to protect your work. If you genuinely need a permanent
fixture, add its ID to `REAP_PROTECTED_VMIDS` in `/etc/aimee-reaper.conf` and
tell an operator, so the exemption is visible rather than hidden.

### Parameters

All of it is configured in `/etc/aimee-reaper.conf` (`REAP_TTL_HOURS`,
`REAP_ACTIVITY_BYTES`, `REAP_ROOTS`, the per-root keep-lists, and
`REAP_PROTECTED_VMIDS`). Every action, and every keepalive, is logged with a
timestamp to `/var/log/aimee-reaper.log`.
POLICYEOF
    chmod 0644 "$POLICY"

    # Claude-based tooling reads CLAUDE.md; point it at the same rules. A real
    # symlink, not an import line, so it cannot drift from AGENTS.md.
    ln -sfn AGENTS.md /root/CLAUDE.md
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

install_systemd() {
    info "Installing systemd units"
    mkdir -p "$STATE_DIR/leases" "$STATE_DIR/activity"
    touch "$LOG"

    cat > /etc/systemd/system/aimee-reaper.service <<'EOF'
[Unit]
Description=Reap abandoned test environments on the .252 test host
Documentation=file:/root/AGENTS.md
After=pve-guests.service
Wants=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aimee-reaper
Nice=10
TimeoutStartSec=900
EOF

    cat > /etc/systemd/system/aimee-reaper.timer <<'EOF'
[Unit]
Description=Hourly sweep for abandoned test environments

[Timer]
# Hourly. Activity is sampled on each run, so a 4h TTL sees four samples before
# anything is destroyed, and an abandoned guest dies within TTL + 1h worst case.
OnCalendar=hourly
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now aimee-reaper.timer
}

# ---------------------------------------------------------------------------
# Postchecks
# ---------------------------------------------------------------------------

postchecks() {
    info "Running postchecks"
    bash -n "$REAPER"    || err "$REAPER has a syntax error"
    bash -n "$KEEPALIVE" || err "$KEEPALIVE has a syntax error"
    bash -n "$STATUS"    || err "$STATUS has a syntax error"

    # A dry run must succeed and must never destroy anything.
    "$REAPER" --dry-run || err "dry run failed"

    systemctl is-enabled aimee-reaper.timer >/dev/null || err "timer not enabled"
    systemctl is-active  aimee-reaper.timer >/dev/null || err "timer not active"
    info "Postchecks passed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    prechecks
    install_config
    install_reaper
    install_agent_commands
    install_policy
    install_systemd
    postchecks

    cat <<EOF

================================================================
Test-environment reaper is armed on $(hostname).

Sweep:   hourly (aimee-reaper.timer), TTL 4h
Policy:  $POLICY (CLAUDE.md symlinks to it)
Log:     $LOG
Config:  $CONF

Agents renew a lease with:  aimee-keepalive vm:ID | ct:ID | /abs/path
Agents check exposure with: aimee-reap-status

A guest dies when EITHER clock runs out: no measurable activity for the
TTL, or no creation/renewal within the TTL. A lease is not immortality.
================================================================
EOF
}

main "$@"
