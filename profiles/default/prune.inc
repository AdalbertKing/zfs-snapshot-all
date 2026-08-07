# Built-in default profile — policy fields copied into a generated [prune:*].
# Slice A: fixture only. Concrete prune scope and recursive=yes|no remain
# orchestration-owned because backup and sync have different safe topologies.
# No section header and no relationship-owned fields.

use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly
gfs          = yes
gfs_pattern  = automated_
