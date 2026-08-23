# PASSIVE profile — copy-side retention. Prefixless ladder: gfs_pattern is
# OMITTED on purpose (Phase 3.5) so the ladder sees every snapshot the pickup
# adopted, whatever the foreign system called it. Reserved-prefix protections
# still apply at the delsnaps.sh layer, unchanged.
use_template = passive_keep_hourly,passive_keep_daily,passive_keep_weekly,passive_keep_monthly
gfs          = yes
