# Applied by release/publish.sh to every exported text file. The dev repo keeps the real lab and
# customer addresses in comments and guides (they are the measurements); the public release
# carries documentation addresses (RFC 5737) and a neutral site name instead. Only these
# specific networks: the private-range globs in the code (10.*|192.168.*|...) must stay.
s/192\.168\.28\./192.0.2./g
s/192\.168\.11\./198.51.100./g
s/10\.98\.0\./203.0.113./g
s/Metropolis/Site-A/g
s/metropolis/site-a/g
s/METROPOLIS/SITE-A/g
# after the Metropolis rules: its domain becomes a documentation domain, not site-a.net
s/site-a\.net/example.org/g
s/10\.99\.0\./203.0.113./g
