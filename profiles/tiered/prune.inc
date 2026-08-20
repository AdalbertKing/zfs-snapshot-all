# Profile "tiered" — policy fields copied into a generated [prune:*].
#
# NO `gfs` line, and that is the substantive difference from the default
# profile rather than an omission. gfs defaults to no, so each keep tier emits
# its OWN flat delsnaps.sh line against its own pattern -- four lines, four
# families, four independent counters. The default profile instead sets
# gfs = yes + gfs_pattern and collapses its tiers into one cascading ladder,
# which only works because all of its tiers share a single family.
#
# A `gfs_pattern` would be meaningless here anyway: the ladder matches ONE
# prefix, and since 2026-08-20 gen-cron refuses a ladder whose contributing
# tiers' patterns do not all start with it. automated_hourly, automated_daily,
# automated_weekly and automated_monthly share only `automated_`, so a ladder
# over them would have to re-bucket all four families together -- which is
# precisely the single-family design this profile exists to avoid.
#
# The concrete prune scope and `recursive` stay orchestration-owned: backup and
# sync have different safe topologies, and a profile that decided the scope of a
# destroy would be deciding topology.

use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly
