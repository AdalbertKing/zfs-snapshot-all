# Security policy

zfsbackup runs as root, opens SSH connections between hosts and destroys ZFS snapshots by design,
so a defect in it can be a security problem on every host it is installed on. Reports are welcome
and are handled before feature work.

## Supported versions

Only the latest release on `main` of this repository. Installed hosts update themselves from it
once an hour, so a fix reaches them without a manual upgrade (unless an administrator has set
`update-hold`).

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private reporting instead: the **Security** tab of this
repository → **Report a vulnerability**. Please include:

- the version (`zfs-backup --version`, which also names the development revision);
- what an attacker needs (a shell on a source, an SSH key of a delegated account, a crafted
  dataset or host name, a config file they can write, …);
- what they gain, and the steps or a proof of concept.

The aim is an answer within a week. When the fix is published, the advisory credits you unless you
ask not to be named.

## Scope — what counts

- Escaping the delegated account: a non-root job account doing more than its ZFS rights and the
  forced commands in `authorized_keys` allow.
- Values from config, relation records, dataset names, host names or remote output being executed
  as code instead of treated as data.
- Weakening SSH host-key checking, or a path where the collector trusts a host it has not paired with.
- Retention, restore or replica media destroying data outside what the administrator configured.

Out of scope: anything that already requires root on the collector, and attacks on Proxmox VE,
OpenZFS or OpenSSH themselves (report those upstream).
