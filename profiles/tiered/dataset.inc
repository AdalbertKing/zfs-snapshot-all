# Profile "tiered" — fields copied into a generated [dataset:*].
#
# All four send tiers on every managed dataset: one dataset section spanning
# four tiers is exactly what use_template's comma list is for, and it is what
# makes the four families arrive on four different cadences from one
# declaration.
#
# No section header and no relationship-owned fields (src/dst/flags/pair_label/
# notify belong to the deployment, and lib-profile.sh refuses them here).
# Deliberately no `recursive`: the deployment decides topology.

use_template = tier_hourly,tier_daily,tier_weekly,tier_monthly
