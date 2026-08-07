# Built-in default profile — fields copied into a generated [dataset:*].
# Slice A: fixture only. No section header and no relationship-owned fields.
# Deliberately no `recursive = no`: today's zfs-backup.sh omits that field,
# and Slice B requires byte-identical effective CONFIG v4 output.

use_template = standard_hourly
