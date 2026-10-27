# Contributing

Thank you for wanting to improve zfsbackup. Reports and ideas are as welcome as code; English and
Polish are both fine.

## How this repository works

This public repository is **generated**: every release is one commit exported from a private
development repository, where the code, the test suites and the review history live. Hosts follow
this repository's `main` with `git merge --ff-only`, so its history only grows and nothing is ever
merged here by hand.

What that means for you:

- **Issues** are the main channel: a bug, a confusing GUI text, a missing feature, a question.
- **Pull requests** are welcome as a precise proposal. The maintainer applies the change in the
  development repository, runs the suites there, and it arrives here with the next release,
  credited to you in [CHANGELOG.md](CHANGELOG.md). The PR is then closed with a link to that
  release, not merged.

## A good bug report

- `zfs-backup --version`;
- the relation type (backup, mirror, local copy, local/remote snapshots) and what you did — the GUI
  window and keys, or the exact command;
- what you expected and what happened, with the relevant lines of the job log;
- replace your own host names, addresses and dataset names if you prefer — say that you did.

## Style of a code change

- Plain bash for the engines and the CLI, Python 3 standard library for the GUI; no new runtime
  dependencies without a discussion first.
- Config, relation records, dataset names, host names and remote output are data: never `source`,
  `eval` or otherwise execute them.
- Do not weaken host-key checking, the delegated-account isolation, the destructive-operation guards
  or the protection of Proxmox-reserved snapshots, even as a shortcut.
- Keep compatibility of the CLI, the config format and the relation records unless the change is
  explicitly a breaking one.
- One logical change per PR, with a short description of the reason and how you checked it
  (`bash -n` on every touched script at minimum; on which host and which ZFS/Proxmox version you
  ran it, if you did).

## Licence

By contributing you agree that your contribution is licensed under the MIT licence of this project
(see [LICENSE](LICENSE)).
