# CCDC Linux Scripts

A collection of Bash utilities for Linux incident response, backup, account rotation, firewall hardening, SSH hardening, monitoring, and reporting.

## Scripts

- `01_linux_inventory.sh` - Read-only host inventory
- `02_linux_backup.sh` - Pre-change configuration and database backups
- `03_linux_passwords.sh` - Credential rotation
- `04_linux_firewall.sh` - Inbound firewall rules with rollback
- `05_linux_ssh.sh` - Conservative SSH hardening
- `06_linux_watch.sh` - Continuous change monitoring
- `07_linux_sessions.sh` - Session inspection and termination
- `08_linux_report.sh` - HTML inventory report
- `fanout.sh` - Run scripts across multiple Linux hosts over SSH

## Safety

Most scripts require root and some perform destructive or service-impacting changes. Read each script's header and back up the system before use. Firewall, password, and session changes can interrupt scoring or lock out administrators.

## Usage

```bash
sudo bash 01_linux_inventory.sh
sudo bash 02_linux_backup.sh
sudo bash 03_linux_passwords.sh
sudo bash 04_linux_firewall.sh 22,80,443
sudo bash 05_linux_ssh.sh
sudo bash 06_linux_watch.sh
sudo bash 07_linux_sessions.sh
sudo bash 08_linux_report.sh
```

For multi-host execution:

```bash
bash fanout.sh hosts.txt 01_linux_inventory.sh
bash fanout.sh hosts.txt 08_linux_report.sh -s
```
