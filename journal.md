# DevOps Pre-Onboarding Practice — Task 1 Journal

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
