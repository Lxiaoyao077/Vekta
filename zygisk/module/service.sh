# Extract the directory path and change directory 
MODDIR="${0%/*}"
cd "$MODDIR" || exit 1

# A root manager runs this script with its own busybox, but a manual bootstrap has nothing in
# front of it except Android's utilities, so this is written for toybox's unshare: it makes a
# mount namespace with -m and takes no propagation flag. The namespace therefore marks its own
# root slave before handing over, which is what keeps the daemon's dex2oat bind-mounts out of
# the global one.
unshare -m /system/bin/sh -c '
    mount -o rslave none / || echo "vector: this mount namespace stays shared" >&2
    exec "$0" "$@"
' "$MODDIR/daemon" "$@" &
