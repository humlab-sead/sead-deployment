#FROM debian:bookworm
FROM docker.io/postgis/postgis:18-3.6

# 'apt-get update' has to share a layer with the installs. Split across two RUNs, the
# update layer gets cached while the archive moves on, and the install then fails with a
# 404 on a package version that no longer exists on the mirror.
#
# gdal-bin gives us ogr2ogr, for loading external geodata (GADM administrative
# boundaries): the postgis image ships the PostGIS extension but none of GDAL's command
# line tools. It is installed without recommends to keep the python bindings and docs out;
# git/curl/sqitch keep theirs, since sqitch is Perl and relies on recommended modules.
RUN apt-get update \
    && apt-get install -y git curl sqitch \
    && apt-get install -y --no-install-recommends gdal-bin unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /

RUN git clone https://github.com/humlab-sead/sead_change_control

#this might be needed by the sead_change_control deploy script, not sure
RUN ln -s /sead_change_control /repo

WORKDIR /sead_change_control

# Add sead_change_control/bin to PATH
ENV PATH="/sead_change_control/bin:$PATH"
