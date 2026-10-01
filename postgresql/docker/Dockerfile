#FROM debian:bookworm
FROM docker.io/library/postgres:16-bookworm

# The postgis/postgis:16-* images are all built on Debian 11 (bullseye), whose security
# archive has been retired from deb.debian.org, so their packages now 404. The postgres
# image already has the PGDG apt repo configured, so PostGIS is installed from there,
# which is what the postgis image does as well.
#
# 'apt-get update' has to share a layer with the installs. Split across two RUNs, the
# update layer gets cached while the archive moves on, and the install then fails with a
# 404 on a package version that no longer exists on the mirror.
RUN apt-get update \
    && apt-get install -y postgresql-16-postgis-3 postgresql-16-postgis-3-scripts git curl sqitch \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /

RUN git clone https://github.com/humlab-sead/sead_change_control

#this might be needed by the sead_change_control deploy script, not sure
RUN ln -s /sead_change_control /repo

WORKDIR /sead_change_control

# Add sead_change_control/bin to PATH
ENV PATH="/sead_change_control/bin:$PATH"
