# SEAD 2026-11.1 upgrade steps: MongoDB 4.4 -> 7.0.
#
# Sourced by './deploy.sh release apply' on a server going to 2026-11.1 or later from an
# earlier release. See "Release upgrade steps" in deploy.sh and releases/README.md.
#
# MongoDB 4.4 is end of life, and its image keeps being flagged for what it bundles. Mongo
# holds data that is nowhere else - saved viewstates, users, roles and sessions - so the
# data directory is upgraded in place rather than rebuilt. MongoDB goes up one major
# version at a time, so it passes through 5.0 and 6.0 in temporary containers on the
# stopped data directory, and the release then starts 7.0 on it.
#
# 7.0 and not 8.0: 8.0.x refuses to start on Linux 6.19 and newer (SERVER-121912), which
# up-to-date machines already run. 7.0.45 is also what VISP runs.
#
# Downtime: from the mongo-to-7.0 step until the release starts everything again, the
# JSON API server (and with it site reports and the map) is down.
#
# Kept for a way back: the dump the built-in backup step makes, and a copy of the 4.4
# data directory beside it. Going back means stopping mongo, putting the copy back as
# mongodb/mounts/mongodb-data-volume, and deploying the previous release.

# shellcheck disable=SC2034  # read by deploy.sh
UPGRADE_SUMMARY="MongoDB 4.4 -> 7.0"

# The versions the data directory passes through, the last being the one compose.yml
# runs. Exact versions, like every image in compose.yml.
MONGO_PATH=(docker.io/mongo:5.0.32 docker.io/mongo:6.0.28 docker.io/mongo:7.0.45)
MONGO_TARGET="7.0"

# Everything that uses MongoDB, stopped while its data directory changes.
MONGO_USERS=(json_api_server mongo-express)

nothing_to_upgrade() {
    [[ "$(upgrade_data_get nothing_to_upgrade)" == 1 ]]
}

check_mongo() {
    local image version fcv size free
    image="$(mongo_release_image)"
    [[ "$image" == "${MONGO_PATH[-1]}" ]] \
        || die "compose.yml runs ${image:-no mongo image}, but this upgrade takes MongoDB to ${MONGO_PATH[-1]}."

    if mongo_data_is_empty; then
        info "MongoDB holds no data yet; there is nothing to upgrade."
        upgrade_data_set nothing_to_upgrade 1
        return 0
    fi
    [[ -n "$(service_container mongo)" ]] \
        || die "mongo is not running, so its version cannot be read. Start it ($0 up mongo), then deploy again."
    version="$(mongo_live_version)"
    fcv="$(mongo_live_fcv)"
    [[ -n "$version" && -n "$fcv" ]] || die "Could not read MongoDB's version."
    info "MongoDB ${version}, featureCompatibilityVersion ${fcv}."
    upgrade_data_set mongo_fcv "$fcv"
    if ! version_lt "$fcv" "$MONGO_TARGET"; then
        info "Already at ${MONGO_TARGET}; there is nothing to upgrade."
        upgrade_data_set nothing_to_upgrade 1
        return 0
    fi
    ! version_lt "$(mongo_major "$version")" 4.4 \
        || die "MongoDB ${version} is older than 4.4, where this upgrade starts. Take it to 4.4 by hand first."

    grep -qw avx /proc/cpuinfo \
        || die "This CPU does not report AVX, which MongoDB 5.0 and later need. On a VM, give it a CPU model that passes AVX through (e.g. host-passthrough)."

    # Room for the dump and for the copy of the data directory.
    size="$(as_container_owner du -sb "$MONGO_DATA_DIR" | cut -f1)"
    free="$(df -B1 --output=avail "$(dirname "$MONGO_DATA_DIR")" | tail -n1 | tr -d ' ')"
    (( free > 2 * size )) \
        || die "MongoDB's data is $((size / 1024 / 1024)) MB; the upgrade needs twice that free beside it, and there is $((free / 1024 / 1024)) MB."
    info "AVX present; $((free / 1024 / 1024)) MB free for $((2 * size / 1024 / 1024)) MB of dump and copy."
}

pull_mongo_path() {
    local image
    for image in "${MONGO_PATH[@]}"; do
        info "Pulling ${image} ..."
        $CONTAINER_TOOL pull -q "$image" >/dev/null
    done
}

# Data a 5.0 is to open has to be at FCV 4.4; one that came up from 4.2 may be lower.
# Skipped when the FCV check_mongo read is 4.4 or higher already: never lowered.
set_fcv_44() {
    mongo_set_live_fcv 4.4
    upgrade_data_set mongo_fcv "$(mongo_live_fcv)"
}

fcv_is_44() {
    nothing_to_upgrade || ! version_lt "$(upgrade_data_get mongo_fcv)" 4.4
}

# Runs in the last temporary container, before it shuts down: every collection must
# hold as many documents as before.
verify_counts() {
    local before after
    before="$(upgrade_data_get counts)"
    after="${before%.before.txt}.after.txt"
    mongo_shell_eval "$1" "$MONGO_COUNTS_JS" > "$after"
    if ! diff -u "$before" "$after" >&2; then
        die "The document counts differ after the upgrade (above: - before, + after). The 4.4 data directory is kept as $(upgrade_data_get data_copy)."
    fi
    info "All $(wc -l < "$after") collections hold as many documents as before."
}

mongo_to_7() {
    local counts copy fcv image
    info "Stopping ${MONGO_USERS[*]} ..."
    $COMPOSE_CMD stop "${MONGO_USERS[@]}"

    counts="$(upgrade_data_get counts)"
    if [[ -z "$counts" ]]; then
        [[ -n "$(service_container mongo)" ]] \
            || die "mongo is not running, so its documents cannot be counted. Start it ($0 up --no-deps mongo), then deploy again."
        mkdir -p "$UPGRADE_BACKUP_DIR"
        counts="${UPGRADE_BACKUP_DIR}/mongo-counts-$(date +%Y%m%d_%H%M%S).before.txt"
        mongo_eval "$MONGO_COUNTS_JS" > "$counts"
        upgrade_data_set counts "$counts"
        info "Counted the documents of $(wc -l < "$counts") collections into ${counts}."
    fi

    info "Stopping mongo ..."
    $COMPOSE_CMD stop mongo

    copy="$(upgrade_data_get data_copy)"
    if [[ -z "$copy" ]]; then
        copy="${MONGO_DATA_DIR}.mongo4.4.$(date +%Y%m%d_%H%M%S)"
        info "Copying the data directory to ${copy} ..."
        as_container_owner cp -a "$MONGO_DATA_DIR" "$copy"
        upgrade_data_set data_copy "$copy"
    fi

    for image in "${MONGO_PATH[@]}"; do
        fcv="$(upgrade_data_get mongo_fcv)"
        if ! version_lt "$fcv" "$(mongo_major "${image##*:}")"; then
            continue
        fi
        if [[ "$image" == "${MONGO_PATH[-1]}" ]]; then
            mongo_hop "$image" verify_counts
        else
            mongo_hop "$image"
        fi
    done
    info "The data directory is at featureCompatibilityVersion $(upgrade_data_get mongo_fcv); the release starts ${MONGO_PATH[-1]} on it."
}

mongo_is_7() {
    nothing_to_upgrade || ! version_lt "$(upgrade_data_get mongo_fcv)" "$MONGO_TARGET"
}

check_mongo_7() {
    local deadline version fcv
    deadline=$((SECONDS + 180))
    until version="$(mongo_live_version 2>/dev/null)" && [[ -n "$version" ]]; do
        (( SECONDS < deadline )) || die "mongo did not answer within 3 minutes. See: $0 logs mongo"
        sleep 5
    done
    fcv="$(mongo_live_fcv)"
    [[ "$(mongo_major "$version")" == "$MONGO_TARGET" && "$fcv" == "$MONGO_TARGET" ]] \
        || die "mongo runs ${version} at featureCompatibilityVersion ${fcv}, not ${MONGO_TARGET}."
    info "MongoDB ${version}, featureCompatibilityVersion ${fcv}."
    nothing_to_upgrade && return 0
    info "Kept until the release is known to be good, then to be removed:"
    info "  $(upgrade_state_get data.upgrade.backup)  (dump of 4.4)"
    info "  $(upgrade_data_get data_copy)  (4.4 data directory; remove with: podman unshare rm -rf <dir>)"
}

step preflight  check-mongo     "MongoDB is 4.4 or later, the CPU has AVX, the disk has room" check_mongo
step pre_apply  pull-mongo-path "pull the MongoDB versions the data passes through"           pull_mongo_path   nothing_to_upgrade
step pre_apply  mongo-fcv-4.4   "set MongoDB's featureCompatibilityVersion to 4.4"            set_fcv_44        fcv_is_44
step post_build mongo-to-7.0    "stop the MongoDB users, take the data directory to 7.0"      mongo_to_7        mongo_is_7
step post_apply check-mongo-7.0 "MongoDB runs 7.0 at featureCompatibilityVersion 7.0"         check_mongo_7
