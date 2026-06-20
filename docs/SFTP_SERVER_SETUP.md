# SFTP Server Setup

This document describes a practical way to set up restricted SFTP-only backup users for Restic and other automated backups.

It is intended to complement [SFTP_TESTING.md](/home/vdrmrt/workspace/restic-batch-backup/docs/SFTP_TESTING.md:1), which focuses on the client-side test flow.

## Purpose

The goal is to create one isolated SFTP area per backup source, with:

- a dedicated Linux user
- key-based authentication
- no shell access
- a chrooted SFTP environment
- one writable `/data` directory inside the chroot

This setup works well for:

- Restic repositories
- non-Restic file backups
- manual SFTP uploads
- per-device or per-server isolation

## Placeholders

Replace these placeholders before running commands:

```text
<backup-user>        SFTP-only backup username, for example backup-<source-name>
<source-name>        Short source/device name used in tags and filenames
<backup-host>        DNS name or IP address of the backup server
<backup-host-alias>  Optional SSH client alias
<client-ip>          Client IP address used only for SSH config validation
```

## Design Summary

Each backup user has:

- a normal Linux account without shell access
- an SSH public key stored under `/home/<backup-user>/.ssh/authorized_keys`
- SFTP-only access
- a chroot folder under `/mnt/backups/sftp/<backup-user>`
- one writable `data` folder inside the chroot

When the user logs in through SFTP, they should land in:

```text
/data
```

Inside that writable folder, the user can create their own structure, for example:

```text
/data/restic
/data/restic/<source-name>
/data/manual
/data/automated-files
/data/config-exports
```

## Folder Structure

Recommended server-side structure:

```text
/mnt/backups/sftp/
└── <backup-user>/
    └── data/
```

Meaning:

```text
/mnt/backups/sftp/<backup-user>      chroot folder, root-owned, not writable by the backup user
/mnt/backups/sftp/<backup-user>/data writable folder for the backup user
```

The backup data is stored under:

```text
/mnt/backups/sftp/<backup-user>/data
```

The SSH key is stored separately under:

```text
/home/<backup-user>/.ssh/authorized_keys
```

## Naming Convention

Use one dedicated user per device, server, or backup source.

Recommended pattern:

```text
backup-<source-name>
```

Template:

```text
User:          <backup-user>
Chroot folder: /mnt/backups/sftp/<backup-user>
Writable data: /mnt/backups/sftp/<backup-user>/data
SSH key home:  /home/<backup-user>/.ssh/authorized_keys
```

## SSH Server Configuration

If the server uses SSH group allowlisting, make sure the backup group is included.

Example:

```bash
cat /etc/ssh/sshd_config.d/98-allowed-groups.conf
```

```sshconfig
AllowGroups ssh-admin backup-sftp
```

Without `backup-sftp` in `AllowGroups`, the SFTP-only backup users may exist and have valid keys but still be denied at SSH login.

Create or edit the SFTP restriction file:

```bash
nano /etc/ssh/sshd_config.d/99-backup-sftp.conf
```

Recommended configuration:

```sshconfig
Match Group backup-sftp
    ChrootDirectory /mnt/backups/sftp/%u
    ForceCommand internal-sftp -d /data
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    PermitTTY no
    PasswordAuthentication no
```

Validate and reload SSH:

```bash
sshd -t
systemctl reload ssh
```

Check the effective SSH settings for a user:

```bash
sshd -T -C user=<backup-user>,host=<backup-host>,addr=<client-ip> | grep -E "forcecommand|chrootdirectory|passwordauthentication|x11forwarding|allowtcpforwarding|permittty"
```

Expected output should include:

```text
chrootdirectory /mnt/backups/sftp/%u
forcecommand internal-sftp -d /data
passwordauthentication no
x11forwarding no
allowtcpforwarding no
permittty no
```

If you use `AllowGroups`, also confirm that the backup user is actually in `backup-sftp`:

```bash
id <backup-user>
```

The output should include `backup-sftp`.

## Create the Backup Group

Create the shared SFTP-only group if it does not already exist:

```bash
getent group backup-sftp >/dev/null || groupadd --system backup-sftp
```

## Create a New Backup User

Set the username variable and create the user:

```bash
BACKUP_USER="backup-<source-name>"

useradd \
  -m \
  -d "/home/${BACKUP_USER}" \
  -s /usr/sbin/nologin \
  -g backup-sftp \
  "${BACKUP_USER}"

passwd -l "${BACKUP_USER}"
```

Check the user:

```bash
getent passwd <backup-user>
id <backup-user>
```

Expected:

```text
<backup-user>:x:<uid>:<gid>::/home/<backup-user>:/usr/sbin/nologin
```

If the server uses `AllowGroups`, the user must be in `backup-sftp` or SSH will reject login before SFTP restrictions are even applied.

## Create the SFTP Backup Folder

Create the chroot and writable data folder:

```bash
BACKUP_USER="backup-<source-name>"

mkdir -p "/mnt/backups/sftp/${BACKUP_USER}/data"
```

Set permissions:

```bash
chown root:root "/mnt/backups/sftp"
chmod 755 "/mnt/backups/sftp"

chown root:root "/mnt/backups/sftp/${BACKUP_USER}"
chmod 755 "/mnt/backups/sftp/${BACKUP_USER}"

chown "${BACKUP_USER}:backup-sftp" "/mnt/backups/sftp/${BACKUP_USER}/data"
chmod 700 "/mnt/backups/sftp/${BACKUP_USER}/data"
```

Important chroot rule:

```text
The chroot folder itself must be root-owned and not writable by the SFTP user.
Only subfolders inside the chroot should be writable.
```

Correct:

```text
/mnt/backups/sftp/<backup-user>       root:root 755
/mnt/backups/sftp/<backup-user>/data  <backup-user>:backup-sftp 700
```

Incorrect:

```text
/mnt/backups/sftp/<backup-user>       <backup-user>:backup-sftp
```

That will cause SSH/SFTP login failure.

## Configure SSH Key Authentication

On the client machine, create a dedicated key:

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/id_ed25519_<backup-user> \
  -C "restic backup-<source-name> to <backup-host>"
```

For unattended backups, the key is usually created without a passphrase.

Show the public key:

```bash
cat ~/.ssh/id_ed25519_<backup-user>.pub
```

On the backup server, add the public key:

```bash
BACKUP_USER="backup-<source-name>"

mkdir -p "/home/${BACKUP_USER}/.ssh"
nano "/home/${BACKUP_USER}/.ssh/authorized_keys"
```

Paste the public key into `authorized_keys`.

Fix permissions:

```bash
chown "${BACKUP_USER}:backup-sftp" "/home/${BACKUP_USER}"
chown -R "${BACKUP_USER}:backup-sftp" "/home/${BACKUP_USER}/.ssh"

chmod 700 "/home/${BACKUP_USER}"
chmod 700 "/home/${BACKUP_USER}/.ssh"
chmod 600 "/home/${BACKUP_USER}/.ssh/authorized_keys"
```

## Optional SSH Client Alias

On the client, add an SSH alias:

```bash
nano ~/.ssh/config
```

Example:

```sshconfig
Host <backup-host-alias>
    HostName <backup-host>
    User <backup-user>
    IdentityFile ~/.ssh/id_ed25519_<backup-user>
    IdentitiesOnly yes
```

Then test:

```bash
ssh <backup-host-alias>
sftp <backup-host-alias>
```

## Test SFTP Access

From the client:

```bash
sftp -i ~/.ssh/id_ed25519_<backup-user> <backup-user>@<backup-host>
```

Expected result:

```text
The user lands in /data.
The user can create folders in /data.
The user cannot write to /.
```

Test commands inside SFTP:

```sftp
pwd
ls
mkdir test-folder
ls
rmdir test-folder
exit
```

## Example Restic Commands

Create the password file on the client:

```bash
mkdir -p ~/.restic
nano ~/.restic/restic-password-<backup-user>.txt
chmod 600 ~/.restic/restic-password-<backup-user>.txt
```

Initialize a Restic repo in the writable SFTP area:

```bash
restic \
  -r sftp:<backup-user>@<backup-host>:/data/restic/<source-name> \
  --password-file ~/.restic/restic-password-<backup-user>.txt \
  init
```

Run a test backup:

```bash
restic \
  -r sftp:<backup-user>@<backup-host>:/data/restic/<source-name> \
  --password-file ~/.restic/restic-password-<backup-user>.txt \
  backup ~/Documents \
  --tag <source-name>
```

List snapshots:

```bash
restic \
  -r sftp:<backup-user>@<backup-host>:/data/restic/<source-name> \
  --password-file ~/.restic/restic-password-<backup-user>.txt \
  snapshots
```

Test restore:

```bash
mkdir -p /tmp/restic-restore-test

restic \
  -r sftp:<backup-user>@<backup-host>:/data/restic/<source-name> \
  --password-file ~/.restic/restic-password-<backup-user>.txt \
  restore latest \
  --target /tmp/restic-restore-test
```

## Non-Restic SFTP Backups

The same SFTP user can also store non-Restic backups.

Example layout inside `/data`:

```text
/data/manual
/data/automated-files
/data/dumps
/data/config-exports
```

The backup user can create these folders after logging in.

## Troubleshooting

### Public key is rejected

Symptom:

```text
Permission denied (publickey)
```

Check the SSH log:

```bash
journalctl -u ssh -n 100 --no-pager
```

Common cause:

```text
Could not open user '<backup-user>' authorized keys '/home/<backup-user>/.ssh/authorized_keys': Permission denied
```

Another common cause:

```text
User is not allowed because none of user's groups are listed in AllowGroups
```

Fix the SSH allowlist if needed:

```sshconfig
AllowGroups ssh-admin backup-sftp
```

Fix:

```bash
chown <backup-user>:backup-sftp /home/<backup-user>
chown -R <backup-user>:backup-sftp /home/<backup-user>/.ssh
chmod 700 /home/<backup-user>
chmod 700 /home/<backup-user>/.ssh
chmod 600 /home/<backup-user>/.ssh/authorized_keys
```

### SFTP connects and immediately closes

Symptom:

```text
client_loop: send disconnect: Broken pipe
Connection closed
```

Common cause:

```text
bad ownership or modes for chroot directory
```

Fix:

```bash
chown root:root /mnt/backups/sftp/<backup-user>
chmod 755 /mnt/backups/sftp/<backup-user>
```

Do not make the chroot folder writable by the backup user.

### User cannot create folders after login

With chroot, `/` is the chroot folder and must be root-owned. The user should create folders inside:

```text
/data
```

Check:

```bash
ls -ld /mnt/backups/sftp/<backup-user>/data
```

Expected:

```text
<backup-user> backup-sftp /mnt/backups/sftp/<backup-user>/data
```

## Checklist for Adding a New Backup User

Replace `<source-name>` with the source/device name. This creates `backup-<source-name>` as the SFTP-only backup user.

```bash
BACKUP_USER="backup-<source-name>"

getent group backup-sftp >/dev/null || groupadd --system backup-sftp

useradd \
  -m \
  -d "/home/${BACKUP_USER}" \
  -s /usr/sbin/nologin \
  -g backup-sftp \
  "${BACKUP_USER}"

passwd -l "${BACKUP_USER}"

mkdir -p "/mnt/backups/sftp/${BACKUP_USER}/data"

chown root:root "/mnt/backups/sftp"
chmod 755 "/mnt/backups/sftp"

chown root:root "/mnt/backups/sftp/${BACKUP_USER}"
chmod 755 "/mnt/backups/sftp/${BACKUP_USER}"

chown "${BACKUP_USER}:backup-sftp" "/mnt/backups/sftp/${BACKUP_USER}/data"
chmod 700 "/mnt/backups/sftp/${BACKUP_USER}/data"

mkdir -p "/home/${BACKUP_USER}/.ssh"
nano "/home/${BACKUP_USER}/.ssh/authorized_keys"

chown "${BACKUP_USER}:backup-sftp" "/home/${BACKUP_USER}"
chown -R "${BACKUP_USER}:backup-sftp" "/home/${BACKUP_USER}/.ssh"

chmod 700 "/home/${BACKUP_USER}"
chmod 700 "/home/${BACKUP_USER}/.ssh"
chmod 600 "/home/${BACKUP_USER}/.ssh/authorized_keys"

sshd -t
systemctl reload ssh
```

## Notes

- Keep the Restic password safe. Without it, restores are impossible.
- Use a dedicated SSH key per backup user or source device.
- Do not reuse the same SFTP user for unrelated machines if isolation matters.
- Do not give backup users shell access.
- Do not make the chroot folder writable by the backup user.
- Make sure restore tests are part of the process, not an afterthought.
