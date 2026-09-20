# DevOps Pre-Onboarding Practice — Journal

## Task 1 — Linux Foundations

**Date completed:** 2026-09-06  
**Host machine:** MacBook Pro  
**Lab VM:** `shopstack-lab`  
**VM platform:** Multipass 1.16.3+mac  
**Guest OS:** Ubuntu 24.04.4 LTS (Noble Numbat), aarch64  
**VM resources:** 2 vCPU, 4 GB RAM, 20 GB disk  
**Primary VM IPv4:** `192.168.252.2/24`

---

## Environment Setup

Multipass was not initially installed on the MacBook Pro.

```bash
multipass version
```

Initial result:

```text
zsh: command not found: multipass
```

I confirmed Homebrew was available:

```bash
brew --version
```

Result:

```text
Homebrew 6.0.19
```

I then installed Multipass:

```bash
brew install --cask multipass
multipass version
```

Result:

```text
multipass   1.16.3+mac
multipassd  1.16.3+mac
```

I created the lab VM and entered it:

```bash
multipass launch 24.04 \
  --name shopstack-lab \
  --cpus 2 \
  --memory 4G \
  --disk 20G

multipass shell shopstack-lab
```

I waited for first-boot initialization to finish before continuing:

```bash
cloud-init status --wait
cloud-init status
```

Result:

```text
status: done
```

I verified the host details:

```bash
hostname
uname -a
cat /etc/os-release
```

Key result:

```text
Hostname: shopstack-lab
Ubuntu 24.04.4 LTS (Noble Numbat)
Architecture: aarch64
```

---

# 4.1 Users, Groups, and Permissions

## 4.1.1 Create `deploy` and `shopstack`

I created the shared group and the deployment user with a home directory and Bash shell, then added the user to the group.

```bash
sudo groupadd shopstack
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG shopstack deploy

id deploy
getent group shopstack
ls -ld /home/deploy
```

Key results:

```text
uid=1001(deploy) gid=1002(deploy) groups=1002(deploy),1001(shopstack)
shopstack:x:1001:deploy
drwxr-x--- ... deploy deploy ... /home/deploy
```

This confirmed that:

- `deploy` has its own home directory.
- Its login shell is Bash.
- `deploy` is a member of the supplementary group `shopstack`.

---

## 4.1.2 `/opt/shopstack`, Ownership, and setgid

I created the shared application directory and applied the required owner, group, and permission mode.

```bash
sudo mkdir -p /opt/shopstack
sudo chown deploy:shopstack /opt/shopstack
sudo chmod 2770 /opt/shopstack

ls -ld /opt/shopstack
```

Result:

```text
drwxrws--- ... deploy shopstack ... /opt/shopstack
```

### Meaning of `2770`

The normal permission part, `770`, means:

- owner: `rwx`
- group: `rwx`
- others: `---`

The leading `2` sets the **setgid bit** on the directory. On a directory, setgid causes newly created files and subdirectories to inherit the directory's group rather than the creator's primary group.

I verified this by creating a file as `deploy`:

```bash
sudo -u deploy touch /opt/shopstack/testfile.txt
sudo -u deploy sh -c \
  'echo "ShopStack confidential test data" > /opt/shopstack/testfile.txt'

sudo ls -l /opt/shopstack/testfile.txt
```

Result:

```text
-rw-rw-r-- 1 deploy shopstack ... /opt/shopstack/testfile.txt
```

Although `deploy` has primary group `deploy`, the file inherited group `shopstack`.

### Why setgid is useful for team directories

For a shared team directory, setgid keeps group ownership consistent automatically. Team members do not need to manually run `chgrp` after creating files, which reduces permission mistakes and makes collaboration more predictable.

---

## 4.1.3 Read-only `auditor` Access Using ACLs

I created the audit user:

```bash
sudo useradd -m -s /bin/bash auditor
id auditor
```

Result:

```text
uid=1002(auditor) gid=1003(auditor) groups=1003(auditor)
```

I installed ACL support:

```bash
sudo apt update
sudo apt install -y acl

command -v setfacl
command -v getfacl
```

Result:

```text
/usr/bin/setfacl
/usr/bin/getfacl
```

I applied read/traverse access to existing directories and read-only access to existing files, while removing permissions for `other`.

```bash
sudo find /opt/shopstack \
  -type d \
  -exec setfacl -m u:auditor:rx,o::--- {} +

sudo find /opt/shopstack \
  -type f \
  -exec setfacl -m u:auditor:r--,o::--- {} +
```

I then configured **default ACLs** so newly created files and directories would inherit appropriate auditor access.

```bash
sudo setfacl -m \
d:u::rwx,\
d:u:auditor:r-x,\
d:g::rwx,\
d:m::rwx,\
d:o::--- \
/opt/shopstack
```

Verification:

```bash
getfacl /opt/shopstack
```

Key result:

```text
user:auditor:r-x
other::---

default:user:auditor:r-x
default:other::---
```

### Existing-file test

```bash
sudo -u auditor cat /opt/shopstack/testfile.txt
```

Result:

```text
ShopStack confidential test data
```

Attempting to create or modify files failed:

```bash
sudo -u auditor touch /opt/shopstack/auditor-test.txt
```

```text
Permission denied
```

```bash
sudo -u auditor sh -c \
  'echo "HACKED" >> /opt/shopstack/testfile.txt'
```

```text
Permission denied
```

### Default ACL inheritance test

I created a new directory and file as `deploy`:

```bash
sudo -u deploy mkdir /opt/shopstack/reports

sudo -u deploy sh -c \
  'echo "September report" > /opt/shopstack/reports/september.txt'
```

I inspected the inherited ACLs:

```bash
sudo getfacl /opt/shopstack/reports
sudo getfacl /opt/shopstack/reports/september.txt
```

The new file showed:

```text
user:auditor:r-x        #effective:r--
other::---
```

The execute bit was masked on the regular file, so the effective auditor permission was read-only.

Auditor could read it:

```bash
sudo -u auditor cat /opt/shopstack/reports/september.txt
```

Result:

```text
September report
```

Auditor could not modify it:

```bash
sudo -u auditor sh -c \
  'echo "modified" >> /opt/shopstack/reports/september.txt'
```

Result:

```text
Permission denied
```

The unrelated `ubuntu` user also could not read the protected file:

```bash
cat /opt/shopstack/reports/september.txt
```

Result:

```text
Permission denied
```

This demonstrated read-only access for the named auditor without making the files world-readable.

---

## 4.1.4 Restricted Passwordless `sudo`

My lab admin user was:

```bash
whoami
```

Result:

```text
ubuntu
```

I confirmed the exact command paths:

```bash
command -v systemctl
command -v journalctl
```

Result:

```text
/usr/bin/systemctl
/usr/bin/journalctl
```

I audited the existing sudo configuration:

```bash
sudo -l
sudo -n true
echo $?

sudo grep -R "$ADMIN_USER" \
  /etc/sudoers /etc/sudoers.d/ 2>/dev/null
```

Multipass/cloud-init had created:

```text
ubuntu ALL=(ALL) NOPASSWD:ALL
```

This was broader than the task requirement.

Before restricting it, I set a normal password for the admin account as a safety measure:

```bash
sudo passwd "$ADMIN_USER"
```

I then created a dedicated sudoers rule:

```bash
printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl, /usr/bin/journalctl\n' \
"$ADMIN_USER" | \
sudo tee /etc/sudoers.d/91-shopstack-admin

sudo chmod 440 /etc/sudoers.d/91-shopstack-admin
sudo visudo -cf /etc/sudoers.d/91-shopstack-admin
```

Result:

```text
/etc/sudoers.d/91-shopstack-admin: parsed OK
```

I backed up and removed the unrestricted cloud-init rule:

```bash
sudo cp \
/etc/sudoers.d/90-cloud-init-users \
/root/90-cloud-init-users.backup

sudo sed -i \
"/^${ADMIN_USER} ALL=.*NOPASSWD: *ALL$/d" \
/etc/sudoers.d/90-cloud-init-users
```

I validated the complete sudoers configuration:

```bash
sudo visudo -c
sudo -l
```

Result:

```text
(ALL : ALL) ALL
(root) NOPASSWD: /usr/bin/systemctl, /usr/bin/journalctl
```

### Positive tests

```bash
sudo -k
sudo -n /usr/bin/systemctl --version
echo $?
```

Result:

```text
0
```

```bash
sudo -k
sudo -n /usr/bin/journalctl --version
echo $?
```

Result:

```text
0
```

### Negative test

```bash
sudo -k
sudo -n /usr/bin/id
echo $?
```

Result:

```text
sudo: a password is required
1
```

Normal authenticated sudo still worked:

```bash
sudo -k
sudo id
```

Result after password entry:

```text
uid=0(root) gid=0(root) groups=0(root)
```

### Why `NOPASSWD: ALL` is discouraged

`NOPASSWD: ALL` allows the account to run any command as root without authentication. If that account or session is compromised, the attacker immediately gains unrestricted root access. Limiting passwordless sudo reduces the attack surface and blast radius according to the principle of least privilege.

The task specifically required passwordless `systemctl` and `journalctl`. In a real production environment I would consider restricting `systemctl` further to specific services and actions because `systemctl` itself is a powerful privileged interface.

---

# 4.2 Processes, Services, and Logs

## 4.2.1 Heartbeat Script

I created the log file and assigned it to the service account/group:

```bash
sudo touch /var/log/shopstack-pulse.log
sudo chown deploy:shopstack /var/log/shopstack-pulse.log
sudo chmod 640 /var/log/shopstack-pulse.log
```

I created `/opt/shopstack/pulse.sh`:

```bash
sudo -u deploy tee /opt/shopstack/pulse.sh > /dev/null <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="/var/log/shopstack-pulse.log"

while true; do
    MESSAGE="$(date --iso-8601=seconds) ShopStack heartbeat"
    echo "$MESSAGE" | tee -a "$LOG_FILE"
    sleep 10
done
EOF

sudo chmod 750 /opt/shopstack/pulse.sh
sudo ls -l /opt/shopstack/pulse.sh
```

I tested it manually:

```bash
sudo -u deploy /opt/shopstack/pulse.sh
```

Observed output:

```text
2026-09-06T17:52:32+08:00 ShopStack heartbeat
2026-09-06T17:52:42+08:00 ShopStack heartbeat
2026-09-06T17:52:52+08:00 ShopStack heartbeat
```

I stopped the manual test with `Ctrl+C` and checked the file log:

```bash
sudo tail /var/log/shopstack-pulse.log
```

The same heartbeat lines were present, confirming that the script appended a timestamped line every 10 seconds.

---

## 4.2.2 `shopstack-pulse.service`

I created the systemd unit:

```ini
[Unit]
Description=ShopStack Pulse Heartbeat Service
After=network.target

[Service]
Type=simple
User=deploy
Group=shopstack
ExecStart=/opt/shopstack/pulse.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Installed with:

```bash
cat <<'EOF' | sudo tee /etc/systemd/system/shopstack-pulse.service
[Unit]
Description=ShopStack Pulse Heartbeat Service
After=network.target

[Service]
Type=simple
User=deploy
Group=shopstack
ExecStart=/opt/shopstack/pulse.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

### `start`

```bash
sudo systemctl start shopstack-pulse.service
sudo systemctl status shopstack-pulse.service
```

Result:

```text
Active: active (running)
Main PID: 2304
```

### `stop`

```bash
sudo systemctl stop shopstack-pulse.service
sudo systemctl status shopstack-pulse.service
```

Result:

```text
Active: inactive (dead)
```

The journal also showed:

```text
shopstack-pulse.service: Deactivated successfully.
Stopped shopstack-pulse.service
```

### `restart`

I started the service again and captured its PID:

```bash
sudo systemctl start shopstack-pulse.service

systemctl show -p MainPID --value \
shopstack-pulse.service
```

Before restart:

```text
2334
```

Then:

```bash
sudo systemctl restart shopstack-pulse.service

systemctl show -p MainPID --value \
shopstack-pulse.service
```

After restart:

```text
2357
```

The PID change confirmed that the service process was restarted.

### `status`

```bash
sudo systemctl status shopstack-pulse.service
```

Result:

```text
Active: active (running)
Main PID: 2357
```

### `enable`

```bash
sudo systemctl enable shopstack-pulse.service
systemctl is-enabled shopstack-pulse.service

ls -l \
/etc/systemd/system/multi-user.target.wants/shopstack-pulse.service
```

Result:

```text
enabled
```

Systemd created the expected symlink:

```text
.../multi-user.target.wants/shopstack-pulse.service
 -> /etc/systemd/system/shopstack-pulse.service
```

Later, after a VM reboot during the storage task, I verified:

```bash
systemctl is-active shopstack-pulse.service
```

Result:

```text
active
```

This provided additional proof that the enabled service started on boot.

---

## 4.2.3 Inspecting Logs with `journalctl`

I inspected recent service logs:

```bash
sudo journalctl \
-u shopstack-pulse.service \
-n 10 \
--no-pager
```

The journal showed heartbeat lines every 10 seconds.

I then captured a specific starting time:

```bash
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
echo "$SINCE"
```

Result:

```text
2026-09-06 17:56:31
```

After waiting:

```bash
sleep 12
```

I filtered the journal:

```bash
sudo journalctl \
-u shopstack-pulse.service \
--since "$SINCE" \
--no-pager
```

Result began after the requested timestamp:

```text
Sep 06 17:56:35 ... ShopStack heartbeat
Sep 06 17:56:45 ... ShopStack heartbeat
Sep 06 17:56:55 ... ShopStack heartbeat
```

This demonstrated time-window filtering for incident investigation.

---

## 4.2.4 Manual Process Kill and Automatic Restart

I found the service process:

```bash
pgrep -af '/opt/shopstack/pulse.sh'
```

Result:

```text
2357 bash /opt/shopstack/pulse.sh
```

I recorded and verified the old main PID:

```bash
OLD_PID=$(systemctl show \
-p MainPID \
--value shopstack-pulse.service)

echo "Old PID: $OLD_PID"
ps -fp "$OLD_PID"
```

Result:

```text
Old PID: 2357
deploy 2357 ... bash /opt/shopstack/pulse.sh
```

I force-killed the process to simulate a crash:

```bash
sudo kill -9 "$OLD_PID"
sleep 3
```

I then captured the new PID:

```bash
NEW_PID=$(systemctl show \
-p MainPID \
--value shopstack-pulse.service)

echo "New PID: $NEW_PID"
```

Result:

```text
New PID: 2499
```

Systemd status showed the service running again:

```text
Active: active (running)
Main PID: 2499
```

I verified the restart in the journal:

```bash
sudo journalctl \
-u shopstack-pulse.service \
--since "2 minutes ago" \
--no-pager
```

Key evidence:

```text
Main process exited, code=killed, status=9/KILL
Failed with result 'signal'.
Scheduled restart job, restart counter is at 1.
Started shopstack-pulse.service
```

The service then resumed heartbeat logging. This demonstrated automatic recovery through `Restart=always`.

---

# 4.3 Networking and Firewall

## 4.3.1 IP Addresses, Default Gateway, and DNS

### IP addresses

```bash
ip addr
ip -br addr
```

Key result:

```text
lo      127.0.0.1/8
enp0s1  192.168.252.2/24
```

`127.0.0.1` is the loopback interface used for communication with the local machine itself.

`192.168.252.2/24` is the VM's IPv4 address on the Multipass virtual network. `/24` corresponds to the subnet mask `255.255.255.0`.

### Default gateway

```bash
ip route
ip route show default
```

Result:

```text
default via 192.168.252.1 dev enp0s1 proto dhcp src 192.168.252.2 metric 100
```

The default gateway `192.168.252.1` is the next-hop router used when the destination is outside the directly connected local subnet.

### DNS

```bash
resolvectl status
resolvectl dns
cat /etc/resolv.conf
```

Key result:

```text
Current DNS Server: 192.168.252.1
DNS Servers: 192.168.252.1 ...
```

`/etc/resolv.conf` contained:

```text
nameserver 127.0.0.53
```

`127.0.0.53` is the local `systemd-resolved` stub resolver. Applications can query this local resolver, which then forwards requests to the upstream DNS server such as `192.168.252.1`.

---

## 4.3.2 HTTP Server on Port 8080

I created a basic test site:

```bash
mkdir -p ~/shopstack-web

echo "ShopStack HTTP test" \
> ~/shopstack-web/index.html

cd ~/shopstack-web
```

In Terminal A I started the HTTP server:

```bash
python3 -m http.server 8080
```

Result:

```text
Serving HTTP on 0.0.0.0 port 8080
```

In Terminal B I verified that the socket was listening:

```bash
ss -tlnp | grep 8080
```

Result:

```text
LISTEN ... 0.0.0.0:8080 ... python3
```

I tested loopback access:

```bash
curl http://127.0.0.1:8080
```

Result:

```text
ShopStack HTTP test
```

I then identified the VM address and tested it:

```bash
VM_IP=$(hostname -I | awk '{print $1}')
echo "$VM_IP"

curl "http://${VM_IP}:8080"
```

Result:

```text
192.168.252.2
ShopStack HTTP test
```

The Python server logs recorded successful HTTP `200` requests.

---

## 4.3.3 UFW Firewall

Initial status:

```bash
sudo ufw status verbose
```

Result:

```text
Status: inactive
```

I explicitly configured the default policies:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

I allowed only SSH and the application test port:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 8080/tcp
sudo ufw show added
```

Configured rules:

```text
ufw allow 22/tcp
ufw allow 8080/tcp
```

I enabled UFW:

```bash
sudo ufw enable
sudo ufw status numbered
```

Result:

```text
Status: active

22/tcp        ALLOW IN    Anywhere
8080/tcp      ALLOW IN    Anywhere
22/tcp (v6)   ALLOW IN    Anywhere (v6)
8080/tcp (v6) ALLOW IN    Anywhere (v6)
```

### Allowed-port proof from another machine

From the MacBook Pro host I first made a command-entry mistake:

```bash
curl --max-time 5 http://VM_IP:8080
```

Result:

```text
curl: (6) Could not resolve host: VM_IP
```

`VM_IP` was a placeholder rather than a shell variable in that host terminal. I corrected the command using the actual VM address:

```bash
curl --max-time 5 http://192.168.252.2:8080
```

Result:

```text
ShopStack HTTP test
```

This proved that inbound TCP/8080 was reachable from outside the VM.

### Blocked-port proof

Inside the VM I intentionally started another HTTP server on port 9090 without adding a UFW allow rule:

```bash
python3 -m http.server 9090 \
--directory ~/shopstack-web \
>/tmp/shopstack-9090.log 2>&1 &

HTTP9090_PID=$!
echo "$HTTP9090_PID"

ss -tlnp | grep 9090
```

Result confirmed a listener:

```text
LISTEN ... 0.0.0.0:9090 ... python3
```

I verified locally that the application itself worked:

```bash
curl --max-time 5 \
http://127.0.0.1:9090
```

Result:

```text
ShopStack HTTP test
```

From the MacBook host:

```bash
curl --max-time 5 \
http://192.168.252.2:9090
```

Result:

```text
curl: (28) Connection timed out after 5006 milliseconds
```

Because port 9090 had a confirmed listening service but was unreachable from the host, this demonstrated that UFW was blocking inbound traffic that was not explicitly allowed.

I later stopped the temporary server:

```bash
kill "$HTTP9090_PID"
```

---

## 4.3.4 DNS Resolution

I confirmed the DNS lookup tools:

```bash
command -v dig
command -v nslookup
```

I resolved `kubernetes.io`:

```bash
dig kubernetes.io
```

Result:

```text
status: NOERROR
ANSWER: 2
```

Example resolved addresses:

```text
3.33.186.135
15.197.167.90
```

I resolved `istio.io`:

```bash
dig istio.io
```

Result:

```text
status: NOERROR
ANSWER: 1
75.2.60.5
```

I then intentionally queried a reserved invalid domain:

```bash
dig definitely-does-not-exist.shopstack.invalid
```

Result:

```text
status: NXDOMAIN
ANSWER: 0
```

### Meaning of the error

`NXDOMAIN` means **Non-Existent Domain**. The DNS query itself reached a working DNS resolver successfully, but the resolver replied that the requested name does not exist.

This differs from errors such as a timeout or `SERVFAIL`, which can indicate connectivity, resolver, or upstream DNS problems.

I cleaned up the temporary HTTP services and verified that ports 8080 and 9090 were no longer listening:

```bash
ss -tlnp | \
grep -E ':8080|:9090' || \
echo "Temporary HTTP servers stopped"
```

Result:

```text
Temporary HTTP servers stopped
```

---

# 4.4 Storage and Scripting Warm-up

## 4.4.1 1 GB File-backed Loop Device

I verified the required tools and current disk layout:

```bash
command -v losetup
command -v mkfs.ext4
command -v findmnt
command -v lsblk
lsblk
```

The main VM disk was `sda`, with the root filesystem on `sda1`. I did not modify its partition table.

### Create the backing file

```bash
sudo mkdir -p /var/lib/shopstack

sudo fallocate \
-l 1G \
/var/lib/shopstack/practice.img

ls -lh /var/lib/shopstack/practice.img
du -h /var/lib/shopstack/practice.img
```

Result:

```text
/var/lib/shopstack/practice.img
Apparent size: 1.0G
```

### Attach as a loop device

```bash
LOOP_DEV=$(sudo losetup \
--find \
--show \
/var/lib/shopstack/practice.img)

echo "$LOOP_DEV"

sudo losetup -l
lsblk
```

Result:

```text
/dev/loop0
```

The loop device mapped to:

```text
/var/lib/shopstack/practice.img
```

### Format as ext4

```bash
sudo mkfs.ext4 "$LOOP_DEV"

lsblk -f "$LOOP_DEV"
sudo blkid "$LOOP_DEV"
```

Result:

```text
TYPE="ext4"
UUID="3d70f29a-c92f-4168-a363-88e965b0f8bb"
```

### Mount at `/mnt/practice`

```bash
sudo mkdir -p /mnt/practice
sudo mount "$LOOP_DEV" /mnt/practice

findmnt /mnt/practice
df -h /mnt/practice
```

Result:

```text
/mnt/practice /dev/loop0 ext4 rw,relatime
/dev/loop0 974M ... /mnt/practice
```

### Persistent `/etc/fstab` configuration

I backed up `/etc/fstab` first:

```bash
sudo cp /etc/fstab /etc/fstab.backup
```

Then added:

```bash
echo '/var/lib/shopstack/practice.img /mnt/practice ext4 loop,defaults 0 2' \
| sudo tee -a /etc/fstab

tail -n 5 /etc/fstab
sudo systemctl daemon-reload
```

The final entry was:

```text
/var/lib/shopstack/practice.img /mnt/practice ext4 loop,defaults 0 2
```

Using the backing-file path with the `loop` mount option allows `mount` to create the loop mapping automatically instead of relying on a fixed `/dev/loopN` number.

### Test `fstab` before reboot

I unmounted the filesystem and removed the manually attached loop device:

```bash
sudo umount /mnt/practice
findmnt /mnt/practice

sudo losetup -d "$LOOP_DEV"
sudo losetup -l
```

I then mounted using only the `/etc/fstab` entry:

```bash
sudo mount /mnt/practice

findmnt /mnt/practice
df -h /mnt/practice
sudo losetup -l
```

Result:

```text
/mnt/practice /dev/loop0 ext4 rw,relatime
```

`losetup` showed the loop device pointing to the backing file with `AUTOCLEAR=1`.

### Reboot persistence test

I rebooted the VM:

```bash
sudo reboot
```

After reconnecting, without manually mounting anything:

```bash
findmnt /mnt/practice
df -h /mnt/practice
sudo losetup -l
```

Result:

```text
/mnt/practice /dev/loop0 ext4 rw,relatime
/dev/loop0 -> /var/lib/shopstack/practice.img
```

This proved that the filesystem survived reboot through `/etc/fstab`.

I also checked:

```bash
systemctl is-active \
shopstack-pulse.service
```

Result:

```text
active
```

This provided additional evidence that the systemd service configured earlier also started automatically after reboot.

---

## 4.4.2 Disk Usage Investigation and Cleanup

I created a controlled test directory:

```bash
sudo mkdir -p \
/mnt/practice/fill-test

sudo chown \
"$USER":"$USER" \
/mnt/practice/fill-test
```

I created an 850 MB test file:

```bash
fallocate \
-l 850M \
/mnt/practice/fill-test/bigfile.bin
```

I checked filesystem usage with `df`:

```bash
df -h /mnt/practice
```

Result:

```text
/dev/loop0 974M 851M 57M 94% /mnt/practice
```

This pushed the filesystem above the required 90% threshold.

### Find the largest consumers with `du`

```bash
du -ah /mnt/practice/fill-test \
| sort -rh \
| head -10
```

Result:

```text
851M /mnt/practice/fill-test/bigfile.bin
851M /mnt/practice/fill-test
```

### `ncdu`

```bash
command -v ncdu
```

There was no output, so `ncdu` was not installed. The task specified `ncdu` only **if available**, so I recorded this and continued without installing it.

### Cleanup

```bash
rm \
/mnt/practice/fill-test/bigfile.bin

df -h /mnt/practice

du -ah /mnt/practice/fill-test \
| sort -rh \
| head -10
```

Result:

```text
/dev/loop0 ... 1% /mnt/practice
4.0K /mnt/practice/fill-test
```

The filesystem returned from 94% usage to 1%.

---

## 4.4.3 `diskguard.sh`, ShellCheck, and Cron

I created `~/diskguard.sh` to inspect all mounted filesystems and return a failure if any one exceeds 80% usage.

```bash
cat > ~/diskguard.sh <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

THRESHOLD=80
EXIT_CODE=0

while read -r filesystem capacity mountpoint; do
    usage=${capacity%\%}

    if (( usage > THRESHOLD )); then
        echo "WARNING: ${mountpoint} (${filesystem}) usage is ${usage}%, above ${THRESHOLD}%."
        EXIT_CODE=1
    fi
done < <(df --output=source,pcent,target | tail -n +2)

if (( EXIT_CODE == 0 )); then
    echo "OK: no mounted filesystem exceeds ${THRESHOLD}% usage."
fi

exit "$EXIT_CODE"
EOF

chmod +x ~/diskguard.sh
```

### Install and run ShellCheck

```bash
sudo apt update
sudo apt install -y shellcheck

command -v shellcheck
shellcheck ~/diskguard.sh
echo $?
```

Result:

```text
/usr/bin/shellcheck
0
```

ShellCheck produced no warnings and returned exit code 0.

### Healthy-state test

```bash
~/diskguard.sh
echo $?
```

Result:

```text
OK: no mounted filesystem exceeds 80% usage.
0
```

### High-usage test

I recreated the 850 MB file:

```bash
fallocate \
-l 850M \
/mnt/practice/fill-test/bigfile.bin

df -h /mnt/practice
```

Result:

```text
94% /mnt/practice
```

I then ran:

```bash
~/diskguard.sh
echo $?
```

Result:

```text
WARNING: /mnt/practice (/dev/loop0) usage is 94%, above 80%.
1
```

This confirmed the required warning and exit code `1`.

I cleaned up and retested:

```bash
rm \
/mnt/practice/fill-test/bigfile.bin

df -h /mnt/practice

~/diskguard.sh
echo $?
```

Result:

```text
1% /mnt/practice
OK: no mounted filesystem exceeds 80% usage.
0
```

### Cron job

I prepared the log file:

```bash
sudo touch /var/log/diskguard.log

sudo chown \
"$USER":"$USER" \
/var/log/diskguard.log

sudo chmod 640 \
/var/log/diskguard.log

ls -l /var/log/diskguard.log
```

I installed a cron entry that runs every 15 minutes:

```bash
(
  crontab -l 2>/dev/null
  echo '*/15 * * * * /home/ubuntu/diskguard.sh >> /var/log/diskguard.log 2>&1'
) | crontab -
```

Verification:

```bash
crontab -l
```

Result:

```text
*/15 * * * * /home/ubuntu/diskguard.sh >> /var/log/diskguard.log 2>&1
```

I confirmed the cron daemon was active:

```bash
systemctl status cron --no-pager
```

Result:

```text
Active: active (running)
```

I also tested the exact command used by cron to confirm that output redirection to the required log worked:

```bash
/home/ubuntu/diskguard.sh \
>> /var/log/diskguard.log 2>&1

cat /var/log/diskguard.log
```

Result:

```text
OK: no mounted filesystem exceeds 80% usage.
```

---

# Checkpoint Questions

## 1. What is the difference between a hard link and a symbolic link?

A **hard link** is another directory entry pointing to the same inode as the original file. Both names refer directly to the same underlying file data. Deleting one filename does not remove the data while another hard link still exists. Hard links normally cannot cross filesystem boundaries, and creating hard links to directories is generally restricted.

A **symbolic link (symlink)** is a separate filesystem object that stores a path to another file or directory. It has its own inode. It can cross filesystem boundaries and can point to directories, but if the target is deleted or moved the symlink becomes broken.

In short:

- hard link → another name for the same inode/data
- symbolic link → a separate file containing a path to another object

---

## 2. What do the `load average` numbers in `uptime` mean?

`uptime` normally shows three load-average values representing approximately the last:

1. 1 minute
2. 5 minutes
3. 15 minutes

Linux load average reflects the average number of tasks that are runnable or waiting in uninterruptible sleep, commonly including processes waiting for CPU or certain I/O.

The values must be interpreted relative to the number of CPU cores. For example, on a 2-CPU VM:

- load around `1.0` means roughly half of total CPU scheduling capacity is demanded
- load around `2.0` means the CPUs are approximately fully occupied
- load persistently above `2.0` suggests work is waiting for CPU or other resources

A high load average is therefore a signal to investigate, not automatically proof of high CPU usage alone.

---

## 3. What happens to file permissions when using `scp` versus `rsync -a`?

`scp` primarily copies file contents to the destination. The newly created destination file is generally subject to destination-side creation rules such as the user's `umask`; metadata preservation is not the main default behaviour.

`rsync -a` uses archive mode. Archive mode is designed to preserve important metadata, including permissions, timestamps, symbolic links, and other attributes where permissions and platform capabilities allow it.

Therefore:

- `scp` → convenient transfer, but destination permissions may be recreated according to the destination environment
- `rsync -a` → designed to preserve source metadata and is generally more appropriate when permissions and file attributes must be retained

---

# Task 1 Summary

All Task 1 practical requirements were completed successfully:

- Created and managed Linux users, groups, setgid permissions, and ACLs.
- Implemented restricted passwordless sudo using the principle of least privilege.
- Built and managed a systemd service with automatic restart.
- Used `journalctl` for service and time-filtered log inspection.
- Identified IP, routing, and DNS configuration.
- Tested HTTP listening and connectivity.
- Configured UFW with default-deny inbound policy and verified both allowed and blocked ports from the MacBook host.
- Performed successful and failing DNS lookups.
- Built a persistent 1 GB loop-backed ext4 filesystem and verified it after reboot.
- Investigated a filesystem above 90% usage using `df` and `du`, then cleaned it up.
- Created a ShellCheck-clean disk monitoring script with correct exit codes.
- Added the disk monitor to cron on a 15-minute schedule with log output.

## Troubleshooting Notes

### Multipass was missing

**Symptom**

```text
zsh: command not found: multipass
```

**Resolution**

Verified Homebrew, installed Multipass with:

```bash
brew install --cask multipass
```

Then successfully created the Ubuntu lab VM.

### Incorrect host-side placeholder in `curl`

**Symptom**

```bash
curl --max-time 5 http://VM_IP:8080
```

returned:

```text
curl: (6) Could not resolve host: VM_IP
```

**Cause**

`VM_IP` was typed as a literal placeholder in the MacBook shell rather than replaced by the actual VM address.

**Resolution**

Used the real Multipass IPv4 address:

```bash
curl --max-time 5 http://192.168.252.2:8080
```

Result:

```text
ShopStack HTTP test
```

This reinforced the difference between a documentation placeholder, a shell variable such as `$VM_IP`, and a literal hostname.

---

**Task 1 status: COMPLETE**

---

# Task 2 — Proxmox and VM Provisioning

## 5.1 Hypervisor Orientation

No Proxmox VE hardware was available. The documented Task 2 fallback permits three cloud VMs or three local VirtualBox VMs.

The MacBook Pro was initially evaluated for the local VirtualBox fallback. It had approximately 8 GB RAM and approximately 25 GiB free storage. Because the Kubernetes environment requires three VMs with 4 GB RAM each, running the full environment locally would heavily overcommit the MacBook and risk resource pressure.

Google Compute Engine was therefore selected for the Final Run.

Provider-specific VPC, subnet, firewall, and initial source-VM settings were configured in the GCP Console. The reusable Machine Image, VM clones, snapshots, resource verification, and static-IP reservation were then performed with `gcloud` in Google Cloud Shell.

VirtualBox 7.2.16 ARMv8 was inspected on the MacBook Pro.

Closest fallback inspection mappings included:

- `qm list` -> `VBoxManage list vms`
- `pct list` -> no direct VirtualBox equivalent
- `pvesm status` -> `VBoxManage list hdds`
- `ip link` -> macOS `ifconfig`

### LXC vs QEMU/KVM

LXC containers share the host Linux kernel. They are lightweight, start quickly, and have low overhead, but provide less kernel isolation and cannot run their own independent guest kernel.

QEMU/KVM virtual machines run their own guest kernels and virtual hardware. They use more resources but provide stronger isolation.

Independent VMs are appropriate for this Kubernetes lab because each Kubernetes node should behave as an independent Linux system.

## 5.2 Cloud-Init VM Template

Under the cloud fallback:

- the official Ubuntu 24.04 LTS GCE image replaced manual `qm disk import`;
- GCE metadata `user-data` replaced the Proxmox cloud-init drive;
- a GCE Machine Image replaced the Proxmox VM template;
- independent Persistent Disks provided the equivalent of full clones.

A dedicated SSH key was created:

`~/.ssh/shopstack_lab_ed25519`

The source VM `shopstack-template-source` used Ubuntu 24.04 LTS, x86_64, `e2-medium`, 2 vCPU, 4 GB RAM, and a 40 GB `pd-standard` disk.

Cloud-init created/configured the `ubuntu` user, installed the SSH authorized key, disabled password SSH authentication, disabled direct root SSH login, and expanded the root filesystem.

Verification showed:

- `cloud-init status`: `done`
- user: `ubuntu`
- internal IP: `10.10.0.2`
- disk: 40 GB
- root partition: approximately 39 GB
- root filesystem: approximately 38 GB ext4

Passwordless SSH succeeded from the MacBook Pro.

Before imaging, the source VM was cleaned using:

`sudo cloud-init clean --logs --machine-id`

The source VM was powered off.

A reusable Machine Image was created:

`shopstack-ubuntu2404-template`

Status: `READY`

Three VMs were created from the reusable image:

- `k8s-cp` — 10.10.0.10
- `k8s-worker-1` — 10.10.0.11
- `k8s-worker-2` — 10.10.0.12

All three use `e2-medium`, with 2 vCPU and 4 GB RAM.

Each node has its own independent 40 GB `pd-standard` disk.

A full clone has an independent disk and can operate independently of the original source template.

A linked clone stores changes relative to a shared parent/base image. It requires less storage, but it depends on that base image.

All three Kubernetes VMs were verified through passwordless SSH.

For each node:

- `cloud-init status` returned `done`;
- the `ubuntu` user was present;
- `hostnamectl` was checked;
- `ip -4 -br a` showed the expected internal IP;
- `lsblk` showed a 40 GB disk;
- `df -hT /` showed approximately 38 GB ext4 root filesystem.

Snapshots were created:

- `k8s-cp-pre-task3`
- `k8s-worker-1-pre-task3`
- `k8s-worker-2-pre-task3`

All three snapshots reported `READY`.

Snapshots are not substitutes for a complete backup strategy. A traditional hypervisor snapshot is primarily a rollback mechanism and may still depend on the same underlying storage.

A real backup design requires independent storage, scheduling, retention, verification, and restore testing.

In Proxmox VE, a backup job would define the protected VM, target storage, schedule, backup mode, and retention.

For example, a Proxmox backup job for `k8s-cp` could run nightly at 02:00 in snapshot mode, write to a Proxmox Backup Server datastore, retain the last 7 daily backups and 4 weekly backups, and include periodic test restores.

In a production environment, Proxmox Backup Server would provide a dedicated backup target with incremental backups, deduplication, verification, retention management, and restore capabilities.

## 5.3 Resource and Networking Hygiene

The GCE `e2-medium` machine type was verified as:

- 2 guest vCPUs
- 4096 MB RAM

The Kubernetes control-plane VM was verified as using `e2-medium`.

Proxmox-style memory ballooning is not exposed as a configurable Google Compute Engine control.

In Proxmox/QEMU, memory ballooning uses a guest balloon driver that allows the hypervisor to dynamically reclaim unused memory from a VM and later return memory when required.

Under the GCP fallback, CPU and RAM were configured through the GCE machine type. Ballooning was documented rather than falsely claiming that a Proxmox-specific control had been configured.

The cluster IP plan is:

- `k8s-cp` — 10.10.0.10
- `k8s-worker-1` — 10.10.0.11
- `k8s-worker-2` — 10.10.0.12

The three addresses were promoted to reserved static internal IPv4 addresses and verified as `IN_USE`.

The MacBook Pro `~/.ssh/config` contains entries for all three nodes.

The following aliases were verified using SSH key authentication:

- `ssh k8s-cp`
- `ssh k8s-worker-1`
- `ssh k8s-worker-2`

Each alias returned the correct hostname, the `ubuntu` user, and the expected internal IP.

## Checkpoint Questions

### What does cloud-init do on first boot, and which of its modules did you use?

Cloud-init automates first-boot initialization using metadata and user-data provided by the platform.

In this lab, cloud-init configured the `ubuntu` user, sudo access, SSH authorized key, password SSH policy, root-login policy, root-partition growth, and root-filesystem resize.

The cloud-config used the `users` section and SSH authentication settings (`ssh_authorized_keys`, `ssh_pwauth`, and `disable_root`), together with `growpart` and `resize_rootfs`. GCE supplied instance metadata and network configuration through its cloud datasource.

### Why build a template instead of installing Ubuntu three times from ISO?

A template provides a consistent and reproducible baseline.

It is faster than performing three independent ISO installations, reduces manual configuration and human error, limits configuration drift, and makes it easy to provision additional nodes in the same known state.

### What is the difference between thick and thin provisioning, and which does `local-lvm` use?

Thick provisioning allocates or reserves virtual-disk storage capacity up front.

Thin provisioning allocates physical storage progressively as data is written, allowing the underlying storage pool to be used more efficiently.

Proxmox `local-lvm` uses LVM-thin and therefore uses thin provisioning.

---

# Task 2 Summary

All Task 2 practical requirements were completed successfully using the documented cloud-VM fallback:

- Evaluated the MacBook Pro as a possible local VirtualBox host.
- Installed and inspected VirtualBox 7.2.16 ARMv8.
- Selected Google Compute Engine after determining that the MacBook Pro did not have sufficient local resources for three 4 GB Kubernetes VMs.
- Created a dedicated ShopStack SSH key.
- Built an Ubuntu 24.04 LTS cloud-init source VM.
- Verified the `ubuntu` user, SSH key authentication, DHCP networking, hostname, 40 GB boot disk, and expanded root filesystem.
- Cleaned the source VM with `cloud-init clean` and created the reusable `shopstack-ubuntu2404-template` Machine Image.
- Provisioned `k8s-cp`, `k8s-worker-1`, and `k8s-worker-2` from the reusable image.
- Verified all three nodes with passwordless SSH, `cloud-init`, `hostnamectl`, network, and disk checks.
- Created and verified a snapshot for each Kubernetes node.
- Verified the `e2-medium` resource allocation of 2 vCPU and 4 GB RAM.
- Reserved stable internal addresses `10.10.0.10`, `10.10.0.11`, and `10.10.0.12`.
- Configured `~/.ssh/config` aliases and successfully connected using `ssh k8s-cp`, `ssh k8s-worker-1`, and `ssh k8s-worker-2`.
- Documented the IP plan, cloud-init template design, snapshot/backup strategy, and Proxmox fallback mappings in the repository.

## Troubleshooting Notes

### VirtualBox CLI was not initially available

**Symptom**

The first VirtualBox version check failed:

```bash
VBoxManage --version
```

Result:

```text
zsh: command not found: VBoxManage
```

**Cause**

VirtualBox was not installed on the MacBook Pro.

**Resolution**

Installed VirtualBox with Homebrew:

```bash
brew install --cask virtualbox
```

Then verified the installation:

```bash
VBoxManage --version
```

Result:

```text
7.2.16r174877
```

I also inspected the platform capabilities with:

```bash
VBoxManage list systemproperties
```

The installed VirtualBox build supported the ARMv8 platform used by the Apple M2 host.

### Local VirtualBox resources were insufficient for the final three-node environment

**Symptom**

I inspected the MacBook Pro hardware:

```bash
system_profiler SPHardwareDataType \
  | grep -E 'Model Name|Model Identifier|Chip|Total Number of Cores|Memory'
```

Key result:

```text
Model Name: MacBook Pro
Chip: Apple M2
Total Number of Cores: 8
Memory: 8 GB
```

I also checked available storage:

```bash
df -h "$HOME"
```

Key result:

```text
Available storage: approximately 25 GiB
```

The required final Kubernetes environment consisted of:

```text
k8s-cp        4 GB RAM
k8s-worker-1  4 GB RAM
k8s-worker-2  4 GB RAM
```

The guest RAM requirement alone was therefore 12 GB, which already exceeded the MacBook Pro's 8 GB of physical memory before accounting for macOS and VirtualBox overhead.

The limited remaining local disk space also provided little headroom for three VM boot disks and later Kubernetes workloads.

**Cause**

Although VirtualBox itself worked on the Apple M2 host, the MacBook Pro did not have sufficient RAM and storage headroom to run the required three-node final environment reliably.

**Resolution**

The task documentation explicitly allows a cloud-VM fallback when Proxmox hardware is unavailable.

I therefore selected Google Compute Engine for the Final Run.

The final GCP design used:

```text
k8s-cp        e2-medium   2 vCPU / 4 GB   40 GB pd-standard
k8s-worker-1  e2-medium   2 vCPU / 4 GB   40 GB pd-standard
k8s-worker-2  e2-medium   2 vCPU / 4 GB   40 GB pd-standard
```

This preserved the learning goals of reproducible VM provisioning, cloud-init, template-based deployment, stable networking, and later Ansible automation without overcommitting the MacBook Pro.

### Ephemeral external IP was reused by a different VM

**Symptom**

The source VM originally used the external IPv4 address:

```text
34.42.37.172
```

After the source VM was powered off and the Kubernetes nodes were created, GCP assigned the same external address to the new `k8s-cp` VM.

The MacBook Pro still had the previous SSH host key for that IP in `~/.ssh/known_hosts`.

**Cause**

The external address was ephemeral and could be reused by Google Cloud after the original VM stopped using it.

Because the new VM had a different SSH host key, keeping the previous entry could cause an SSH host-key mismatch.

**Resolution**

Removed only the old entry for that IP before connecting to the new VM:

```bash
ssh-keygen -R 34.42.37.172
```

This allowed the new `k8s-cp` host key to be accepted cleanly.

### Control-plane hostname initially used the GCE internal FQDN

**Symptom**

Initial verification of `k8s-cp` returned:

```text
k8s-cp.us-central1-a.c.project-d289b572-dfb9-4c0f-9db.internal
```

`hostnamectl` also showed:

```text
Static hostname: (unset)
```

**Cause**

The control-plane VM was using a transient hostname supplied by Google Compute Engine instead of an explicitly configured static hostname.

**Resolution**

Set explicit static hostnames:

```bash
sudo hostnamectl set-hostname k8s-cp
```

```bash
sudo hostnamectl set-hostname k8s-worker-1
```

```bash
sudo hostnamectl set-hostname k8s-worker-2
```

Verification returned the expected short hostnames:

```text
k8s-cp
k8s-worker-1
k8s-worker-2
```

This made the node identities consistent for later Ansible and Kubernetes configuration.

### SSH firewall source could not be pinned to one VPN public IP

**Symptom**

The administrator's VPN exit IP changes frequently.

A firewall rule restricted to a single `/32` public IP would therefore stop allowing SSH whenever the VPN endpoint changed.

**Cause**

The VPN uses changing public exit addresses rather than one stable administrator source address.

**Resolution**

For this temporary lab, the SSH firewall rule was configured as:

```text
Protocol/port: TCP/22
Source: 0.0.0.0/0
Target tag: shopstack-k8s
```

SSH still requires the dedicated ShopStack private key and the rule only applies to VMs carrying the `shopstack-k8s` network tag.

This is a lab convenience and not a production recommendation.

In production, SSH access should instead be restricted to trusted source ranges or provided through a controlled mechanism such as Identity-Aware Proxy, a VPN with stable addressing, or a bastion host.

### macOS `.DS_Store` appeared as an untracked repository file

**Symptom**

Before staging the Task 2 deliverables:

```bash
git status --short
```

showed:

```text
?? .DS_Store
```

**Cause**

Finder automatically created a macOS `.DS_Store` metadata file in the repository directory.

It was not part of the Task 2 deliverables.

**Resolution**

Removed it before staging:

```bash
rm -f .DS_Store
```

A subsequent `git status --short` showed only the intended Task 2 deliverables.

---

**Task 2 status: COMPLETE**
---

# Task 3 — Ansible: Automated K8s Node Setup

**Date completed:** 2026-09-13
**Control node:** MacBook Pro
**Managed platform:** Google Compute Engine
**Managed OS:** Ubuntu 24.04.4 LTS, x86_64
**Kubernetes version:** v1.37.0
**Container runtime:** containerd 2.2.1

The three Task 2 VMs were reused directly:

```text
k8s-cp        10.10.0.10
k8s-worker-1  10.10.0.11
k8s-worker-2  10.10.0.12
```

All node preparation and Kubernetes bootstrap configuration in this task was performed through Ansible. No interactive SSH session was used to configure the managed nodes.

---

# 6.1 Ansible Foundations

## 6.1.1 Install Ansible and Create the Inventory

At the start of Task 3, the repository was clean and the latest commit was the completed Task 2 commit:

```bash
cd ~/shopstack-devops-lab
pwd
git status
git log --oneline --decorate -3
```

Key result:

```text
/Users/peipei/shopstack-devops-lab
On branch main
nothing to commit, working tree clean

f92f3a6 (HEAD -> main) Complete Task 2 VM provisioning
0fc7b09 Complete Task 1 Linux foundations
```

Ansible was not initially installed:

```bash
ansible --version
```

Result:

```text
zsh: command not found: ansible
```

I installed Ansible with Homebrew:

```bash
brew install ansible
```

Verification:

```bash
ansible --version
```

Key result:

```text
ansible [core 2.21.4]
Ansible package: 14.4.0
Python: 3.14.7
Executable: /opt/homebrew/bin/ansible
```

I created the Ansible directory and inventory:

```bash
mkdir -p ansible
```

`ansible/inventory.ini`:

```ini
[control_plane]
k8s-cp node_ip=10.10.0.10

[workers]
k8s-worker-1 node_ip=10.10.0.11
k8s-worker-2 node_ip=10.10.0.12

[all:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3
```

The inventory separates the control-plane and worker groups while preserving the stable internal GCP addresses for Kubernetes node configuration.

## 6.1.2 Verify Ansible Connectivity

From the `ansible/` directory, I tested all three nodes:

```bash
ansible all -i inventory.ini -m ping
```

Result:

```text
k8s-cp       SUCCESS -> pong
k8s-worker-1 SUCCESS -> pong
k8s-worker-2 SUCCESS -> pong
```

### Why Ansible is agentless

Ansible uses an **agentless, push-based** model. The control node connects to managed Linux nodes over SSH and executes modules using Python available on the managed nodes. A continuously running Ansible-specific agent is not required.

In this lab:

```text
MacBook Pro
    |
    | SSH + Python
    v
k8s-cp
k8s-worker-1
k8s-worker-2
```

A pull-based configuration model works in the opposite direction: the managed node periodically contacts a central service or repository, downloads its desired configuration, and applies it locally.

In short:

```text
Push model: control system -> managed node
Pull model: managed node -> configuration source
```

## 6.1.3 Gather Facts and Check Uptime

I gathered operating-system facts from all nodes:

```bash
ansible all -i inventory.ini -m setup | grep ansible_distribution
```

All three nodes reported Ubuntu 24.04 Noble information:

```text
ansible_distribution: Ubuntu
ansible_distribution_major_version: 24
ansible_distribution_release: noble
ansible_distribution_version: 24.04
```

I checked uptime on all three nodes with one command:

```bash
ansible all -i inventory.ini -m command -a uptime
```

Key result:

```text
k8s-worker-1: up 3:17
k8s-worker-2: up 3:17
k8s-cp:       up 3:18
```

The Ansible `command` module displayed `CHANGED` because it executed a command, but `uptime` itself did not modify the systems.

I also confirmed the Ansible collections used by the playbook:

```bash
ansible-galaxy collection list | grep -E 'community\.general|ansible\.posix'
```

Result:

```text
ansible.posix       2.2.2
community.general   13.4.0
```

---

# 6.2 Node Preparation Playbook

I created `ansible/k8s-node-setup.yaml` using three roles:

```text
common
containerd
k8s_packages
```

The final playbook structure was:

```yaml
---
- name: Prepare Kubernetes nodes
  hosts: all
  become: true
  gather_facts: true

  roles:
    - common
    - containerd
    - k8s_packages
```

I used syntax checks while building the playbook:

```bash
ansible-playbook -i inventory.ini k8s-node-setup.yaml --syntax-check
```

Result:

```text
playbook: k8s-node-setup.yaml
```

## 6.2.1 `common` Role

I created:

```text
ansible/roles/common/tasks/main.yml
```

The role performs the following actions on all three nodes:

- sets each hostname from the Ansible inventory;
- adds all three Kubernetes nodes to `/etc/hosts`;
- disables active swap;
- comments swap entries out of `/etc/fstab`;
- persists the `overlay` and `br_netfilter` kernel modules;
- loads both modules immediately;
- configures the required Kubernetes sysctls.

The managed `/etc/hosts` block is:

```text
10.10.0.10 k8s-cp
10.10.0.11 k8s-worker-1
10.10.0.12 k8s-worker-2
```

Kernel modules are persisted in `/etc/modules-load.d/k8s.conf`:

```text
overlay
br_netfilter
```

The Kubernetes sysctls are stored in `/etc/sysctl.d/99-kubernetes.conf`:

```text
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
```

The first `common` role run completed successfully:

```text
k8s-cp        changed=4 failed=0
k8s-worker-1  changed=4 failed=0
k8s-worker-2  changed=4 failed=0
```

I verified the final state on all three nodes through Ansible. The hostnames were correct, `/etc/hosts` contained all three node mappings, `swapon --show` returned no active swap devices, and no uncommented swap entry remained in `/etc/fstab`.

The required modules were loaded:

```text
br_netfilter
overlay
```

The live sysctl values were:

```text
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
```

This confirmed that the `common` role prepared all three nodes for Kubernetes networking and scheduling requirements.

## 6.2.2 `containerd` Role

I created:

```text
ansible/roles/containerd/tasks/main.yml
ansible/roles/containerd/handlers/main.yml
```

The role:

- installs `containerd`;
- creates `/etc/containerd`;
- generates the default containerd configuration;
- changes the cgroup driver to systemd;
- enables and starts the service;
- restarts containerd through a handler when the configuration changes.

The configuration was generated from:

```text
containerd config default
```

and the required cgroup setting was changed to:

```text
SystemdCgroup = true
```

The first containerd run completed successfully:

```text
k8s-cp        changed=5 failed=0
k8s-worker-1  changed=5 failed=0
k8s-worker-2  changed=5 failed=0
```

Verification on all three nodes showed:

```text
containerd 2.2.1
SystemdCgroup = true
service: active
service: enabled
```

## 6.2.3 `k8s_packages` Role

I created:

```text
ansible/roles/k8s_packages/tasks/main.yml
ansible/roles/k8s_packages/defaults/main.yml
```

The pinned values were:

```yaml
kubernetes_repo_minor: "v1.37"
kubernetes_package_version: "1.37.0-1.1"
```

The role:

- installs repository prerequisites;
- downloads the Kubernetes repository signing key;
- creates the GPG keyring;
- configures the Kubernetes v1.37 apt repository;
- installs exact versions of `kubelet`, `kubeadm`, and `kubectl`;
- holds all three packages using Ansible `dpkg_selections`.

The configured repository was:

```text
https://pkgs.k8s.io/core:/stable:/v1.37/deb/
```

The first package installation run completed successfully:

```text
k8s-cp        changed=6 failed=0
k8s-worker-1  changed=6 failed=0
k8s-worker-2  changed=6 failed=0
```

Runtime checks returned:

```text
kubeadm: v1.37.0
kubelet: Kubernetes v1.37.0
kubectl: Client Version v1.37.0
```

An initial attempt to display the exact Debian package versions with:

```bash
dpkg-query -W -f="${Package} ${Version}\n" kubelet kubeadm kubectl
```

inside an Ansible shell command produced blank version lines because the remote shell expanded `${Package}` and `${Version}` before `dpkg-query` interpreted them as format placeholders.

I corrected the verification with:

```bash
ansible all -i inventory.ini -b -m command -a "dpkg-query -W kubelet kubeadm kubectl"
```

All three nodes returned:

```text
kubeadm  1.37.0-1.1
kubectl  1.37.0-1.1
kubelet  1.37.0-1.1
```

The held packages were also verified:

```text
kubeadm
kubectl
kubelet
```

---

# 6.3 Bootstrap the Kubernetes Cluster with kubeadm

## Preflight Verification

Before initializing Kubernetes, I inspected the actual GCP networking and runtime state through Ansible.

Observed node addressing:

```text
k8s-cp        ens4  10.10.0.10/32
k8s-worker-1  ens4  10.10.0.11/32
k8s-worker-2  ens4  10.10.0.12/32
```

The default gateway was `10.10.0.1`.

All nodes reported:

```text
NTPSynchronized=yes
```

Before bootstrap:

```text
admin.conf=absent
kubelet.conf=absent
```

The containerd CRI plugins reported:

```text
io.containerd.cri.v1 images   ok
io.containerd.cri.v1 runtime  linux/amd64 ok
```

This confirmed that the nodes were synchronized, had clean kubeadm state, and had a working containerd CRI implementation.

## 6.3.1 Create `k8s-cluster.yaml` and Bootstrap the Cluster

I created:

```text
ansible/k8s-cluster.yaml
```

The kubeadm configuration used:

```text
Kubernetes version: v1.37.0
API advertise address: 10.10.0.10
Pod network CIDR: 10.244.0.0/16
Service CIDR: 10.96.0.0/12
CRI socket: unix:///run/containerd/containerd.sock
```

The control-plane node registration explicitly used `10.10.0.10` as the node IP.

Initialization was guarded by the existence of:

```text
/etc/kubernetes/admin.conf
```

so rerunning the playbook would not initialize the cluster again.

I checked the playbook syntax:

```bash
ansible-playbook -i inventory.ini k8s-cluster.yaml --syntax-check
```

Result:

```text
playbook: k8s-cluster.yaml
```

I then initialized the control plane:

```bash
ansible-playbook -i inventory.ini k8s-cluster.yaml
```

Initial recap:

```text
k8s-cp: changed=4 failed=0
```

After initialization:

```text
admin.conf=PRESENT
```

The Kubernetes API server was:

```text
https://10.10.0.10:6443
```

Before a CNI was installed, the observed transitional state was:

```text
k8s-cp   NotReady
```

and both CoreDNS pods were:

```text
0/1 Pending
```

The control-plane static components were already running:

```text
etcd
kube-apiserver
kube-controller-manager
kube-scheduler
kube-proxy
```

The node was not yet Ready because pod networking had not yet been installed.

### Flannel CNI

I used Flannel as the CNI plugin, pinned at:

```text
v0.28.9
```

Because the GCP nodes use `ens4` for cluster traffic, the playbook modified the Flannel DaemonSet arguments to include:

```text
--iface=ens4
```

The playbook downloaded the pinned Flannel manifest, applied it, waited for the DaemonSet rollout, and waited for CoreDNS to become available.

After Flannel was installed:

```text
k8s-cp   Ready
```

The Flannel pod was:

```text
1/1 Running
```

The live Flannel arguments were verified as:

```text
["--ip-masq","--kube-subnet-mgr","--iface=ens4"]
```

Both CoreDNS pods became:

```text
1/1 Running
```

with pod-network addresses `10.244.0.2` and `10.244.0.3`.

### Worker Join Automation

The worker-join portion of `k8s-cluster.yaml` checks for:

```text
/etc/kubernetes/kubelet.conf
```

on each worker. If it is absent, the worker is considered not yet joined.

The control plane then:

1. creates a temporary kubeadm bootstrap token;
2. calculates the Kubernetes CA discovery hash;
3. records the bootstrap token ID;
4. generates the join information;
5. waits for the token's JWS signature in the `cluster-info` ConfigMap.

The temporary bootstrap token used a 30-minute TTL. Sensitive token-handling tasks used `no_log` so the token was not printed in normal Ansible output.

The JWS readiness check returned:

```text
Bootstrap token JWS is available. Worker join can proceed.
```

Each worker received a temporary `JoinConfiguration`, then successfully joined the cluster through `kubeadm join`.

The temporary worker join configuration was removed after the join, and the temporary bootstrap token was deleted from the control plane.

Final cluster verification returned:

```text
NAME           STATUS   ROLES           VERSION   INTERNAL-IP
k8s-cp         Ready    control-plane   v1.37.0   10.10.0.10
k8s-worker-1   Ready    <none>          v1.37.0   10.10.0.11
k8s-worker-2   Ready    <none>          v1.37.0   10.10.0.12
```

All three nodes used `containerd://2.2.1` and reported Ubuntu 24.04.4 LTS.

## 6.3.2 Local `kubectl` Access from the MacBook Pro

I copied the Kubernetes admin kubeconfig from the control plane to the MacBook Pro using Ansible's `fetch` module:

```bash
mkdir -p ~/.kube

ansible k8s-cp -i inventory.ini -b -m fetch \
  -a "src=/etc/kubernetes/admin.conf dest=$HOME/.kube/shopstack-config flat=yes"
```

I restricted the file permission:

```bash
chmod 600 ~/.kube/shopstack-config
```

The original kubeconfig API endpoint was:

```text
https://10.10.0.10:6443
```

Because this is the control plane's private GCP address, I did not expose Kubernetes API port 6443 publicly. Instead, I created a local SSH tunnel:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 \
  k8s-cp
```

I verified the listener:

```bash
lsof -nP -iTCP:6443 -sTCP:LISTEN
```

Key result:

```text
ssh ... TCP 127.0.0.1:6443 (LISTEN)
```

I preserved the original kubeconfig and created a tunnel-specific copy:

```bash
cp ~/.kube/shopstack-config ~/.kube/shopstack-tunnel-config
chmod 600 ~/.kube/shopstack-tunnel-config
```

I modified only the tunnel copy:

```bash
KUBECONFIG=~/.kube/shopstack-tunnel-config \
kubectl config set-cluster kubernetes \
  --server=https://127.0.0.1:6443 \
  --tls-server-name=10.10.0.10
```

Verification showed:

```text
server: https://127.0.0.1:6443
tls-server-name: 10.10.0.10
```

This allowed the MacBook Pro to reach the private Kubernetes API through SSH while preserving TLS certificate verification.

Local cluster verification:

```bash
KUBECONFIG=~/.kube/shopstack-tunnel-config kubectl cluster-info
KUBECONFIG=~/.kube/shopstack-tunnel-config kubectl get nodes -o wide
```

Result:

```text
Kubernetes control plane is running at https://127.0.0.1:6443

k8s-cp         Ready   ... 10.10.0.10
k8s-worker-1   Ready   ... 10.10.0.11
k8s-worker-2   Ready   ... 10.10.0.12
```

This proved that local `kubectl` on the MacBook Pro was controlling the three-node kubeadm cluster rather than minikube.

## 6.3.3 Idempotency Proof

I created:

```text
ansible/evidence/
```

and saved the rerun output of both playbooks.

### Node-preparation playbook

```bash
ansible-playbook -i inventory.ini k8s-node-setup.yaml 2>&1 \
  | tee evidence/idempotency-node-setup.txt
```

Final recap:

```text
k8s-cp        changed=0 failed=0
k8s-worker-1  changed=0 failed=0
k8s-worker-2  changed=0 failed=0
```

### Cluster playbook

```bash
ansible-playbook -i inventory.ini k8s-cluster.yaml 2>&1 \
  | tee evidence/idempotency-cluster.txt
```

The rerun detected that the workers were already joined, so the bootstrap-token generation and worker-join tasks were skipped.

Final recap:

```text
k8s-cp        changed=0 failed=0
k8s-worker-1  changed=0 failed=0
k8s-worker-2  changed=0 failed=0
```

### Why idempotency matters

Idempotency means repeatedly applying the same configuration leaves a correctly configured system in the same desired state instead of repeatedly changing it.

This is important in configuration management because automation must be safe to rerun. For example, an idempotent Kubernetes automation should not duplicate `/etc/hosts` entries, rewrite unchanged configuration, reinstall already-correct packages, recreate an existing cluster, or rejoin workers that are already members.

The two `changed=0` reruns demonstrated that both Task 3 playbooks had converged on the intended state.

## 6.3.4 Ansible Vault

I created a demonstration variable file containing a lab-only demo value and restricted it to owner read/write access:

```bash
chmod 600 vault-demo.yml
```

I encrypted the variable file:

```bash
ansible-vault encrypt vault-demo.yml
```

Result:

```text
Encryption successful
```

The encrypted file began with:

```text
$ANSIBLE_VAULT;1.1;AES256
```

I then demonstrated decryption:

```bash
ansible-vault decrypt vault-demo.yml
```

Result:

```text
Decryption successful
```

Finally, I encrypted the file again before repository storage:

```bash
ansible-vault encrypt vault-demo.yml
```

Final verification showed the Ansible Vault header and `600` permissions. The Vault password itself was not stored in the repository.

---

# Checkpoint Questions

## 1. Why must swap be disabled for kubelet, and why do the bridge sysctls matter for pod networking?

Kubernetes needs predictable memory accounting so that kubelet can make scheduling and eviction decisions based on the memory actually available to workloads. In this lab, swap was disabled at runtime and persistently in `/etc/fstab` rather than relying on swap behaviour that was not deliberately configured for Kubernetes.

The networking sysctls support pod networking:

```text
net.bridge.bridge-nf-call-iptables=1
```

allows IPv4 packets crossing a Linux bridge to pass through netfilter/iptables processing.

```text
net.ipv4.ip_forward=1
```

allows the Linux kernel to forward IPv4 traffic between interfaces and network paths.

Together with `br_netfilter`, these settings support forwarding and filtering of Kubernetes pod and service traffic.

## 2. What is the difference between a playbook, a role, and a task? When would you use `import_tasks` vs `include_tasks`?

A **task** is an individual unit of Ansible work, such as installing one package or writing one configuration file.

A **role** is a reusable structure that groups related tasks, handlers, defaults, variables, templates, and files. In this task the roles were `common`, `containerd`, and `k8s_packages`.

A **playbook** defines the higher-level automation flow: which hosts are targeted, privilege settings, variables, and which roles or tasks should run.

`import_tasks` is a static, parse-time import. It is suitable when the task structure is known in advance.

`include_tasks` is dynamic and evaluated at runtime. It is useful when task inclusion depends on runtime variables, conditions, loops, or discovered state.

In short:

```text
import_tasks  -> static / parse-time
include_tasks -> dynamic / runtime
```

## 3. Why pin package versions and hold them instead of installing `latest`?

Using `latest` can cause different nodes to receive different package versions depending on when automation runs or when repositories publish new releases.

For Kubernetes, upgrades should be deliberate and coordinated. Pinning and holding the packages provides reproducible provisioning, consistent versions across nodes, protection from accidental upgrades, easier troubleshooting, and controlled upgrade planning.

In this lab the packages were pinned to:

```text
kubeadm  1.37.0-1.1
kubectl  1.37.0-1.1
kubelet  1.37.0-1.1
```

## 4. Your kubeadm cluster has one control-plane node — what would a highly available control plane require?

The current lab has one control-plane node, so the control plane is a single point of failure.

A highly available design would normally use multiple control-plane nodes, commonly at least three so etcd can maintain quorum after one failure. It would also use a stable control-plane endpoint, a load balancer in front of the API servers, multiple API server instances, replicated controller-manager and scheduler processes using leader election, an HA etcd topology, and placement across separate failure domains where possible.

Worker nodes would normally connect to the stable load-balanced control-plane endpoint rather than the IP address of one individual API server.

---

# Task 3 Summary

All Task 3 practical requirements were completed successfully:

- Installed Ansible on the MacBook Pro control node.
- Created an inventory with separate `control_plane` and `workers` groups.
- Verified agentless SSH/Python connectivity to all three GCP nodes.
- Gathered Ubuntu facts and uptime using Ansible ad-hoc commands.
- Built the `common`, `containerd`, and `k8s_packages` roles.
- Configured hostnames and `/etc/hosts`.
- Verified swap was disabled.
- Persisted and loaded `overlay` and `br_netfilter`.
- Configured the required Kubernetes sysctls.
- Installed containerd 2.2.1 with `SystemdCgroup = true`.
- Enabled and started containerd on all nodes.
- Configured the Kubernetes v1.37 apt repository.
- Installed `kubelet`, `kubeadm`, and `kubectl` at exact version `1.37.0-1.1`.
- Held all three Kubernetes packages.
- Initialized the control plane using kubeadm.
- Installed Flannel v0.28.9 and explicitly used the GCP `ens4` interface.
- Verified CoreDNS and Flannel health.
- Generated temporary worker bootstrap credentials and waited for their JWS signature.
- Joined both worker nodes through Ansible.
- Deleted the temporary bootstrap token after the join completed.
- Verified all three Kubernetes nodes as `Ready`.
- Copied the admin kubeconfig to the MacBook Pro.
- Used an SSH tunnel to access the private GCP Kubernetes API without exposing port 6443 publicly.
- Verified local `kubectl` access from the MacBook Pro.
- Demonstrated full idempotency with `changed=0` on both playbooks.
- Demonstrated Ansible Vault encryption and decryption.
- Stored the final Vault demo in encrypted form.

The final Task 3 repository structure was:

```text
ansible/
├── evidence/
│   ├── idempotency-cluster.txt
│   └── idempotency-node-setup.txt
├── inventory.ini
├── k8s-cluster.yaml
├── k8s-node-setup.yaml
├── roles/
│   ├── common/
│   │   └── tasks/
│   │       └── main.yml
│   ├── containerd/
│   │   ├── handlers/
│   │   │   └── main.yml
│   │   └── tasks/
│   │       └── main.yml
│   └── k8s_packages/
│       ├── defaults/
│       │   └── main.yml
│       └── tasks/
│           └── main.yml
└── vault-demo.yml
```

## Troubleshooting Notes

### Ansible was not initially installed on the MacBook Pro

**Symptom**

```bash
ansible --version
```

returned:

```text
zsh: command not found: ansible
```

**Cause**

The MacBook Pro had not previously been configured as an Ansible control node.

**Resolution**

Installed Ansible with Homebrew:

```bash
brew install ansible
```

Verification returned:

```text
ansible [core 2.21.4]
```

### Exact package-version query initially returned blank lines

**Symptom**

The first package verification used:

```bash
dpkg-query -W -f="${Package} ${Version}\n" kubelet kubeadm kubectl
```

inside an Ansible shell command. The package-version section returned blank lines even though the Kubernetes binaries worked.

**Cause**

`${Package}` and `${Version}` were interpreted by the remote shell as shell-variable references before `dpkg-query` could interpret them as formatting placeholders. Because those shell variables were unset, they expanded to empty strings.

**Resolution**

Used Ansible's `command` module with the default `dpkg-query` output format:

```bash
ansible all -i inventory.ini -b -m command -a "dpkg-query -W kubelet kubeadm kubectl"
```

This returned the expected versions on all three nodes:

```text
kubeadm  1.37.0-1.1
kubectl  1.37.0-1.1
kubelet  1.37.0-1.1
```

### Control plane was `NotReady` before the CNI was installed

**Observation**

Immediately after `kubeadm init`:

```text
k8s-cp   NotReady
```

and both CoreDNS pods were `0/1 Pending` while the control-plane static pods were already running.

**Cause**

The cluster did not yet have a Container Network Interface plugin, so pod networking was not available.

**Resolution**

Installed the pinned Flannel CNI and configured it to use:

```text
--iface=ens4
```

After Flannel became ready, `k8s-cp` became `Ready` and both CoreDNS pods became `1/1 Running`.

This was an expected bootstrap transition rather than a kubeadm failure.

### The GCP Kubernetes API used a private address

**Observation**

The fetched admin kubeconfig contained:

```text
https://10.10.0.10:6443
```

The task required local `kubectl` on the MacBook Pro to control the cluster, but I did not want to expose Kubernetes API port 6443 publicly.

**Resolution**

Created a local SSH tunnel:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 \
  k8s-cp
```

I then configured a separate tunnel-specific kubeconfig with:

```text
server: https://127.0.0.1:6443
tls-server-name: 10.10.0.10
```

This allowed the MacBook Pro to reach the private Kubernetes API through SSH while preserving TLS certificate verification. Local `kubectl get nodes -o wide` then returned all three nodes as `Ready`.

---

**Task 3 status: COMPLETE**
---

# Task 4 — Kubernetes Fundamentals and Helm

**Date completed:** 2026-09-14
**Working machine:** MacBook Pro (Apple M2, arm64)
**Primary Kubernetes environment:** Three-node kubeadm cluster on Google Compute Engine
**Primary Kubernetes version:** v1.37.0
**Primary container runtime:** containerd 2.2.1
**Scratch environment:** minikube v1.38.1 using the Docker driver, Kubernetes v1.35.1
**Application namespace:** `shopstack`
**Container registry:** `ghcr.io/culerty516/shopstack-frontend`
**Helm version used for the task:** Helm v3.22.0
**Podman:** 6.1.1 on the MacBook Pro; 4.9.3 on `k8s-worker-2`
**Trivy:** 0.74.0
**Self-hosted deploy runner:** GitHub Actions Runner 2.337.0 on the MacBook Pro, registered as an ephemeral repository runner

The Task 3 kubeadm cluster was reused directly. Because the Kubernetes API is private on the GCP VPC, local `kubectl` access from the MacBook Pro continued to use the SSH tunnel established in Task 3. The kubeadm cluster was the preferred target for the remaining Task 4 work. Minikube was used as a scratch environment for context switching, the metrics-server/HPA exercise, and the explicit minikube ingress-addon requirement.

The primary cluster was:

```text
k8s-cp        10.10.0.10   control-plane   amd64
k8s-worker-1  10.10.0.11   worker          amd64
k8s-worker-2  10.10.0.12   worker          amd64
```

---

# 7.1 Cluster Bootstrap

## 7.1.1 Verify kubeadm, Start Minikube, and Practice Context Switching

At the start of Task 4, the repository was at the completed Task 3 commit. The kubeadm context was configured to use the locally forwarded API endpoint on `127.0.0.1:6443`.

The initial verification failed:

```bash
kubectl get nodes -o wide
kubectl cluster-info
```

Key error:

```text
The connection to the server 127.0.0.1:6443 was refused
```

I checked the local listener and found that the SSH tunnel was no longer running. I recreated the tunnel:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 \
  k8s-cp
```

Verification then succeeded:

```text
NAME           STATUS   ROLES           VERSION   INTERNAL-IP
k8s-cp         Ready    control-plane   v1.37.0   10.10.0.10
k8s-worker-1   Ready    <none>          v1.37.0   10.10.0.11
k8s-worker-2   Ready    <none>          v1.37.0   10.10.0.12
```

`kubectl cluster-info` reported the Kubernetes control plane through:

```text
https://127.0.0.1:6443
```

I also started the existing minikube scratch cluster with the Docker driver:

```bash
KUBECONFIG="$HOME/.kube/config" \
minikube start --driver=docker
```

The minikube node became `Ready` and reported Kubernetes v1.35.1.

I created a merged Task 4 kubeconfig so both environments could be selected from one file:

```bash
KUBECONFIG="$HOME/.kube/shopstack-tunnel-config:$HOME/.kube/config" \
kubectl config view --flatten \
  > "$HOME/.kube/task4-final-config"
```

```bash
chmod 600 "$HOME/.kube/task4-final-config"
```

```bash
export KUBECONFIG="$HOME/.kube/task4-final-config"
```

I listed the merged contexts:

```bash
kubectl config get-contexts
```

The available contexts included:

```text
docker-desktop
ingress-lab
kubernetes-admin@kubernetes
minikube
```

I practised switching to minikube:

```bash
kubectl config use-context minikube
kubectl config current-context
kubectl get nodes -o wide
```

and then back to the kubeadm cluster:

```bash
kubectl config use-context kubernetes-admin@kubernetes
kubectl config current-context
kubectl get nodes -o wide
```

### Cluster targeting for the rest of Task 4

The three-node kubeadm cluster was the primary environment for the Kubernetes application, Online Boutique, Ingress, custom frontend, and Helm deployment. Minikube was intentionally used as the scratch environment for HPA/metrics-server experimentation and for confirming the minikube ingress addon. Online Boutique was initially attempted on minikube, but the final stable deployment was moved to the kubeadm cluster after the Apple Silicon scratch environment showed sustained emulation/resource pressure.

---

## 7.1.2 Explore the Control Plane

I listed the `kube-system` pods and identified the main control-plane components. The kubeadm cluster showed:

```text
coredns
etcd
kube-apiserver
kube-controller-manager
kube-proxy
kube-scheduler
```

I also confirmed that `kube-proxy` was running as a DaemonSet on all three nodes and CoreDNS was running as a Deployment with two replicas.

On `k8s-cp`, I inspected:

```bash
sudo ls -lah /etc/kubernetes/manifests
```

The static-pod manifests were:

```text
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
```

### Core component roles

- **kube-apiserver** is the control-plane entry point. It exposes the Kubernetes API, performs authentication/authorization and admission processing, validates requests, and persists desired state through etcd.
- **etcd** is the distributed key-value store containing the authoritative cluster state.
- **kube-scheduler** watches for unscheduled Pods and selects suitable nodes based on resources, constraints, affinity, taints/tolerations, and other scheduling rules.
- **kube-controller-manager** runs reconciliation controllers that continually move actual cluster state toward declared desired state.
- **kube-proxy** runs on nodes and implements Service networking rules so ClusterIP/NodePort traffic reaches appropriate endpoints.
- **CoreDNS** provides Kubernetes service discovery and DNS resolution for Pods and Services.

The static-pod design means the kubelet on the control-plane node watches `/etc/kubernetes/manifests` and directly manages those critical control-plane Pods without requiring a normal Deployment.

---

## 7.1.3 Create and Select the `shopstack` Namespace

I created the namespace declaratively in:

```text
k8s/namespace.yaml
```

and applied it:

```bash
kubectl apply -f k8s/namespace.yaml
```

I then set it as the default namespace for the current kubeadm context:

```bash
kubectl config set-context \
  --current \
  --namespace=shopstack
```

Verification returned:

```text
shopstack
```

for the current context namespace.

---

# 7.2 First Workload — from Pod to Deployment

## 7.2.1 Imperative Bare Pod

I created the one deliberately imperative bare Pod required by the exercise:

```bash
kubectl run nginx-pod \
  --image=nginx:1.27 \
  --port=80
```

I waited for readiness and confirmed it was `1/1 Running` on a worker node. I port-forwarded it:

```bash
kubectl port-forward pod/nginx-pod 8080:80
```

A separate terminal returned HTTP `200 OK` from nginx.

I then deleted the bare Pod:

```bash
kubectl delete pod nginx-pod
```

and confirmed it no longer existed.

### Why controllers are preferred

A bare Pod is an individual runtime object. If the node fails or the Pod is deleted, Kubernetes has no higher-level desired-state object instructing it to recreate the workload. A Deployment/ReplicaSet instead declares a desired replica count and continually reconciles the real state, providing self-healing, scaling, rollout history, rolling updates, and rollback capability. For application workloads I therefore used controllers from this point onward.

---

## 7.2.2 Deployment and ClusterIP Service

I created the git-tracked manifests:

```text
k8s/frontend-deployment.yaml
k8s/frontend-service.yaml
```

The initial Deployment used:

```text
replicas: 3
image: nginx:1.27
```

and the Service used:

```text
type: ClusterIP
selector: app=frontend
port: 80
```

I applied them and watched the rollout:

```bash
kubectl apply -f k8s/frontend-deployment.yaml
```

```bash
kubectl apply -f k8s/frontend-service.yaml
```

```bash
kubectl rollout status deployment/frontend --timeout=120s
```

The Deployment reached:

```text
frontend   3/3   3   3
```

and the three Pods were distributed across `k8s-worker-1` and `k8s-worker-2`.

Port-forwarding the Service also returned the nginx page successfully.

---

## 7.2.3 Rolling Update, Revision History, and Rollback

I inspected the initial revision history:

```bash
kubectl rollout history deployment/frontend
```

The initial revision was `1`.

I changed the tracked image from:

```text
nginx:1.27
```

to:

```text
nginx:1.27.5
```

and re-applied the manifest. The rollout completed successfully and the live Deployment reported `nginx:1.27.5`.

The history then contained revisions `1` and `2`.

I tested rollback:

```bash
kubectl rollout undo deployment/frontend
```

After the rollback completed, the live image returned to:

```text
nginx:1.27
```

and the revision history advanced again.

`kubectl rollout undo` warned that the resource had previously been managed with `kubectl apply`, and that rollback does not rewrite the `last-applied-configuration` annotation. I therefore also restored the tracked manifest to `nginx:1.27` and re-applied it so declarative source and live state remained aligned.

---

## 7.2.4 Resources, Liveness, Readiness, and a Broken Readiness Probe

I added resource requests and limits:

```yaml
requests:
  cpu: 50m
  memory: 64Mi
limits:
  cpu: 200m
  memory: 128Mi
```

and HTTP liveness/readiness probes against `/`.

After applying the change, all three Pods became Ready and the Service had three healthy endpoints.

I then deliberately changed only the readiness path to:

```text
/definitely-not-ready
```

and re-applied the Deployment.

The new Pod stayed:

```text
0/1 Running
```

with no container restart. `kubectl describe pod` showed repeated:

```text
Readiness probe failed: HTTP probe failed with statuscode: 404
```

The old three Ready Pods remained Service endpoints while the new Pod appeared in the EndpointSlice with:

```text
ready: false
serving: false
```

The Deployment rollout timed out because the new ReplicaSet could not become Ready.

One command-entry attempt used a literal placeholder:

```text
kubectl describe pod <NOT_READY_POD_NAME>
```

which produced a zsh parse error. I corrected this by using the actual Pod name.

I restored the readiness path to `/`, re-applied the Deployment, and the rollout completed. The Service once again contained only Ready endpoints.

### Why the Pod did not restart

Readiness controls whether a Pod is eligible to receive Service traffic. A failed readiness probe marks the container NotReady but does not kill it. Liveness answers a different question: whether the process is still healthy enough to continue running. Repeated liveness failure causes kubelet to restart the container.

---

## 7.2.5 Scaling and HPA

I first scaled the Deployment declaratively from three to five replicas and verified:

```text
frontend   5/5
```

For the HPA requirement, I switched to the minikube scratch cluster and enabled the metrics-server addon:

```bash
minikube addons enable metrics-server
```

I confirmed the Metrics API became usable with `kubectl top` and deployed the same frontend workload there.

The HPA manifest was stored in:

```text
k8s/frontend-hpa.yaml
```

using `autoscaling/v2`, with:

```text
minReplicas: 5
maxReplicas: 10
CPU target: 50%
```

### Initial load attempt and metrics-server pressure

My first HTTP load-generator approach pushed the small minikube environment hard enough that metrics-server itself became unhealthy. HPA events included failures such as:

```text
failed to get cpu utilization
unable to fetch metrics from resource metrics API
```

This made the first load method unsuitable for demonstrating HPA behaviour reliably.

After the environment recovered, I used a controlled CPU load inside one existing frontend Pod rather than adding multiple aggressive load-generator Pods.

The loaded frontend Pod reached approximately:

```text
184m CPU
```

The HPA then showed:

```text
cpu: 81%/50%
replicas: 8
```

and the Deployment became:

```text
8/8
```

`kubectl describe hpa frontend` recorded:

```text
SuccessfulRescale  New size: 8; reason: cpu resource utilization (percentage of request) above target
```

I stopped the temporary CPU load after proving the rescale.

This exercise demonstrated both the HPA dependency on resource metrics and the importance of not starving the very telemetry components used for autoscaling decisions.

---

# 7.3 Configuration and Secrets

## 7.3.1 ConfigMap Mounted into the Frontend

I created:

```text
k8s/frontend-configmap.yaml
```

with an `index.html` containing:

```text
Feature flag: VERSION_A
```

### Initial mounting mistake

I applied the ConfigMap and Deployment, but the response still showed the default nginx page. Inspection of the tracked Deployment showed that the expected `volumeMounts` and `volumes` blocks were absent.

The ConfigMap itself was correct; the Deployment simply was not consuming it.

I corrected the Deployment to mount the ConfigMap at:

```text
/usr/share/nginx/html
```

After re-applying and completing the rollout, the page returned:

```text
ShopStack Frontend
Feature flag: VERSION_A
```

### ConfigMap update without a Deployment rollout

In another Terminal, `KUBECONFIG` was initially empty and `kubectl` was still using the minikube context. A lookup for the kubeadm frontend therefore returned `NotFound`.

I corrected the terminal session with:

```bash
export KUBECONFIG="$HOME/.kube/task4-final-config"
```

and selected:

```text
kubernetes-admin@kubernetes
```

Before changing the ConfigMap, the Deployment reported the same generation/revision and I recorded the existing Pod names.

I then changed:

```text
VERSION_A
```

to:

```text
VERSION_B
```

and applied only the ConfigMap.

The Deployment generation/revision stayed unchanged and the Pod names remained unchanged. After the projected ConfigMap volume updated, the same Pods served:

```text
Feature flag: VERSION_B
```

This showed that updating a mounted ConfigMap does not itself change the Deployment Pod template and therefore does not cause a rollout. Kubernetes updates projected ConfigMap volume contents asynchronously on existing Pods.

---

## 7.3.2 Secret Consumption

I created the lab-only Secret manifest:

```text
k8s/frontend-secret.yaml
```

with the keys:

```text
db-user
db-password
```

The values were deliberately non-production demonstration credentials. `kubectl describe secret` showed the key sizes without printing their contents.

I updated the frontend Deployment to consume them through `secretKeyRef` as:

```text
DB_USER
DB_PASSWORD
```

### Base64 is not encryption

The Kubernetes Secret API commonly represents values using base64. Base64 only converts arbitrary bytes to a text-safe representation. Anyone who can read the Secret object can decode it; base64 provides no confidentiality by itself.

Production-grade alternatives include:

- **External Secrets Operator** backed by a provider such as Google Secret Manager, AWS Secrets Manager, or another managed secret store/KMS.
- **Sealed Secrets**, where an encrypted SealedSecret can safely be stored in Git and only the in-cluster controller can decrypt it.

In production I would also combine secret management with least-privilege RBAC and Kubernetes/etcd encryption at rest where applicable. Real credentials should not be committed in plaintext to a public repository.

---

# 7.4 Deploy the Full Demo Application

## 7.4.1 Online Boutique

I downloaded the Online Boutique v0.10.6 release manifest into:

```text
k8s/online-boutique.yaml
```

The tracked upstream manifest was 980 lines and referenced the v0.10.6 microservice images.

### First attempt on Apple Silicon minikube

I initially deployed the application into `shopstack` on minikube. Some of the v0.10.6 images inspected during this run were `linux/amd64`. Running those workloads on the Apple M2 minikube environment therefore involved emulation.

The existing minikube profile was also resource-constrained. During the rollout:

```text
CPU utilisation exceeded 200% of the Docker-host allocation
multiple liveness/readiness probes timed out
several services entered repeated restarts / CrashLoopBackOff
```

The events showed probe timeouts across several services, including cart, recommendation, currency, ad, and frontend.

I tried non-destructive resource troubleshooting. Starting the existing profile with a larger `--cpus` value produced:

```text
You cannot change the CPUs for an existing minikube cluster. Please first delete the cluster.
```

I deliberately did not delete/reset the cluster. I also tested increased Docker CPU quota and limited temporary CPU-limit adjustments while diagnosing the bottleneck.

The workload remained unreliable under this M2 emulation/resource combination, and the MacBook became noticeably saturated.

### Final deployment on native x86_64 kubeadm

Because the task explicitly prefers the kubeadm cluster, I stopped using minikube for the final Online Boutique runtime, restored the tracked release manifest to the clean upstream v0.10.6 form, switched back to `kubernetes-admin@kubernetes`, and applied it to the GCP kubeadm cluster.

On the native AMD64 workers, all twelve Online Boutique Deployments converged successfully to their desired `1/1` Ready state. The email and recommendation services had a small number of startup probe restarts while the stack was converging, but they remained stable afterward.

The important conclusion was not that Online Boutique universally lacks ARM support; rather, the exact v0.10.6 image/platform combination and resource limits observed in this run made the M2 minikube environment significantly less stable than the native x86_64 kubeadm workers.

---

## 7.4.2 Ingress at `shopstack.local`

For the primary kubeadm cluster, I installed ingress-nginx using the upstream bare-metal manifest. The controller became:

```text
1/1 Running
```

on `k8s-worker-2`, and the controller Service exposed NodePorts for HTTP/HTTPS.

I created:

```text
k8s/online-boutique-ingress.yaml
```

with:

```text
host: shopstack.local
path: /
backend: frontend:80
ingressClassName: nginx
```

I mapped:

```text
127.0.0.1 shopstack.local
```

in the MacBook Pro `/etc/hosts` file.

The GCP nodes only exposed private cluster addresses to this lab workflow, so I used a local port-forward to the ingress-nginx controller:

```bash
kubectl port-forward \
  -n ingress-nginx \
  service/ingress-nginx-controller \
  8080:80
```

Then:

```bash
curl -I http://shopstack.local:8080/
```

returned HTTP `200`.

A browser test also displayed Online Boutique.

### Browser HTTPS mistake

Chrome initially produced:

```text
ERR_SSL_PROTOCOL_ERROR
```

because it attempted HTTPS against the plain-HTTP local port-forward. Using the explicit URL:

```text
http://shopstack.local:8080/
```

fixed the browser test.

One later ingress port-forward session also reported:

```text
error: lost connection to pod
```

I restarted the same port-forward and it worked normally afterward.

### Explicit minikube ingress-addon requirement

Although the final application was on kubeadm, I separately started minikube and ran:

```bash
minikube addons enable ingress
```

`minikube addons list` showed:

```text
ingress   enabled
```

and the minikube ingress-nginx controller was `1/1 Running`. I then stopped minikube and returned to the kubeadm context.

---

## 7.4.3 Troubleshooting Drill — Broken Service Selector

I deliberately broke the Online Boutique frontend Service selector from:

```text
app=frontend
```

to:

```text
app=frontend-broken
```

The Service itself still existed, but:

```bash
kubectl get endpoints frontend
```

returned:

```text
<none>
```

and the EndpointSlice had no usable endpoint.

I diagnosed the failure using the required tools.

### `kubectl get` / `describe`

`kubectl describe service frontend` showed:

```text
Selector: app=frontend-broken
Endpoints:
```

while the frontend Pod had:

```text
app=frontend
```

### `kubectl logs`

The frontend application logs continued to show successful HTTP requests and successful `/_healthz` readiness requests. This established that the application process itself was healthy.

### `kubectl debug` / ephemeral containers

I attached a BusyBox ephemeral debug container to the frontend Pod and tested its local health endpoint. The debug container returned:

```text
ok
```

I then used another ephemeral container to call the Service DNS name. It resolved the Service ClusterIP but failed to connect:

```text
Connecting to frontend (10.106.92.186:80)
wget: can't connect to remote host ... Connection refused
```

### Root cause and fix

The application Pod was healthy, but the Service selector no longer matched the Pod label, so Kubernetes had no endpoints behind the Service.

I repaired the Service declaratively by re-applying the tracked Online Boutique manifest. The selector returned to:

```text
app=frontend
```

and the endpoint was restored on port `8080`.

This drill demonstrated why I should follow the path layer by layer: workload health, labels, Service selector, endpoints, and only then external routing.

---

# 7.5 Build a Container Image from Git — Podman and Docker

## 7.5.1 Write the Application and Commit It

I created:

```text
frontend-src/app.py
frontend-src/requirements.txt
```

The Python Flask application has two endpoints:

```text
GET /         -> HTML greeting plus version string
GET /healthz  -> HTTP 200 with "ok"
```

Dependencies were pinned:

```text
Flask==3.1.2
gunicorn==23.0.0
```

I tested the app locally in a temporary Python virtual environment with Gunicorn. The root page reported version `0.1.0` and `/healthz` returned HTTP `200`.

During the Task 4 audit I noticed that the source had been created before the required meaningful git commit was made. I reconstructed the actual `0.1.0` source state before the visible version bump and committed it as:

```text
046aac3 Add containerized ShopStack frontend v0.1.0
```

The later visible release change was committed separately as:

```text
65ccfd1 Release ShopStack frontend v0.2.0
```

This preserved a genuine versioned Git history rather than collapsing both states into one final commit.

---

## 7.5.2 Dockerfile, Non-root Runtime, and Image Size

The first container attempt used a pinned slim Python base. Functionally it worked and already ran as UID/GID `10001`, but the Podman image was approximately:

```text
158 MB
```

which was slightly above the task's approximate 150 MB target.

`podman history` showed the base image was the dominant layer, so I optimized the final Dockerfile to use the pinned base:

```dockerfile
FROM python:3.13-alpine3.22
```

The final image:

- uses a pinned base tag rather than `latest`;
- creates a dedicated `shopstack` account with UID/GID `10001`;
- runs with `USER 10001:10001`;
- uses Gunicorn on port `8080`;
- installs only the pinned application requirements;
- includes a `.dockerignore` to exclude local artifacts.

The Podman image dropped to approximately:

```text
57.6 MB
```

which was comfortably below the target.

The task allows either a multi-stage build or at minimum a slim/distroless-style base. This implementation uses a small Alpine runtime rather than a multi-stage build.

---

## 7.5.3 Podman as the Primary Tool

Podman was not initially installed on the MacBook Pro:

```text
zsh: command not found: podman
```

I installed Podman 6.1.1 with Homebrew. Because macOS does not provide a native Linux kernel for Linux containers, Podman uses a lightweight Linux Podman Machine. I initialized and started a rootless ARM64 Podman Machine with 2 CPUs, 2 GiB memory, and a 20 GiB disk.

The final semantic local image tag was:

```text
shopstack-frontend:0.1.0
```

I built and ran it with Podman, verified the root page, verified `/healthz`, and confirmed inside the container:

```text
uid=10001(shopstack) gid=10001(shopstack)
```

I also used:

```text
podman images
podman inspect
podman history
```

The optimized ARM64 image reported approximately `57.6 MB`.

For comparison during optimization I retained evidence of:

```text
0.1.0-slim    ~158 MB
0.1.0-alpine  ~57.6 MB
```

### Podman architecture compared with Docker

Podman is daemonless: normal CLI operations do not depend on one long-running privileged central daemon equivalent to `dockerd`. The Podman CLI and libraries create the necessary container processes through a fork/exec model and an OCI runtime such as `crun`/`runc`.

Podman also supports rootless operation as a first-class mode. Reducing the privileges of the container-management process limits the impact of a container-engine compromise.

Its process-oriented model integrates naturally with systemd. A Podman container can be represented by a systemd user unit, which is exactly what I later demonstrated on `k8s-worker-2` with `podman generate systemd --new`.

On macOS, the Podman CLI still requires the Podman Machine Linux VM because the containers themselves need a Linux kernel; that does not change the daemonless/rootless model inside the Linux container host.

---

## 7.5.4 Build the Same Dockerfile with Docker and Scan It

I built the same final Dockerfile with Docker Desktop.

Docker inspection showed:

```text
Architecture: arm64
OS: linux
User: 10001:10001
Image ID: sha256:0e465d970c8174c1cd671b55d481aa2288adec372e90f1140e31d61cdc0f8998
```

Docker's inspect content size was approximately:

```text
19.3 MB
```

while Docker Desktop's local disk accounting displayed a larger disk-use figure.

The equivalent final Podman Alpine build reported:

```text
Podman image ID:
33d5178de1f31b51f59c4a2e9cb342950afdb638cce39cc6a39fe05a5f8d04b5

Podman size:
57.6 MB
57640187 bytes
```

The Docker and Podman image IDs were therefore different even though both were built from the same Dockerfile.

These values do not have to match byte-for-byte even with the same Dockerfile. Different builders can emit different creation metadata, timestamps, manifests, provenance, and storage bookkeeping. The important OCI compatibility result was that the same Dockerfile built and ran correctly with both engines, with the same application behaviour and non-root UID.

### Trivy findings

I installed Trivy 0.74.0 and scanned:

```bash
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --format table \
  shopstack-frontend:0.1.0
```

Trivy detected Alpine 3.22.4. The scan recorded:

```text
HIGH:     10
CRITICAL: 0
```

The Python-package section did not report vulnerabilities in this scan. The OS findings included OpenSSL packages (`libcrypto3`/`libssl3`) and util-linux/libuuid-related findings, with fixed versions shown for the relevant entries because `--ignore-unfixed` was used.

The later CI security gate intentionally fails only on `CRITICAL` vulnerabilities, so this image passed that gate while still leaving the HIGH findings visible for normal remediation planning.

---

## 7.5.5 Push to GHCR

At this stage the local repository did not yet have a GitHub remote. I authenticated GitHub CLI as:

```text
culerty516
```

For the initial Podman package push I used a separate scoped GHCR access token entered through a hidden shell variable and piped to:

```text
podman login ghcr.io --password-stdin
```

The token itself was not printed or committed.

Because the kubeadm worker nodes are AMD64, I built an AMD64 image with Podman and pushed:

```text
ghcr.io/culerty516/shopstack-frontend:0.1.0
```

The pushed image was initially a **single-platform OCI image**, not a multi-architecture index. Therefore:

```text
podman manifest inspect ...
```

returned an error explaining that treating a single image as a manifest list was not implemented. This was not a failed push; the multi-architecture index was intentionally created later in Section 7.6 of Task 4.

An anonymous remote inspection initially received `401 Unauthorized` because the GHCR package was private. I changed the package visibility to public. After that, I logged Docker out of GHCR and successfully pulled the package anonymously, proving the cluster could also pull it without an imagePullSecret.

---

## 7.5.6 Deploy My Own Image and Release `0.2.0`

I created:

```text
k8s/frontend-own-deployment.yaml
```

The Deployment uses:

```text
image: ghcr.io/culerty516/shopstack-frontend:0.1.0
replicas: 3
containerPort: 8080
readiness: /healthz
liveness: /healthz
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
```

I replaced the Online Boutique frontend workload with my own image while keeping the `frontend` Service/Ingress path. The rollout reached three Ready Pods and the ingress response showed:

```text
Version: 0.1.0
```

with `/healthz` returning HTTP `200`.

I then made the required visible application change. Version `0.2.0` added:

```text
Release: Kubernetes-ready frontend
```

I rebuilt the AMD64 image with Podman, pushed:

```text
ghcr.io/culerty516/shopstack-frontend:0.2.0
```

and updated the tracked Deployment to version `0.2.0`.

The rollout completed successfully and all three Pods were Ready. The ingress response showed:

```text
Version: 0.2.0
Release: Kubernetes-ready frontend
```

and `/healthz` still returned HTTP `200`.

These `0.1.0` and `0.2.0` application states are the pair intended for the later Istio canary exercise.

---

## 7.5.7 Tagging Discipline

I do not deploy mutable `latest` tags for this lab.

`latest` is an anti-pattern because the same tag can point at different image content over time. A Deployment manifest that says only `image: app:latest` therefore does not provide a durable mapping from source/release to artifact. Rollback becomes ambiguous because an older Kubernetes ReplicaSet may still refer to the same mutable tag while the registry now serves different bytes.

`imagePullPolicy` adds another source of confusion. If the pull policy is omitted when an object is first created, Kubernetes commonly defaults `latest` to `Always` and a non-`latest` tag to `IfNotPresent`. The stored `imagePullPolicy` field does not automatically change merely because the image tag is edited later. Relying on implicit tag/pull behaviour is therefore fragile.

My convention is:

```text
semver tags for human releases: 0.1.0, 0.2.0
immutable full Git SHA tags for CI builds
```

This makes build provenance and rollback targets explicit.

---

## 7.5.8 Rootless Podman with a systemd User Unit on a VM

The original task names a Proxmox VM. The Final Run uses the documented GCP cloud-VM substitution from Tasks 2–3, so I used the existing Ubuntu 24.04 AMD64 worker `k8s-worker-2`. This preserves the learning objective: run the registry image rootlessly on a normal Linux host outside Kubernetes and manage it with a systemd user service.

I installed Podman from Ubuntu packages on `k8s-worker-2` and verified:

```text
podman version 4.9.3
rootless=true
arch=amd64
```

The normal `ubuntu` user also had subordinate UID/GID ranges in `/etc/subuid` and `/etc/subgid`.

One first `podman info --format` expression attempted to access a field not exposed by this Podman version and returned a Go-template field error. I reran the command using only the supported `Rootless` and `Arch` fields.

I pulled the public image:

```text
ghcr.io/culerty516/shopstack-frontend:0.2.0
```

and ran it rootlessly bound only to:

```text
127.0.0.1:18080 -> container 8080
```

The root page and `/healthz` both worked, and:

```bash
podman exec shopstack-frontend id
```

showed:

```text
uid=10001(shopstack) gid=10001(shopstack)
```

I generated the required systemd user unit with:

```bash
podman generate systemd \
  --new \
  --name \
  shopstack-frontend \
  > ~/.config/systemd/user/container-shopstack-frontend.service
```

Podman 4.9.3 printed a deprecation notice recommending Quadlets for new deployments. I retained `podman generate systemd --new` here because the practice task explicitly requires demonstrating that command.

I stopped/removed the manually started container, reloaded the user manager, and enabled the generated service. `systemctl --user status` reported:

```text
Active: active (running)
```

under the user's systemd slice.

I enabled user lingering with `loginctl` so the user service could stay active independently of an interactive SSH login. After logging out and reconnecting, the service was still active and the page still returned version `0.2.0`.

Installing Podman on the Kubernetes worker did not replace or reconfigure the Kubernetes CRI. kubelet continued using containerd; Podman was a separate user-space container tool for this host exercise.

---

# 7.6 CI/CD — Multi-Architecture Images with GitHub Actions

## 7.6.1 Repository and Workflow

I created the public GitHub repository:

```text
culerty516/shopstack-devops-lab
```

and added it as `origin`.

The CI workflow is:

```text
.github/workflows/build-image.yaml
```

It is triggered by:

```text
push to main
push of tags matching v*
workflow_dispatch
```

The initial workflow was committed as:

```text
1618be3 Add multi-arch container CI pipeline
```

---

## 7.6.2 Multi-arch Build and GHCR Push

The workflow performs the required build path:

```text
actions/checkout@v4
docker/setup-qemu-action@v3
docker/setup-buildx-action@v3
GHCR login with the built-in GITHUB_TOKEN
docker buildx build --platform linux/amd64,linux/arm64 --push
```

It pushes the image with the immutable full Git SHA. When the Git ref is a version tag such as `v0.2.0`, it additionally strips the leading `v` and pushes the semantic version tag `0.2.0`.

The workflow does not store a long-lived personal registry token for normal CI image publication; it uses the repository-scoped built-in `GITHUB_TOKEN` with `packages: write` permission.

---

## 7.6.3 Verify the Manifest List and Run ARM64

The first green `main` CI image used Git SHA:

```text
1618be311e79937b3befe47c94f6efdf2a7a692f
```

I inspected it with:

```bash
docker buildx imagetools inspect \
  ghcr.io/culerty516/shopstack-frontend:1618be311e79937b3befe47c94f6efdf2a7a692f
```

The OCI index contained:

```text
linux/amd64
linux/arm64
```

plus `unknown/unknown` attestation manifests generated by the build tooling.

The index digest was:

```text
sha256:e20c0bebd149d5cda992cf70e72a313c25393ffa0664e7a015e04a469daf9168
```

I then explicitly pulled the ARM64 platform on the Apple M2 MacBook Pro and inspected it as:

```text
ARCH=arm64 OS=linux USER=10001:10001
```

I ran that ARM64 image locally. The page returned version `0.2.0`, `/healthz` returned HTTP `200`, and the container ran as UID/GID `10001`.

This demonstrated that the same registry tag could resolve to the appropriate platform-specific manifest on an ARM64 machine.

---

## 7.6.4 Manual Trigger and Trivy CRITICAL Gate

The workflow includes:

```yaml
workflow_dispatch:
```

for manual execution.

A separate scan job runs Trivy 0.74.0 against both:

```text
linux/amd64
linux/arm64
```

with:

```text
--exit-code 1
--severity CRITICAL
```

Therefore a CRITICAL vulnerability on either platform fails the workflow.

The verified runs completed the scan job successfully with no CRITICAL findings.

---

## 7.6.5 Green Runs, Build Time, and Buildx Cache

The first green push run was:

```text
Run ID: 34775919450
Branch: main
Result: success
```

Its measured multi-architecture build step took:

```text
38 seconds
```

The workflow originally included `cache-from` and `cache-to` settings for the GitHub Actions cache, but a log inspection did not show actual BuildKit cache import/hits.

I corrected the inline Buildx environment by adding the GitHub Actions runtime exposure step and committed the cache fix as:

```text
72b17ba Enable GitHub Actions Buildx cache
```

After one run populated the cache, I triggered the workflow manually. The cached run was:

```text
Run ID: 34776876099
Event: workflow_dispatch
Result: success
```

Its build logs showed:

```text
importing cache manifest from gha:...
CACHED
CACHED
...
```

across the Dockerfile steps, and the measured multi-architecture build time dropped to:

```text
6 seconds
```

This demonstrates the purpose of `cache-from`/`cache-to`: BuildKit can reuse unchanged layers from a previous workflow execution rather than rebuilding them on every clean GitHub-hosted runner.

A version tag was also tested. I created/pushed `v0.2.0`, which triggered a green tag run and published `ghcr.io/culerty516/shopstack-frontend:0.2.0` as a proper multi-architecture OCI index containing both AMD64 and ARM64 manifests.

## 7.6.6 Stretch Goal — Automated Deploy Stage

I extended the workflow so a successful push to `main` continues from image build and Trivy scanning into a Helm deployment against the kubeadm cluster.

The deploy job is ordered after both previous jobs:

```text
build -> scan -> deploy
```

and is limited to pushes to `main`:

```yaml
if: github.event_name == 'push' && github.ref == 'refs/heads/main'
```

The deployment uses a repository-level self-hosted runner on the MacBook Pro with the custom label:

```text
task4-deploy
```

I used GitHub Actions Runner `2.337.0` and registered it with `--ephemeral`, so it accepts one job and then automatically removes its runner credentials/registration. This avoided leaving a permanently available general-purpose runner attached to the public repository.

The deploy job performs the following path:

```text
checkout repository
-> configure Homebrew kubectl/Helm paths
-> reuse/start the local kubeadm SSH API tunnel
-> helm upgrade --install with image.tag=<full Git SHA>
-> wait for the Deployment rollout
-> verify the live Deployment image equals the expected SHA image
-> port-forward the Service
-> verify the application page contains the Git SHA
-> verify /healthz returns ok
```

The Helm command uses an immutable image tag rather than `latest`:

```bash
helm upgrade --install shopstack-frontend \
  charts/frontend-chart \
  --namespace shopstack \
  --kube-context kubernetes-admin@kubernetes \
  --set image.repository="${IMAGE_REPOSITORY}" \
  --set-string image.tag="${GITHUB_SHA}" \
  --wait \
  --timeout 5m
```

### First deploy run: failed on macOS shell compatibility

The first deployment-enabled workflow run was:

```text
Run ID: 34820950439
Commit: ad669e3 Add automated Helm deployment stage
```

The build and scan jobs both passed, and the self-hosted runner successfully reached the kubeadm API. All three nodes were reported `Ready`. The deploy job then failed before `helm upgrade` executed with:

```text
bad substitution
```

The failing expression was:

```bash
${GITHUB_REPOSITORY_OWNER,,}
```

That Bash 4+ lowercase expansion had worked on the GitHub-hosted Ubuntu build runner, but the macOS self-hosted runner executed workflow shell steps with Apple's `/bin/bash`, which does not support that syntax.

I changed only the failing portability point, replacing the Bash-specific expansion with:

```bash
IMAGE_OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
```

I verified the replacement directly with macOS `/bin/bash`, then committed the fix as:

```text
17ea244 Fix macOS deploy runner shell compatibility
```

Because the first runner was ephemeral, it had already consumed its single job and deregistered even though that job failed. I registered a new ephemeral runner for the retry.

### Successful end-to-end deployment

The corrected workflow run was:

```text
Run ID: 34822419994
Commit SHA: 17ea2441328d1945fd0d10b5a4c3adb7691382fe
Result: success
```

All three jobs were green:

```text
Build and push multi-arch image       18s   success
Trivy CRITICAL vulnerability gate     26s   success
Deploy SHA image to kubeadm          1m18s  success
```

The deploy job upgraded the existing Helm release:

```text
Release: shopstack-frontend
Namespace: shopstack
Status: deployed
Revision: 2
```

The rollout verification compared the expected and live images and they matched exactly:

```text
Expected: ghcr.io/culerty516/shopstack-frontend:17ea2441328d1945fd0d10b5a4c3adb7691382fe
Deployed: ghcr.io/culerty516/shopstack-frontend:17ea2441328d1945fd0d10b5a4c3adb7691382fe
```

The CI application check returned the new immutable version from the page:

```text
Version: 17ea2441328d1945fd0d10b5a4c3adb7691382fe
Release: Kubernetes-ready frontend
```

and `/healthz` returned:

```text
ok
```

Post-run cluster verification showed Helm history:

```text
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         deployed    Upgrade complete
```

and three frontend Pods were `1/1 Running` across `k8s-worker-1` and `k8s-worker-2`.

The ephemeral runner then printed:

```text
Job Deploy SHA image to kubeadm completed with result: Succeeded
Removed .credentials
Removed .runner
```

A subsequent repository-runner API query returned no runner entries, confirming that the temporary runner deregistered cleanly.

### Cluster credentials and GitOps security discussion

For this lab I deliberately did **not** upload the kubeconfig or the ShopStack SSH private key to GitHub Secrets. The self-hosted runner used the MacBook Pro's existing local kubeconfig:

```text
~/.kube/task4-final-config
```

and the existing SSH configuration/tunnel to reach the private kubeadm API.

This avoids storing long-lived cluster credentials in the hosted CI service, but it does not remove the trust problem: workflow code running on a self-hosted runner can potentially access credentials and files available to the runner account. This is especially important for a public repository. I reduced that exposure in this lab by using a repository-scoped runner, a specific deploy label, and an **ephemeral** one-job registration rather than leaving a permanent runner online.

For production, a pull-based GitOps model such as **Argo CD** or **Flux** is preferable where practical. CI can build, scan, and publish the immutable image and update desired state in Git, while an in-cluster controller pulls and reconciles that state. This keeps direct cluster credentials out of the hosted CI path and gives the cluster-side controller an auditable reconciliation model.

The Node.js 20 deprecation annotations shown by GitHub Actions were warnings from third-party/action runtime compatibility; they did not cause the successful run to fail.

---

# 7.7 Package Management with Helm

## 7.7.1 Helm 3 and Helm 2 Comparison

The MacBook Pro initially had Helm 4.3.0 on PATH. Because the practice task explicitly requires Helm 3, I installed the Homebrew `helm@3` keg and placed it first in PATH.

Verification returned:

```text
/opt/homebrew/opt/helm@3/bin/helm
Helm v3.22.0
```

I left Helm 4 installed but used Helm 3 for this task.

### Helm 3 vs Helm 2

Helm 2 depended on the in-cluster **Tiller** server component, which performed privileged release operations on behalf of Helm clients. This created a significant operational and security surface, particularly when Tiller had broad cluster permissions.

Helm 3 is client-only from the user's perspective and communicates directly with the Kubernetes API using the caller's kubeconfig/RBAC identity. There is no Tiller server.

By default, Helm 3 stores release records in Kubernetes **Secrets** in the target namespace. These records include rendered release information and historical revisions used for operations such as `helm history` and rollback.

---

## 7.7.2 Bitnami Repository, `--set`, Values File, and Precedence

I added/used the Bitnami repository and searched for nginx. The chart used in this exercise was:

```text
bitnami/nginx
chart version: 25.1.11
app version: 1.31.5
```

I installed it into a new namespace with the custom release name:

```text
shopstack-nginx-lab
```

and initially overrode:

```text
replicaCount=2
```

using `--set`.

The release became revision `1` and the Deployment reached `2/2`.

Bitnami emitted warnings that this chart version used rolling `latest` image tags in its current public catalog configuration and recommended explicit production resource settings. I treated that as a useful example of why chart defaults must be reviewed rather than trusted blindly.

I then created:

```text
charts/helm-lab-values.yaml
```

with:

```yaml
replicaCount: 3
service:
  type: ClusterIP
```

I upgraded the same release with the values file and pinned chart version `25.1.11`. Revision `2` reached `3/3` and the Service changed to `ClusterIP`.

### Value precedence

For the parts used in this task, Helm applies values roughly from lower to higher precedence as:

```text
chart defaults
< values files supplied with -f/--values (later files override earlier files)
< command-line overrides such as --set / --set-string
```

This lets a reusable chart provide safe defaults while environment/release-specific files and explicit CI overrides replace only the values that need to differ.

---

## 7.7.3 Upgrade, History, Rollback, List, and Status

After the values-file upgrade, `helm history` showed:

```text
1  superseded  Install complete
2  deployed    Upgrade complete
```

I rolled the release back to revision `1`:

```bash
helm rollback \
  shopstack-nginx-lab \
  1 \
  --namespace helm-lab
```

The rollback succeeded. The Deployment returned to two replicas and the Service returned to the revision-1 `LoadBalancer` configuration.

`helm history` then showed a new revision:

```text
1  superseded  Install complete
2  superseded  Upgrade complete
3  deployed    Rollback to 1
```

I listed releases across all namespaces:

```bash
helm list -A
```

Key result:

```text
NAME                 NAMESPACE  REVISION  UPDATED                               STATUS    CHART          APP VERSION
shopstack-nginx-lab  helm-lab   3         2026-09-14 03:23:23.973638 +0800 HKT  deployed  nginx-25.1.11  1.31.5
```

I then inspected the release directly:

```bash
helm status \
  shopstack-nginx-lab \
  -n helm-lab
```

Key result:

```text
NAME: shopstack-nginx-lab
LAST DEPLOYED: Mon Sep 14 03:23:23 2026
NAMESPACE: helm-lab
STATUS: deployed
REVISION: 3
TEST SUITE: None
CHART NAME: nginx
CHART VERSION: 25.1.11
APP VERSION: 1.31.5
```

For the repository deliverable, I also saved the live Helm revision history under `charts/`:

```bash
helm history shopstack-nginx-lab \
  -n helm-lab \
  > charts/helm-history-evidence.txt
```

The evidence file contains:

```text
REVISION  UPDATED                   STATUS      CHART          APP VERSION  DESCRIPTION
1         Mon Sep 14 03:18:33 2026  superseded  nginx-25.1.11  1.31.5       Install complete
2         Mon Sep 14 03:21:04 2026  superseded  nginx-25.1.11  1.31.5       Upgrade complete
3         Mon Sep 14 03:23:23 2026  deployed    nginx-25.1.11  1.31.5       Rollback to 1
```

This demonstrates that Helm rollback creates another release revision instead of deleting history.

---

## 7.7.4 Inspect a Chart Before Installation

I inspected Bitnami's defaults with:

```bash
helm show values \
  bitnami/nginx \
  --version 25.1.11 \
  > /tmp/bitnami-nginx-default-values.yaml
```

The default file contained about 1307 lines. Important defaults included:

```text
replicaCount: 1
service.type: LoadBalancer
resourcesPreset: nano
resources: {}
```

I rendered the chart locally with my values file:

```bash
helm template shopstack-nginx-preview \
  bitnami/nginx \
  --namespace helm-lab \
  --version 25.1.11 \
  --values charts/helm-lab-values.yaml \
  > /tmp/shopstack-nginx-preview.yaml
```

The rendered output included resources such as a NetworkPolicy, PodDisruptionBudget, ServiceAccount, Secret, Service, and Deployment. It showed:

```text
replicas: 3
Service type: ClusterIP
```

The preview was not installed; `helm list` still contained only the real `shopstack-nginx-lab` release.

---

## 7.7.5 Author and Deploy the ShopStack Frontend Chart

I scaffolded:

```bash
helm create charts/frontend-chart
```

and then deliberately trimmed the generated chart to the Task 4 frontend resources.

The final chart contains:

```text
charts/frontend-chart/Chart.yaml
charts/frontend-chart/values.yaml
charts/frontend-chart/templates/deployment.yaml
charts/frontend-chart/templates/service.yaml
charts/frontend-chart/templates/ingress.yaml
charts/frontend-chart/.helmignore
```

The chart metadata is:

```text
chart version: 0.1.0
appVersion: 0.2.0
```

The default values parameterize:

```text
replicaCount: 3
image.repository: ghcr.io/culerty516/shopstack-frontend
image.tag: 0.2.0
image.pullPolicy: IfNotPresent
service.type: ClusterIP
service.port: 80
ingress.className: nginx
ingress.host: shopstack.local
resource requests: 50m CPU / 64Mi
resource limits: 200m CPU / 128Mi
```

The Deployment template also preserves the `/healthz` probes and non-root UID/GID `10001`.

Validation:

```bash
helm lint charts/frontend-chart
```

returned:

```text
1 chart(s) linted, 0 chart(s) failed
```

The only lint note was the optional recommendation to add an icon.

I rendered the chart locally and verified the generated objects were only:

```text
Service
Deployment
Ingress
```

with the correct multi-architecture GHCR image, three replicas, resources, ClusterIP Service, and `shopstack.local` Ingress.

The chart and Helm lab values were committed as:

```text
a2918fc Add ShopStack frontend Helm chart
```

### Replace the loose frontend resources with the Helm release

Before Helm installation, there was no Helm release in `shopstack`; the frontend Deployment, Service, and Ingress were still the loose-manifest versions.

I explicitly deleted those three plain-managed frontend resources and confirmed they no longer existed. I then installed the chart using the CI/CD-friendly form:

```bash
helm upgrade --install shopstack-frontend \
  charts/frontend-chart \
  --namespace shopstack \
  --wait \
  --timeout 5m
```

Helm reported:

```text
Release "shopstack-frontend" does not exist. Installing it now.
STATUS: deployed
REVISION: 1
```

The Helm-managed Deployment became `3/3`, the Service had three endpoints on port `8080`, and the Ingress advertised `shopstack.local`.

Through the ingress-nginx port-forward:

```text
Version: 0.2.0
Release: Kubernetes-ready frontend
```

and `/healthz` returned HTTP `200`.

I also verified Helm ownership metadata on the Deployment, Service, and Ingress:

```text
managed-by=Helm
release-name=shopstack-frontend
release-namespace=shopstack
```

### Helm lifecycle vs loose manifests

With loose manifests, Kubernetes stores objects but does not have an application-level release concept connecting all of them into one versioned unit. I must track which YAML files belong together and explicitly apply/delete them.

With Helm, the release record groups the rendered resources and their revision history. Running:

```text
helm uninstall shopstack-frontend -n shopstack
```

would remove the resources owned by that release. I did not uninstall the final frontend release because it is the desired end state for the next tasks.

---

## 7.7.6 Stretch Goal — Package and Distribute the Chart with OCI

I packaged the chart:

```bash
helm package \
  charts/frontend-chart \
  --destination /tmp/shopstack-helm-packages
```

The package was:

```text
frontend-chart-0.1.0.tgz
```

and `helm show chart` confirmed:

```text
name: frontend-chart
version: 0.1.0
appVersion: 0.2.0
```

I authenticated Helm to GHCR and pushed the chart as an OCI artifact:

```text
ghcr.io/culerty516/charts/frontend-chart:0.1.0
```

The OCI artifact digest was:

```text
sha256:ca624f3d505df842bd7c1309d91d25c150e83b7c60cf34ca81db4c75ce27cb3f
```

I then pulled version `0.1.0` back from GHCR. The pulled artifact reported the same OCI digest.

Finally, I compared the local packaged tarball with the tarball pulled back from the registry. Both files had:

```text
SHA256 36da64dd3eb8be743d9f7fdb10d5b7002cbd42a612a804b59f41beaaf1f1731a
```

This verified that the downloaded `.tgz` was byte-for-byte identical to the package I pushed.

The OCI artifact digest and the tarball SHA256 are different identifiers for different objects/layers in the distribution model, so they are not expected to be identical to one another.

### Chart repository vs OCI distribution

A traditional Helm chart repository distributes packaged `.tgz` charts over HTTP together with an `index.yaml`; clients add it with `helm repo add` and refresh metadata with `helm repo update`.

An OCI registry stores the chart as an OCI artifact and uses registry workflows such as:

```text
helm push oci://...
helm pull oci://...
```

OCI distribution lets teams use the same registry authentication, access controls, retention/governance, and content-addressed digest concepts for both container images and Helm charts. In this lab, GHCR now stores both the ShopStack frontend image and the frontend Helm chart.

---

# Checkpoint Questions

## 1. What is the difference between a Service of type `ClusterIP`, `NodePort`, and `LoadBalancer`?

`ClusterIP` exposes a stable virtual IP that is reachable only inside the cluster. It is the normal choice for internal service-to-service communication and was used for the ShopStack frontend Service.

`NodePort` allocates a port on each Kubernetes node and forwards traffic received on `<node-ip>:<node-port>` to the Service. It makes a Service externally reachable if the node network/firewall allows it, but exposes infrastructure details and is usually a lower-level building block rather than the preferred production entry point.

`LoadBalancer` asks an integrated cloud/controller implementation to provision or attach an external load balancer and route it to the Service. On a bare kubeadm cluster without such an integration, the external IP can remain `pending`, which is exactly what was observed with the Bitnami lab release.

---

## 2. What actually happens inside the cluster when you run `kubectl apply -f deployment.yaml`?

`kubectl` reads the manifest, resolves the target API resource, and sends the desired object to the Kubernetes API server using an apply/patch operation. The API server authenticates and authorizes the request, runs admission, validates/defaults the object, and stores the resulting desired state in etcd.

For a Deployment, the Deployment controller notices the desired state and creates/updates a ReplicaSet. The ReplicaSet controller creates the required Pods. The scheduler assigns unscheduled Pods to suitable nodes. Kubelets on those nodes pull/start the container images through the CRI runtime and continually report status. Other controllers update related state such as EndpointSlices when Pods become Ready.

The important model is reconciliation: `kubectl apply` declares desired state; controllers do the ongoing work needed to make actual state match it.

---

## 3. Why did the broken readiness probe not restart the Pod, while a broken liveness probe would?

Readiness answers: **should this Pod receive traffic now?** A failed readiness probe makes the Pod NotReady and removes it from normal Service endpoints, but the process may still be healthy and useful while warming up or waiting on a dependency.

Liveness answers: **is this container still healthy enough to keep running?** Repeated liveness failure tells kubelet that the container should be restarted according to its restart policy.

In this lab, the intentionally broken readiness path returned HTTP 404, the Pod remained Running with restart count 0, and the EndpointSlice marked it `ready:false`.

---

## 4. What problem does Helm solve that plain `kubectl apply` does not, and when might plain manifests or Kustomize be preferable?

Helm packages multiple Kubernetes resources as one versioned application release. It provides templating/values, reusable configuration, dependency packaging, release revision history, upgrade, rollback, and uninstall semantics.

Plain manifests can be preferable when the application is small and explicit YAML is clearer than introducing a template language. Kustomize can be preferable when I want to keep valid plain Kubernetes YAML and layer environment-specific patches/overlays without turning the manifests into templates.

Helm is especially valuable for a reusable application package with multiple configurable environments; plain YAML/Kustomize can be simpler for platform resources where transparency and direct Kubernetes-native configuration matter more than application packaging.

---

## 5. What does `helm upgrade --install` do, and why is it the standard form in CI/CD pipelines?

`helm upgrade --install <release> <chart>` is an idempotent-style release command:

- if the named release exists, Helm upgrades it;
- if it does not exist, Helm installs it.

A pipeline therefore does not need separate branching logic for first deployment versus later releases. The same command can converge the release to the chart/values provided by that CI/CD run.

In this task, the first `shopstack-frontend` invocation printed that the release did not exist and installed revision 1.

---

## 6. Where does Helm store release state, and what are the security implications?

Helm 3 normally stores release state as Kubernetes Secrets in the release namespace. Those records allow Helm to reconstruct release history and perform operations such as rollback.

Kubernetes Secret data is not magically confidential merely because the resource kind is `Secret`; its API representation is base64-encoded and the data may also exist in etcd. Access must therefore be protected with Kubernetes RBAC and, for stronger protection, encryption at rest for Kubernetes/etcd data.

A user who can read Helm release Secrets may learn rendered configuration, including values that should never have contained plaintext credentials in the first place. Sensitive values should come from a proper secret-management workflow rather than being embedded casually in chart values.

---

## 7. Why should a container run as a non-root user, and what does a multi-stage build buy you?

Running as non-root limits the privileges available if the application or one of its dependencies is compromised. It reduces the chance that a container escape or accidental filesystem operation immediately has root-level impact and works with Kubernetes security controls such as `runAsNonRoot`.

A multi-stage build separates build-time tooling from the final runtime filesystem. Compilers, package managers, source trees, and temporary build artifacts can remain in an earlier stage while only the final executable/runtime files are copied into the last stage. This usually reduces image size and attack surface.

This lab used the task's allowed alternative rather than a multi-stage build: the final image used a small pinned Alpine Python base and ran as UID/GID 10001, reducing the initial ~158 MB image to ~57.6 MB.

---

## 8. What is an OCI image manifest list, and why does a single tag now work on both AMD64 and ARM64 machines?

A multi-platform OCI image tag points to an **image index** (commonly called a manifest list). The index contains references to separate image manifests for combinations such as:

```text
linux/amd64
linux/arm64
```

When a client pulls the tag, the container engine selects the manifest matching its OS/architecture and downloads the correct layers.

The GitHub Actions workflow created one multi-architecture tag for the ShopStack frontend. `docker buildx imagetools inspect` showed both AMD64 and ARM64 entries, and the Apple M2 MacBook pulled/reran the ARM64 variant from the same Git SHA tag successfully.

---

## 9. Why does Podman not need a daemon, and why does that matter for security and systemd integration?

Podman does not require a permanent central daemon to own normal container lifecycles. The CLI/libpod process creates containers through the OCI runtime and supporting processes, then the application container can continue independently.

This removes a long-running privileged daemon from the normal control path and makes rootless operation practical, reducing the privilege boundary for normal users.

It also maps well to systemd because containers can be managed as ordinary service processes. In the VM exercise I generated a user unit, enabled it with `systemctl --user`, enabled lingering, logged out, and confirmed the rootless container service remained active.

---

## 10. Trace the full path of your code: what happens between `git push` and a Pod serving the new version? Which steps are automated and which are still manual?

For the final Task 4 implementation, the `main` branch path is:

```text
source change in frontend-src/ or deployment workflow
        |
git commit + git push main
        |
GitHub Actions trigger
        |
GitHub-hosted build job
checkout source
        |
QEMU + Docker Buildx
        |
build one multi-platform OCI index
  linux/amd64 + linux/arm64
        |
push immutable full Git-SHA tag to GHCR
        |
Trivy scans AMD64 and ARM64
CRITICAL finding would fail the workflow
        |
self-hosted ephemeral MacBook deploy runner
        |
verify/reuse SSH tunnel to private kubeadm API
        |
helm upgrade --install
--set-string image.tag=<full Git SHA>
        |
Kubernetes API stores the new Helm release state
        |
Deployment/ReplicaSet creates replacement Pods
        |
containerd pulls the matching AMD64 image manifest
        |
readiness probe passes
        |
Service EndpointSlice includes the Ready Pods
        |
CI verifies rollout and exact live image tag
        |
CI port-forwards the frontend Service
        |
CI checks the page contains the same Git SHA
and /healthz returns ok
        |
Pod is serving the new version
```

Version-tag (`v*`) runs still build and publish the semver tag, but the deploy job is intentionally restricted to `push` events on `main`.

### Automated in Task 4

- workflow trigger after a push to `main`;
- multi-architecture AMD64/ARM64 image creation;
- immutable Git-SHA publication to GHCR;
- Buildx layer-cache use;
- CRITICAL vulnerability gate on both architectures;
- deploy job dependency on successful build and scan jobs;
- kubeadm API connectivity check;
- Helm upgrade using the exact Git SHA image;
- Deployment rollout verification;
- exact expected-vs-deployed image comparison;
- application response and `/healthz` verification.

### Still manual in this lab

- the developer still chooses/makes the source change, commits it, and pushes it;
- because I intentionally used a one-job ephemeral self-hosted runner for this public lab repository, I manually register/start that runner before the deployment workflow needs it;
- a production promotion/approval policy is not modelled here.

Once the ephemeral runner is registered and listening, the path from a successful `main` push through build, scan, Helm upgrade, rollout, and application verification is automated.

For production, I would prefer GitOps with Argo CD or Flux for the final reconciliation step so hosted CI does not need direct cluster credentials.

---

# Task 4 Summary

All mandatory Task 4 practical requirements were completed successfully.

The final implementation demonstrated:

- verification and operation of the three-node kubeadm cluster from the MacBook Pro through a private SSH tunnel;
- a minikube scratch cluster and explicit context switching;
- control-plane component and static-pod inspection;
- a dedicated `shopstack` namespace;
- bare-Pod creation only for the required exercise, followed by controller-based workloads;
- declarative Deployment and ClusterIP Service management;
- rolling update, revision history, rollback, resource controls, liveness/readiness probes, and readiness-failure behaviour;
- scaling from 3 to 5 replicas and an HPA that successfully scaled 5 -> 8 at a 50% CPU target;
- ConfigMap mounting and live ConfigMap update behaviour without a Deployment rollout;
- Kubernetes Secret consumption through environment variables and secret-management analysis;
- Online Boutique v0.10.6 deployment, including a documented Apple Silicon minikube resource/emulation investigation and final stable native AMD64 kubeadm deployment;
- ingress-nginx, `shopstack.local`, `/etc/hosts`, and a working HTTP ingress path;
- the required deliberate Service-selector failure diagnosed with `get`, `describe`, `logs`, and ephemeral `kubectl debug` containers;
- a custom Flask frontend with `/` and `/healthz`;
- a pinned, non-root OCI Dockerfile reduced to ~57.6 MB;
- Podman-primary build/run/inspect/history workflow and Docker comparison;
- Trivy scanning with 10 HIGH and 0 CRITICAL findings in the recorded local scan;
- public GHCR publication of `0.1.0` and `0.2.0`;
- visible Kubernetes rollout from frontend `0.1.0` to `0.2.0`;
- semantic-version and immutable Git-SHA tagging discipline;
- rootless Podman on `k8s-worker-2` managed by a persistent systemd user unit;
- a GitHub Actions pipeline building one AMD64+ARM64 OCI index with QEMU/Buildx and the built-in `GITHUB_TOKEN`;
- native ARM64 pull/run verification on the Apple M2;
- manual workflow dispatch and a CRITICAL Trivy CI gate;
- a verified GitHub Actions Buildx cache path, reducing the measured build from 38 seconds to 6 seconds on the cached run;
- an automated `main` deploy stage using an ephemeral self-hosted MacBook runner, Helm, the immutable full Git SHA image tag, rollout verification, and live HTTP health/version checks;
- a real cross-platform CI troubleshooting cycle where macOS `/bin/bash` rejected Bash 4+ lowercase expansion, followed by a portable `printf | tr` fix and a fully green retry;
- Helm 3 usage, Bitnami repo install, `--set`, values files, upgrade/history/rollback/list/status, `helm show values`, and `helm template`;
- a trimmed custom ShopStack Helm chart for Deployment + Service + Ingress;
- migration from loose frontend resources to the Helm-owned `shopstack-frontend` release;
- Helm chart packaging plus OCI push/pull through GHCR as an additional stretch exercise.

Both Task 4 Section 7.6.6 (automated CI deploy stage) and Section 7.7.6 (Helm OCI packaging/distribution) stretch goals were completed.

---

## Final Task 4 Repository Artifacts

The Task 4 work produced the following repository artifact groups:

```text
k8s/
├── frontend-configmap.yaml
├── frontend-deployment.yaml
├── frontend-hpa.yaml
├── frontend-own-deployment.yaml
├── frontend-secret.yaml
├── frontend-service.yaml
├── namespace.yaml
├── online-boutique-ingress.yaml
└── online-boutique.yaml
```

```text
frontend-src/
├── .dockerignore
├── Dockerfile
├── app.py
└── requirements.txt
```

```text
.github/workflows/build-image.yaml
```

```text
charts/
├── helm-history-evidence.txt
├── helm-lab-values.yaml
└── frontend-chart/
    ├── .helmignore
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml
        ├── ingress.yaml
        └── service.yaml
```

Canonical registry locations:

```text
Container image:
ghcr.io/culerty516/shopstack-frontend

Helm OCI chart:
ghcr.io/culerty516/charts/frontend-chart:0.1.0
```

Important Task 4 commits:

```text
046aac3 Add containerized ShopStack frontend v0.1.0
65ccfd1 Release ShopStack frontend v0.2.0
9b056d3 Add Task 4 Kubernetes manifests
1618be3 Add multi-arch container CI pipeline
72b17ba Enable GitHub Actions Buildx cache
a2918fc Add ShopStack frontend Helm chart
ad669e3 Add automated Helm deployment stage
17ea244 Fix macOS deploy runner shell compatibility
```

---

# Troubleshooting Notes

## Local kubeadm API connection failed because the SSH tunnel was absent

**Symptom**

```text
The connection to the server 127.0.0.1:6443 was refused
```

**Cause**

The kubeconfig intentionally points at the local SSH-forwarded API endpoint, but the forwarding SSH process was no longer listening.

**Resolution**

Recreated the tunnel to `10.10.0.10:6443` through `k8s-cp`. `kubectl get nodes` immediately returned all three nodes Ready. I did not modify or reset the cluster.

This same condition appeared again later after changing environments; recreating the tunnel again restored access.

---

## A new Terminal used the wrong Kubernetes context

**Symptom**

A kubeadm frontend lookup returned `NotFound`, and:

```bash
echo "$KUBECONFIG"
```

was empty while `kubectl config current-context` reported `minikube`.

**Cause**

The environment variable exported in another terminal is not inherited by a newly opened terminal session.

**Resolution**

Exported:

```text
~/.kube/task4-final-config
```

and explicitly selected `kubernetes-admin@kubernetes` before continuing.

This reinforced that `kubectl` errors must be interpreted in the context of the currently selected cluster.

---

## Broken readiness probe stalled the rollout but did not restart the container

**Symptom**

The new frontend Pod was `0/1 Running`; the rollout timed out; readiness returned HTTP 404.

**Cause**

The readiness path had deliberately been changed to `/definitely-not-ready` while liveness still targeted `/`.

**Resolution**

Observed the non-ready EndpointSlice state, restored readiness to `/`, applied the manifest, and the rollout completed.

---

## Literal shell placeholders caused parse/path errors

During troubleshooting I once pasted a command containing a literal placeholder such as:

```text
<NOT_READY_POD_NAME>
```

zsh interpreted the angle brackets as shell syntax rather than as documentation text.

I corrected the command by substituting the actual resource name first. This is a reminder that documentation placeholders are not literal shell arguments.

---

## HPA metrics failed under an overly aggressive minikube load test

**Symptom**

The HPA showed an unknown CPU target and events reported failures to fetch metrics from `pods.metrics.k8s.io`.

**Cause**

The first HTTP load-generator test put enough pressure on the small minikube Docker environment that metrics-server itself became unhealthy.

**Resolution**

Allowed the scratch cluster to recover and changed one variable: instead of adding more HTTP load-generator Pods, generated controlled CPU load inside one existing frontend Pod. The metrics pipeline stayed available, CPU reached 81% of request against a 50% target, and HPA successfully scaled the Deployment from 5 to 8.

---

## ConfigMap existed but was not mounted

**Symptom**

The ConfigMap was created but the frontend still served the standard nginx page.

**Cause**

The first Deployment manifest version did not actually contain `volumeMounts`/`volumes` referencing `frontend-config`.

**Resolution**

Added the ConfigMap volume and mounted it read-only at `/usr/share/nginx/html`, then re-applied the Deployment. The frontend served `VERSION_A`, and the later ConfigMap-only update changed it to `VERSION_B` without a Deployment rollout.

---

## Online Boutique was unstable on the Apple M2 minikube scratch cluster

**Symptom**

Multiple services repeatedly failed liveness/readiness probes or entered CrashLoopBackOff while Docker showed sustained CPU saturation.

**Cause**

The exact v0.10.6 images inspected in this run included AMD64 workloads, while minikube was running on Apple Silicon. Emulation combined with the small existing minikube resource allocation produced enough CPU scheduling delay to trigger aggressive one-second health checks.

**Resolution**

I first investigated resource usage and performed limited non-destructive CPU/resource experiments. The existing minikube profile could not be resized through normal `minikube start --cpus=...` without deleting it, and I did not reset the lab. I then moved the final deployment to the task-preferred native AMD64 kubeadm cluster and re-applied the clean upstream manifest. The full demo converged there.

---

## Browser reported `ERR_SSL_PROTOCOL_ERROR` for the Ingress

**Symptom**

The browser failed while curl against the ingress port-forward worked.

**Cause**

The browser attempted HTTPS against local port `8080`, while the port-forward was plain HTTP to ingress-nginx port 80.

**Resolution**

Used the explicit URL:

```text
http://shopstack.local:8080/
```

---

## Ingress port-forward lost its backend connection once

**Symptom**

```text
error: lost connection to pod
```

**Resolution**

Restarted the same `kubectl port-forward` command. The following session accepted requests normally. No Ingress or cluster configuration change was required.

---

## Deliberate Service selector mismatch removed all frontend endpoints

**Symptom**

The Service existed but `kubectl get endpoints frontend` returned `<none>`. Direct application health inside the Pod still succeeded.

**Cause**

The Service selector was intentionally changed to `app=frontend-broken` while Pods still used `app=frontend`.

**Resolution**

Confirmed the mismatch using `describe`, verified the application using logs and an ephemeral debug container, then re-applied the tracked Online Boutique manifest. Endpoints were restored.

---

## Podman was not installed on the MacBook Pro

**Symptom**

```text
zsh: command not found: podman
```

**Resolution**

Installed Podman 6.1.1 with Homebrew, initialized the Linux Podman Machine, and kept it in rootless mode.

---

## First Dockerfile exceeded the approximate image-size target

**Symptom**

The working slim-based image was approximately `158 MB`, slightly above the requested `~150 MB` target.

**Cause**

`podman history` showed that the runtime base dominated the image size.

**Resolution**

Changed to the pinned Alpine Python base and rebuilt the same application as non-root. The Podman image fell to approximately `57.6 MB` while preserving functionality.

---

## `podman manifest inspect` failed on the first GHCR image

**Symptom**

Podman reported that treating a single image as a manifest list was not implemented.

**Cause**

The manually pushed `0.1.0` package at that point was one AMD64 OCI image, not a multi-platform index.

**Resolution**

Used normal image inspection/pull to verify it. The proper AMD64+ARM64 OCI index was subsequently built in Section 7.6 of Task 4 using Buildx.

---

## Anonymous GHCR inspection initially returned `401`

**Cause**

The newly pushed image package was private.

**Resolution**

Changed the package visibility to public, logged Docker out of GHCR, and successfully pulled the image anonymously.

---

## Running the AMD64 release image locally on the M2 produced a platform warning

The manually built `0.2.0` release was intentionally AMD64 so it could run on the kubeadm workers. When I tested that specific image locally on the ARM64 Mac/Podman environment, Podman warned about the architecture mismatch. Emulation still ran it successfully and both application endpoints worked.

The later GitHub Actions multi-architecture image removed this mismatch by publishing both architectures under one tag.

---

## Podman 4.9.3 rejected one `podman info` template field

**Symptom**

A format string containing `.Host.CgroupVersion` failed because that field was not available in the host-info structure exposed by the installed version.

**Resolution**

Re-ran the query with supported fields and confirmed:

```text
rootless=true arch=amd64
```

---

## `podman generate systemd` printed a deprecation warning

Podman 4.9.3 recommended Quadlets for modern systemd integration. The task specifically requires `podman generate systemd --new`, so I completed the required exercise and documented the warning. For a new production service I would evaluate Quadlets instead.

---

## Helm 4 was active but the task required Helm 3

**Symptom**

The first `helm version` returned Helm `v4.3.0`.

**Resolution**

Installed the Homebrew `helm@3` keg and placed `/opt/homebrew/opt/helm@3/bin` first in PATH. Verification returned Helm `v3.22.0`, which was used for the rest of the task.

---

## Buildx cache flags were present but no cache hit was visible

**Symptom**

The workflow contained `cache-from type=gha` and `cache-to type=gha`, but the first logs did not show BuildKit importing the expected cache manifest.

**Cause**

The inline Buildx invocation did not yet have the GitHub Actions cache runtime variables exposed in the job environment.

**Resolution**

Added the GitHub Actions runtime exposure step, ran once to populate the cache, and then triggered another workflow manually. The next logs showed `importing cache manifest from gha` and many `CACHED` steps. The measured build time improved from 38 seconds to 6 seconds.

---

## First self-hosted CI deploy failed with `bad substitution`

**Symptom**

The first deployment-enabled run, `34820950439`, completed the multi-architecture build and both Trivy scans, then failed at the `Deploy immutable SHA image with Helm` step. The runner reported:

```text
bad substitution
```

**Evidence**

The preceding connectivity step had already returned all three kubeadm nodes as `Ready`, so this was not a Kubernetes API, SSH tunnel, kubeconfig, or Helm connectivity failure. The error occurred while assigning the GHCR repository string before `helm upgrade` was executed.

**Cause**

The workflow used:

```bash
${GITHUB_REPOSITORY_OWNER,,}
```

which is Bash 4+ lowercase syntax. It worked on the GitHub-hosted Ubuntu runner, but the self-hosted macOS job executed with Apple's older `/bin/bash`, which does not support that expansion.

**Resolution**

Changed the deploy job only, replacing the unsupported expansion with the portable form:

```bash
IMAGE_OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
```

I verified this with `/bin/bash` locally and committed:

```text
17ea244 Fix macOS deploy runner shell compatibility
```

Because the runner was configured with `--ephemeral`, the failed job still consumed that one runner registration. GitHub removed its `.credentials` and `.runner` state, so I registered a new ephemeral runner for the retry.

The next run, `34822419994`, completed build, scan, Helm deployment, rollout verification, image-tag verification, application response verification, and runner deregistration successfully.

**Lesson**

A workflow that is valid on a GitHub-hosted Linux runner can still fail on a self-hosted runner because the shell/runtime version is part of the execution environment. CI scripts intended to run across heterogeneous runners should avoid unnecessary version-specific shell syntax or explicitly control the shell version.

---

## Git history needed a meaningful `0.1.0` application commit

**Observation**

The application/container work had progressed through `0.2.0` before the required initial application commit was persisted.

**Resolution**

Before committing the Task 4 application artifacts, I restored the actual `0.1.0` state, committed it with a meaningful message, then restored and committed `0.2.0` separately. This created auditable source history for both releases rather than falsely documenting a commit that had never existed.

---

**Task 4 status: COMPLETE**
---

# Task 5 — Istio Service Mesh

**Date completed:** 2026-09-14<br>
**Working machine:** MacBook Pro (Apple M2, arm64)<br>
**Primary Kubernetes environment:** Three-node kubeadm cluster on Google Compute Engine<br>
**Kubernetes version:** v1.37.0<br>
**Container runtime:** containerd 2.2.1<br>
**Application namespace:** `shopstack`<br>
**Istio version:** 1.31.0<br>
**Istio installation profile:** `demo`<br>
**Kubernetes context:** `kubernetes-admin@kubernetes`<br>
**Local kubeconfig:** `~/.kube/task4-final-config`

Task 5 reused the Task 4 kubeadm environment. At the start of the task, the repository was on `main` at:

```text
32b2aa3 Complete Task 4 Kubernetes and Helm
```

The cluster consisted of:

```text
k8s-cp        10.10.0.10   control-plane   v1.37.0
k8s-worker-1  10.10.0.11   worker          v1.37.0
k8s-worker-2  10.10.0.12   worker          v1.37.0
```

The Kubernetes API remained private. Local `kubectl` access from the MacBook Pro continued to use the SSH tunnel from Task 3/4:

```text
127.0.0.1:6443 -> k8s-cp 10.10.0.10:6443
```

---

# 8.1 Installation and Sidecar Injection

## 8.1.1 Install Istio with the `demo` Profile

The `istio-system` namespace did not exist at the start of the task, and `istioctl` was not yet installed on the MacBook Pro.

I downloaded Istio 1.31.0 for Apple Silicon:

```bash
mkdir -p "$HOME/.local/share/istio"
cd "$HOME/.local/share/istio"

curl -L https://istio.io/downloadIstio | \
  ISTIO_VERSION=1.31.0 TARGET_ARCH=arm64 sh -
```

The downloaded client was verified as:

```text
Mach-O 64-bit executable arm64
client version: 1.31.0
```

I installed `istioctl` persistently in the Homebrew binary path:

```bash
install -m 0755 \
  "$HOME/.local/share/istio/istio-1.31.0/bin/istioctl" \
  /opt/homebrew/bin/istioctl
```

Verification:

```bash
command -v istioctl
istioctl version --remote=false
```

Result:

```text
/opt/homebrew/bin/istioctl
client version: 1.31.0
```

Before installation I ran the Istio precheck:

```bash
istioctl x precheck
```

Result:

```text
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
```

I installed the required demo profile:

```bash
istioctl install --set profile=demo -y
```

Key result:

```text
✔ Istio core installed
✔ Istiod installed
✔ Egress gateways installed
✔ Ingress gateways installed
✔ Installation complete
```

The control plane was verified:

```bash
kubectl get pods -n istio-system -o wide
```

Key result:

```text
istio-egressgateway    1/1 Running
istio-ingressgateway   1/1 Running
istiod                 1/1 Running
```

Version verification returned:

```text
client version: 1.31.0
control plane version: 1.31.0
data plane version: 1.31.0
```

The ingress gateway Service was a `LoadBalancer` with a pending external IP, which is expected in this bare kubeadm/GCP lab without a Kubernetes LoadBalancer implementation. I therefore used `kubectl port-forward` for local ingress verification.

---

## 8.1.2 Enable Automatic Sidecar Injection

Before enabling injection, the `shopstack` Pods were normal single-container application Pods.

I labeled the namespace:

```bash
kubectl label namespace shopstack \
  istio-injection=enabled \
  --overwrite
```

Verification showed:

```text
istio-injection=enabled
```

I restarted all application Deployments so the admission webhook could inject Envoy:

```bash
kubectl rollout restart deployment -n shopstack
```

I waited for every Deployment to complete its rollout.

Afterward, application Pods reported `2/2` READY, for example:

```text
adservice               2/2 Running
cartservice             2/2 Running
frontend                2/2 Running
productcatalogservice   2/2 Running
shippingservice         2/2 Running
```

I also verified registration with Istio:

```bash
istioctl proxy-status
```

All ShopStack sidecars were connected to Istiod 1.31.0 and subscribed to the expected xDS types:

```text
CDS, LDS, EDS, RDS
```

### What the sidecar proxy intercepts

In sidecar mode, Istio injects an Envoy proxy alongside the application container. Traffic entering and leaving the workload is transparently redirected through Envoy. This lets the mesh provide capabilities such as:

- workload-to-workload mTLS and identity;
- Layer 7 routing and traffic splitting;
- retries and timeouts;
- fault injection;
- authorization policy enforcement;
- telemetry, metrics, and distributed tracing.

The application itself does not need to implement these service-mesh features directly.

### Sidecar mode vs ambient mesh

The newer ambient model removes the requirement for one Envoy sidecar in every application Pod. Instead, node-level `ztunnel` proxies provide the secure Layer 4 data plane, including workload identity and mTLS. Optional waypoint proxies can provide Layer 7 processing where it is required.

The practical difference is:

```text
Sidecar mode:
application Pod + per-Pod Envoy

Ambient mode:
application Pod without sidecar
        |
        +-- node-level ztunnel for L4 security/identity
        +-- optional waypoint for L7 policy/routing
```

Ambient mode can reduce per-Pod proxy overhead and can enroll workloads without restarting them for sidecar injection. This task required sidecar mode only, so ambient mesh was documented but not deployed.

---

# 8.2 Ingress Gateway and Traffic Management

## 8.2.1 Replace the Plain Kubernetes Ingress

Task 4 had a Helm-managed nginx Ingress:

```text
name: shopstack
class: nginx
host: shopstack.local
backend: frontend:80
```

The Helm release had:

```text
ingress.enabled: true
```

Because Task 5 required the plain Ingress to be replaced by Istio, I changed the chart default:

```yaml
ingress:
  enabled: false
```

I validated the chart:

```bash
helm lint charts/frontend-chart
```

Result:

```text
1 chart(s) linted, 0 chart(s) failed
```

I also rendered the chart and confirmed that it no longer produced an `Ingress`.

I created:

```text
istio/gateway.yaml
istio/virtualservice.yaml
```

The Gateway listened for HTTP traffic on `shopstack.local`, using the Istio ingress gateway selector.

The initial VirtualService routed:

```text
shopstack.local
    |
    v
frontend.shopstack.svc.cluster.local:80
```

I applied both resources:

```bash
kubectl apply -f istio/gateway.yaml
kubectl apply -f istio/virtualservice.yaml
```

Validation:

```bash
istioctl analyze -n shopstack
```

Result:

```text
✔ No validation issues found when analyzing namespace: shopstack.
```

Before removing the old Ingress, I proved that the Istio path already worked:

```bash
kubectl port-forward \
  -n istio-system \
  svc/istio-ingressgateway \
  18080:80
```

Then:

```bash
curl -H 'Host: shopstack.local' \
  http://127.0.0.1:18080/
```

returned:

```text
HTTP 200
Version: 32b2aa3a1be201d9707848c9305646e9b0409249
```

I then upgraded the Helm release using the already-deployed immutable image tag while keeping `ingress.enabled=false`.

The release moved to revision 4, and:

```bash
kubectl get ingress -n shopstack
```

returned:

```text
No resources found in shopstack namespace.
```

The live frontend image remained unchanged, and the Istio Gateway path continued to return HTTP `200`.

This completed the cutover without changing the application image.

---

## 8.2.2 Canary Release — `0.1.0` and `0.2.0`

I verified the two ShopStack frontend images.

`0.1.0` was an AMD64 OCI image:

```text
ghcr.io/culerty516/shopstack-frontend:0.1.0
Platform: linux/amd64
```

`0.2.0` was the multi-architecture image index containing:

```text
linux/amd64
linux/arm64
```

The application exposes its visible version through `APP_VERSION`, so the two releases could be distinguished in HTTP responses.

I created:

```text
istio/canary-workloads.yaml
```

with:

```text
shopstack-frontend-v1 -> image 0.1.0 -> APP_VERSION=0.1.0
shopstack-frontend-v2 -> image 0.2.0 -> APP_VERSION=0.2.0
```

Both Pods used:

```text
app=shopstack-frontend-canary
```

and were separated by:

```text
version=v1
version=v2
```

A dedicated Service selected the canary application label:

```text
shopstack-frontend-canary
```

Both versions rolled out successfully as `2/2 Running`.

I verified the versions directly by port-forwarding each Deployment.

v1 returned:

```text
Version: 0.1.0
```

v2 returned:

```text
Version: 0.2.0
Release: Kubernetes-ready frontend
```

I created:

```text
istio/destinationrule.yaml
```

with two subsets:

```yaml
subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

I then updated `istio/virtualservice.yaml` to route:

```text
90% -> v1
10% -> v2
```

A loop of 100 requests through the Istio ingress gateway produced:

```text
91 0.1.0
 9 0.2.0
```

Calculated result:

```text
v0.1.0: 91 / 100 = 91%
v0.2.0:  9 / 100 = 9%
```

The exact result is probabilistic, but this was consistent with the configured 90/10 weighted split.

---

## 8.2.3 Timeout, Retry, and Fault Injection

The final VirtualService was extended with:

```yaml
timeout: 3s
retries:
  attempts: 2
  perTryTimeout: 1s
  retryOn: 5xx,reset,connect-failure,refused-stream
```

The 90/10 canary routing remained in place.

For the controlled fault test I created:

```text
istio/tests/virtualservice-delay-test.yaml
```

The temporary test route matched this header:

```text
x-istio-fault: delay
```

and applied:

```yaml
fault:
  delay:
    percentage:
      value: 100
    fixedDelay: 2s
```

Before applying the fault configuration, three baseline requests were:

```text
HTTP 200 | time=0.534534s
HTTP 200 | time=0.525886s
HTTP 200 | time=0.526400s
```

With the `2s` fault applied, three matching requests returned:

```text
HTTP 200 | time=2.632622s
HTTP 200 | time=2.698547s
HTTP 200 | time=2.775500s
```

The responses remained successful, but the approximately two-second increase in latency demonstrated that Istio fault injection was active.

I then immediately restored the normal tracked VirtualService:

```bash
kubectl apply -f istio/virtualservice.yaml
```

and verified:

```text
HTTP 200 | time=0.835131s
```

`istioctl analyze -n shopstack` remained clean after the test.

---

# 8.3 Security and Observability

## 8.3.1 Strict mTLS

Before applying a `PeerAuthentication`, no peer authentication resources existed:

```bash
kubectl get peerauthentication -A
```

Result:

```text
No resources found
```

I created a deliberately non-mesh client in the `default` namespace with:

```yaml
sidecar.istio.io/inject: "false"
```

The Pod was `1/1 Running`, proving it had no Envoy sidecar.

Before strict mTLS, it could reach the canary Service:

```text
HTTP 200
```

I created:

```text
istio/peer-authentication.yaml
```

with:

```yaml
spec:
  mtls:
    mode: STRICT
```

After applying it to `shopstack`, the exact same plaintext request failed:

```text
HTTP 000
curl: (56) Recv failure: Connection reset by peer
curl_exit_code=56
```

At the same time, traffic entering through the Istio ingress gateway still returned:

```text
HTTP 200
```

All application Pods remained `2/2 Running`, and:

```bash
istioctl analyze -n shopstack
```

returned no validation issues.

This demonstrated that plaintext traffic from outside the mesh was rejected while mesh-managed traffic continued to work.

The temporary plaintext test Pod was deleted afterward.

---

## 8.3.2 Workload Identity and AuthorizationPolicy

The existing Helm frontend was initially using the Kubernetes `default` ServiceAccount. Allowing:

```text
cluster.local/ns/shopstack/sa/default
```

would not have represented a frontend-only identity because any workload using the same ServiceAccount would share that principal.

I therefore created a dedicated Helm-managed ServiceAccount:

```text
shopstack-frontend
```

The following Task 5 chart changes were made:

```text
charts/frontend-chart/templates/serviceaccount.yaml
charts/frontend-chart/templates/deployment.yaml
```

The Helm frontend Deployment now uses:

```yaml
serviceAccountName: shopstack-frontend
```

The two canary Deployments were also updated to use the same frontend identity.

After the Helm upgrade and canary rollouts, all frontend Pods used:

```text
SERVICEACCOUNT
shopstack-frontend
```

I created:

```text
istio/authorization-policy.yaml
```

targeting:

```text
app=productcatalogservice
```

and allowing only:

```text
cluster.local/ns/shopstack/sa/shopstack-frontend
```

To prove the policy, I created two temporary mesh clients:

```text
frontend-authz-client -> ServiceAccount shopstack-frontend
authz-test-client     -> ServiceAccount authz-test
```

The allowed frontend identity reached the product catalog workload and received:

```text
HTTP/1.1 415 Unsupported Media Type
content-type: application/grpc
grpc-status: 3
grpc-message: invalid gRPC request content-type ""
```

The request was intentionally sent with ordinary `curl` to a gRPC service. The `415` response demonstrated that the request passed Istio authorization and reached the service/protocol layer; importantly, it was not denied by RBAC.

The other ServiceAccount was rejected by Envoy:

```text
HTTP/1.1 403 Forbidden
server: envoy

RBAC: access denied
```

This proved that the AuthorizationPolicy was enforcing workload identity rather than simply allowing all mesh traffic.

The temporary authorization test resources were deleted afterward.

---

## 8.3.3 Prometheus, Grafana, Kiali, and Jaeger

I used the observability manifests shipped with the same Istio 1.31.0 release:

```text
samples/addons/prometheus.yaml
samples/addons/grafana.yaml
samples/addons/kiali.yaml
samples/addons/jaeger.yaml
```

All four Deployments completed successfully:

```text
grafana      1/1
jaeger       1/1
kiali        1/1
prometheus   1/1
```

Prometheus itself ran as a `2/2` Pod in this sample configuration.

The kubeadm cluster did not expose the Kubernetes Metrics API:

```text
error: Metrics API not available
```

for `kubectl top`. This did not block Task 5 because Istio's Prometheus telemetry pipeline was independent and worked correctly.

### Enable tracing

I inspected the Istio MeshConfig and confirmed the existing Jaeger OpenTelemetry provider:

```yaml
name: jaeger
opentelemetry:
  port: 4317
  service: jaeger-collector.istio-system.svc.cluster.local
```

There was initially no `Telemetry` resource.

I created:

```text
istio/telemetry.yaml
```

with:

```yaml
tracing:
  - providers:
      - name: jaeger
    randomSamplingPercentage: 100
```

The 100% sample rate was used specifically for this lab evidence.

I also created a temporary injected `telemetry-client` so I could generate controlled mesh traffic.

### Generate telemetry

I generated:

- 100 internal mesh requests from `telemetry-client` to `frontend`;
- 100 requests through the Istio ingress gateway;
- controlled `404` requests so Grafana would have error-rate data.

Prometheus reported a populated `istio_requests_total` dataset and response-code metrics including both `200` and `404`.

Jaeger listed application services including:

```text
frontend.shopstack
loadgenerator.shopstack
shopstack-frontend-canary.shopstack
telemetry-client.shopstack
```

A trace query returned multiple two-span traces containing both:

```text
frontend.shopstack
loadgenerator.shopstack
```

### Kiali evidence

Kiali was port-forwarded locally on port `20001`.

The healthy service graph showed the `shopstack` namespace with multiple applications/services/edges, including the canary versions, and a clean capture showed:

```text
HTTP success: 100%
Error: 0%
```

A separate Kiali capture visibly showed the mTLS lock indicators.

#### Healthy service graph

![Kiali healthy service graph](docs/evidence/task5/kiali-healthy-service-graph.png)

#### mTLS lock verification

![Kiali mTLS lock verification](docs/evidence/task5/kiali-mtls-lock-verification.png)

The first graph attempts showed persistent failures even after manually generated traffic was healthy. I used Prometheus to isolate the active non-2xx source:

```text
source=loadgenerator
destination=frontend
code=404
rate=4.252631578947368
```

The root cause was that the Online Boutique `loadgenerator` continued requesting routes such as `/cart`, `/product/...`, and `/setCurrency`, while the Task 4 custom Flask frontend only implemented its smaller lab route set.

Loadgenerator logs confirmed those requests were failing continuously while `/` remained successful.

For a clean evidence window I temporarily scaled `loadgenerator` from one replica to zero, waited for the previous errors to leave the short metrics window, generated only successful traffic, captured the healthy graph, and then immediately restored the Deployment to one replica.

Final restoration:

```text
deployment/loadgenerator   1/1
pod/loadgenerator          2/2 Running
```

### Grafana evidence

Grafana's Istio Mesh Dashboard was captured using the Prometheus datasource.

The evidence showed:

```text
Traffic Volume: 2.22 req/s
Success Rate:   100%
4xx:            2.16 req/s
5xx:            0 req/s
```

This provided the required request-rate and error-rate visualization.

![Grafana request and error rates](docs/evidence/task5/grafana-request-error-rates.png)

### Jaeger evidence

The captured Jaeger trace detail showed:

```text
Services:    2
Depth:       2
Total Spans: 2
```

with the distributed path:

```text
loadgenerator.shopstack
        |
        v
frontend.shopstack
```

This satisfied the distributed-tracing evidence requirement.

![Jaeger distributed trace](docs/evidence/task5/jaeger-distributed-trace.png)

### Observability evidence stored in the repository

The final Task 5 observability screenshots are stored under:

```text
docs/evidence/task5/
├── kiali-healthy-service-graph.png
├── kiali-mtls-lock-verification.png
├── grafana-request-error-rates.png
└── jaeger-distributed-trace.png
```

These screenshots document the Kiali service graph and mTLS state, Grafana request/error rates, and Jaeger distributed trace captured during the Final Run.

---

## 8.3.4 `istioctl analyze` and Sidecar Configuration Inspection

The final namespace analysis was clean:

```bash
istioctl analyze -n shopstack
```

Result:

```text
✔ No validation issues found when analyzing namespace: shopstack.
```

Final proxy status showed the ShopStack data plane and gateways registered with Istiod 1.31.0.

I selected the v1 canary sidecar:

```text
shopstack-frontend-v1-6d4c4b987-254fx
```

The Pod was:

```text
2/2 Running
```

I inspected its Envoy configuration with:

```bash
istioctl proxy-config clusters
istioctl proxy-config listeners
istioctl proxy-config routes
istioctl proxy-config endpoints
```

### Clusters

The sidecar contained outbound clusters for:

```text
frontend.shopstack.svc.cluster.local
productcatalogservice.shopstack.svc.cluster.local
shopstack-frontend-canary.shopstack.svc.cluster.local
```

The canary destination also contained the expected subset clusters:

```text
v1
v2
```

### Listeners

The listener configuration showed Envoy routes/listeners for the application and mesh service ports, including HTTP traffic on ports such as `80`, `3550`, `8080`, and the observability services.

### Routes

The route table contained entries for ShopStack services, the canary Service, Istio observability services, and the local inbound application route.

### Endpoints

The canary endpoints were both healthy:

```text
10.244.2.44:8080   HEALTHY   outbound|80|v1|shopstack-frontend-canary...
10.244.1.46:8080   HEALTHY   outbound|80|v2|shopstack-frontend-canary...
```

Final security resources were also present:

```text
PeerAuthentication/default                    STRICT
AuthorizationPolicy/productcatalog-frontend-only   ALLOW
```

---

# Checkpoint Questions

## 1. What is the difference between a `VirtualService` and a `DestinationRule`?

A `VirtualService` defines **how traffic is routed**. It can match requests by host, URI, headers, or other attributes, choose one or more destinations, apply weights, and configure traffic behavior such as retries, timeouts, redirects, or fault injection.

A `DestinationRule` defines policies for traffic **after the destination has been selected**. It can define named subsets using workload labels and can also configure destination-side traffic policies such as load balancing, connection pools, outlier detection, and TLS behavior.

In this task:

```text
VirtualService:
90% -> v1
10% -> v2
timeout/retry configuration

DestinationRule:
v1 -> version=v1
v2 -> version=v2
```

In short:

```text
VirtualService  -> where/how to route the request
DestinationRule -> how to treat the selected destination/subsets
```

---

## 2. Why does strict mTLS break health checks or legacy clients, and what is `PERMISSIVE` mode for?

`STRICT` mTLS requires protected workload traffic to authenticate with Istio-issued mutual-TLS credentials. A legacy client or a non-mesh Pod sending ordinary plaintext directly to a workload cannot complete that mTLS exchange and is rejected.

This was demonstrated directly in the lab:

```text
Before STRICT:
HTTP 200

After STRICT:
HTTP 000
Recv failure: Connection reset by peer
```

Health checking requires care because not every probe or external health-check source necessarily participates in the mesh. Istio sidecars support Kubernetes probe handling/rewrite behavior, but arbitrary legacy plaintext clients are not automatically converted into mesh identities.

`PERMISSIVE` mode accepts both plaintext and Istio mTLS. It is useful as a migration mode while workloads are progressively enrolled into the mesh or while compatibility with legacy callers is still required. Once all intended callers can use mesh mTLS, `STRICT` provides the stronger steady-state policy.

---

## 3. Where does workload identity come from in Istio, and how does it relate to SPIFFE?

Istio workload identity is derived primarily from the Kubernetes trust domain, namespace, and ServiceAccount.

For the dedicated frontend identity in this task, the SPIFFE-style identity is:

```text
spiffe://cluster.local/ns/shopstack/sa/shopstack-frontend
```

Istiod provides workload certificates to Envoy, and mTLS uses those certificates to authenticate peers.

AuthorizationPolicy can then authorize the authenticated identity. The policy used in this task allowed:

```text
cluster.local/ns/shopstack/sa/shopstack-frontend
```

to call the product catalog workload, while a different ServiceAccount was rejected with:

```text
RBAC: access denied
```

Therefore the ServiceAccount is not just a Kubernetes organizational label; in the mesh it becomes part of the cryptographically authenticated workload identity.

---

# Task 5 Summary

All Task 5 practical requirements were completed successfully:

- Installed Istio 1.31.0 using the `demo` profile.
- Verified Istiod, ingress gateway, and egress gateway health.
- Enabled automatic sidecar injection in `shopstack`.
- Restarted application Deployments and verified `2/2` Pods plus `istioctl proxy-status`.
- Documented sidecar interception and the conceptual difference between sidecar and ambient mesh.
- Disabled the Task 4 Helm-managed plain Ingress.
- Created an Istio `Gateway` and `VirtualService` for `shopstack.local`.
- Deployed visible `0.1.0` and `0.2.0` frontend canary versions.
- Created a `DestinationRule` with `v1` and `v2` subsets.
- Configured 90/10 weighted routing and proved it with 100 requests (`91/9` observed).
- Added a 3-second timeout and two retry attempts.
- Demonstrated a 2-second Istio fault delay with measured request latency.
- Enabled namespace-wide `STRICT` mTLS.
- Proved that a non-mesh plaintext client changed from HTTP `200` to connection reset/HTTP `000`.
- Added the dedicated `shopstack-frontend` ServiceAccount.
- Restricted Product Catalog access to the frontend workload identity.
- Proved another ServiceAccount was denied with `HTTP 403` and `RBAC: access denied`.
- Installed Prometheus, Grafana, Kiali, and Jaeger from the Istio 1.31.0 sample manifests.
- Enabled 100% Jaeger sampling for lab evidence with an Istio `Telemetry` resource.
- Generated mesh traffic and verified Prometheus metrics.
- Captured a Kiali service graph and mTLS lock evidence.
- Captured a Grafana dashboard with request and error rates.
- Captured a two-service Jaeger distributed trace.
- Ran final `istioctl analyze` successfully.
- Inspected one sidecar with `istioctl proxy-config clusters`, `listeners`, `routes`, and `endpoints`.
- Verified final `PeerAuthentication` and `AuthorizationPolicy` resources.

## Final Task 5 Repository Artifacts

Required Task 5 deliverables:

```text
istio/
├── authorization-policy.yaml
├── destinationrule.yaml
├── gateway.yaml
├── peer-authentication.yaml
└── virtualservice.yaml
```

Additional Task 5 implementation/evidence manifests created during the Final Run:

```text
istio/
├── canary-workloads.yaml
├── telemetry.yaml
└── tests/
    ├── authz-test-client.yaml
    ├── plaintext-client.yaml
    ├── telemetry-client.yaml
    └── virtualservice-delay-test.yaml
```

Supporting Helm-chart changes:

```text
charts/frontend-chart/
├── values.yaml
└── templates/
    ├── deployment.yaml
    └── serviceaccount.yaml
```

Observability evidence:

```text
docs/evidence/task5/
├── kiali-healthy-service-graph.png
├── kiali-mtls-lock-verification.png
├── grafana-request-error-rates.png
└── jaeger-distributed-trace.png
```

The Task 5 implementation and repository evidence are complete. The observability screenshots are stored under `docs/evidence/task5/` and linked in Section 8.3.3.

---

# Troubleshooting Notes

## Existing SSH tunnel caused an initial `Address already in use`

**Symptom**

At the start of Task 5, attempting to create the local API tunnel returned:

```text
bind [127.0.0.1]:6443: Address already in use
Could not request local forwarding.
```

**Cause**

The existing tunnel from the earlier task was already listening on local port `6443`.

**Resolution**

I verified the cluster directly with:

```bash
kubectl get nodes -o wide
```

All three nodes were Ready, proving that the existing tunnel was already functional. No tunnel or cluster change was required at that point.

---

## Kubernetes Metrics API was not available

**Symptom**

```bash
kubectl top nodes
kubectl top pods -n istio-system
```

returned:

```text
error: Metrics API not available
```

**Cause**

The kubeadm cluster did not have a working Kubernetes Metrics API available for `kubectl top`.

**Resolution**

No change was required for Task 5. Istio Prometheus was installed separately and successfully collected `istio_requests_total` and response-code telemetry, which was the required observability path for this task.

---

## The local Kubernetes API SSH tunnel expired during Kiali evidence capture

**Symptom**

A Kiali port-forward exited, and subsequent `kubectl` commands returned:

```text
The connection to the server 127.0.0.1:6443 was refused
```

`lsof` showed no listener on local port `6443`.

**Cause**

The SSH tunnel to the private kubeadm API had ended during the longer observability session.

**Resolution**

Re-established only the existing local forward:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 \
  k8s-cp
```

Kubernetes access returned immediately. The Kiali Pod remained `1/1 Running`, and the Kiali port-forward subsequently returned HTTP `200`. No Kubernetes or Istio resource needed to be changed.

---

## Temporary telemetry client completed after one hour

**Symptom**

The temporary client later showed:

```text
telemetry-client   0/2   Completed
```

**Cause**

Its helper container had been created with:

```text
sleep 3600
```

and the observability/evidence session lasted longer than one hour.

**Resolution**

Changed only the helper lifetime:

```text
sleep 3600
->
sleep 86400
```

The Pod was recreated and returned:

```text
2/2 Running
```

No Istio configuration change was required.

---

## Kiali initially showed persistent failures despite successful manual requests

**Symptom**

Kiali continued to show failing application/service/workload health even after manually generated gateway traffic returned only HTTP `200`.

A 200-request validation showed:

```text
HTTP 200: 200
Failed/non-200: 0
```

**Investigation**

A Prometheus query grouped non-2xx traffic by source, destination, and response code.

The only active failing source was:

```text
source=loadgenerator
destination=frontend
code=404
rate=4.252631578947368
```

The loadgenerator log showed that `/` succeeded but the original Online Boutique paths such as `/cart`, `/product/...`, `/cart/checkout`, and `/setCurrency` were continuously failing.

**Cause**

The Online Boutique loadgenerator expected the original full Online Boutique frontend route set. Task 4 had replaced the `frontend` workload with the custom ShopStack Flask frontend, which intentionally implements a much smaller route set.

This was an application traffic-pattern mismatch, not an Istio routing or mTLS failure.

**Resolution**

For the clean Kiali evidence window only, I recorded the original replica count, temporarily scaled `loadgenerator` to zero, waited for old errors to leave the short metrics window, generated only successful traffic, and verified that the one-minute non-2xx Prometheus query returned no active failures.

I then restored the original replica count:

```text
deployment/loadgenerator   1/1
pod/loadgenerator          2/2 Running
```

This preserved the normal application state after evidence capture.

---

## The first loadgenerator log command used the wrong container name

**Symptom**

```text
error: container server is not valid for pod ...
```

**Cause**

The Online Boutique loadgenerator container was named `main`, not `server`.

**Resolution**

I inspected the Pod's container names and then used:

```text
-c main
```

to retrieve the loadgenerator logs successfully.

---

**Task 5 status: COMPLETE**
---

# Task 6 — Data Stores: PostgreSQL, Redis, Elasticsearch, NebulaGraph

**Final Run period:** 2026-09-15 to 2026-09-19<br>
**Date completed:** 2026-09-19<br>
**Working machine:** MacBook Pro<br>
**Primary Kubernetes environment:** Three-node kubeadm cluster on Google Compute Engine<br>
**Kubernetes version:** v1.37.0<br>
**Container runtime:** containerd 2.2.1<br>
**Node OS:** Ubuntu 24.04.4 LTS<br>
**Application namespace:** `shopstack`<br>
**Data-store namespace:** `data`<br>
**Istio namespace:** `istio-system`<br>
**ECK namespace:** `elastic-system`<br>
**Nebula Operator namespace:** `nebula-system`<br>
**Kubeconfig:** `~/.kube/task4-final-config`<br>

The Final Run reused the kubeadm cluster from Tasks 3–5:

```text
k8s-cp        10.10.0.10   control-plane   v1.37.0
k8s-worker-1  10.10.0.11   worker          v1.37.0
k8s-worker-2  10.10.0.12   worker          v1.37.0
```

Each VM remained at approximately 2 vCPU and 4 GiB RAM. I did not increase the VM size just to make the Task 6 data stores fit.

The Kubernetes API was still private. Local `kubectl` access depended on the SSH tunnel:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 \
  k8s-cp
```

At the start of Task 6 the tunnel was not running, so:

```bash
kubectl get nodes -o wide
```

returned:

```text
The connection to the server 127.0.0.1:6443 was refused
```

`lsof` showed no listener on TCP/6443. After recreating the SSH forward, all three nodes returned `Ready`.

---

# Storage Preparation for Task 6

The kubeadm cluster initially had no StorageClass, CSI driver, PV, or PVC:

```text
kubectl get storageclass
No resources found

kubectl get csidriver
No resources found

kubectl get pv
No resources found

kubectl get pvc -A
No resources found
```

The Kubernetes nodes also had no `providerID` and no region/zone topology labels. GCE metadata confirmed all three VMs were in `us-central1-a`.

The VM service-account scopes contained storage/logging/monitoring-related scopes but no Compute Engine scope. Rather than turning Task 6 into a cloud-CSI reconfiguration exercise, I used the simple local provisioner that the later storage task explicitly allows for kubeadm exercises.

I installed Rancher Local Path Provisioner v0.0.36:

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
```

The provisioner became available and created:

```text
NAME         PROVISIONER             RECLAIM   BINDING
local-path   rancher.io/local-path   Delete    WaitForFirstConsumer
```

This StorageClass was used as the lab persistence substrate. Task 7 separately demonstrates cloud block storage with GCP Persistent Disk, documents the GCE PD CSI production direction, and uses `local-path` for the Kubernetes persistence exercises as permitted by the task.

---

# 9.1 PostgreSQL on Kubernetes

## 9.1.1 Namespace and credential reuse

I created the `data` namespace declaratively:

```text
data/namespace.yaml
```

Before creating PostgreSQL, I verified the existing Task 4 Section 7.3 frontend database Secret:

```text
namespace: shopstack
name:      frontend-db-secret
type:      Opaque
keys:
  db-password
  db-user
```

The existing values were verified to match the intended Final Run lab credentials.

Kubernetes Secrets are namespace-scoped, so a Pod in `data` cannot directly reference a Secret stored in `shopstack`. I copied the same encoded Secret data into an equivalent runtime Secret:

```text
data/frontend-db-secret
```

I compared the source and destination encoded values and received:

```text
PASS: data/db-user exactly matches Task 4 Section 7.3 shopstack/db-user
PASS: data/db-password exactly matches Task 4 Section 7.3 shopstack/db-password
```

The credential values were not committed as a new plaintext Secret manifest.

---

## 9.1.2 PostgreSQL StatefulSet and headless Service

Files:

```text
data/postgres-headless-service.yaml
data/postgres-statefulset.yaml
```

The PostgreSQL design was:

```text
PostgreSQL image: postgres:16
StatefulSet:      postgres
Pod:              postgres-0
Namespace:        data
Service:          postgres-headless
Service type:     headless (clusterIP: None)
Port:             5432
PVC:              5Gi
Access mode:      ReadWriteOnce
StorageClass:     local-path
```

The StatefulSet used the copied `frontend-db-secret`:

```text
POSTGRES_USER     <- db-user
POSTGRES_PASSWORD <- db-password
```

It also configured:

```text
PGDATA=/var/lib/postgresql/data/pgdata
```

Resource settings:

```text
requests:
  cpu: 100m
  memory: 256Mi

limits:
  cpu: 1
  memory: 1Gi
```

Readiness and liveness checks used `pg_isready`.

I validated both manifests with server-side dry-run before applying them.

The workload converged successfully:

```text
NAME       READY
postgres   1/1
```

Initial Pod state:

```text
postgres-0   1/1   Running   0 restarts   k8s-worker-2
```

The data PVC bound dynamically:

```text
PVC:          postgres-data-postgres-0
Status:       Bound
Capacity:     5Gi
Access mode:  ReadWriteOnce
StorageClass: local-path
PV:           pvc-8ce1363e-8b71-49b9-bd9f-0747bbc8e2f5
```

The headless Service showed:

```text
postgres-headless   ClusterIP   None   5432/TCP
```

### Why StatefulSet instead of Deployment?

A StatefulSet exists for workloads that need stable identity and stable storage.

For PostgreSQL this matters because:

- `postgres-0` has a stable ordinal identity;
- the headless Service provides stable network naming;
- `volumeClaimTemplates` keep the StatefulSet ordinal associated with its PVC;
- ordered lifecycle semantics are available for stateful replicas.

A Deployment treats Pods as interchangeable. That is ideal for stateless application replicas but less suitable when one replica must remain associated with a particular persistent volume and stable identity.

Running a production relational database in Kubernetes is still a debated operational choice. Kubernetes can run it, but the team must own storage reliability, backups, failover, upgrades, monitoring, and recovery. For many production systems a managed database is the better choice when those operational guarantees are more important than running the database inside the cluster.

---

## 9.1.3 Create `boutique` and `products`

I created a temporary PostgreSQL 16 client Pod in the `data` namespace and connected through the headless Service.

Version check:

```text
PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2)
```

I created:

```text
database: boutique
owner:    shopstack-demo-user
```

Then:

```sql
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    sku VARCHAR(32) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    category VARCHAR(50) NOT NULL,
    price NUMERIC(10,2) NOT NULL
);
```

Five rows were inserted:

| ID | SKU | Product | Category | Price |
|---:|---|---|---|---:|
| 1 | SKU-001 | Mouse | electronics | 199.00 |
| 2 | SKU-002 | Keyboard | electronics | 699.00 |
| 3 | SKU-003 | USB Hub | electronics | 329.00 |
| 4 | SKU-004 | Laptop Stand | accessories | 249.00 |
| 5 | SKU-005 | Bottle | lifestyle | 129.00 |

Verification:

```text
SELECT COUNT(*) FROM products;
5
```

The temporary client Pod was deleted after the bootstrap.

---

# 9.2 PostgreSQL Backup and Restore

## 9.2.1 Logical backup with `pg_dump`

I created a custom-format backup from inside `postgres-0`:

```bash
pg_dump \
  -U "$POSTGRES_USER" \
  -d boutique \
  -Fc \
  -f /tmp/boutique.dump
```

The dump size was approximately 3.4 KiB.

`pg_restore -l` showed the expected `products` table, sequence, constraints, and table data.

The in-cluster SHA-256 was:

```text
ea6fb8d4e88f74e0e545489a8c52831ea9e97be109ed58d6457e88d0dfcbc49f
```

I copied the dump to the MacBook:

```bash
kubectl cp \
  data/postgres-0:/tmp/boutique.dump \
  /tmp/shopstack-task6/boutique.dump
```

Local verification returned the same SHA-256:

```text
ea6fb8d4e88f74e0e545489a8c52831ea9e97be109ed58d6457e88d0dfcbc49f
```

`file` identified it as:

```text
PostgreSQL custom database dump - v1.15-0
```

I then copied the external backup back into the PostgreSQL Pod as a separate restore input:

```text
/tmp/boutique-restore.dump
```

and verified its checksum again.

---

## 9.2.2 Disaster drill

Before destruction:

```text
products row count = 5
```

I deliberately dropped the table:

```sql
DROP TABLE products;
```

The next query failed as expected:

```text
ERROR: relation "products" does not exist
```

I restored the database objects and data with:

```bash
pg_restore \
  -U "$POSTGRES_USER" \
  -d boutique \
  /tmp/boutique-restore.dump
```

Post-restore verification returned:

```text
products row count = 5
```

and the exact five expected products were present again.

`postgres-0` remained healthy:

```text
1/1 Running
```

at this stage.

### Restore runbook

I created:

```text
runbooks/postgres-restore.md
```

The first attempt to create the Markdown runbook used a shell heredoc containing Markdown code fences and left the terminal at a `heredoc>` prompt. I removed the incomplete file and recreated it using safe inner fencing. The final runbook had the expected sections:

```text
Scope
Create a logical backup
Copy the backup outside the cluster
Disaster drill
Restore from the external backup copy
Verify recovery
Recovery Notes
```

The final file was approximately 4.3 KiB.

---

## 9.2.3 Nightly backup CronJob

Tracked files:

```text
data/postgres-backup-pvc.yaml
data/postgres-backup-cronjob.yaml
```

### First implementation in `data`

The first version used:

```text
namespace: data
schedule: 0 2 * * *
dedicated backup PVC: postgres-backups
size: 2Gi
```

A manual Job created from the CronJob completed:

```text
NAME                     STATUS     COMPLETIONS
postgres-backup-manual   Complete   1/1
```

The Job log showed:

```text
Creating backup: /backups/boutique-20260915T142841Z.dump
Backup completed:
-rw-r--r-- ... 3.4K ... /backups/boutique-20260915T142841Z.dump
```

The dedicated PVC bound successfully.

### Final implementation in `shopstack`

While implementing PostgreSQL network isolation, I chose an Istio `AuthorizationPolicy` that allows PostgreSQL only from the `shopstack` namespace.

That meant the final backup workload also needed to originate from `shopstack`.

I therefore changed the tracked backup PVC and CronJob to:

```text
namespace: shopstack
```

The CronJob now connects to:

```text
postgres-headless.data.svc.cluster.local:5432
```

The final Pod template carries:

```text
app=postgres-backup
```

and, because `shopstack` already has automatic sidecar injection, the backup Job received:

```text
istio-init
istio-proxy
pg-dump
```

The final runtime backup PVC was:

```text
shopstack/postgres-backups
PV: pvc-02979155-64cc-4600-b5c9-22929ead0c85
Capacity: 2Gi
Status: Bound
```

A manual test from the final CronJob completed:

```text
NAME                             STATUS     COMPLETIONS
postgres-backup-shopstack-test   Complete   1/1
```

Log:

```text
Creating backup: /backups/boutique-20260915T150050Z.dump
Backup completed:
-rw-r--r-- ... 3.9K ... /backups/boutique-20260915T150050Z.dump
```

After the authorization policy was enabled, a second test also completed:

```text
postgres-backup-authz-test   Complete   1/1
```

The earlier `data` CronJob was deleted. Its old runtime backup PVC remained Bound, but the repository manifest represents the final `shopstack` implementation.

---

## Logical vs physical PostgreSQL backup

`pg_dump` is a **logical backup**. It exports database objects and rows at the logical SQL level. It is portable and useful for migrations, selective restores, and small/medium databases, but a large restore can take significant time.

A **physical backup** copies the PostgreSQL data representation, usually with a base backup and WAL archiving. It is designed for whole-cluster recovery and is the basis for point-in-time recovery.

Point-in-time recovery is required when I need the database as it existed at a particular moment, for example immediately before an accidental destructive statement. A base backup can be restored and WAL replay stopped at the desired recovery target.

---

# 9.3 PostgreSQL Operations and Access Control

## 9.3.1 Read-only `reporting` user

I generated a random runtime password and stored it in:

```text
data/reporting-db-secret
```

with keys:

```text
db-user
db-password
```

The first role-creation attempt used `psql -c` together with:

```text
:'reporting_password'
```

and failed with:

```text
ERROR: syntax error at or near ":"
```

The failed command did not create the role.

I retained the generated password and changed only the SQL-input method. Feeding SQL to `psql` through stdin succeeded:

```text
CREATE ROLE
```

The role was then granted:

```sql
GRANT CONNECT ON DATABASE boutique TO reporting;
GRANT USAGE ON SCHEMA public TO reporting;
GRANT SELECT ON TABLE products TO reporting;
```

Validation from a temporary reporting client:

```text
SELECT from products  -> succeeds
INSERT into products  -> ERROR: permission denied for table products
DELETE from products  -> ERROR: permission denied for table products
```

The row count remained:

```text
5
```

`\dp products` showed:

```text
reporting=r/...
```

which confirmed read-only table permission.

---

## 9.3.2 Restrict PostgreSQL to `shopstack`

I inspected the CNI implementation before relying on Kubernetes NetworkPolicy.

The kubeadm cluster uses Flannel:

```text
kube-flannel/kube-flannel-ds
```

and there was no Calico DaemonSet.

The CNI configuration on the worker showed the Flannel plugin. Vanilla Flannel does not provide NetworkPolicy enforcement by itself.

The task permits either Kubernetes NetworkPolicy **or** Istio `AuthorizationPolicy`, so I used the already-running Istio service mesh for the actual PostgreSQL enforcement.

### Inject PostgreSQL into Istio

I added:

```text
sidecar.istio.io/inject: "true"
```

to the PostgreSQL Pod template.

After rollout, `postgres-0` contained:

```text
application container:
  postgres

init/restartable sidecars:
  istio-init
  istio-proxy
```

and reported:

```text
postgres-0   2/2 Running
```

The original PostgreSQL PVC remained Bound and the products row count remained `5`.

### Security resources

Files:

```text
data/postgres-peer-authentication.yaml
data/postgres-authorization-policy.yaml
```

The policy design was:

```text
PeerAuthentication:
  selector: app=postgres
  mTLS: STRICT

AuthorizationPolicy:
  selector: app=postgres
  action: ALLOW
  source namespace: shopstack
  destination port: 5432
```

### Positive test

A PostgreSQL client in `shopstack` received an Istio sidecar and, using valid credentials, returned:

```text
SELECT COUNT(*) FROM products;
5
```

### Negative test

I created a separate namespace:

```text
postgres-deny-test
```

enabled sidecar injection, copied the same valid database credentials into it, and ran the same query.

The client was rejected:

```text
psql: error: connection to server at
"postgres-headless.data.svc.cluster.local" ...
server closed the connection unexpectedly

exit code 2
```

Because both tests used valid database credentials and both clients were mesh-enabled, this demonstrated namespace-based Istio authorization rather than authentication failure.

The deny-test namespace was deleted afterward.

---

## 9.3.3 Performance and active connections

I ran:

```sql
EXPLAIN ANALYZE
SELECT *
FROM products
WHERE category = 'electronics';
```

Observed plan:

```text
Seq Scan on products
actual rows: 3
Rows Removed by Filter: 2
Planning Time: 0.546 ms
Execution Time: 0.072 ms
```

The three matching rows were:

```text
SKU-001 Mouse    199.00
SKU-002 Keyboard 699.00
SKU-003 USB Hub  329.00
```

With only five rows, a sequential scan is reasonable; adding an index solely for this tiny test table would not provide meaningful benefit.

`pg_stat_activity` showed one active `boutique` session:

```text
usename: shopstack-demo-user
datname: boutique
state:   active
```

The grouped connection check returned:

```text
active = 1
```

---

# 9.4 Redis Cache Layer

## 9.4.1 Redis StatefulSet and authentication

Files:

```text
redis/redis-service.yaml
redis/redis-statefulset.yaml
```

I generated a random Redis password and stored it in the runtime Secret:

```text
data/redis-auth-secret
key: redis-password
```

Redis was deployed as:

```text
Redis version:   8.10.1
Namespace:       data
StatefulSet:     redis
Pod:             redis-0
Service:         redis
Port:            6379
PVC:             1Gi
Access mode:     RWO
StorageClass:    local-path
```

The Redis server command included:

```text
--requirepass "$REDIS_PASSWORD"
--appendonly yes
--appendfsync everysec
--dir /data
```

Resource settings:

```text
requests:
  cpu: 50m
  memory: 128Mi

limits:
  cpu: 500m
  memory: 512Mi
```

Initial state:

```text
redis-0   1/1 Running
PVC redis-data-redis-0 -> Bound
PV pvc-2c555873-4c94-42ef-b8a8-eeba5585dece
```

Runtime verification:

```text
appendonly
yes

appendfsync
everysec
```

Unauthenticated `PING` returned:

```text
NOAUTH Authentication required.
```

Authenticated `PING` returned:

```text
PONG
```

---

## 9.4.2 Five Redis data structures

I connected from a temporary Redis 8.10.1 client Pod.

### STRING with TTL

The first short 10-second test expired before the follow-up command, returning:

```text
TTL = -2
```

I repeated it with a 60-second TTL:

```text
SET product:SKU-001 "Mouse|electronics|199.00" EX 60
GET -> Mouse|electronics|199.00
TTL -> 47
```

After waiting 61 seconds:

```text
TTL -> -2
GET -> nil
```

This proved expiry rather than only setting a TTL.

### HASH — shopping cart

```text
HSET cart:customer-001 SKU-001 1 SKU-003 2
```

Result:

```text
SKU-001 -> 1
SKU-003 -> 2
```

### LIST — job queue

```text
LPUSH jobs:email order:1001 order:1002
```

The list contained:

```text
order:1002
order:1001
```

`BRPOP jobs:email 1` consumed:

```text
order:1001
```

### SET — unique visitors

I added:

```text
customer-001
customer-002
customer-003
customer-001
```

Redis reported only three unique additions and:

```text
SCARD visitors:SKU-001
3
```

Members:

```text
customer-001
customer-002
customer-003
```

### ZSET — product leaderboard

Scores:

```text
SKU-001 150
SKU-003 120
SKU-002 95
SKU-004 60
SKU-005 45
```

`ZREVRANGE ... WITHSCORES` returned the expected ranking.

Type verification returned:

```text
cart        = hash
queue       = list
visitors    = set
leaderboard = zset
```

---

# 9.4.3 Persistence and AOF

I wrote:

```text
persistence:proof = survives-redis-restart
```

and verified it before restart.

### Trigger a save

I explicitly ran:

```text
BGSAVE
```

Redis returned:

```text
Background saving started
```

Persistence status then showed:

```text
rdb_last_bgsave_status:ok
aof_enabled:1
aof_last_write_status:ok
```

The Redis PVC contained both RDB and AOF-related data:

```text
/data/dump.rdb

/data/appendonlydir/
  appendonly.aof.1.base.rdb
  appendonly.aof.1.incr.aof
  appendonly.aof.manifest
```

### Pod restart / persistence proof

Before deletion:

```text
redis-0 Pod UID:
70f83bc2-b21f-44d7-b69c-25e1d3b2d7c7

PVC:
redis-data-redis-0

PV:
pvc-2c555873-4c94-42ef-b8a8-eeba5585dece
```

I deleted `redis-0`.

The StatefulSet recreated it with a new Pod UID:

```text
4daec710-f114-43ff-8f62-f0e2062183a1
```

The same PVC and PV remained bound.

After recreation:

```text
GET persistence:proof
survives-redis-restart
```

The shopping-cart hash also survived, and the top three leaderboard entries were still:

```text
SKU-001 150
SKU-003 120
SKU-002 95
```

AOF was still enabled.

### RDB vs AOF

RDB produces point-in-time snapshots. It is compact and fast to restore, but changes after the latest snapshot can be lost.

AOF records write operations. It can reduce the potential data-loss window, at the cost of more write and storage overhead.

`appendfsync everysec` is a durability/performance compromise. Redis normally flushes the AOF to stable storage approximately once per second rather than fsyncing every write. This avoids the much higher I/O cost of synchronous fsync on every write, but a sudden host/OS failure can lose roughly the most recent second of acknowledged writes that had not yet been durably flushed.

For a disposable session cache, RDB or even no Redis persistence can be acceptable if authoritative state exists elsewhere. For a Redis-backed job queue, AOF is preferable because losing recent accepted jobs is more serious, although workloads needing strong delivery guarantees may be better served by a dedicated durable message broker.

---

# 9.4.4 Cache-aside pattern

File:

```text
redis/cache-aside-notes.md
```

I demonstrated cache-aside with `SKU-002`.

First, Redis had no cached value:

```text
DEL product:SKU-002 -> 0
GET product:SKU-002 -> nil
```

I queried PostgreSQL:

```text
SKU-002|Keyboard|electronics|699.00
```

Then populated Redis:

```text
SET product:SKU-002 \
    "SKU-002|Keyboard|electronics|699.00" \
    EX 300
```

The next lookup returned the cached value and the observed TTL was:

```text
282
```

Flow:

```text
GET Redis
  |
  +-- hit  -> return cached value
  |
  +-- miss -> query PostgreSQL
              |
              +-> SET Redis with TTL
              |
              +-> return database result
```

Two documented failure modes:

**Cache stampede** — a popular key expires and many clients query PostgreSQL simultaneously.
Mitigation: request coalescing/distributed lock, prewarming, or randomized TTLs.

**Stale data** — PostgreSQL is updated while Redis still contains an old value.
Mitigation: invalidate/update the Redis key after a successful database write and use bounded TTLs.

PostgreSQL remains the system of record.

---

# 9.4.5 Redis observation and security

`INFO` returned:

```text
redis_version:          8.10.1
redis_mode:             standalone
used_memory:            978208
used_memory_human:      955.28K
used_memory_peak_human: 955.62K
connected_clients:      1
keyspace_hits:          5
keyspace_misses:        1
```

Observed cache hit rate:

```text
5 / (5 + 1) = 83.3%
```

### Why Redis should not be exposed directly to the Internet

Redis is a high-speed data service that can read and mutate application state. Direct Internet exposure unnecessarily increases the attack surface. Historically Redis was designed for trusted networks and did not always rely on authentication by default; even with modern authentication, a weak/leaked credential or permissive ACL could expose data or destructive commands.

In production Redis should remain on private networking, use strong authentication/ACLs, enforce least privilege, rotate credentials, and avoid publishing port 6379 directly to the public Internet.

### Network restriction

I created:

```text
redis/redis-networkpolicy.yaml
```

which expresses the intended rule:

```text
only namespace shopstack -> Redis TCP/6379
```

However, the cluster uses vanilla Flannel, so I did not treat that manifest alone as effective enforcement.

I added Istio injection to the Redis Pod and created:

```text
redis/redis-peer-authentication.yaml
redis/redis-authorization-policy.yaml
```

Final Redis protection:

```text
PeerAuthentication: STRICT
AuthorizationPolicy:
  source namespace = shopstack
  destination port = 6379
```

The Redis Pod became:

```text
redis-0   2/2 Running
```

A `shopstack` client with valid Redis credentials returned:

```text
PONG
```

and could read:

```text
persistence:proof
survives-redis-restart
```

A mesh-enabled client in a separate `redis-deny-test` namespace used the **same valid Redis credentials** but received:

```text
I/O error
Error: Server closed the connection
exit code 1
```

The test namespace was deleted afterward.

---

# 9.4 Stretch — Redis Sentinel Failover

Files:

```text
redis/sentinel-lab.yaml
redis/sentinel-vs-cluster.md
```

## Topology

I deployed three Redis data nodes with persistent PVCs:

```text
redis-ha-0
redis-ha-1
redis-ha-2
```

and three Sentinel Pods:

```text
redis-sentinel-ha-0
redis-sentinel-ha-1
redis-sentinel-ha-2
```

Each data node used a 1Gi `local-path` PVC.

Initial replication:

```text
redis-ha-0  role=master  connected_slaves=2

redis-ha-1  role=slave
            master_host=redis-ha-0.data.svc.cluster.local
            master_link_status=up

redis-ha-2  role=slave
            master_host=redis-ha-0.data.svc.cluster.local
            master_link_status=up
```

All three Sentinels agreed on the initial primary, and:

```text
SENTINEL CKQUORUM mymaster
OK 3 usable Sentinels. Quorum and failover authorization can be reached
```

Sentinel quorum was configured as:

```text
2
```

Other settings included:

```text
down-after-milliseconds = 5000
failover-timeout        = 15000
parallel-syncs          = 1
```

## Real failover drill

I wrote:

```text
sentinel:failover-proof = written-before-primary-failure
```

to the primary and confirmed it had replicated to both replicas.

I then deliberately removed the original primary and scaled:

```text
redis-ha-0 -> replicas=0
```

After Sentinel convergence:

```text
new master IP: 10.244.1.74
redis-ha-1: role=master
redis-ha-2: role=slave
```

Sentinel logs showed the full failover sequence:

```text
+sdown
+odown              quorum 3/2
+try-failover
+elected-leader
+selected-slave
+promoted-slave
+switch-master
```

The proof key on the promoted master still returned:

```text
written-before-primary-failure
```

I restored `redis-ha-0`.

It rejoined as a replica of the new master:

```text
redis-ha-0 role=slave  master_host=10.244.1.74
redis-ha-1 role=master connected_slaves=2
redis-ha-2 role=slave  master_host=10.244.1.74
```

Final quorum remained healthy:

```text
OK 3 usable Sentinels. Quorum and failover authorization can be reached
```

After the stretch evidence was complete, I scaled the three Redis HA Deployments and Sentinel StatefulSet to zero to release resources. Their three PVCs remained Bound.

## Sentinel vs Redis Cluster

**Redis Sentinel** provides high availability for a primary/replica topology. The whole dataset remains on one primary and is replicated to the replicas. Sentinel monitors health and coordinates promotion.

**Redis Cluster** adds horizontal sharding. Redis hash slots are spread across multiple primaries, and each primary can have replicas. This increases total capacity and write throughput but requires cluster-aware clients and introduces resharding and multi-key operational complexity.

For this lab, Sentinel was the better fit because the objective was failover, not horizontal Redis sharding.

---

# 9.5 Elasticsearch and Kibana with ECK

## 9.5.1 Install ECK

I added the official Elastic Helm repository and installed:

```text
release: elastic-operator
chart:   eck-operator-3.5.0
app:     3.5.0
namespace: elastic-system
```

The operator became:

```text
elastic-operator-0   1/1 Running   k8s-worker-1
```

I initially assumed the Helm chart deployed a Deployment and ran:

```bash
kubectl rollout status deployment/elastic-operator \
  -n elastic-system
```

Kubernetes returned:

```text
Error from server (NotFound): deployments.apps "elastic-operator" not found
```

I inspected the release and corrected the command to:

```text
statefulset/elastic-operator
```

The StatefulSet rollout completed successfully.

### ECK CRDs

The operator installed multiple Elastic CRDs, including:

```text
elasticsearches.elasticsearch.k8s.elastic.co
kibanas.kibana.k8s.elastic.co
agents.agent.k8s.elastic.co
apmservers.apm.k8s.elastic.co
beats.beat.k8s.elastic.co
logstashes.logstash.k8s.elastic.co
...
```

Both `Elasticsearch` and `Kibana` expose namespaced `v1` storage APIs.

A CRD extends the Kubernetes API with an application-specific resource type. The ECK controller watches these custom resources and continuously reconciles lower-level objects such as Pods/StatefulSets, Services, Secrets, certificates, and configuration.

---

# Resource headroom before Elasticsearch

Before scheduling Elasticsearch, the workers already carried workloads from Tasks 4 and 5.

I recorded the exact baseline replicas in:

```text
/tmp/task6-pre-elasticsearch-replicas.txt
```

Saved ShopStack state:

```text
adservice                   1
cartservice                 1
checkoutservice             1
currencyservice             1
emailservice                1
frontend                    3
loadgenerator               1
paymentservice              1
productcatalogservice       1
recommendationservice       1
redis-cart                  1
shippingservice             1
shopstack-frontend-v1       1
shopstack-frontend-v2       1

helm-lab/shopstack-nginx-lab 2
istio-system/prometheus      1
```

To create enough headroom for the memory-heavy Task 6 workloads, I scaled those live Deployments to zero.

This was a **runtime capacity-management action**. It did not change their tracked manifests or erase their saved baseline.

After scaling them down, worker requests fell to approximately:

```text
worker-1:
  CPU requests    300m / 2 cores
  Memory requests 572Mi

worker-2:
  CPU requests    320m / 2 cores
  Memory requests 476Mi
```

PostgreSQL, Redis, and the Istio ingress gateway remained running.

---

# 9.5.2 Elasticsearch cluster

File:

```text
elastic/elasticsearch.yaml
```

Final configuration:

```text
Elasticsearch version: 9.5.3
name:                  shopstack
namespace:             data
NodeSets:              1
node count:            1
node:                  k8s-worker-2

JVM:
  -Xms2g
  -Xmx2g

requests:
  cpu:    500m
  memory: 2300Mi

limits:
  cpu:    2
  memory: 3Gi

PVC:
  5Gi
  ReadWriteOnce
  local-path
```

`node.store.allow_mmap` was disabled for the lab.

The ECK resource initially showed `ApplyingChanges`, then converged to:

```text
shopstack   green   1   9.5.3   Ready
```

The Elasticsearch Pod:

```text
shopstack-es-default-0
1/1 Running
node: k8s-worker-2
```

PVC:

```text
elasticsearch-data-shopstack-es-default-0
5Gi
Bound
PV: pvc-3906be67-5494-4b23-9c30-bc7bc9f23a6e
```

The live JVM options were:

```text
-Xms2g -Xmx2g
```

### ECK-generated credentials

ECK generated:

```text
data/shopstack-es-elastic-user
key: elastic
```

I retrieved the password at runtime without storing it in the repository.

This is safer than hard-coding a static password in the Elasticsearch CR, shell script, or Git history. Kubernetes RBAC can restrict Secret reads, and the credential is created as part of the ECK-managed resource lifecycle.

The Secret still requires normal production protections such as least-privilege RBAC, encryption at rest, and rotation; Kubernetes Secret storage does not automatically make a credential safe.

The Elasticsearch API confirmed:

```text
cluster_name: shopstack
version:      9.5.3
```

One command attempted to pipe to `jq` **inside** the Elasticsearch container and failed:

```text
sh: jq: command not found
exit code 127
```

I therefore used local `jq` or a separate curl client Pod rather than modifying the Elasticsearch image.

---

# 9.5.3 Products index and search

Final repository files:

```text
elastic/products-mapping.json
elastic/products-bulk.ndjson
elastic/query-fuzzy.json
elastic/query-bool.json
elastic/query-aggregation.json
```

## Mapping correction

My first mapping used:

```text
name
```

as the text field.

The task specifically requires:

```text
title
```

with a keyword sub-field.

Rather than leaving a near-match, I corrected the repository files, deleted the temporary `products` index, recreated it, and re-indexed all documents.

The final mapping contains:

```text
sku          keyword
title        text + title.keyword
description  text
category     keyword
price        double
stock        integer
```

Index settings:

```text
number_of_shards:   1
number_of_replicas: 1
```

## Bulk indexing

`elastic/products-bulk.ndjson` contains 20 NDJSON lines:

```text
10 action lines
10 document lines
```

All lines validated as JSON.

The final `_bulk` operation returned:

```text
errors:  false
indexed: 10
```

Final count:

```text
10
```

## Fuzzy query

Query typo:

```text
keybord
```

with:

```text
fuzziness: AUTO
```

Result:

```text
total_hits: 1

SKU-002
Keyboard
699.00
```

## Bool query: `match` + `range`

The final bool query combines:

```text
must:
  match title = keyboard

filter:
  price between 200 and 800
```

Result:

```text
total_hits: 1

SKU-002
Keyboard
699.00
```

## Aggregation

The final category aggregation returned:

```text
electronics  5
accessories  3
lifestyle    2
```

The aggregation file also calculates average price per category.

---

# 9.5.4 Kibana through Istio

File:

```text
elastic/kibana.yaml
```

Repository desired state:

```text
Kibana version: 9.5.3
count:          1
Elasticsearch:  shopstack
node:           k8s-worker-1

requests:
  cpu:    200m
  memory: 512Mi

limits:
  cpu:    1
  memory: 1Gi
```

For the internal service, the ECK self-signed HTTP certificate was disabled so the Istio HTTP route could terminate at Kibana over cluster HTTP.

The initial Kibana Pod became:

```text
shopstack-kb-74b8454795-4wxgc
1/1 Running
k8s-worker-1
```

Kibana health:

```text
green
nodes: 1
```

Service:

```text
shopstack-kb-http
ClusterIP
5601/TCP
```

An internal curl returned:

```text
HTTP 200
```

## Istio exposure

I reused the existing Task 5 Gateway rather than creating another ingress stack.

`istio/gateway.yaml` was extended with:

```text
kibana.shopstack.local
```

and I created:

```text
istio/kibana-virtualservice.yaml
```

Destination:

```text
shopstack-kb-http.data.svc.cluster.local:5601
```

The existing `shopstack.local` route and 90/10 canary VirtualService were left intact.

The Istio ingress gateway HTTP NodePort was:

```text
32442
```

I created the MacBook tunnel:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:18080:10.10.0.10:32442 \
  k8s-cp
```

Host-header verification returned:

```text
HTTP/1.1 200 OK
```

for:

```text
Host: kibana.shopstack.local
```

I added:

```text
127.0.0.1 kibana.shopstack.local
```

to `/etc/hosts`, flushed the macOS DNS cache, and verified:

```text
http://kibana.shopstack.local:18080/login
HTTP 200
```

The ECK `elastic` password was copied to the clipboard for the interactive login.

The required Dev Tools evidence was saved as:

```text
docs/evidence/task6/kibana-dev-tools-products-query.png
```

The terminal audit confirms the screenshot file exists in the repository evidence directory.

---

# 9.5.5 Cluster health, shards, snapshot procedure, and ILM

## Cluster health

After Kibana/system indices existed, `_cluster/health` returned:

```text
cluster_name:          shopstack
status:                yellow
number_of_nodes:       1
active_primary_shards: 53
active_shards:         53
unassigned_shards:     1
```

For the `products` index:

```text
primary shard:
  STARTED
  docs: 10

replica shard:
  UNASSIGNED
```

Allocation explain returned:

```text
can_allocate: no
decider:      same_shard
decision:     NO
```

Reason:

```text
a copy of this shard is already allocated to this node
```

The `products` index is configured with one primary and one replica, but the Elasticsearch cluster contains only one node. Elasticsearch will not place a replica on the same node as its primary, so the primary remains available while the replica is unassigned.

That is why this single-node lab is `yellow` rather than `green`.

A **shard** is a horizontal unit of an Elasticsearch index. A **replica** is another copy of a primary shard that provides redundancy and can also contribute read capacity when another suitable node exists.

## Snapshot runbook

I did not create a second temporary object-storage system solely for Task 6.

Task 7 is responsible for MinIO and the `shopstack-backups` object-storage bucket, so I documented the exact Elasticsearch-to-S3-compatible procedure in:

```text
runbooks/elasticsearch-snapshot.md
```

The 224-line runbook covers:

```text
ECK secureSettings
MinIO / S3-compatible credentials
repository name: shopstack-backups
bucket:          shopstack-backups
_snapshot repository registration
_verify
snapshot creation with wait_for_completion
snapshot listing
restore
recovery monitoring
products/_count verification
```

Expected post-restore `products` count:

```text
10
```

The runbook also documents that snapshots must live outside the Elasticsearch data PVC and that snapshots protect recoverability while replicas protect availability.

## ILM

File:

```text
elastic/ilm-notes.md
```

ILM is appropriate for continuously growing time-series/log-style data such as:

```text
application logs
access logs
audit events
infrastructure logs
metrics
```

A typical lifecycle can keep recent data hot, roll over by size/age, move older data to cheaper tiers, and delete data after the required retention period.

The ShopStack `products` index is application state, not disposable log data, so age-based deletion would be inappropriate. Snapshot/restore and application-controlled updates are more relevant for that index.

---

# 9.5.6 Resource discipline and Metrics Server

The cluster initially had no Metrics API:

```text
kubectl get apiservice v1beta1.metrics.k8s.io
NotFound
```

and:

```text
kubectl top ...
error: Metrics API not available
```

I downloaded the official Metrics Server v0.9.0 manifest:

```text
registry.k8s.io/metrics-server/metrics-server:v0.9.0
```

Downloaded manifest SHA-256:

```text
1cec29a5267809306a2c6ec74a3e449abbb705b4a8beed0c8a1963910f72c79b
```

The installation created the APIService, Service, RBAC, and Deployment, but the Deployment remained:

```text
0/1
```

and readiness timed out.

Metrics Server logs showed the actual cause on all three nodes:

```text
tls: failed to verify certificate:
x509: cannot validate certificate for 10.10.0.x
because it doesn't contain any IP SANs
```

The kubelet serving certificates did not contain the node InternalIP addresses as SANs.

For this lab only, I patched Metrics Server with:

```text
--kubelet-insecure-tls
```

The rollout then completed:

```text
metrics-server   1/1 Running
```

and the APIService became:

```text
AVAILABLE=True
```

`kubectl top` then worked.

This is a lab workaround, not a production recommendation. It keeps HTTPS but disables kubelet serving-certificate verification. In production I would issue trusted kubelet serving certificates with the correct node IP SANs and remove this flag.

## Actual observed usage

First working sample:

| Resource | CPU | Memory |
|---|---:|---:|
| `k8s-cp` | 183m | 1270Mi |
| `k8s-worker-1` | 160m | 1828Mi |
| `k8s-worker-2` | 134m | 3248Mi |
| Elasticsearch | 43m | 2696Mi |
| Kibana | 28m | 908Mi |

A later sample showed:

```text
Elasticsearch  43m   2697Mi
Kibana         29m    925Mi
PostgreSQL     24m     71Mi
Redis          12m     45Mi
```

Worker 2 was around 84–85% memory utilization while Elasticsearch was running.

Resource notes were saved in:

```text
elastic/resource-discipline.md
```

### Elasticsearch heap rule

The Final Run uses:

```text
-Xms2g -Xmx2g
container limit = 3Gi
```

The JVM heap is therefore approximately:

```text
2 / 3 = 66.7%
```

That is higher than the common production rule of thumb of keeping Elasticsearch heap around 50% of the memory available to the process.

The remaining memory is needed for JVM native memory, direct buffers, Lucene/native structures, memory-mapped/file-backed data, and the filesystem cache.

The lab intentionally keeps the required approximately 4Gi worker VM size. I did not increase VM RAM just to achieve an ideal ratio. For a production-style 2Gi heap, roughly 4Gi or more of container memory plus node headroom would be more appropriate.

---

# 9.6 NebulaGraph

## 9.6.1 Nebula Operator

I added the required official repository:

```bash
helm repo add nebula-operator \
  https://vesoft-inc.github.io/nebula-operator/charts
```

Latest chart selected during the run:

```text
chart version: 1.8.8
appVersion:    1.8.8
```

I installed the operator into:

```text
nebula-system
```

Helm returned one warning:

```text
Warning: tls: failed to find any PEM data in certificate input
```

but the release completed:

```text
STATUS: deployed
REVISION: 1
```

Running operator Pods included two controller-manager Pods and two scheduler Pods across the two workers.

One important verification was that the actual container image shipped by this chart was:

```text
vesoft/nebula-operator:v1.8.7
```

even though the Helm chart and `appVersion` were `1.8.8`.

This is a useful operational lesson: chart version, `appVersion`, and actual image tag should be inspected rather than assumed to be identical.

Installed CRDs included:

```text
NebulaCluster
NebulaBackup
NebulaCronBackup
NebulaRestore
NebulaAutoscaler
```

The `NebulaCluster` CRD served/stored:

```text
v1alpha1
```

---

## Operator vs hand-written StatefulSet

A Kubernetes operator combines CRDs with an application-aware reconciliation loop.

### Operator advantages

1. It exposes database-level desired state rather than forcing the user to manually manage every low-level Kubernetes resource.
2. It automates application-specific lifecycle behavior such as component creation, topology reconciliation, and scaling.

### Operator risk

The controller and CRDs become another dependency. An operator bug, version mismatch, bad reconciliation decision, or CRD compatibility problem can affect the database lifecycle.

### Hand-written StatefulSet advantages

1. The Kubernetes resources are explicit and easier to inspect directly.
2. There is no extra application-specific controller required for basic Pod/PVC lifecycle.

### Hand-written StatefulSet risk

Kubernetes understands the Pod/storage lifecycle but not the database protocol. Failover, topology changes, upgrades, and database-specific coordination must be implemented and operated manually.

PostgreSQL in 9.1 therefore demonstrated the hand-managed model; ECK and Nebula Operator demonstrated operator-managed state.

---

# 9.6.2 NebulaCluster

Before writing the CR I inspected the installed schema with `kubectl explain`.

The CRD confirmed:

```text
metad.dataVolumeClaim
storaged.dataVolumeClaims
graphd has no main graph-data claim field
```

File:

```text
nebula/nebula-cluster.yaml
```

Initial topology:

```text
graphd:
  replicas: 1
  image: vesoft/nebula-graphd:v3.8.0

metad:
  replicas: 1
  image: vesoft/nebula-metad:v3.8.0
  PVC: 2Gi local-path

storaged:
  replicas: 1
  image: vesoft/nebula-storaged:v3.8.0
  PVC: 2Gi local-path
  enableAutoBalance: true
```

All three components were pinned to:

```text
k8s-worker-1
```

to keep them away from the memory-heavy Elasticsearch node on worker 2.

Initial reconciliation:

```text
NebulaCluster shopstack-nebula
READY=True

graphd desired/ready:   1/1
metad desired/ready:    1/1
storaged desired/ready: 1/1
```

Pods:

```text
shopstack-nebula-graphd-0     1/1 Running
shopstack-nebula-metad-0      1/1 Running
shopstack-nebula-storaged-0   1/1 Running
```

PVCs:

```text
metad-data-shopstack-nebula-metad-0
  2Gi
  Bound
  PV pvc-2540e183-e7e6-42a2-8a87-a0f34b2f326b

storaged-data-shopstack-nebula-storaged-0
  2Gi
  Bound
  PV pvc-89b91de9-0b45-4284-a788-29755cbf1a7d
```

`graphd` exposed:

```text
9669
19669
```

Initially, before the graph space existed, `SHOW HOSTS` showed the one storaged host `ONLINE` but with no valid partition.

---

# 9.6.3 Graph schema and data

Files:

```text
nebula/schema.ngql
nebula/sample-data.ngql
```

Space:

```text
shopstack
partition_num = 1
replica_factor = 1
vid_type = FIXED_STRING(32)
```

Tags:

```text
product(name, category, price)
customer(name)
```

Edges:

```text
browsed()
bought(quantity)
```

Products:

```text
p001 Mouse        electronics 199
p002 Keyboard     electronics 699
p003 USB Hub      electronics 329
p004 Laptop Stand accessories 249
p005 Bottle       lifestyle   129
```

Customers:

```text
c001 Gerald
c002 Pei
c003 Mia
```

Bought edges:

```text
c001 -> p001
c001 -> p002
c001 -> p003
c002 -> p001
c002 -> p004
c003 -> p001
c003 -> p005
```

Browsed edges:

```text
c001 -> p004
c002 -> p002
c003 -> p003
```

## Multiline nGQL problem

The first `sample-data.ngql` file formatted one `INSERT` across several physical lines.

When the entire file was passed to:

```text
nebula-console -e
```

the console treated the physical lines as separate commands.

The first line:

```text
INSERT VERTEX ... VALUES
```

was therefore executed before its value rows and returned syntax errors. The following value lines also failed individually.

I did not reset the space.

I rewrote each complete `INSERT` statement onto one physical line. The second run succeeded for:

```text
product vertices
customer vertices
bought edges
browsed edges
```

Final verification showed:

```text
SHOW TAGS:
customer
product

SHOW EDGES:
bought
browsed
```

and all five products / three customers could be queried.

---

# 9.6.4 Required nGQL queries

File:

```text
nebula/queries.ngql
```

## A. Products bought by one customer

For `c001 / Gerald`:

```text
Mouse      199
Keyboard   699
USB Hub    329
```

## B. 2-hop recommendation

Pattern:

```text
product <- bought - customer - bought -> other product
```

Starting from:

```text
p001 / Mouse
```

the query returned four distinct products:

```text
p005 Bottle
p004 Laptop Stand
p002 Keyboard
p003 USB Hub
```

## C. Most-bought product

Counts:

```text
Mouse        3
USB Hub      1
Laptop Stand 1
Keyboard     1
Bottle       1
```

Therefore `p001 / Mouse` was the most-bought product in the sample graph.

## nGQL vs SQL vs openCypher/GQL

SQL is table-oriented. Relationships are normally represented with foreign keys and traversed through joins.

nGQL is graph-oriented: vertices, tags, edges, and traversals are first-class concepts. A multi-hop pattern can be represented directly rather than manually composing relational joins.

The `MATCH` syntax is conceptually similar to openCypher/GQL pattern matching, but nGQL still has its own syntax and semantic rules.

One example from this lab was:

```text
ORDER BY id(p)
```

which returned:

```text
SemanticError: Only column name can be used as sort item
```

I corrected it by aliasing the expression:

```text
RETURN id(p) AS product_id, ...
ORDER BY product_id
```

The corrected query returned all five products.

---

# 9.6.5 Distributed architecture, scale, and persistence

## Component roles

### graphd

`graphd` is the client-facing query / compute layer. It accepts nGQL on port 9669, plans queries, and coordinates execution.

### metad

`metad` stores cluster metadata and control information such as spaces, schemas, topology, and partition metadata. It is persistent and used a PVC in this lab.

### storaged

`storaged` stores the actual graph partitions containing vertices and edges. It is the main persistent data layer and used PVC-backed storage.

Summary:

```text
graphd     query/compute            no main graph-data PVC
metad      metadata/control state   persistent
storaged   graph data               persistent
```

## Scale storaged 1 -> 2

I edited the tracked `NebulaCluster` CR:

```text
storaged replicas: 1 -> 2
```

After applying it, the operator reconciled:

```text
GRAPHD  1/1
METAD   1/1
STORAGED 2/2
READY=True
```

The second storage Pod appeared:

```text
shopstack-nebula-storaged-1
```

with a new 2Gi PVC:

```text
storaged-data-shopstack-nebula-storaged-1
PV: pvc-8d360bfc-6ed4-4228-844f-cfcf82fdf742
```

`SHOW HOSTS` showed both storage hosts ONLINE.

Because the existing space was created with:

```text
partition_num = 1
replica_factor = 1
```

the original `storaged-0` remained leader for:

```text
shopstack:1
```

while `storaged-1` correctly showed:

```text
No valid partition
```

Adding a storage process does not retroactively change the space replication factor.

## Delete storaged Pod and prove persistence

Before deletion:

```text
Pod:
shopstack-nebula-storaged-0

Pod UID:
d45c5a66-d20f-4b4f-845a-0d35d510ea00

PVC UID:
89b91de9-0b45-4284-a788-29755cbf1a7d

PV:
pvc-89b91de9-0b45-4284-a788-29755cbf1a7d

PV UID:
fbadb698-5463-4231-a54a-84b42ee5c859
```

I deleted the Pod.

After operator/StatefulSet recreation:

```text
new Pod UID:
06ed6ba2-9890-4c7f-9630-b4d184176b16
```

The PVC UID, PV name, and PV UID were unchanged.

`SHOW HOSTS` returned both storaged hosts ONLINE, and:

```text
SHOW SPACES
```

still returned:

```text
shopstack
```

A product-level query then returned all five persisted products:

```text
p001 Mouse
p002 Keyboard
p003 USB Hub
p004 Laptop Stand
p005 Bottle
```

This demonstrated that the Pod object was replaceable while state remained on the PVC/PV.

---

# 9.6.6 NebulaGraph BR backup runbook

File:

```text
runbooks/nebula-backup.md
```

The 286-line runbook documents the Community NebulaGraph BR workflow using the MinIO object store that Task 7 will provide.

The documented target is:

```text
bucket: shopstack-backups
prefix: nebula/
```

The runbook covers:

```text
BR prerequisites
nebula-agent requirement
SHOW HOSTS
SHOW SPACES
MinIO / S3-compatible credentials
br backup full
br show
object verification
offline/disruptive restore preparation
br restore full
post-restore service verification
post-restore graph queries
backup cleanup and retention
```

The procedure treats restore as an offline/disruptive maintenance operation.

Final service checks showed:

```text
SHOW HOSTS:
storaged-0 ONLINE
storaged-1 ONLINE

SHOW SPACES:
shopstack
```

---

# 9.6 Stretch — NebulaGraph Studio

File:

```text
nebula/studio.yaml
```

The Studio workload was:

```text
image:     vesoft/nebula-graph-studio:v3.10.0
namespace: data
replicas:  1
node:      k8s-worker-1
port:      7001
Service:   ClusterIP
```

Resources:

```text
requests:
  cpu: 50m
  memory: 128Mi

limits:
  cpu: 500m
  memory: 512Mi
```

The Deployment rolled out successfully:

```text
nebula-studio   1/1 Running
```

An in-cluster curl returned:

```text
HTTP 200
```

## Istio exposure

I extended the existing Gateway with:

```text
studio.shopstack.local
```

and created:

```text
istio/nebula-studio-virtualservice.yaml
```

Destination:

```text
nebula-studio.data.svc.cluster.local:7001
```

### Dry-run caught an indentation error

The first script inserted:

```text
studio.shopstack.local
```

with four spaces instead of eight.

Server-side dry-run rejected the Gateway:

```text
spec.servers[1] ... must be of type object: "string"
```

Because I tested with `--dry-run=server`, the invalid Gateway never replaced the working live resource.

I corrected the indentation, repeated the dry-run successfully, and then applied the files.

Final Gateway hosts:

```text
shopstack.local
kibana.shopstack.local
studio.shopstack.local
```

Final VirtualServices:

```text
shopstack
kibana
nebula-studio
```

Using the same ingress NodePort tunnel, Host-header access returned:

```text
HTTP 200
```

I added:

```text
127.0.0.1 studio.shopstack.local
```

to `/etc/hosts`, flushed DNS, and the hostname request also returned:

```text
HTTP 200
```

The Studio evidence screenshot was saved as:

```text
docs/evidence/task6/nebula-studio-shopstack-graph.png
```

The terminal audit confirms the screenshot exists.

---

# End-of-Task Resource Management

The required VM sizing remained unchanged at approximately 2 vCPU / 4 GiB per node.

The Task 6 data stores and operators pushed CPU requests and memory utilization close to the capacity of the small lab workers.

At the end of the recorded session, worker 1 showed:

```text
CPU requests:    1850m / 2000m = 92%
Memory requests: 3200Mi        = 84%
```

Worker 2 was using approximately:

```text
3318Mi = 87%
```

of memory by `kubectl top`.

## Attempt to bring Kibana back while Studio was running

I changed the live Kibana CR back to:

```text
count: 1
```

but the new Kibana Pod remained `Pending`.

Scheduler event:

```text
0/3 nodes are available:
1 Insufficient cpu,
1 node did not match the Pod nodeSelector,
1 node had an untolerated taint
```

The Kibana Pod required:

```text
nodeSelector: k8s-worker-1
main container request: 200m CPU / 512Mi
init container request: 100m CPU / 50Mi
```

I scaled the live Nebula Studio Deployment to zero to free its `50m` request, but Kibana still did not schedule within the next 300 seconds.

I therefore returned the live Kibana CR to:

```text
count: 0
```

Final verification:

```text
kubectl get pod \
  -n data \
  -l kibana.k8s.elastic.co/name=shopstack

No resources found in data namespace.
```

Nebula Studio was also left at live replica count `0`.

### Repository desired state was preserved

The tracked manifests were **not** changed to zero:

```text
elastic/kibana.yaml:
  version: 9.5.3
  count: 1

nebula/studio.yaml:
  replicas: 1

nebula/nebula-cluster.yaml:
  graphd:    1
  metad:     1
  storaged:  2
```

Therefore the repository still describes the deployable Task 6 configuration. Scaling the completed UI components down was a runtime capacity decision, not a reduction of the deliverable.

Earlier Task 4/5 application Deployments had also been scaled down live after their original replica counts were captured in `/tmp/task6-pre-elasticsearch-replicas.txt`. Their tracked manifests were not changed by that runtime scaling.

---

# Troubleshooting Notes

## Kubernetes API SSH tunnel repeatedly expired

The local kubeconfig points to:

```text
https://127.0.0.1:6443
```

so when the SSH forward ended, commands failed with either:

```text
connection refused
```

or:

```text
TLS handshake timeout
```

At one point a stale listener still occupied TCP/6443:

```text
bind [127.0.0.1]:6443: Address already in use
```

`lsof` showed the SSH PID, but the process disappeared before `kill` could act on it.

I did not reset kubeadm or expose the API publicly. I checked the listener state and recreated only the existing SSH forward when required.

## PostgreSQL role password quoting

The first `CREATE ROLE` attempt using a `psql -c` command plus `:'reporting_password'` failed with a syntax error.

I verified that the role had not been created, kept the generated password, and changed to stdin-fed SQL. The second attempt succeeded.

## PostgreSQL backup namespace changed after access-control design

The first CronJob in `data` worked, but the final PostgreSQL policy only allows `shopstack`.

I moved the tracked backup CronJob/PVC to `shopstack`, used the FQDN for PostgreSQL, and verified the new Job received an Istio sidecar and still completed.

This aligned the backup workload with the final namespace authorization model.

## Redis command paste contained terminal bracketed-paste characters

One pasted command started with:

```text
[200~kubectl
```

and zsh returned:

```text
bad pattern
```

No cluster object changed. I re-ran the intended command cleanly.

## ECK operator was a StatefulSet, not a Deployment

I initially used:

```text
kubectl rollout status deployment/elastic-operator
```

and received `NotFound`.

Inspection showed the Helm chart had deployed a StatefulSet. Using:

```text
statefulset/elastic-operator
```

was correct.

## Elasticsearch container did not include `jq`

A command attempted to pipe Elasticsearch API output to `jq` inside the Elasticsearch container:

```text
sh: jq: command not found
```

I did not install extra packages into the database container. I moved JSON processing outside the container / into the temporary curl client workflow.

## Elasticsearch mapping was corrected from `name` to `title`

The first products mapping worked technically but used the field name `name`.

Because the task explicitly requires `title` as text with a keyword sub-field, I corrected the mapping and data files, deleted the temporary index, recreated it, and repeated indexing/search validation.

The final repository and final query evidence use `title`.

## Metrics Server certificate failure

The official Metrics Server Pod was Running but NotReady and the APIService had no usable metrics.

Logs showed that every kubelet serving certificate lacked the node-IP SAN.

The lab-only `--kubelet-insecure-tls` patch resolved it. In production this flag should be removed after issuing trusted kubelet serving certificates with the correct SANs.

## Nebula multiline `INSERT` statements

`nebula-console -e` treated multiline physical statements as separate commands and produced syntax errors around `VALUES` and the value rows.

I rewrote each full `INSERT` onto one physical line. The corrected script loaded all graph data without deleting/recreating the space.

## Nebula `ORDER BY` expression

This query failed:

```text
ORDER BY id(p)
```

with:

```text
Only column name can be used as sort item
```

I aliased the expression and sorted by the alias:

```text
RETURN id(p) AS product_id, ...
ORDER BY product_id
```

The corrected query returned all five persisted products.

## Nebula Studio Gateway indentation

A script inserted the Studio host at the wrong YAML indentation.

Server-side dry-run rejected it before it could affect the live Gateway.

After correcting the host to align with the existing host list, both dry-run and live apply succeeded.

## Final Kibana scheduling failure was capacity-related

The final Kibana Pod did not crash. It never scheduled.

`kubectl describe` showed:

```text
Insufficient cpu
```

on its required worker.

This was a scheduler-capacity issue caused by accumulated Task 6 workload requests on fixed-size 4Gi/2-vCPU nodes. I kept the required VM sizing and scaled the already-evidenced UI component down rather than increasing lab resources.

---

# Checkpoint Questions

## 1. What is the difference between a logical backup (`pg_dump`) and a physical backup (base backup / WAL archiving)? When would you need point-in-time recovery?

A logical backup exports SQL-level database objects and rows. `pg_dump` is portable and convenient for selective recovery or migration, but restoring a very large logical dump can be slow.

A physical backup captures the PostgreSQL data representation and is normally paired with WAL archiving. It is more appropriate for whole-cluster disaster recovery and is the foundation for point-in-time recovery.

Point-in-time recovery is needed when the required target is a specific moment, for example immediately before an accidental destructive update or table drop. I would restore a base backup and replay WAL only up to the selected recovery target.

---

## 2. Why does a StatefulSet Pod keep the same name and storage after rescheduling?

A StatefulSet gives each replica a stable ordinal identity such as:

```text
postgres-0
shopstack-nebula-storaged-0
```

A `volumeClaimTemplate` creates a stable PVC associated with that ordinal. Deleting/recreating the Pod produces a new Pod UID, but the same ordinal is recreated and it mounts the same PVC.

The Nebula persistence drill demonstrated this directly: the storaged Pod UID changed while the PVC UID and PV UID remained unchanged.

---

## 3. What risks come with putting database passwords in environment variables, and what are the alternatives?

Environment variables are easy to use but can leak through debugging output, accidental logging, process/container inspection, crash diagnostics, shell history, or overly broad permissions to Pod specifications.

Kubernetes Secrets separate the credential from the application manifest, but their base64 API representation is not encryption by itself.

Production controls should include:

- least-privilege RBAC;
- encryption at rest;
- credential rotation;
- external secret managers such as Vault or cloud secret services;
- mounted secret files or controlled secret injection where appropriate;
- never committing real credentials to Git.

---

## 4. For each data store, name one workload it is right for and one it is wrong for. Why not use PostgreSQL for everything?

### PostgreSQL

Good fit:

```text
transactional business data, orders, users, inventory, relational records
```

Poor fit:

```text
very high-volume ephemeral cache lookups
```

### Redis

Good fit:

```text
cache, session data, counters, rate limits, short-lived queues/leaderboards
```

Poor fit:

```text
authoritative relational OLTP data with complex integrity constraints
```

### Elasticsearch

Good fit:

```text
full-text search, fuzzy matching, relevance ranking, log search, aggregations
```

Poor fit:

```text
ACID relational transactions and referential-integrity-heavy OLTP
```

### NebulaGraph

Good fit:

```text
relationship-heavy recommendations, fraud graphs, social/network traversals
```

Poor fit:

```text
simple CRUD entities with shallow relationships where SQL is already natural
```

PostgreSQL can implement many things, but forcing every workload into one engine can make caching, full-text relevance, or deep relationship traversal unnecessarily inefficient or complex. Additional stores are justified only when their workload advantage is worth their operational cost.

---

## 5. Redis RDB vs AOF: which would you choose for a session store, and which for a job queue? Why?

RDB creates periodic snapshots. It is compact and fast to restore, but writes after the latest snapshot can be lost.

AOF records write commands and can provide a much smaller data-loss window. With `appendfsync everysec`, Redis trades approximately one second of possible recent-write loss for much better write performance than fsyncing every command.

For a disposable/reconstructable session cache, RDB or no persistence may be acceptable.

For a Redis-based job queue, I would prefer AOF because recent accepted jobs are more important to preserve. If the workload needs strict delivery guarantees, I would consider a dedicated durable queue instead.

---

## 6. Why is a single-node Elasticsearch cluster `yellow`, and what do shards and replicas do?

`yellow` means all primary shards are allocated, but one or more replicas are not.

The Final Run `products` index had:

```text
1 primary
1 replica
1 Elasticsearch node
```

The primary was `STARTED`; the replica was `UNASSIGNED`.

Allocation explain returned the `same_shard` decider because Elasticsearch will not place a replica on the same node that already owns the primary copy.

Shards partition index data. Replicas are additional copies of primary shards that provide redundancy and can also serve reads when another node is available.

---

## 7. When is a graph database the right tool over a relational one — and when is it overkill?

A graph database is useful when relationships themselves are central to the workload and queries frequently traverse multiple hops, for example:

```text
recommendations
fraud rings
social relationships
network topology
dependency graphs
```

It is overkill when the workload is mostly straightforward entities with shallow relationships and ordinary CRUD/filtering/aggregation. In that case PostgreSQL is usually simpler to operate and easier for most teams to maintain.

---

## 8. What do graphd, metad, and storaged each do, and which hold persistent state?

```text
graphd:
  query-facing compute layer
  accepts/plans nGQL
  does not hold the main graph dataset

metad:
  metadata/control plane
  spaces, schema, topology, partition metadata
  persistent

storaged:
  actual graph partitions
  vertices and edges
  persistent
```

In the Final Run, metad and storaged received PVCs; graphd did not receive a main graph-data PVC.

---

## 9. What problem does a Kubernetes operator solve compared with plain StatefulSet manifests, and what new failure modes does it introduce?

A StatefulSet knows generic Kubernetes stateful-workload semantics, but it does not understand Elasticsearch or NebulaGraph as database systems.

An operator adds:

```text
CRDs
+
application-aware reconciliation loop
```

so the desired state can be expressed at the database/application level and automatically translated into lower-level Kubernetes resources and lifecycle actions.

Benefits include:

- application-specific lifecycle automation;
- consistent reconciliation;
- easier topology/scaling changes;
- higher-level declarative configuration.

New failure modes include:

- operator/controller bugs;
- CRD/operator version incompatibility;
- unexpected reconciliation;
- controller outages;
- an additional privileged dependency in the cluster.

The operator itself must therefore be versioned, monitored, and tested like any other production control-plane component.

---

# Final Task 6 Repository Artifacts

## PostgreSQL / data

```text
data/namespace.yaml
data/postgres-authorization-policy.yaml
data/postgres-backup-cronjob.yaml
data/postgres-backup-pvc.yaml
data/postgres-headless-service.yaml
data/postgres-peer-authentication.yaml
data/postgres-statefulset.yaml

runbooks/postgres-restore.md
```

## Redis

```text
redis/cache-aside-notes.md
redis/redis-authorization-policy.yaml
redis/redis-networkpolicy.yaml
redis/redis-peer-authentication.yaml
redis/redis-service.yaml
redis/redis-statefulset.yaml
redis/sentinel-lab.yaml
redis/sentinel-vs-cluster.md
```

## Elasticsearch / Kibana

```text
elastic/elasticsearch.yaml
elastic/ilm-notes.md
elastic/kibana.yaml
elastic/products-bulk.ndjson
elastic/products-mapping.json
elastic/query-aggregation.json
elastic/query-bool.json
elastic/query-fuzzy.json
elastic/resource-discipline.md

runbooks/elasticsearch-snapshot.md
istio/kibana-virtualservice.yaml
docs/evidence/task6/kibana-dev-tools-products-query.png
```

## NebulaGraph

```text
nebula/nebula-cluster.yaml
nebula/queries.ngql
nebula/sample-data.ngql
nebula/schema.ngql
nebula/studio.yaml

runbooks/nebula-backup.md
istio/nebula-studio-virtualservice.yaml
docs/evidence/task6/nebula-studio-shopstack-graph.png
```

The existing:

```text
istio/gateway.yaml
```

was modified to add:

```text
kibana.shopstack.local
studio.shopstack.local
```

while preserving `shopstack.local`.

At the final audit:

```text
elastic/kibana.yaml      count: 1
nebula/studio.yaml       replicas: 1
nebula/nebula-cluster    graphd=1, metad=1, storaged=2
```

were all present in the tracked desired-state files.

---

# Task 6 Summary

Task 6 Final Run completed all four data-store areas:

```text
PostgreSQL
  hand-written StatefulSet
  stable PVC
  logical backup / real restore drill
  nightly CronJob
  reporting read-only role
  Istio namespace restriction
  EXPLAIN ANALYZE / pg_stat_activity

Redis
  Redis 8.10.1 StatefulSet
  Secret-based authentication
  STRING / HASH / LIST / SET / ZSET
  TTL expiry proof
  AOF + BGSAVE + PVC restart persistence proof
  cache-aside demonstration
  INFO metrics and 83.3% observed hit rate
  Redis namespace isolation
  real 3-node Sentinel failover drill

Elasticsearch / Kibana
  ECK 3.5.0 operator
  Elasticsearch 9.5.3 single-node cluster
  2Gi JVM heap and 5Gi PVC
  ECK-generated credentials
  corrected title mapping
  10-product bulk index
  fuzzy / bool+range / aggregation queries
  Kibana through Istio
  required Dev Tools screenshot
  yellow-shard diagnosis
  snapshot runbook
  ILM notes
  real kubectl top resource evidence

NebulaGraph
  Nebula Operator chart 1.8.8
  NebulaGraph 3.8.0
  graphd / metad / storaged
  PVC-backed persistent components
  product/customer graph
  browsed/bought relationships
  three required nGQL queries
  storaged scale 1 -> 2
  delete/recreate persistence proof with stable PVC/PV
  BR backup runbook
  NebulaGraph Studio through Istio
  Studio screenshot evidence
```

The task also produced real troubleshooting evidence around private API tunnels, SQL quoting, Redis persistence, ECK resource type assumptions, Elasticsearch mapping correction, Metrics Server kubelet certificates, nGQL command parsing, graph-query semantics, Istio Gateway validation, and fixed-size cluster capacity.

---

**Task 6 status: COMPLETE**
---

# Task 7 — Storage: Block and Object

**Date completed:** 2026-09-20<br>
**Working machine:** MacBook Pro (Apple Silicon, arm64)<br>
**Primary Kubernetes environment:** Three-node kubeadm cluster on Google Compute Engine<br>
**Kubernetes version:** v1.37.0<br>
**Container runtime:** containerd 2.2.1<br>
**StorageClass used for Kubernetes persistence exercises:** `local-path` (`rancher.io/local-path`)<br>
**MinIO server:** `RELEASE.2025-04-22T22-12-26Z`<br>
**MinIO client (`mc`):** `RELEASE.2025-08-13T08-35-41Z`<br>
**Istio version already present from Task 5:** 1.31.0

The Task 3–6 kubeadm cluster was reused directly.

Because the Final Run uses Google Compute Engine rather than Proxmox, the Task 10.1 hypervisor-side block-storage exercise was implemented with **GCP Persistent Disk hot-attach**. This is the same block-storage concept from the guest Linux point of view, but I documented the provider substitution explicitly rather than claiming that Proxmox was used.

The Kubernetes API remained private. Local `kubectl` access continued to use:

```bash
export KUBECONFIG="$HOME/.kube/task4-final-config"
```

and, when required, the existing SSH tunnel:

```bash
ssh -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 \
  k8s-cp
```

---

# Pre-task Cluster Recovery and Resource Discipline

Before starting the storage exercises, `k8s-worker-2` had stopped posting normal node status.

Serial-console evidence repeatedly showed:

```text
systemd[1]: Failed to start systemd-journald.service - Journal Service.
```

I searched the serial output for OOM and disk-capacity evidence:

```bash
gcloud compute instances get-serial-port-output k8s-worker-2 \
  --zone=us-central1-a \
  --port=1 \
  | grep -Ei 'oom-killer|out of memory|killed process|memory cgroup'
```

No OOM-killer evidence was returned.

I also searched for storage errors:

```bash
gcloud compute instances get-serial-port-output k8s-worker-2 \
  --zone=us-central1-a \
  --port=1 \
  | grep -Ei 'no space left|filesystem|ext4-fs|I/O error|read-only file system|disk'
```

The output contained normal historical boot-time ext4 messages, including the root filesystem initially mounting read-only and then being remounted read-write. It did not provide evidence of a current full-disk or I/O failure.

Because the guest remained unhealthy while the GCP VM itself was running, I performed a GCE instance reset:

```bash
gcloud compute instances reset k8s-worker-2 \
  --zone=us-central1-a \
  --quiet
```

My first `kubectl wait` after the reset accidentally used the default localhost context because `KUBECONFIG` had not yet been exported in that Terminal:

```text
The connection to the server localhost:8080 was refused
```

I corrected the client environment:

```bash
export KUBECONFIG="$HOME/.kube/task4-final-config"
kubectl config current-context
```

Result:

```text
kubernetes-admin@kubernetes
```

The worker then returned Ready:

```text
k8s-cp         Ready
k8s-worker-1   Ready
k8s-worker-2   Ready
```

I verified SSH access and PostgreSQL integrity:

```bash
ssh k8s-worker-2 'hostname; uptime'
```

```bash
kubectl -n data exec postgres-0 -c postgres -- sh -ec '
psql -U "$POSTGRES_USER" -d boutique \
  -Atc "SELECT COUNT(*) FROM products;"
'
```

Result:

```text
5
```

This confirmed that the recovery did not damage the PostgreSQL dataset.

## Temporary Elasticsearch scale-down

`kubectl top` showed Elasticsearch using approximately:

```text
2263Mi
```

and `k8s-worker-2` was at approximately 74% memory after recovery.

The Elasticsearch CR was actually named:

```text
data/shopstack
```

not `shopstack-es`.

I confirmed the runtime relationship:

```text
Elasticsearch CR: shopstack
StatefulSet:      shopstack-es-default
```

For Task 7 resource headroom, I temporarily paused the ECK operator and scaled the generated Elasticsearch StatefulSet to zero:

```bash
kubectl -n elastic-system scale statefulset elastic-operator \
  --replicas=0
```

```bash
kubectl -n data scale statefulset shopstack-es-default \
  --replicas=0
```

The Elasticsearch PVC remained Bound:

```text
elasticsearch-data-shopstack-es-default-0
5Gi
RWO
local-path
```

After the Elasticsearch Pod terminated, `k8s-worker-2` memory dropped to approximately:

```text
735Mi / 19%
```

This was a **temporary lab runtime capacity measure**. The tracked Elasticsearch CR still declares one node. Before a later full-stack demo or Capstone run, ECK/Elasticsearch must be restored to the tracked desired state.

---

# 10.1 Block Storage on Linux

## 10.1.1 Hot-add a block disk

I used `k8s-worker-1` for the Task 7 Linux block-storage exercise so the PostgreSQL node on `k8s-worker-2` was not disturbed.

Before attaching a disk:

```bash
ssh k8s-worker-1 \
  'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS'
```

The VM had only its existing 40 GiB boot disk:

```text
sda  40G
```

I also confirmed the initial disk set with:

```bash
ssh k8s-worker-1 \
  'sudo fdisk -l 2>/dev/null | grep "^Disk /dev/"'
```

I created a dedicated 10 GiB GCP `pd-balanced` disk:

```bash
gcloud compute disks create task7-block-worker1 \
  --size=10GB \
  --type=pd-balanced \
  --zone=us-central1-a
```

and hot-attached it to the running VM:

```bash
gcloud compute instances attach-disk k8s-worker-1 \
  --disk=task7-block-worker1 \
  --device-name=task7-block \
  --mode=rw \
  --zone=us-central1-a
```

After `udevadm settle`, `lsblk` showed:

```text
sdb  10G  disk
```

The stable GCP device symlink resolved to:

```bash
readlink -f /dev/disk/by-id/google-task7-block
```

Result:

```text
/dev/sdb
```

`fdisk -l` confirmed:

```text
Disk /dev/sdb: 10 GiB
Disk model: PersistentDisk
```

The disk was initially unpartitioned and unformatted.

---

## 10.1.2 Partition, XFS, `/data`, and UUID-based `fstab`

I created a GPT partition table and one Linux filesystem partition:

```bash
ssh k8s-worker-1 '
DEV="$(readlink -f /dev/disk/by-id/google-task7-block)"
printf "g\nn\n1\n\n\nw\n" | sudo fdisk "$DEV"
'
```

The resulting layout was:

```text
sdb      10G disk
└─sdb1   10G part
```

I formatted the partition as XFS:

```bash
ssh k8s-worker-1 '
PART=/dev/disk/by-id/google-task7-block-part1
sudo mkfs.xfs "$PART"
'
```

I mounted it at `/data`:

```bash
ssh k8s-worker-1 '
sudo mkdir -p /data
PART=/dev/disk/by-id/google-task7-block-part1
sudo mount "$PART" /data
'
```

Verification:

```text
TARGET SOURCE    FSTYPE
/data  /dev/sdb1 xfs
```

and:

```text
/dev/sdb1  xfs  10G  ...  /data
```

The XFS filesystem UUID was:

```text
3156f12a-78de-4791-b088-e77280d130e6
```

I backed up `/etc/fstab` and added a UUID-based entry:

```text
UUID=3156f12a-78de-4791-b088-e77280d130e6 /data xfs defaults 0 0
```

I tested the entry by unmounting and mounting from `fstab`:

```bash
sudo umount /data
sudo mount -a
```

`findmnt /data` again showed:

```text
/data  /dev/sdb1  xfs
```

### Why `/dev/sdb` is unsafe in `/etc/fstab`

Names such as `/dev/sdb` are kernel enumeration names. They can change when disks are added/removed or when device discovery order changes during boot.

A filesystem UUID identifies the filesystem itself and is therefore a more stable persistent-mount reference.

For a cloud VM, the provider's `/dev/disk/by-id/...` names are also useful for identifying attached disks, while the filesystem UUID is appropriate for the final persistent filesystem mount.

---

## 10.1.3 LVM Stretch — online growth

I completed the optional LVM stretch goal using a second dedicated 10 GiB Persistent Disk:

```bash
gcloud compute disks create task7-lvm-worker1 \
  --size=10GB \
  --type=pd-balanced \
  --zone=us-central1-a
```

```bash
gcloud compute instances attach-disk k8s-worker-1 \
  --disk=task7-lvm-worker1 \
  --device-name=task7-lvm \
  --mode=rw \
  --zone=us-central1-a
```

The guest identified it as:

```text
/dev/sdc
```

I created the LVM stack:

```bash
sudo pvcreate /dev/sdc
sudo vgcreate shopstack-vg /dev/sdc
sudo lvcreate -L 4G -n data-lv shopstack-vg
```

Initial state:

```text
PV: /dev/sdc
VG: shopstack-vg
LV: data-lv
LV size: 4.00 GiB
VG free: <6.00 GiB
```

I formatted the logical volume as XFS and mounted it:

```bash
sudo mkfs.xfs /dev/shopstack-vg/data-lv
sudo mkdir -p /data-lvm
sudo mount /dev/shopstack-vg/data-lv /data-lvm
```

I wrote a marker before resizing:

```text
Task 7 LVM online growth test
```

Before growth:

```text
LV size:        4.00 GiB
XFS filesystem: 4.0 GiB
```

I extended the logical volume while it remained mounted:

```bash
sudo lvextend -l +100%FREE /dev/shopstack-vg/data-lv
```

Immediately afterward:

```text
LV size:        <10.00 GiB
XFS filesystem: 4.0 GiB
```

This demonstrated that growing the block device/LV does not automatically grow the filesystem.

I then resized XFS online:

```bash
sudo xfs_growfs /data-lvm
```

Final state:

```text
LV size:        <10.00 GiB
XFS filesystem: 10 GiB
```

The pre-growth marker still existed, proving that the online resize preserved existing data.

### Why LVM matters in cloud environments

Cloud disks are frequently resized as capacity requirements grow. LVM adds an abstraction layer between block devices and filesystems, allowing capacity to be pooled and logical volumes to be extended without redesigning the application mount layout.

The storage layers are:

```text
cloud block disk
  -> LVM PV
  -> VG
  -> LV
  -> filesystem
  -> mount point
```

The cloud provider can enlarge or add block devices; LVM then provides flexible guest-side allocation before the filesystem is grown.

---

# 10.2 Persistent Storage in Kubernetes

## 10.2.1 StorageClass, dynamic provisioning, and CSI

The cluster used the Rancher Local Path Provisioner installed during Task 6.

```bash
kubectl get storageclass
```

Result:

```text
NAME         PROVISIONER             RECLAIM   BINDING
local-path   rancher.io/local-path   Delete    WaitForFirstConsumer
```

It was not marked as the default StorageClass.

The PostgreSQL claim explicitly requested:

```text
storageClassName: local-path
```

### Dynamic provisioning

Dynamic provisioning means that an application requests storage through a PVC and the StorageClass/provisioner creates a matching PV automatically, instead of an administrator pre-creating each PV manually.

In this lab:

```text
PVC
  -> StorageClass local-path
  -> rancher.io/local-path provisioner
  -> dynamically created PV
```

The local-path provisioner is a lab persistence substrate. It creates node-local storage and is **not** being treated as production cloud block CSI storage.

### CSI research

CSI stands for **Container Storage Interface**. It standardizes how storage vendors integrate provisioning, attachment, mounting, expansion, and lifecycle operations with Kubernetes.

For this GCP environment, the cloud block-storage driver I would use for a production-style Persistent Disk implementation is the **GCE Persistent Disk CSI Driver**, whose CSI driver name is:

```text
pd.csi.storage.gke.io
```

Task 10.2 explicitly permits using a simple local provisioner for these exercises, so I did not turn Task 7 into a GCP CSI reconfiguration exercise.

---

## 10.2.2 PostgreSQL PVC and real database files

The Task 6 PostgreSQL StatefulSet already used the required 5 GiB RWO `volumeClaimTemplates` configuration:

```text
name=postgres-data
storageClass=local-path
accessModes=ReadWriteOnce
size=5Gi
```

The volume was mounted at:

```text
/var/lib/postgresql/data
```

The PostgreSQL container used:

```text
PGDATA=/var/lib/postgresql/data/pgdata
```

The PVC was:

```text
postgres-data-postgres-0
```

and was Bound to:

```text
pvc-8ce1363e-8b71-49b9-bd9f-0747bbc8e2f5
```

The database files were present under the PVC-backed path, including:

```text
base/
global/
pg_commit_ts/
pg_logical/
pg_multixact/
pg_stat/
...
```

This demonstrated that the StatefulSet was not merely declaring a PVC; PostgreSQL's actual database cluster lived on the mounted persistent storage.

---

## 10.2.3 Persistence proof — delete Pod

Before deleting `postgres-0`:

```text
OLD_UID=6a4e3161-8bac-480f-a5cf-d67bd5dcbebd
PV=pvc-8ce1363e-8b71-49b9-bd9f-0747bbc8e2f5
products row count=5
```

I deleted the Pod:

```bash
kubectl -n data delete pod postgres-0
```

The StatefulSet recreated it and it became Ready.

The new UID was:

```text
NEW_UID=7cc8a59e-7514-4423-a831-1b2766dc82cc
```

The Pod object was therefore definitely new, but the PVC remained:

```text
postgres-data-postgres-0
```

and the PV remained:

```text
pvc-8ce1363e-8b71-49b9-bd9f-0747bbc8e2f5
```

The database row count was still:

```text
5
```

This demonstrated that Pod lifecycle and persistent-data lifecycle were separated.

---

## 10.2.3 Persistence proof — delete whole StatefulSet

Before deleting the StatefulSet I checked its PVC retention policy:

```text
whenDeleted=Retain
whenScaled=Retain
```

The PVC did not have an owner reference that would cause it to be automatically garbage-collected with the StatefulSet.

The bound PV had:

```text
reclaimPolicy=Delete
```

These are different lifecycle controls:

```text
StatefulSet PVC retention policy
  -> controls whether the PVC survives StatefulSet deletion/scaling

PV reclaim policy
  -> controls what happens to the PV/backend storage when the PVC itself is released/deleted
```

I recorded the existing PV:

```text
BEFORE_PV=pvc-8ce1363e-8b71-49b9-bd9f-0747bbc8e2f5
```

I deleted the StatefulSet:

```bash
kubectl -n data delete statefulset postgres
```

After the Pod disappeared, the PVC was still:

```text
Bound
```

and the PV was still:

```text
Bound
```

I recreated the StatefulSet from the tracked manifest:

```bash
kubectl apply -f data/postgres-statefulset.yaml
```

After `postgres-0` returned Ready:

```text
AFTER_PV=pvc-8ce1363e-8b71-49b9-bd9f-0747bbc8e2f5
```

The exact same PV was reused.

The product row count was again:

```text
5
```

This proved persistence across deletion and recreation of the whole StatefulSet.

### Retain vs Delete

A PV with `Retain` is not automatically destroyed when its claim is released; an administrator must deliberately recover or clean it up.

A PV with `Delete` allows the provisioner to remove the backing storage when the PVC is deleted/released.

In this exercise, the StatefulSet-level PVC retention policy was `Retain`, so deleting the StatefulSet did not delete the PVC. The PV therefore never reached the stage where its `Delete` reclaim policy would remove the backing storage.

---

## 10.2.4 RWO second-node test

The PostgreSQL PV node affinity was:

```text
kubernetes.io/hostname = k8s-worker-2
```

I created the declarative test Pod:

```text
storage/rwo-second-node-test.yaml
```

It referenced:

```text
postgres-data-postgres-0
```

but deliberately selected:

```text
kubernetes.io/hostname: k8s-worker-1
```

The Pod remained:

```text
Pending
```

The scheduler reported:

```text
0/3 nodes are available:
1 node(s) didn't match PersistentVolume's node affinity,
1 node(s) didn't match Pod's node affinity/selector,
1 node(s) had untolerated taint(s).
```

After capturing the evidence I deleted only the test Pod. PostgreSQL remained:

```text
2/2 Running
```

and the row count remained:

```text
5
```

### RWO vs RWX

`ReadWriteOnce` means a volume is mounted read-write by a single **node** at a time. It does not necessarily mean that only one Pod on that same node can ever reference it.

`ReadWriteMany` is intended for storage that multiple nodes can mount read-write concurrently, typically a shared file-storage system such as NFS.

In this lab, the local-path PV was also tied to `k8s-worker-2` through node affinity. Therefore the observed failure was specifically a **local PV topology/node-affinity conflict**, not a cloud CSI `Multi-Attach` error.

For this lab's database usage, the practical conclusion is:

> **block storage = one filesystem, one consumer at a time; this is exactly what a database wants.**

The more precise Kubernetes nuance is that RWO is a single-node access mode.

---

# 10.3 Object Storage — MinIO

## 10.3.1 Deploy PVC-backed MinIO

I created the namespace declaratively:

```text
minio/namespace.yaml
```

Namespace:

```text
storage
```

Root credentials were generated at runtime and stored in:

```text
Secret/storage/minio-root-credentials
```

The actual credential values were not written into the journal or committed to Git.

I created:

```text
minio/pvc.yaml
minio/deployment.yaml
minio/service.yaml
```

The PVC requested:

```text
5Gi
ReadWriteOnce
storageClassName: local-path
```

The Deployment used:

```text
quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z
```

with:

```text
API:     9000
Console: 9001
```

The MinIO Pod became:

```text
1/1 Running
```

and the PVC became:

```text
minio-data
Bound
5Gi
RWO
local-path
```

The dynamically created PV was:

```text
pvc-f89f6458-8584-4e77-b34f-f8434f03e287
```

with node affinity to:

```text
k8s-worker-2
```

Inside the container:

```bash
df -h /data
```

showed `/dev/root`.

That is expected for Rancher Local Path Provisioner: the provisioner creates a directory on the node's local/root filesystem and mounts that directory into the Pod. Kubernetes still manages the storage through a PVC/PV, but the backend is not a dedicated GCE block device.

### Why object storage is not a POSIX filesystem

MinIO exposes an S3-compatible **object API**.

Clients interact with:

```text
bucket
object key
PUT
GET
HEAD
DELETE
HTTP/S3 requests
```

rather than opening a normal POSIX file and performing arbitrary in-place byte writes.

Object storage has a flat key/object model that can emulate folder prefixes, but those prefixes are not normal filesystem directories. Object operations are API operations rather than POSIX file syscalls.

MinIO itself may use a filesystem/block device internally, but applications should consume it through the object API.

---

## 10.3.2 S3 API, buckets, and presigned URLs

The MacBook Pro did not initially have `mc`.

I installed the pinned ARM64 client:

```text
RELEASE.2025-08-13T08-35-41Z
```

and verified the downloaded binary with SHA-256:

```text
a877fd0c183409da9f20f9d6e1811987298bbbca1aa03428eebdffba79fb9445
```

Result:

```text
OK
```

`mc --version` returned:

```text
mc version RELEASE.2025-08-13T08-35-41Z
Runtime: go1.24.6 darwin/arm64
```

I connected to MinIO through a local port-forward and created the alias:

```text
shopstack -> http://127.0.0.1:9000
```

`mc admin info shopstack` reported one online drive and a healthy MinIO instance.

I created the required buckets:

```bash
mc mb --ignore-existing shopstack/shopstack-images
mc mb --ignore-existing shopstack/shopstack-backups
```

`mc ls shopstack` showed:

```text
shopstack-images/
shopstack-backups/
```

### Normal object upload/download

I uploaded:

```text
shopstack-images/minio-test.txt
```

listed it with `mc ls`, downloaded it, and compared the original and downloaded copies:

```text
UPLOAD/DOWNLOAD MATCH
```

### Presigned download

I generated a short-lived presigned download URL with:

```text
mc share download --expire 10m
```

The URL itself was kept in a shell variable and was not printed into the journal.

I downloaded through the presigned URL and compared the content:

```text
PRESIGNED DOWNLOAD MATCH
```

### Presigned upload

I generated a short-lived upload form with:

```text
mc share upload --expire 10m
```

and uploaded:

```text
presigned-upload.txt
```

The uploaded object was downloaded and compared:

```text
PRESIGNED UPLOAD MATCH
```

### Why presigned URLs matter

A normal application can authenticate and authorize a user, then generate a short-lived URL for one object operation.

The browser/mobile client can then transfer the object directly to/from S3-compatible storage:

```text
client
  -> presigned S3 request
  -> object storage
```

instead of:

```text
client
  -> application server
  -> object storage
```

This reduces application-server bandwidth and memory pressure while keeping the bucket private. The permission is time-limited and operation-specific.

---

## 10.3.3 Application service account and least privilege

I created the policy:

```text
minio/shopstack-images-rw-policy.json
```

It permits the application identity to:

```text
ListBucket / GetBucketLocation on shopstack-images
GetObject / PutObject / DeleteObject on shopstack-images/*
```

It does not grant access to:

```text
shopstack-backups
```

I created the parent identity:

```text
shopstack-app-parent
```

and attached:

```text
shopstack-images-rw
```

I then created a dedicated service account.

My first attempt generated a 48-character secret key:

```bash
openssl rand -hex 24
```

MinIO rejected it:

```text
The secret key is invalid.
(secret key length should be between 8 and 40)
```

I regenerated the service-account secret as:

```bash
openssl rand -hex 16
```

which produced:

```text
32 characters
```

The service account was created successfully.

Its runtime credentials were stored in:

```text
Secret/shopstack/minio-app-credentials
```

without printing the values.

### Positive proof — images bucket

Using an alias authenticated with the application service account:

```text
shopstack-app
```

I listed `shopstack-images`, uploaded `app-policy-test.txt`, downloaded it, and compared the result:

```text
APP IMAGES READ/WRITE PASS
```

### Negative proof — backup bucket

Listing the backups bucket returned:

```text
Access Denied
```

and:

```text
EXPECTED DENY: backups list blocked
```

Attempting to upload to the backups bucket returned insufficient permissions and:

```text
EXPECTED DENY: backups write blocked
```

Using the administrative alias I verified that the denied object did not exist:

```text
CONFIRMED: denied object does not exist
```

### Mapping to AWS IAM concepts

The MinIO design maps directly onto familiar AWS concepts:

```text
MinIO service account/access key
  -> IAM principal/access key

MinIO JSON policy
  -> IAM policy

s3:GetObject / s3:PutObject / s3:ListBucket
  -> IAM/S3 actions

arn:aws:s3:::shopstack-images/*
  -> S3 resource ARN

anything not explicitly allowed
  -> implicit deny
```

This makes the policy model transferable to AWS S3 work.

---

## 10.3.4 PostgreSQL backup CronJob -> MinIO + restore

The existing Task 6 backup CronJob originally contained one container:

```text
pg-dump
```

and wrote nightly backups to:

```text
PVC/shopstack/postgres-backups
```

I preserved the existing PVC copy and extended the CronJob so the same dump is also uploaded to MinIO.

### Backup-only MinIO identity

I created:

```text
minio/shopstack-backups-rw-policy.json
```

The policy permits:

```text
ListBucket / GetBucketLocation on shopstack-backups
GetObject / PutObject on shopstack-backups/*
```

It intentionally does not grant object deletion.

I created:

```text
shopstack-backup-parent
```

and a dedicated backup service account.

The runtime credentials were stored in:

```text
Secret/shopstack/minio-backup-credentials
```

### Updated CronJob

The tracked file remained:

```text
data/postgres-backup-cronjob.yaml
```

The updated Job template contains:

```text
pg-dump
minio-upload
```

`pg-dump` writes a custom-format PostgreSQL dump to the existing `/backups` PVC.

The uploader waits for a Pod-specific completion marker and then uploads the same file to:

```text
http://minio.storage.svc.cluster.local:9000
shopstack-backups/
```

### First object-backup Job failure

The first manual test Job failed.

`pg-dump` succeeded:

```text
Creating backup: /backups/boutique-20260920T091237Z.dump
Backup completed:
3.9K
```

but the uploader returned:

```text
/bin/sh: line 3: hostname: command not found
```

Cause:

```text
quay.io/minio/mc
```

is intentionally small and did not contain the `hostname` utility used by my first marker implementation.

I fixed this by using the Kubernetes Downward API in both containers:

```yaml
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
```

and changed the marker to:

```text
/backups/.${POD_NAME}.ready
```

This removed the dependency on a utility that was not present in the image.

### Successful object backup

I applied the corrected CronJob and manually triggered:

```text
postgres-backup-object-test-172238
```

The Job completed successfully.

`pg-dump` created:

```text
boutique-20260920T092242Z.dump
```

and the uploader logged:

```text
Uploading boutique-20260920T092242Z.dump to shopstack-backups
Object backup completed
```

`mc ls shopstack/shopstack-backups` showed:

```text
boutique-20260920T092242Z.dump
3.9 KiB
```

### Real restore from the object copy

I downloaded the actual object from MinIO:

```text
shopstack/shopstack-backups/boutique-20260920T092242Z.dump
```

The local SHA-256 was:

```text
1f431c7c7e6997c34c17e36490108bfe3b189aace0049d2c5196f5e769360f80
```

I copied it into `postgres-0`, created a temporary database:

```text
boutique_object_restore
```

and restored with `pg_restore`.

Comparison:

```text
original_rows=5
restored_rows=5
OBJECT RESTORE VERIFIED
```

I then removed the temporary restore database and files.

The production database remained:

```text
5
```

rows.

This demonstrated a real recovery path from the object-storage copy, not merely the existence of a backup file.

### Reuse by other data stores

The same S3-compatible backup system can also be used as:

```text
NebulaGraph BR object-storage target
Elasticsearch S3 snapshot repository
```

The Task 6 runbooks already documented those future integrations against the Task 7 MinIO object-storage design.

---

## 10.3.5 Versioning and lifecycle

Before this step, the long-running local MinIO port-forward exited with:

```text
error: lost connection to pod
```

I verified:

```text
all Kubernetes nodes Ready
MinIO Pod 1/1 Running
MinIO Service present
```

so the failure was only the local port-forward stream.

I restarted the port-forward and confirmed:

```text
MinIO API OK
```

before continuing.

### Enable versioning

I enabled versioning on:

```text
shopstack-backups
```

Verification:

```text
shopstack/shopstack-backups versioning is enabled
```

### Create and overwrite an object

I uploaded:

```text
Task 7 backup version ONE
```

as:

```text
task7-versioning-proof.txt
```

Then I overwrote the same key with:

```text
Task 7 backup version TWO
```

The current object returned:

```text
Task 7 backup version TWO
```

Version listing showed:

```text
v2  d57d7311-f604-4ecf-bdce-6cfffb1f37cd
v1  fdf22ff9-4674-422b-b956-ec93c11fe74d
```

### Restore the previous version

I downloaded the old v1 explicitly by version ID:

```text
fdf22ff9-4674-422b-b956-ec93c11fe74d
```

The retrieved content was:

```text
Task 7 backup version ONE
```

Verification:

```text
PREVIOUS VERSION RETRIEVED
```

I uploaded that old content to the same object key again.

The new current object became:

```text
Task 7 backup version ONE
```

and verification returned:

```text
PREVIOUS VERSION RESTORED AS CURRENT
```

The final version history contained:

```text
v3  ONE  2c5949c2-7ed0-42fe-9e17-baf975d6aa85
v2  TWO  d57d7311-f604-4ecf-bdce-6cfffb1f37cd
v1  ONE  fdf22ff9-4674-422b-b956-ec93c11fe74d
```

### Lifecycle policy

I added:

```text
NoncurrentVersionExpiration = 7 days
```

The lifecycle rule was enabled.

### Why versioning matters for backup integrity

Versioning protects against accidental overwrite and many cases of accidental or unauthorized replacement because the previous object remains recoverable.

It also improves ransomware recovery options when an attacker or compromised application overwrites current objects.

However, versioning is not a complete anti-ransomware control by itself. If an attacker has credentials that can delete versions or modify lifecycle rules, historical versions can still be destroyed.

A stronger design combines:

```text
versioning
least-privilege backup identity
no routine delete permission
retention/lifecycle controls
independent credentials
restore testing
checksums
and, where available, immutable/object-lock retention
```

The successful PostgreSQL restore drill was therefore as important as enabling versioning.

---

## 10.3.6 MinIO Console through Istio

I reused the existing Task 5 Istio Gateway rather than creating a second ingress stack.

Existing hosts were:

```text
shopstack.local
kibana.shopstack.local
studio.shopstack.local
```

I extended:

```text
istio/gateway.yaml
```

with:

```text
minio.shopstack.local
```

and created:

```text
istio/minio-virtualservice.yaml
```

The destination was:

```text
minio.storage.svc.cluster.local:9001
```

### Gateway YAML validation error

My first automated edit inserted the new host with incorrect YAML indentation.

Client-side dry-run rejected the file:

```text
error converting YAML to JSON:
yaml: line 17: did not find expected key
```

The live Gateway had not yet been modified.

I inspected the whitespace and corrected:

```yaml
hosts:
  - shopstack.local
  - kibana.shopstack.local
  - studio.shopstack.local
  - minio.shopstack.local
```

The second dry-run succeeded and I applied both resources.

Live verification showed:

```text
shopstack-gateway
  shopstack.local
  kibana.shopstack.local
  studio.shopstack.local
  minio.shopstack.local
```

and:

```text
VirtualService/minio
host:        minio.shopstack.local
destination: minio.storage.svc.cluster.local
port:        9001
```

### Route verification

The kubeadm Istio ingress Service was a `LoadBalancer`, but because this self-managed cluster did not have cloud LoadBalancer integration, its external IP remained:

```text
<pending>
```

I forwarded local port 8080 to the Istio ingress gateway and tested the Gateway host route:

```bash
curl -sS \
  -o /dev/null \
  -w 'HTTP %{http_code}\n' \
  -H 'Host: minio.shopstack.local' \
  http://127.0.0.1:8080/
```

Result:

```text
HTTP 200
```

I added:

```text
127.0.0.1 minio.shopstack.local
```

to the MacBook Pro `/etc/hosts`.

A background ingress port-forward later exited before the browser test, so I restarted the same port-forward in a foreground Terminal and kept it open while using the browser.

The browser then successfully reached:

```text
http://minio.shopstack.local:8080
```

through:

```text
browser
 -> localhost:8080
 -> istio-ingressgateway:80
 -> shopstack-gateway
 -> VirtualService/minio
 -> minio.storage.svc.cluster.local:9001
```

I logged in and opened:

```text
Object Browser
 -> shopstack-backups
```

The bucket browser showed:

```text
boutique-20260920T092242Z.dump
task7-versioning-proof.txt
```

The required screenshot was stored as:

```text
docs/evidence/task7/minio-console-bucket-browser.png
```

![MinIO bucket browser](docs/evidence/task7/minio-console-bucket-browser.png)

---

# Checkpoint Questions

## 1. What is the relationship between PV, PVC, and StorageClass?

A **PersistentVolume (PV)** represents storage capacity available to Kubernetes.

A **PersistentVolumeClaim (PVC)** is an application's request for storage, including capacity and access mode.

A **StorageClass** describes how storage should be provisioned, including the provisioner/CSI driver, reclaim behavior, binding mode, and other backend-specific parameters.

With dynamic provisioning the relationship is:

```text
Pod / StatefulSet
  -> PVC
  -> StorageClass
  -> provisioner / CSI driver
  -> PV
  -> backend storage
```

In this lab:

```text
postgres-data-postgres-0
  -> local-path
  -> rancher.io/local-path
  -> pvc-8ce1363e-...
```

The PVC is what the workload references; the PV is the storage resource that satisfies the claim.

---

## 2. What does `volumeBindingMode: WaitForFirstConsumer` do, and why does it matter for multi-zone clusters?

`WaitForFirstConsumer` delays volume provisioning/binding until a Pod that consumes the PVC is being scheduled.

This allows Kubernetes to consider the Pod's scheduling constraints and storage topology together.

Without this delay, a dynamically provisioned volume could be created in one zone before Kubernetes knows where the Pod can run. The Pod might then be schedulable only in another zone, creating a topology conflict.

With `WaitForFirstConsumer`:

```text
Pod scheduling requirements
+ node/zone topology
+ storage topology
```

can be evaluated before the storage is committed.

In this lab, `local-path` uses the same idea to create node-local storage only after a consumer provides a scheduling context.

---

## 3. Why is NFS usually a poor choice for database data files, while block storage is a good one?

A database such as PostgreSQL expects filesystem behavior with predictable durability and latency for operations such as:

```text
fsync
random reads/writes
file locking
rename
WAL writes
metadata operations
```

Block storage gives the database a filesystem with direct single-host semantics and normally provides more predictable latency and failure behavior.

NFS adds a networked filesystem layer, network latency, server availability dependencies, caching/locking considerations, and more complex failure semantics.

Modern enterprise NFS systems can support databases when explicitly designed and validated for that workload, but block storage is normally the simpler and more predictable default for PostgreSQL data files.

---

## 4. Block vs file vs object storage — one ShopStack workload for each

### Block storage

Best fit:

```text
PostgreSQL data directory
```

Why:

The database needs a mounted filesystem, durable random read/write operations, `fsync`, WAL, and low-latency single-writer semantics.

### File storage

Natural fit:

```text
a shared POSIX workspace for generated ShopStack reports,
imports, or shared application files that multiple replicas
must mount concurrently
```

Why:

Multiple Pods can use normal filesystem operations against the same shared hierarchy.

This Final Run did not deploy an NFS backend, but this is the storage model that would fit that type of shared-file workload.

### Object storage

Best fit:

```text
product images
database backup dumps
Elasticsearch snapshots
NebulaGraph backup objects
```

Why:

These are naturally stored and retrieved as whole objects through an S3 API, do not require POSIX in-place editing, and benefit from bucket policies, presigned URLs, versioning, and lifecycle controls.

---

## 5. Why can PostgreSQL's data directory not run on MinIO even though both are "storage"?

PostgreSQL does not simply need a place that can hold bytes. It needs POSIX filesystem semantics.

The database continuously performs operations such as:

```text
open/read/write
random in-place updates
fsync
rename
directory operations
WAL updates
file locking
```

MinIO exposes objects through an S3-compatible HTTP API.

An S3 object is addressed by bucket/key and is normally replaced as an object operation rather than mutated like an ordinary local file.

Therefore:

```text
PostgreSQL data directory -> mounted filesystem/block storage
PostgreSQL backup dump    -> object storage is an excellent fit
```

That is why the live PGDATA remained on a PVC while `pg_dump` artifacts were sent to MinIO.

---

## 6. What does S3 compatibility buy operationally?

S3 compatibility gives applications and operators a common object-storage API model:

```text
buckets
object keys
GET / PUT / DELETE
access keys
signed requests
presigned URLs
IAM-style policies
versioning
lifecycle
```

Tools and application designs built around these concepts can move between S3-compatible providers with comparatively small changes.

For example, the PostgreSQL backup design still consists of:

```text
create pg_dump
authenticate to object storage
upload object to backup bucket
download object during restore
```

Moving between AWS S3 and MinIO mainly changes the endpoint, credentials, and provider-specific configuration rather than the core backup workflow.

The same compatibility is also why Elasticsearch S3 snapshot tooling and NebulaGraph backup workflows can target an S3-compatible MinIO service.

---

# Final Task 7 Repository Artifacts

## Linux / Kubernetes storage evidence

```text
storage/rwo-second-node-test.yaml
```

Existing PostgreSQL storage manifests reused and verified:

```text
data/postgres-statefulset.yaml
data/postgres-headless-service.yaml
```

The storage write-up and persistence proof are documented in this Task 7 journal, including:

```text
GCP Persistent Disk hot-add
XFS /data mount
UUID-based /etc/fstab
LVM online growth
StorageClass / CSI notes
PVC/PV evidence
Pod deletion persistence proof
StatefulSet deletion persistence proof
RWO second-node failure
```

## MinIO

```text
minio/namespace.yaml
minio/pvc.yaml
minio/deployment.yaml
minio/service.yaml
minio/shopstack-images-rw-policy.json
minio/shopstack-backups-rw-policy.json
```

Updated PostgreSQL backup integration:

```text
data/postgres-backup-cronjob.yaml
```

Istio exposure:

```text
istio/gateway.yaml
istio/minio-virtualservice.yaml
```

Screenshot evidence:

```text
docs/evidence/task7/minio-console-bucket-browser.png
```

Runtime Secrets created during the Final Run:

```text
storage/minio-root-credentials
shopstack/minio-app-credentials
shopstack/minio-backup-credentials
```

The secret values are intentionally not stored in Git. The journal records the creation method without exposing the credentials.

---

# Troubleshooting Notes

## `k8s-worker-2` was unhealthy before Task 7 practical work

**Symptom**

Serial output repeatedly reported:

```text
Failed to start systemd-journald.service
```

The node stopped behaving normally.

**Investigation**

I checked serial output for:

```text
OOM killer
out of memory
no space left
I/O error
read-only filesystem
```

No current OOM or full-disk evidence was found.

**Resolution**

Performed a GCE instance reset, restored the correct `KUBECONFIG`, waited for the node to become Ready, then verified PostgreSQL row count `5`.

I did not reset kubeadm, certificates, or the cluster.

---

## Elasticsearch CR name assumption was wrong

**Symptom**

```text
Elasticsearch "shopstack-es" not found
```

**Cause**

The generated StatefulSet was named `shopstack-es-default`, but the ECK custom resource itself was named:

```text
shopstack
```

**Resolution**

Used:

```bash
kubectl get elasticsearch -A
```

and the tracked manifest to identify the real CR name before making any resource decision.

---

## Kubernetes API tunnel expired during Task 7

**Symptom**

```text
The connection to the server 127.0.0.1:6443 was refused
```

**Cause**

The private kubeadm API is intentionally accessed through an SSH tunnel, and the previous forwarding process had ended.

**Resolution**

Recreated only the SSH forward to `10.10.0.10:6443`. No cluster resource was reset.

---

## `mc admin policy entities` opened help/pager

**Symptom**

The command displayed `mc` help in the internal pager.

**Cause**

The policy name was passed as a positional argument instead of with:

```text
--policy
```

**Resolution**

Exited the pager and used:

```bash
mc admin policy entities \
  shopstack \
  --policy shopstack-images-rw \
  --disable-pager
```

The expected parent-user mapping was returned.

---

## MinIO service-account secret was too long

**Symptom**

```text
secret key length should be between 8 and 40
```

**Cause**

`openssl rand -hex 24` produced a 48-character hex string.

**Resolution**

Used:

```bash
openssl rand -hex 16
```

which produced a 32-character secret. The service account was then created successfully.

---

## Backup uploader image did not contain `hostname`

**Symptom**

The first object-backup Job failed with:

```text
/bin/sh: line 3: hostname: command not found
```

while `pg_dump` itself had succeeded.

**Cause**

The minimal `quay.io/minio/mc` image did not include the `hostname` utility used by the marker script.

**Resolution**

Used Kubernetes Downward API `metadata.name` as `POD_NAME` and changed the marker to:

```text
/backups/.${POD_NAME}.ready
```

The next Job completed and uploaded the real dump to MinIO.

---

## MinIO local port-forward lost its Pod stream

**Symptom**

The background port-forward exited and `mc` returned connection refused.

The log showed:

```text
error: lost connection to pod
```

**Investigation**

All three nodes were Ready and the MinIO Pod remained:

```text
1/1 Running
```

**Resolution**

Restarted only the local port-forward. MinIO data and bucket configuration were unchanged.

---

## Istio Gateway YAML indentation error

**Symptom**

Client-side dry-run rejected `istio/gateway.yaml`:

```text
yaml: line 17: did not find expected key
```

**Cause**

An automated edit inserted `minio.shopstack.local` two spaces too far left.

**Resolution**

Inspected the file with line numbers and visible whitespace, corrected the indentation, and reran dry-run before applying.

This prevented malformed YAML from reaching the live Gateway.

---

## Background Istio port-forward exited before browser evidence

**Symptom**

The host-header `curl` through the Istio Gateway had already returned:

```text
HTTP 200
```

but the browser later showed `ERR_CONNECTION_REFUSED`.

**Cause**

The background local port-forward on TCP/8080 had exited.

**Resolution**

Ran the same ingress port-forward in a dedicated foreground Terminal while using the browser.

The MinIO Console then loaded successfully through:

```text
minio.shopstack.local:8080
```

and the required bucket-browser screenshot was captured.

---

# Task 7 Summary

Task 7 Final Run completed the full storage path:

```text
Linux block storage
  GCP Persistent Disk hot-add
  lsblk / fdisk identification
  GPT partition
  XFS
  /data
  UUID-based /etc/fstab
  real unmount + mount -a verification
  LVM PV/VG/LV
  online LV growth
  online XFS growth
  data preserved

Kubernetes persistence
  local-path StorageClass inspection
  dynamic provisioning explanation
  GCE PD CSI research
  PostgreSQL 5Gi RWO volumeClaimTemplate
  real PGDATA files on the PVC
  Pod deletion persistence proof
  whole-StatefulSet deletion persistence proof
  stable PVC/PV reuse
  RWO second-node topology failure
  RWO/RWX and block/file/object comparison

MinIO object storage
  storage namespace
  Secret-based root credentials
  PVC-backed single-node MinIO
  shopstack-images
  shopstack-backups
  mc client
  normal upload/download
  presigned download/upload
  images-only application service account
  backup access denied for app identity
  dedicated backup identity
  PostgreSQL CronJob upload to S3-compatible storage
  real object backup restore: 5 rows -> 5 rows
  bucket versioning
  previous-version recovery
  7-day non-current lifecycle
  MinIO Console through Istio
  bucket-browser screenshot
```

The required journal conclusion is:

> **block storage = one filesystem, one consumer at a time; this is exactly what a database wants.**

For Kubernetes access-mode terminology, `ReadWriteOnce` specifically means one node at a time; the local-path topology in this lab also tied the volume to one node.

No Task 7 practical infrastructure requirement remains outstanding.

---

**Task 7 status: COMPLETE**
---