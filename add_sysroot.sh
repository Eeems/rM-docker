#!/bin/sh

set -eux

SYSROOT="$1"
SYSROOTFS="$2"

if ! [ -f "$SYSROOTFS" ]; then
  echo "${SYSROOTFS} not found"
  exit 1
fi
IP="$(ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')"
PORT=2999

conf_path="$(mktemp --suffix=.conf)"
log_path="$(mktemp --suffix=.log)"
exclude_path="$(mktemp --suffix=.exclude)"
script_path="$(mktemp --suffix=.sh)"
trap 'rm -f -- "$conf_path" "$log_path" "$exclude_path" "$script_path"' EXIT

cat <<EOF > "$script_path"
#!/bin/sh
set -e
chroot_path="\$(mktemp -d)"
trap 'grep "\$chroot_path" /proc/mounts | cut -d" " -f2 | xargs -r umount -ql && rmdir "\$chroot_path"' EXIT
src_path=/home/root/.local/share/sysroot
mount --bind "\$src_path" "\$chroot_path"
mount -t proc /proc "\${chroot_path}/proc"
mount --rbind /sys "\${chroot_path}/sys"
mount --rbind /dev "\${chroot_path}/dev"
mount -t tmpfs tmpfs "\${chroot_path}/tmp"
mount -t tmpfs tmpfs "\${chroot_path}/run"
mount -t tmpfs tmpfs "\${chroot_path}/var/volatile"
mount --bind /home "\${chroot_path}/home"
if [ -d /home/root/.entware ]; then
  mkdir -p opt
  mount --bind /home/root/.entware "\${chroot_path}/opt"
fi

rsync -a /bin/. "\${chroot_path}/bin"
rsync -a /lib/. "\${chroot_path}/lib"
rsync -a /usr/bin/. "\${chroot_path}/usr/bin"
rsync -a /usr/lib/. "\${chroot_path}/usr/lib"
cp /etc/resolv.conf "\${chroot_path}/etc/resolv.conf"
rsync -avh --devices --specials /run/systemd/resolve "\${chroot_path}/run/systemd"

chroot "\$chroot_path" bash -l
EOF

cat <<EOF > "$exclude_path"
etc/cups/ssl
home/root
etc/gshadow
etc/passwd-
etc/securetty
etc/shadow
etc/cups/cups-files.conf
etc/cups/cups-files.conf.default
etc/cups/cupsd.conf
etc/cups/cupsd.conf.default
etc/cups/snmp.conf
etc/cups/snmp.conf.default
usr/libexec/cups/backend/ipp
usr/libexec/cups/backend/lpd
usr/sbin/cupsd
usr/share/polkit-1/rules.d/***
var/cache/cups/***
var/spool/cups/***
EOF

cat <<EOF > "$conf_path"
port = ${PORT}
address = ${IP}
log file = ${log_path}

[sysroot]
  path = ${SYSROOT}
  use chroot = false
  read only = true
  exclude from = ${exclude_path}
EOF

rsync \
  --daemon \
  --no-detach \
  --config="$conf_path" &
rsync_pid=$!

sleep 1

if ! kill -0 "$rsync_pid"; then
  echo "Failed to start rsync:"
  cat "$log_path"
  exit 1
fi

trap 'kill "$rsync_pid"; cat "$log_path"' EXIT

guestfish --rw --blocksize=512 --add "$SYSROOTFS" <<GFS
set-network true
run

mount /dev/sda2 /
mount /dev/sda4 /home

mkdir-p /home/root/.local/share/sysroot
mkdir-p /home/root/.local/bin

rsync-in rsync://root@${IP}:${PORT}/sysroot /home/root/.local/share/sysroot archive:true
upload ${script_path} /home/root/.local/bin/sysfs_chroot
write-append /home/root/.bashrc "PATH=$PATH:~/.local/bin"
write-append /home/root/.bashrc ""
GFS
