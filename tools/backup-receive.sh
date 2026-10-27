#!/bin/bash
# The far side of tools/backup.sh. Installed on the backup destination and wired
# into authorized_keys as a forced command:
#
#   restrict,command="/usr/local/sbin/bunk-backup-receive" ssh-ed25519 AAAA… bunk-backup
#
# That is the whole point of this file. The machine taking backups holds a key to
# the machine storing them, and if the first is compromised the second must not
# be. With a forced command the key can do exactly one thing: append a blob. It
# cannot list, read, delete or get a shell — so an attacker on the control plane
# can neither retrieve old backups nor destroy them.
#
# The blob is already encrypted to a certificate whose private key is not here
# either, so this host stores something it cannot read. That is deliberate: it
# means the destination does not have to be trusted, which is what allows the
# archive to eventually live on hardware we do not own.
set -euo pipefail

DEST="${BUNK_BACKUP_DIR:-/var/backups/bunk}"
MIN_AGE_DAYS="${BUNK_BACKUP_MIN_AGE_DAYS:-30}"
MAX_FILES="${BUNK_BACKUP_MAX_FILES:-90}"
MAX_BYTES="${BUNK_BACKUP_MAX_BYTES:-2147483648}"   # 2 GiB

install -d -m 700 "$DEST"

# One upload at a time. Without it the file-count check below is check-then-act,
# and parallel connections could each write up to MAX_BYTES at once.
exec 9>"$DEST/.lock"
flock 9

# The client passes the filename as the (forced-away) command line. Take only the
# exact shape tools/backup.sh produces, never a path: this input comes from a
# host we are defending against.
raw="${SSH_ORIGINAL_COMMAND:-}"
name="$(basename -- "$raw")"
[[ "$name" =~ ^bunk-[0-9]{8}T[0-9]{6}Z\.tar\.zst\.enc$ ]] || {
  echo "refusing name: $raw" >&2; exit 2;
}

# A full store refuses instead of rotating. Rotating here is what let the sender
# delete history: enough uploads pushed every genuine archive out of a
# "keep the newest N" window. A flood now makes the next real backup fail --
# loud, and recoverable -- instead of erasing the ones that already exist.
count=$(find "$DEST" -maxdepth 1 -name 'bunk-*.tar.zst.enc' | wc -l)
[ "$count" -lt "$MAX_FILES" ] || {
  echo "refusing upload: store already holds $count archives (cap $MAX_FILES)" >&2; exit 6;
}

# Append-only means append-only. Without this, a key that cannot delete can
# still overwrite yesterday's backup with a byte of garbage under the same name,
# which destroys it just as thoroughly.
[ -e "$DEST/$name" ] && { echo "refusing to overwrite $name" >&2; exit 5; }

tmp="$(mktemp "$DEST/.incoming.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"

# head -c bounds the write: an attacker with the key should not be able to fill
# the disk that holds every other backup.
head -c "$MAX_BYTES" > "$tmp"
size=$(stat -c %s "$tmp")
[ "$size" -gt 0 ] || { echo "empty upload" >&2; exit 3; }
[ "$size" -lt "$MAX_BYTES" ] || { echo "upload hit the $MAX_BYTES byte cap" >&2; exit 4; }

# -n: two uploads racing the same name must not both "succeed".
mv -n "$tmp" "$DEST/$name"
[ -e "$tmp" ] && { echo "refusing to overwrite $name" >&2; exit 5; }
trap - EXIT
chmod 400 "$DEST/$name"

echo "stored $name ($size bytes, sha256 $(sha256sum "$DEST/$name" | cut -c1-16)…)"

# Retention by arrival time: the mtime this host gave each file when it arrived,
# something the sender cannot set. No number of uploads can make a young archive
# old, so nothing younger than MIN_AGE_DAYS is ever removed.
#
# Age alone is not enough, though. An attacker who holds the control plane can
# stop the real backups, wait MIN_AGE_DAYS and upload once: every genuine archive
# is old by then. So the last arrival of each calendar month is kept for
# KEEP_MONTHS months. Uploads from an attacker arrive after the compromise, so
# the months before it keep a genuine archive whatever the sender does.
KEEP_MONTHS="${BUNK_BACKUP_KEEP_MONTHS:-12}"
now=$(date +%s)
declare -A monthly
find "$DEST" -maxdepth 1 -name 'bunk-*.tar.zst.enc' -printf '%T@ %p\n' | sort -rn |
  while read -r mtime old; do
    age_days=$(( (now - ${mtime%.*}) / 86400 ))
    [ "$age_days" -ge "$MIN_AGE_DAYS" ] || continue
    month=$(date -d "@${mtime%.*}" +%Y-%m)
    if [ "$age_days" -lt "$((KEEP_MONTHS * 31))" ] && [ -z "${monthly[$month]:-}" ]; then
      monthly[$month]=1
      continue
    fi
    echo "pruning $(basename "$old")"
    rm -f -- "$old"
  done
