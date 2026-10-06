#!/usr/bin/env bash
# deploy.sh — SEAD deployment utility
#
# Usage: ./deploy.sh <command> [args...]
#
# Commands:
#   install              Fresh install of the entire SEAD stack
#   update <service>     Rebuild and restart a specific service
#   build [service...]   Build Docker images (all or specific)
#   up [service...]      Start services in detached mode
#   down                 Stop and remove all containers
#   restart [service]    Restart all (or one) service
#   status               Show running status of all containers
#   versions             Report the versions of everything installed and running
#   release <command>    Cut, deploy or apply a SEAD release (see releases/README.md)
#   logs [service]       Tail logs (all services or specific one)
#   shell <service>      Open an interactive shell inside a container
#   import-db            Re-import the PostgreSQL database
#   preload-jas [--background]
#                         Preload the JSON API Server MongoDB cache
#   flush-cache          Flush the JAS graph cache via the REST API
#   generate-env [--update]
#                         Generate .env from .env-example, or add what it lacks
#   rotate-secrets       Overwrite ALL secrets in .env with fresh random values

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# Container engine detection
# ──────────────────────────────────────────────────────────────────────────────
# Returns true when the engine's compose stack is actually usable.
# 'podman-compose' is the standalone Python tool; it just needs to be installed.
# 'podman'/'docker' delegate to their compose sub-command which requires the
# daemon socket to be reachable.
_engine_compose_works() {
    local engine="$1"
    case "$engine" in
        podman-compose|docker-compose)
            command -v "$engine" &>/dev/null
            ;;
        podman|docker)
            command -v "$engine" &>/dev/null && "$engine" compose ls &>/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

detect_container_engine() {
    local candidate
    # Prefer native compose integrations first.
    for candidate in podman docker podman-compose docker-compose; do
        if _engine_compose_works "$candidate"; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

CONTAINER_TOOL="${CONTAINER_TOOL:-$(detect_container_engine)}"
if [[ -z "$CONTAINER_TOOL" ]]; then
    echo "ERROR: No supported compose engine found. Install one of: podman compose, docker compose, podman-compose, docker-compose." >&2
    exit 1
fi

# In prod mode the override file is excluded so COMPOSE_CMD gets explicit -f flags.
# DEPLOY_MODE is read from .env (set during install); default to dev if unset.
# Can also be forced on the command line: DEPLOY_MODE=prod ./deploy.sh up
#
# Standalone compose tools (podman-compose, docker-compose) are invoked directly.
# Integrated tools (podman, docker) use the 'compose' sub-command.
build_compose_cmd() {
    local prod="${DEPLOY_MODE:-dev}"
    case "$CONTAINER_TOOL" in
        podman-compose|docker-compose)
            # Standalone tools: 'podman-compose -f compose.yml' or 'podman-compose'
            [[ "$prod" == "prod" ]] && echo "$CONTAINER_TOOL -f compose.yml" || echo "$CONTAINER_TOOL"
            ;;
        *)
            # Integrated sub-command: 'podman compose -f compose.yml' or 'podman compose'
            [[ "$prod" == "prod" ]] && echo "$CONTAINER_TOOL compose -f compose.yml" || echo "$CONTAINER_TOOL compose"
            ;;
    esac
}
COMPOSE_CMD="$(build_compose_cmd)"

# podman-compose may hang on stacks that use depends_on condition: service_healthy.
# When native podman compose is available, transparently switch to it for compatibility.
apply_compose_compatibility_override() {
    [[ "$CONTAINER_TOOL" == "podman-compose" ]] || return 0
    command -v podman &>/dev/null || return 0
    podman compose ls &>/dev/null 2>&1 || return 0

    local override_file="compose.override.yml"
    if [[ "${DEPLOY_MODE:-dev}" == "dev" ]] \
        && [[ -f "$override_file" ]] \
        && grep -qE 'condition:[[:space:]]*service_healthy' "$override_file"; then
        warn "Detected depends_on condition: service_healthy in ${override_file}; switching from podman-compose to native 'podman compose' to avoid known startup hangs."
        CONTAINER_TOOL="podman"
        export CONTAINER_TOOL
    fi
}

# Keep compose.override.yml aligned with DEPLOY_MODE during install.
# In prod mode, the override file is renamed to ".disabled".
# In dev mode, a disabled override file is restored back to its active name.
sync_override_file_for_mode() {
    local override_file="compose.override.yml"
    local disabled_file="${override_file}.disabled"

    if [[ "${DEPLOY_MODE:-dev}" == "prod" ]]; then
        if [[ -f "$override_file" ]]; then
            if [[ -f "$disabled_file" ]]; then
                local backup_file="${disabled_file}.$(date +%Y%m%d_%H%M%S)"
                mv "$disabled_file" "$backup_file"
                warn "Found existing ${disabled_file}; moved it to ${backup_file}"
            fi
            mv "$override_file" "$disabled_file"
            info "Disabled ${override_file} for prod mode."
        elif [[ -f "$disabled_file" ]]; then
            info "${override_file} already disabled for prod mode."
        else
            warn "${override_file} not found; nothing to disable."
        fi
        return
    fi

    if [[ -f "$disabled_file" ]]; then
        if [[ -f "$override_file" ]]; then
            local backup_file="${disabled_file}.$(date +%Y%m%d_%H%M%S)"
            mv "$disabled_file" "$backup_file"
            warn "Both ${override_file} and ${disabled_file} existed; kept ${override_file} and moved ${disabled_file} to ${backup_file}"
        else
            mv "$disabled_file" "$override_file"
            info "Re-enabled ${override_file} for dev mode."
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Colour helpers
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# The SEAD release this checkout carries. See releases/README.md.
RELEASE_MANIFEST="sead-release.env"

# One value from the release manifest. Read rather than sourced: sourcing would export
# the manifest's refs, and compose lets an exported variable beat .env - which has to
# stay what the stack is really built from, so that a deviation from the release shows.
manifest_value() {
    sed -n "s/^${1}=//p" "$SCRIPT_DIR/$RELEASE_MANIFEST" 2>/dev/null | tail -n1
}

# Database import defaults
SEAD_CHANGE_CONTROL_REPO="humlab-sead/sead_change_control"
DEFAULT_DB_DEPLOY_TAG="$(manifest_value SEAD_CHANGE_CONTROL_RELEASE)"
DEFAULT_DB_DEPLOY_TAG="${DEFAULT_DB_DEPLOY_TAG:-@2026.04}"
SEAD_QUERY_API_REPO="humlab-sead/sead_query_api"
DEFAULT_SEAD_QUERY_API_RELEASE="main"
DB_IMPORT_TARGET_DB="sead_staging"
DB_IMPORT_USER="sead_master"
DB_IMPORT_SERVICE="postgresql"
# GADM boundary data. Fetched on demand into a mounted directory, never vendored.
GADM_IMPORT_SCRIPT="/sead_change_control/bin/import_gadm_data.sh"
GADM_DATA_DIR="/var/lib/gadm"

# ──────────────────────────────────────────────────────────────────────────────
# Environment helpers
# ──────────────────────────────────────────────────────────────────────────────
load_env() {
    local explicit_deploy_mode_set=0
    local explicit_deploy_mode="${DEPLOY_MODE:-}"
    if [[ -n "${DEPLOY_MODE+x}" ]]; then
        explicit_deploy_mode_set=1
    fi

    if [[ -f .env ]]; then
        set -a
        # shellcheck disable=SC1091
        source .env
        set +a
    fi

    # Keep an explicit DEPLOY_MODE from the command invocation authoritative.
    if (( explicit_deploy_mode_set )); then
        DEPLOY_MODE="$explicit_deploy_mode"
        export DEPLOY_MODE
    fi

    apply_compose_compatibility_override

    # Rebuild COMPOSE_CMD now that DEPLOY_MODE / engine may have been updated.
    COMPOSE_CMD="$(build_compose_cmd)"
}

# Generates a 48-character alphanumeric password (~285 bits of entropy).
# Prefers openssl's CSPRNG; falls back to /dev/urandom (equally secure on Linux 3.17+).
generate_password() {
    local length=48
    if command -v openssl &>/dev/null; then
        # Request ~2× the bytes we need to have plenty after filtering non-alphanumerics.
        openssl rand -base64 $(( length * 2 )) | tr -dc 'A-Za-z0-9' | head -c "$length"
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    fi
}

# Fill any empty PASSWORD / SECRET / SALT / _PASS / _KEY field with a random value.
# Matches both upper- and mixed-case key names (e.g. DATABASE_PASSWORD, QueryBuilderSetting__Store__Password).
# Keys that must be left for the operator to fill in manually.
# They are never touched by automatic secret generation or rotation.
MANUAL_SECRETS=(
    MATOMO_SUPERUSER_PASSWORD
    JAS_GOOGLE_CLIENT_ID
    JAS_GOOGLE_CLIENT_SECRET
    JAS_GITHUB_CLIENT_ID
    JAS_GITHUB_CLIENT_SECRET
    JAS_ORCID_CLIENT_ID
    JAS_ORCID_CLIENT_SECRET
)

is_manual_secret() {
    local key="$1"
    for skip in "${MANUAL_SECRETS[@]}"; do
        [[ "$key" == "$skip" ]] && return 0
    done
    return 1
}

fill_random_secrets() {
    local file="$1"
    # Pattern: line ends with a key whose suffix (case-insensitive) is PASSWORD, SECRET, SALT, _PASS, or _KEY,
    # followed by = and nothing (or only whitespace).
    local pattern='^[A-Za-z0-9_]*(PASSWORD|SECRET|SALT|_PASS|_KEY|Password)=[[:space:]]*$'
    while grep -qE "$pattern" "$file"; do
        local key
        key=$(grep -m1 -E "$pattern" "$file" | cut -d= -f1)
        if is_manual_secret "$key"; then
            # Break the loop by temporarily marking the line so grep no longer matches it,
            # then restore the original empty value so the file stays clean.
            sed -i -E "s|^(${key})=[[:space:]]*$|\1=__SKIP__|" "$file"
            continue
        fi
        local val
        val=$(generate_password)
        sed -i -E "s|^(${key})=[[:space:]]*$|\1=${val}|" "$file"
        info "Generated random value for ${key}"
    done
    # Restore any temporarily-skipped entries back to empty
    sed -i -E 's/=__SKIP__$/=/' "$file"
}

# Copy values from one .env key to another, keeping dependent credentials in sync.
# Usage: sync_linked_vars <file> <source_key> <dest_key> [<source_key2> <dest_key2> ...]
sync_linked_vars() {
    local file="$1"; shift
    while [[ $# -ge 2 ]]; do
        local src="$1" dst="$2"; shift 2
        local val
        val=$(grep -m1 -E "^${src}=" "$file" | cut -d= -f2-)
        if [[ -n "$val" ]]; then
            sed -i -E "s|^(${dst})=.*$|\1=${val}|" "$file"
            info "Synced ${dst} ← ${src}"
        else
            warn "Could not sync ${dst}: source key ${src} has no value in $file"
        fi
    done
}

# Import matching KEY=value entries from an existing env file into a target env file.
# Only keys already present in the target file are updated.
import_env_values_from_file() {
    local target_file="$1"
    local source_file="$2"

    [[ -f "$target_file" ]] || die "Target env file not found: $target_file"
    [[ -f "$source_file" ]] || die "Source env file not found: $source_file"
    [[ -r "$source_file" ]] || die "Source env file is not readable: $source_file"

    declare -A source_values=()
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            value="${BASH_REMATCH[3]}"
            source_values["$key"]="$value"
        fi
    done < "$source_file"

    local target_keys=()
    mapfile -t target_keys < <(
        grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$target_file" \
            | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' \
            | awk '!seen[$0]++'
    )

    local imported=0
    for key in "${target_keys[@]}"; do
        if [[ -v "source_values[$key]" ]]; then
            set_env_var "$target_file" "$key" "${source_values[$key]}"
            imported=$((imported + 1))
        fi
    done

    info "Imported ${imported}/${#target_keys[@]} values from ${source_file}."
}

# Optionally prompt for an old env file and import matching values.
prompt_import_old_env() {
    local target_file="$1"
    [[ -f "$target_file" ]] || die "Target env file not found: $target_file"

    # Skip prompting in non-interactive runs.
    if [[ ! -t 0 ]]; then
        info "Non-interactive mode detected; skipping optional old .env import."
        return 0
    fi

    local answer
    read -rp "Import values from an existing .env file? [y/N]: " answer
    case "${answer,,}" in
        y|yes) ;;
        *)
            info "Skipping old .env import."
            return 0
            ;;
    esac

    local source_path
    while true; do
        read -rp "Enter path to old .env file (ENTER to cancel): " source_path
        source_path="${source_path%$'\r'}"

        if [[ -z "$source_path" ]]; then
            info "Old .env import cancelled."
            return 0
        fi

        if [[ "$source_path" == "~" ]]; then
            source_path="$HOME"
        elif [[ "$source_path" == "~/"* ]]; then
            source_path="$HOME/${source_path#"~/"}"
        fi

        if [[ ! -f "$source_path" ]]; then
            warn "File not found: $source_path"
            continue
        fi
        if [[ ! -r "$source_path" ]]; then
            warn "File is not readable: $source_path"
            continue
        fi

        import_env_values_from_file "$target_file" "$source_path"
        return 0
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# generate-env command
# ──────────────────────────────────────────────────────────────────────────────
# SEAD login defaults: the dev IdP and the ORCID sandbox in dev, SWAMID and
# orcid.org online. Values already set are kept.
apply_login_defaults() {
    local file="$1"
    if [[ "${DEPLOY_MODE}" == "prod" ]]; then
        set_env_default "$file" SAML_FEDERATION swamid
        set_env_default "$file" JAS_ORCID_ISSUER https://orcid.org
    else
        set_env_default "$file" SAML_FEDERATION local
        set_env_default "$file" SAML_DEV_IDP_HOST sead-idp.local
        set_env_default "$file" JAS_ORCID_ISSUER https://sandbox.orcid.org
    fi
    info "SAML_FEDERATION=$(get_env_var "$file" SAML_FEDERATION), JAS_ORCID_ISSUER=$(get_env_var "$file" JAS_ORCID_ISSUER)"
}

# The .env-example a release carries, or this checkout's when no release is named.
env_example_of() {
    local release="${1:-}"
    if [[ -z "$release" ]]; then
        cat .env-example
        return
    fi
    git show "refs/tags/${release}:.env-example" 2>/dev/null \
        || die "There is no .env-example in SEAD release ${release} (is the tag fetched?)."
}

# The variables an .env-example defines that .env does not, in the example's order.
# Reads the example from stdin.
missing_env_keys() {
    local key
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d = | awk '!seen[$0]++' | while IFS= read -r key; do
        grep -qE "^${key}=" .env || echo "$key"
    done
}

# Stops a deploy whose .env lacks variables the release's compose.yml and services
# expect. Compose would start them with those unset, which fails late and unclearly.
check_release_env() {
    local release="${1:-}" missing
    [[ -f .env ]] || die ".env not found. Install the stack first: $0 install"
    # The release refs and the release records are what the deploy writes itself.
    missing="$(env_example_of "$release" | missing_env_keys \
        | grep -vxE 'SEAD_RELEASE|SEAD_PREVIOUS_RELEASE|SBC_RELEASE|JAS_RELEASE|SEAD_QUERY_API_RELEASE|SEAD_CHANGE_CONTROL_RELEASE' || true)"
    [[ -z "$missing" ]] && return 0

    error ".env lacks these variables, which ${release:-this release}'s .env-example defines:"
    printf '  %s\n' $missing >&2
    die "Add them with '$0 generate-env --update${release:+ ${release}}', review .env, then deploy again."
}

# Adds the variables .env lacks from .env-example (a release's, when one is named),
# with the example's values. New secrets are generated, new host ports asked for;
# nothing already in .env changes. sead_authority_service/.env is left alone.
cmd_update_env() {
    local release="${1:-}"
    [[ -z "$release" || "$release" =~ $RELEASE_NAME_PATTERN ]] \
        || die "Usage: $0 generate-env --update [<YYYY-MM.N>]"
    [[ -f .env ]] || die ".env not found. Run '$0 generate-env' first."

    local example missing
    example="$(env_example_of "$release")"
    missing="$(missing_env_keys <<< "$example")"
    if [[ -z "$missing" ]]; then
        success ".env already has every variable ${release:-this checkout}'s .env-example defines."
        return 0
    fi

    local backup=".env.bak.$(date +%Y%m%d_%H%M%S)"
    cp .env "$backup"
    chmod 600 "$backup"
    info "Backup saved to $backup"

    # The new lines are filled on their own, so an empty secret already in .env stays
    # as the operator left it.
    local added key
    added="$(mktemp)"
    for key in $missing; do
        grep -m1 -E "^${key}=" <<< "$example" >> "$added"
    done
    fill_random_secrets "$added"
    {
        echo
        echo "# Added from ${release:-this checkout}'s .env-example by '$0 generate-env --update' on $(date +%F)"
        cat "$added"
    } >> .env
    rm -f "$added"

    apply_login_defaults .env

    # A host port has to be free of every instance on the host, which this .env does
    # not know about, so a new one is always asked for.
    for key in $missing; do
        [[ "$key" == *_PORT ]] || continue
        if [[ -t 0 ]]; then
            prompt_unique_host_port .env "$key" "${key} (must be unique on this host)"
        else
            warn "${key}=$(get_env_var .env "$key") was taken from .env-example; check that no other instance on this host uses it."
        fi
    done

    success "Added to .env:"
    local value
    for key in $missing; do
        value="$(get_env_var .env "$key")"
        if [[ -z "$value" ]]; then
            value="(empty)"
        elif [[ "$key" =~ (PASSWORD|SECRET|SALT|_PASS|_KEY|Password)$ ]]; then
            value="(secret, not shown)"
        fi
        info "  ${key}=${value}"
    done
    warn "Review .env before deploying - especially the host ports and the login settings."
}

cmd_generate_env() {
    if [[ "${1:-}" == "--update" ]]; then
        shift
        cmd_update_env "$@"
        return
    fi
    [[ -f .env-example ]] || die ".env-example not found. Are you in the right directory?"

    if [[ -f .env ]]; then
        warn ".env already exists — skipping generation. Delete it first to regenerate."
        return 0
    fi

    cp .env-example .env
    chmod 600 .env
    info "Copied .env-example → .env"

    prompt_import_old_env .env

    fill_random_secrets .env

    # Persist the chosen deploy mode into .env so all future invocations respect it
    if grep -qE '^DEPLOY_MODE=' .env; then
        sed -i -E "s|^DEPLOY_MODE=.*$|DEPLOY_MODE=${DEPLOY_MODE}|" .env
    else
        echo "DEPLOY_MODE=${DEPLOY_MODE}" >> .env
    fi
    info "DEPLOY_MODE=${DEPLOY_MODE} written to .env"

    apply_login_defaults .env

    # Keep QueryBuilder credentials in sync with the read-only DB user/password
    sync_linked_vars .env \
        DATABASE_READ_ONLY_USER     QueryBuilderSetting__Store__Username \
        DATABASE_READ_ONLY_PASSWORD QueryBuilderSetting__Store__Password

    success ".env generated with random passwords/secrets."

    # Sub-service: sead_authority_service
    if [[ -f sead_authority_service/.env.example ]]; then
        cp sead_authority_service/.env.example sead_authority_service/.env
        chmod 600 sead_authority_service/.env
        # Clear keys that require manual configuration
        sed -i -E 's/^OPENAI_API_KEY=.*/OPENAI_API_KEY=/' sead_authority_service/.env
        sed -i -E 's/^GEONAMES_USERNAME=.*/GEONAMES_USERNAME=/' sead_authority_service/.env
        info "Copied sead_authority_service/.env.example → sead_authority_service/.env"
        warn "Set OPENAI_API_KEY and GEONAMES_USERNAME manually in sead_authority_service/.env if needed."
    fi

    warn "Review .env before proceeding — especially DOMAIN and COMPOSE_PROJECT_NAME."
    warn "The following secrets were left empty and must be set manually:"
    for key in "${MANUAL_SECRETS[@]}"; do
        warn "  $key"
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# rotate-secrets command — replace ALL existing secret values with new ones
# ──────────────────────────────────────────────────────────────────────────────

# Like fill_random_secrets but replaces populated values too.
rotate_secrets_in_file() {
    local file="$1"
    # Match lines whose key suffix is PASSWORD, SECRET, SALT, _PASS, _KEY, or Password,
    # regardless of whether there is already a value.
    local pattern='^([A-Za-z0-9_]*(PASSWORD|SECRET|SALT|_PASS|_KEY|Password))=.*$'
    while IFS= read -r line; do
        if [[ "$line" =~ $pattern ]]; then
            local key="${BASH_REMATCH[1]}"
            if is_manual_secret "$key"; then
                info "Skipping manual secret: ${key}"
                continue
            fi
            local val
            val=$(generate_password)
            sed -i -E "s|^(${key})=.*$|\1=${val}|" "$file"
            info "Rotated secret for ${key}"
        fi
    done < <(grep -E "$pattern" "$file")
}

cmd_rotate_secrets() {
    [[ -f .env ]] || die ".env not found. Run './deploy.sh generate-env' first."

    echo
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                        WARNING                               ║${NC}"
    echo -e "${RED}║  ALL passwords and secrets in .env will be OVERWRITTEN with  ║${NC}"
    echo -e "${RED}║  newly generated random values.                              ║${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}║  Running services will lose database/API connectivity until  ║${NC}"
    echo -e "${RED}║  they are restarted and any affected databases are updated.  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    read -rp "Type YES (all caps) to confirm: " confirmation
    [[ "$confirmation" == "YES" ]] || { info "Aborted — no changes made."; return 0; }

    # Back up the current .env before touching it
    local backup=".env.bak.$(date +%Y%m%d_%H%M%S)"
    cp .env "$backup"
    chmod 600 "$backup"
    info "Backup saved to $backup"

    rotate_secrets_in_file .env

    # Re-sync derived credentials after rotation
    sync_linked_vars .env \
        DATABASE_READ_ONLY_USER     QueryBuilderSetting__Store__Username \
        DATABASE_READ_ONLY_PASSWORD QueryBuilderSetting__Store__Password

    success "All secrets in .env have been rotated."
    warn "Restart the stack ('$0 restart') and re-run any database password updates to apply the new credentials."
}

# ──────────────────────────────────────────────────────────────────────────────
# Repository cloning helpers
# ──────────────────────────────────────────────────────────────────────────────
clone_if_missing() {
    local dir="$1"
    local url="$2"
    if [[ -d "$dir/.git" ]]; then
        info "Repository '$dir' already present — skipping clone."
    elif [[ -d "$dir" && -n "$(ls -A "$dir")" ]]; then
        # sead_query_api's build files used to be kept in this repository, so an older
        # deployment can have the directory, with leftovers, but no clone in it.
        die "${dir} exists but is not a clone of ${url}. Move it aside (mv ${dir} ${dir}.old) and run this again."
    else
        info "Cloning $url → $dir ..."
        git clone --recurse-submodules "$url" "$dir"
        success "Cloned $dir"
    fi
}

# Update or append a KEY=value entry in an env-style file.
set_env_var() {
    local file="$1"
    local key="$2"
    local value="$3"

    [[ -f "$file" ]] || die "$file not found."

    local escaped_value="$value"
    escaped_value="${escaped_value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"

    if grep -qE "^${key}=" "$file"; then
        sed -i -E "s|^(${key})=.*$|\\1=${escaped_value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

get_env_var() {
    local file="$1"
    local key="$2"
    grep -m1 -E "^${key}=" "$file" | cut -d= -f2- || true
}

# Set KEY=value only if the key is missing or empty.
set_env_default() {
    local file="$1"
    local key="$2"
    local value="$3"
    [[ -n "$(get_env_var "$file" "$key")" ]] || set_env_var "$file" "$key" "$value"
}

is_valid_compose_project_name() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

is_valid_domain_name() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    [[ "$value" =~ [[:space:]/:] ]] && return 1
    return 0
}

is_valid_tcp_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

is_host_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q .
        return
    fi
    if command -v lsof &>/dev/null; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
        return
    fi
    return 1
}

find_duplicate_port_key() {
    local file="$1"
    local target_key="$2"
    local target_port="$3"
    local key configured_port

    for key in WEB_PORT MONGO_EXPRESS_PORT JAS_PORT POSTGRESQL_PORT SEAD_AGENT_PORT; do
        [[ "$key" == "$target_key" ]] && continue
        configured_port="$(get_env_var "$file" "$key")"
        [[ -n "$configured_port" && "$configured_port" == "$target_port" ]] || continue
        echo "$key"
        return 0
    done
    return 1
}

prompt_compose_project_name() {
    local file="$1"
    local current input

    current="$(get_env_var "$file" COMPOSE_PROJECT_NAME)"
    while true; do
        read -rp "COMPOSE_PROJECT_NAME (unique, lowercase letters/numbers/_/-) [${current}]: " input
        input="${input:-$current}"
        input="${input%$'\r'}"

        if ! is_valid_compose_project_name "$input"; then
            warn "Invalid COMPOSE_PROJECT_NAME '${input}'. Use: lowercase letters, numbers, '_' or '-'."
            continue
        fi

        set_env_var "$file" COMPOSE_PROJECT_NAME "$input"
        return 0
    done
}

prompt_domain_name() {
    local file="$1"
    local current input

    current="$(get_env_var "$file" DOMAIN)"
    while true; do
        read -rp "DOMAIN (unique host name, no scheme/port) [${current}]: " input
        input="${input:-$current}"
        input="${input%$'\r'}"

        if ! is_valid_domain_name "$input"; then
            warn "Invalid DOMAIN '${input}'. Provide a host name like 'sead.local' or 'sead.example.org'."
            continue
        fi

        set_env_var "$file" DOMAIN "$input"
        return 0
    done
}

prompt_unique_host_port() {
    local file="$1"
    local key="$2"
    local label="$3"
    local current input keep_port duplicate_key

    current="$(get_env_var "$file" "$key")"
    while true; do
        read -rp "${label} [${current}]: " input
        input="${input:-$current}"
        input="${input%$'\r'}"

        if ! is_valid_tcp_port "$input"; then
            warn "Invalid port '${input}'. Enter a number from 1 to 65535."
            continue
        fi

        if duplicate_key="$(find_duplicate_port_key "$file" "$key" "$input")"; then
            warn "${key}=${input} conflicts with ${duplicate_key}. Each published host port must be unique."
            continue
        fi

        if is_host_port_in_use "$input"; then
            read -rp "Port ${input} is currently in use on this host. Keep it anyway? [y/N]: " keep_port
            case "${keep_port,,}" in
                y|yes) ;;
                *) continue ;;
            esac
        fi

        set_env_var "$file" "$key" "$input"
        return 0
    done
}

prompt_unique_instance_settings() {
    local file="$1"
    [[ -f "$file" ]] || die "Env file not found: $file"

    if [[ ! -t 0 ]]; then
        info "Non-interactive mode detected; keeping COMPOSE_PROJECT_NAME, DOMAIN, and host ports from ${file}."
        return 0
    fi

    echo
    echo -e "${CYAN}Set per-instance values (must be unique on a shared host):${NC}"
    warn "These values are intentionally not auto-generated."

    prompt_compose_project_name "$file"
    prompt_domain_name "$file"
    prompt_unique_host_port "$file" WEB_PORT            "WEB_PORT (router HTTP)"
    prompt_unique_host_port "$file" MONGO_EXPRESS_PORT  "MONGO_EXPRESS_PORT (mongo-express)"
    prompt_unique_host_port "$file" JAS_PORT            "JAS_PORT (JSON API Server)"
    prompt_unique_host_port "$file" POSTGRESQL_PORT     "POSTGRESQL_PORT (PostgreSQL)"
    prompt_unique_host_port "$file" SEAD_AGENT_PORT     "SEAD_AGENT_PORT (SEAD agent)"

    success "Saved unique instance settings in ${file}."
}

# Pull images for services that are image-based (not build-based).
pull_non_build_images() {
    info "Pulling prebuilt images for services without local Docker builds..."
    if $COMPOSE_CMD pull --ignore-buildable; then
        success "Prebuilt images pulled."
        return
    fi

    warn "'$CONTAINER_TOOL compose pull --ignore-buildable' not supported; falling back to '$CONTAINER_TOOL compose pull'."
    $COMPOSE_CMD pull
    success "Images pulled."
}

# Fetch release tags from GitHub API for a repository.
# Usage: fetch_github_release_tags "owner/repo"
# Prints one tag per line. Returns non-zero if none could be fetched.
fetch_github_release_tags() {
    local repo="$1"
    [[ -n "$repo" ]] || return 1

    local endpoint="repos/${repo}/releases?per_page=100"
    local api_url="https://api.github.com/${endpoint}"
    local response http_code release_json
    local github_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

    # Prefer authenticated GitHub API requests via `gh` when available.
    if command -v gh &>/dev/null; then
        local gh_response gh_error
        if gh_response="$(
            gh api \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "$endpoint" 2>&1
        )"; then
            release_json="$gh_response"
            http_code=200
        else
            gh_error="$(printf '%s\n' "$gh_response" | head -n1)"
            if [[ -n "$gh_error" ]]; then
                warn "Authenticated GitHub request failed for ${repo} via gh (${gh_error}). Falling back to curl." >&2
            else
                warn "Authenticated GitHub request failed for ${repo} via gh. Falling back to curl." >&2
            fi
        fi

        # If no explicit env token is set, try reading one from gh for curl fallback.
        if [[ -z "$github_token" ]]; then
            github_token="$(gh auth token 2>/dev/null || true)"
        fi
    fi

    if [[ -z "${release_json:-}" ]]; then
        local -a curl_args=(
            -sS -L
            -H "Accept: application/vnd.github+json"
            -H "X-GitHub-Api-Version: 2022-11-28"
            -w $'\n%{http_code}'
        )
        if [[ -n "$github_token" ]]; then
            curl_args+=(-H "Authorization: Bearer ${github_token}")
        fi
        curl_args+=("$api_url")

        if ! response="$(curl "${curl_args[@]}")"; then
            warn "Failed to fetch release list from ${api_url} (network/curl error)." >&2
            return 1
        fi

        http_code="${response##*$'\n'}"
        release_json="${response%$'\n'*}"
    fi

    if ! [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
        warn "Failed to fetch release list for ${repo}: unexpected HTTP status '${http_code}'." >&2
        return 1
    fi

    if (( http_code >= 400 )); then
        local api_message
        api_message="$(
            printf '%s\n' "$release_json" \
                | grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]+"' \
                | head -n1 \
                | sed -E 's/.*"([^"]+)"/\1/'
        )"
        if [[ -n "$api_message" ]]; then
            warn "Failed to fetch release list for ${repo} (HTTP ${http_code}): ${api_message}" >&2
        else
            warn "Failed to fetch release list for ${repo} (HTTP ${http_code})." >&2
        fi
        return 1
    fi

    local tags=()
    mapfile -t tags < <(
        {
            printf '%s\n' "$release_json" \
                | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
                | sed -E 's/.*"([^"]+)"/\1/' \
                | awk '!seen[$0]++'
        } || true
    )

    if [[ ${#tags[@]} -eq 0 ]]; then
        warn "No release tags found in GitHub response for ${repo}." >&2
        return 1
    fi
    printf '%s\n' "${tags[@]}"
}

# Prompt the operator to choose a ref to deploy.
# Includes the primary branch, the 5 newest GitHub release tags, and a manual ref option.
# Given a pinned tag, offers that tag in place of the branch, as the default: a SEAD
# release pins tags only.
# Usage: prompt_release_ref <service_name> <repo> <primary_branch> [pinned_tag]
prompt_release_ref() {
    local service_name="$1"
    local repo="$2"
    local primary_branch="$3"
    local pinned_tag="${4:-}"

    [[ -n "$service_name" && -n "$repo" && -n "$primary_branch" ]] || die "prompt_release_ref called with missing arguments."

    SELECTED_RELEASE_REF=""

    local manual_ref_option="[Enter another Git ref]"
    local default_ref="${pinned_tag:-$primary_branch}"
    local options=("$default_ref")
    local releases=()

    if mapfile -t releases < <(fetch_github_release_tags "$repo") && [[ ${#releases[@]} -gt 0 ]]; then
        local tag
        local release_count=0
        for tag in "${releases[@]}"; do
            [[ -z "$tag" ]] && continue
            [[ "$tag" =~ ^\[[A-Z]+\] ]] && continue
            [[ "$tag" == "$default_ref" ]] && continue
            options+=("$tag")
            release_count=$((release_count + 1))
            [[ $release_count -ge 5 ]] && break
        done
    else
        warn "Could not fetch release list from GitHub for ${repo}. Falling back to '${default_ref}' only."
    fi

    options+=("$manual_ref_option")

    echo
    echo -e "${CYAN}Select ${service_name} release to deploy:${NC}"
    local idx
    for idx in "${!options[@]}"; do
        if [[ -n "$pinned_tag" && "${options[$idx]}" == "$pinned_tag" ]]; then
            echo "  $((idx + 1))) ${options[$idx]} (pinned by the current release)"
        elif [[ "${options[$idx]}" == "$primary_branch" ]]; then
            echo "  $((idx + 1))) ${options[$idx]} (branch)"
        elif [[ "${options[$idx]}" == "$manual_ref_option" ]]; then
            echo "  $((idx + 1))) ${options[$idx]}"
        else
            echo "  $((idx + 1))) ${options[$idx]} (release)"
        fi
    done

    local choice selected
    while true; do
        read -rp "Enter choice [1-${#options[@]}] (default: 1 ${default_ref}): " choice
        choice="${choice:-1}"

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            selected="${options[$((choice - 1))]}"
            break
        fi

        echo "Please enter a number between 1 and ${#options[@]}."
    done

    if [[ "$selected" == "$manual_ref_option" ]]; then
        while true; do
            read -rp "Enter a Git ref (branch, tag, or commit): " selected
            if [[ -n "$selected" ]]; then
                break
            fi
            echo "Git ref cannot be empty."
        done
    fi

    SELECTED_RELEASE_REF="$selected"
}

# Prompt for a sead_change_control deploy tag.
# Tries to list GitHub release tags and falls back to the default tag.
# Usage: prompt_db_deploy_tag [deploy_tag]
prompt_db_deploy_tag() {
    local provided_tag="${1:-}"
    local default_tag="$DEFAULT_DB_DEPLOY_TAG"

    SELECTED_DB_DEPLOY_TAG=""

    if [[ -n "$provided_tag" ]]; then
        SELECTED_DB_DEPLOY_TAG="$provided_tag"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        info "Non-interactive mode detected; using default deploy tag '${default_tag}'."
        SELECTED_DB_DEPLOY_TAG="$default_tag"
        return 0
    fi

    local options=("$default_tag")
    local releases=()

    if mapfile -t releases < <(fetch_github_release_tags "$SEAD_CHANGE_CONTROL_REPO") && [[ ${#releases[@]} -gt 0 ]]; then
        local tag
        for tag in "${releases[@]}"; do
            [[ -z "$tag" ]] && continue
            [[ "$tag" =~ ^\[[A-Z]+\] ]] && continue
            [[ "$tag" == "$default_tag" ]] && continue
            options+=("$tag")
        done
    else
        warn "Could not fetch release tags from GitHub for ${SEAD_CHANGE_CONTROL_REPO}. Defaulting to '${default_tag}' unless you enter a custom tag."
    fi

    echo
    echo -e "${CYAN}Select sead_change_control deploy tag:${NC}"
    local idx
    for idx in "${!options[@]}"; do
        if [[ "${options[$idx]}" == "$default_tag" ]]; then
            echo "  $((idx + 1))) ${options[$idx]} (default)"
        else
            echo "  $((idx + 1))) ${options[$idx]} (release)"
        fi
    done
    echo "  c) Enter a custom tag"

    local choice selected custom_tag
    while true; do
        read -rp "Enter choice [1-${#options[@]} or c] (default: 1 ${default_tag}): " choice
        choice="${choice:-1}"

        case "${choice,,}" in
            c)
                read -rp "Enter deploy tag (example: ${default_tag}): " custom_tag
                custom_tag="${custom_tag//$'\r'/}"
                if [[ -n "$custom_tag" ]]; then
                    selected="$custom_tag"
                    break
                fi
                echo "Deploy tag cannot be empty."
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
                    selected="${options[$((choice - 1))]}"
                    break
                fi
                echo "Please enter a number between 1 and ${#options[@]}, or 'c' for custom."
                ;;
        esac
    done

    SELECTED_DB_DEPLOY_TAG="$selected"
}

# Sets the database users' passwords from .env and grants the read-only users what they
# read, in the given database (default: the SEAD one). Run after an import.
apply_database_access() {
    local db="${1:-$DB_IMPORT_TARGET_DB}"
    [[ -n "${DATABASE_READ_ONLY_PASSWORD:-}" ]] || die "DATABASE_READ_ONLY_PASSWORD is empty. Check .env."
    [[ -n "${DATABASE_PASSWORD:-}" ]] || die "DATABASE_PASSWORD is empty. Check .env."

    info "Applying extensions, passwords, and grants in ${db}..."
    $COMPOSE_CMD exec -T "$DB_IMPORT_SERVICE" psql -h postgresql -U "$DB_IMPORT_USER" -d "$db" -v ON_ERROR_STOP=1 <<-EOSQL
	    -- Enable PostGIS extension
	    CREATE EXTENSION IF NOT EXISTS postgis;

	    -- Set passwords for users
	    ALTER USER postgrest_anon WITH PASSWORD '${DATABASE_READ_ONLY_PASSWORD}';
	    ALTER USER sead_ro WITH PASSWORD '${DATABASE_READ_ONLY_PASSWORD}';
	    ALTER USER sead_master WITH PASSWORD '${DATABASE_PASSWORD}';
	    ALTER USER humlab_admin WITH PASSWORD '${DATABASE_PASSWORD}';

	    -- Grant USAGE on schemas (public & facet) to read-only users
	    GRANT USAGE ON SCHEMA audit TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA bugs_import TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA clearing_house TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA clearing_house_commit TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA facet TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA postgrest_api TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA postgrest_default_api TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA public TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA sead_utility TO sead_ro, postgrest_anon;
	    GRANT USAGE ON SCHEMA sqitch TO sead_ro, postgrest_anon;

	    -- Grant SELECT on all existing tables in public & facet schemas
	    GRANT SELECT ON ALL TABLES IN SCHEMA audit TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA bugs_import TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA clearing_house TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA clearing_house_commit TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA facet TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA postgrest_api TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA postgrest_default_api TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA public TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA sead_utility TO sead_ro, postgrest_anon;
	    GRANT SELECT ON ALL TABLES IN SCHEMA sqitch TO sead_ro, postgrest_anon;

	    -- Ensure SELECT permission applies to future tables in public & facet schemas
	    ALTER DEFAULT PRIVILEGES IN SCHEMA public
	    GRANT SELECT ON TABLES TO sead_ro, postgrest_anon;

	    ALTER DEFAULT PRIVILEGES IN SCHEMA facet
	    GRANT SELECT ON TABLES TO sead_ro, postgrest_anon;

	    -- Grant SELECT on all existing sequences (IDs, etc.) in public & facet schemas
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA bugs_import TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA clearing_house TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA clearing_house_commit TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA facet TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA postgrest_api TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA postgrest_default_api TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA sead_utility TO sead_ro, postgrest_anon;
	    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA sqitch TO sead_ro, postgrest_anon;

	    -- Ensure SELECT permission applies to future sequences in public & facet schemas
	    ALTER DEFAULT PRIVILEGES IN SCHEMA public
	    GRANT USAGE, SELECT ON SEQUENCES TO sead_ro, postgrest_anon;

	    ALTER DEFAULT PRIVILEGES IN SCHEMA facet
	    GRANT USAGE, SELECT ON SEQUENCES TO sead_ro, postgrest_anon;
	EOSQL
}

# Execute the database import workflow previously handled by run_database_import.sh.
# Usage: run_database_import [deploy_tag]
run_database_import() {
    local deploy_tag="${1:-}"

    prompt_db_deploy_tag "$deploy_tag"
    deploy_tag="${SELECTED_DB_DEPLOY_TAG:-$DEFAULT_DB_DEPLOY_TAG}"

    [[ -n "${DATABASE_READ_ONLY_PASSWORD:-}" ]] || die "DATABASE_READ_ONLY_PASSWORD is empty. Check .env."
    [[ -n "${DATABASE_PASSWORD:-}" ]] || die "DATABASE_PASSWORD is empty. Check .env."

    info "Using deploy tag '${deploy_tag}' for sead_change_control."

    info "Updating sead_change_control repository inside the ${DB_IMPORT_SERVICE} container..."
    $COMPOSE_CMD exec "$DB_IMPORT_SERVICE" bash -c "git -C /sead_change_control pull --ff-only"

    info "Running database import command inside the ${DB_IMPORT_SERVICE} container..."
    $COMPOSE_CMD exec "$DB_IMPORT_SERVICE" bash -c \
        "cd /sead_change_control && ./bin/deploy-staging --port 5432 --user ${DB_IMPORT_USER} --create-database --on-conflict drop --source-type empty --target-db-name ${DB_IMPORT_TARGET_DB} --deploy-to-tag '${deploy_tag}' --ignore-git-tags --host postgresql"

    apply_database_access

    if [[ -f .env ]]; then
        set_env_var .env SEAD_CHANGE_CONTROL_RELEASE "$deploy_tag"
        success "SEAD_CHANGE_CONTROL_RELEASE set to '${deploy_tag}' in .env"
    fi

    success "Database import complete."
}

# ──────────────────────────────────────────────────────────────────────────────
# install command
# ──────────────────────────────────────────────────────────────────────────────
cmd_install() {
    info "Starting fresh SEAD installation"

    # Prerequisites
    for tool in git curl; do
        command -v "$tool" &>/dev/null || die "Required tool '$tool' not found. Please install it."
    done

    # Ask which compose command to use.
    echo
    echo -e "${CYAN}Select compose command:${NC}"
    local engine_opts=()
    local engine_labels=()

    # Only show compose-capable engines.
    for candidate in podman docker podman-compose docker-compose; do
        _engine_compose_works "$candidate" || continue
        local label="$candidate"
        case "$candidate" in
            podman)         label="podman compose (recommended)" ;;
            docker)         label="docker compose (recommended)" ;;
            podman-compose) label="podman-compose (legacy standalone)" ;;
            docker-compose) label="docker-compose (legacy standalone)" ;;
        esac
        engine_opts+=("$candidate")
        engine_labels+=("$label")
    done
    if [[ ${#engine_opts[@]} -eq 0 ]]; then
        die "No supported compose engine found. Install one of: podman compose, docker compose, podman-compose, docker-compose."
    fi
    local default_engine_idx=0
    # Prefer native compose integrations as defaults; fall back to auto-detected tool.
    for i in "${!engine_opts[@]}"; do
        [[ "${engine_opts[$i]}" == "podman" ]] && default_engine_idx=$i
    done
    for i in "${!engine_opts[@]}"; do
        if [[ "${engine_opts[$i]}" == "docker" && "${engine_opts[$default_engine_idx]}" != "podman" ]]; then
            default_engine_idx=$i
        fi
    done
    for i in "${!engine_opts[@]}"; do
        if [[ "${engine_opts[$default_engine_idx]}" != "podman" && "${engine_opts[$default_engine_idx]}" != "docker" ]] \
            && [[ "${engine_opts[$i]}" == "$CONTAINER_TOOL" ]]; then
            default_engine_idx=$i
        fi
    done
    for i in "${!engine_opts[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${engine_labels[$i]}"
    done
    local engine_choice
    while true; do
        read -rp "Enter choice [1-${#engine_opts[@]}] (default: $((default_engine_idx+1)) ${engine_opts[$default_engine_idx]}): " engine_choice
        engine_choice="${engine_choice:-$((default_engine_idx+1))}"
        if [[ "$engine_choice" =~ ^[0-9]+$ ]] && (( engine_choice >= 1 && engine_choice <= ${#engine_opts[@]} )); then
            CONTAINER_TOOL="${engine_opts[$((engine_choice-1))]}"
            break
        fi
        echo "Please enter a number between 1 and ${#engine_opts[@]}."
    done
    export CONTAINER_TOOL
    apply_compose_compatibility_override
    COMPOSE_CMD="$(build_compose_cmd)"
    info "Using compose command: $CONTAINER_TOOL"

    # Ask for deployment mode
    echo
    echo -e "${CYAN}Select deployment mode:${NC}"
    echo "  1) prod  — production build, compose.override.yml is disabled"
    echo "  2) dev   — development mode, compose.override.yml is active"
    local mode_choice
    while true; do
        read -rp "Enter choice [1/2] (default: 1 prod): " mode_choice
        mode_choice="${mode_choice:-1}"
        case "$mode_choice" in
            1|prod)  DEPLOY_MODE=prod; break ;;
            2|dev)   DEPLOY_MODE=dev;  break ;;
            *) echo "Please enter 1 or 2." ;;
        esac
    done
    info "Deploy mode set to: ${DEPLOY_MODE}"
    sync_override_file_for_mode
    COMPOSE_CMD="$(build_compose_cmd)"

    # Clone application source repositories
    clone_if_missing sead_browser_client "https://github.com/humlab-sead/sead_browser_client"
    clone_if_missing json_api_server     "https://github.com/humlab-sead/json_api_server"
    clone_if_missing sead_query_api      "https://github.com/${SEAD_QUERY_API_REPO}"

    # Generate .env if not already present
    cmd_generate_env

    [[ -f .env ]] || die ".env is missing. Run './deploy.sh generate-env' to create it."
    # Persist the chosen container engine before load_env so sourcing .env doesn't
    # overwrite the selection with the blank template value.
    set_env_var .env CONTAINER_TOOL "$CONTAINER_TOOL"
    prompt_unique_instance_settings .env

    # Install the SEAD release this checkout carries, unless the operator would rather pick
    # each service's version by hand - a dev instance following main, for instance.
    local release use_release=""
    release="$(manifest_value SEAD_RELEASE)"
    if [[ -n "$release" ]]; then
        echo
        read -rp "Install SEAD release ${release}? Answer n to pick each service's version instead. [Y/n]: " use_release
    fi
    if [[ -n "$release" && ! "$use_release" =~ ^[Nn] ]]; then
        apply_release_refs
        record_applied_release
    else
        select_and_apply_release_ref "client"
        select_and_apply_release_ref "json_api_server"
        select_and_apply_release_ref "sead_query_api"
    fi

    # Reload env so variables (DOMAIN, DATABASE_USER, etc.) are available in this shell
    load_env

    # The SAML SP's keys are made for DOMAIN, so only once it is final
    cmd_sp_keys

    echo
    warn "Please review .env now (especially manual API/OAuth credentials)."
    warn "Press ENTER to continue with the build, or Ctrl-C to abort."
    read -r

    # Pull image-based services explicitly before local builds.
    pull_non_build_images

    # Build all images
    info "Building Docker images (this may take several minutes)..."
    compose_build
    success "All images built."

    # Start services
    info "Starting services..."
    $COMPOSE_CMD up -d
    success "Services started."

    # Wait for PostgreSQL to be accepting connections
    info "Waiting for PostgreSQL to become healthy..."
    local retries=60
    until $COMPOSE_CMD exec -T postgresql pg_isready -U "${DATABASE_USER:-sead_master}" &>/dev/null; do
        retries=$((retries - 1))
        [[ $retries -le 0 ]] && die "PostgreSQL did not become healthy within 5 minutes."
        sleep 5
    done
    success "PostgreSQL is ready."

    # Import database schema & data
    info "Importing database via sead_change_control (this may take a long time)..."
    run_database_import

    # Restart services so everything picks up the populated database
    info "Restarting all services..."
    cmd_down
    $COMPOSE_CMD up -d
    success "Stack restarted."

    # Preload JSON API Server MongoDB cache in the background so install can finish immediately.
    start_preload_jas_background

    # Boundary data last, also detached. The database it loads into was just recreated, so
    # this has to run after the import rather than before it.
    start_gadm_import_background

    # Re-load env to get fresh DOMAIN / WEB_PORT values
    load_env
    echo
    success "Installation complete!"
    info "The stack should now be available at http://${DOMAIN:-localhost}:${WEB_PORT:-80}"
}

# ──────────────────────────────────────────────────────────────────────────────
# sp-keys command — the SAML Service Provider's keys for this server
# ──────────────────────────────────────────────────────────────────────────────
cmd_sp_keys() {
    DOMAIN="${DOMAIN:-}" "$SCRIPT_DIR/router/scripts/generate-sp-keys.sh" "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# update command — pull latest code (if local repo), rebuild, restart
# ──────────────────────────────────────────────────────────────────────────────

# Returns the local source directory for services that have one.
service_source_dir() {
    case "$1" in
        client)           echo "sead_browser_client" ;;
        json_api_server)  echo "json_api_server" ;;
        sead_query_api)   echo "sead_query_api" ;;
        *)                echo "" ;;
    esac
}

# Configure release selection metadata for services that support GitHub releases.
# Sets RELEASE_REPO, PRIMARY_BRANCH, and ENV_REF_VAR for the given service.
set_release_selection_config() {
    local service="$1"
    RELEASE_REPO=""
    PRIMARY_BRANCH=""
    ENV_REF_VAR=""

    case "$service" in
        client)
            RELEASE_REPO="humlab-sead/sead_browser_client"
            PRIMARY_BRANCH="master"
            ENV_REF_VAR="SBC_RELEASE"
            ;;
        json_api_server)
            RELEASE_REPO="humlab-sead/json_api_server"
            PRIMARY_BRANCH="main"
            ENV_REF_VAR="JAS_RELEASE"
            ;;
        sead_query_api)
            RELEASE_REPO="$SEAD_QUERY_API_REPO"
            PRIMARY_BRANCH="$DEFAULT_SEAD_QUERY_API_RELEASE"
            ENV_REF_VAR="SEAD_QUERY_API_RELEASE"
            ;;
    esac
}

# Prompt for a service release ref and persist it to .env when possible.
select_and_apply_release_ref() {
    local service="$1"
    set_release_selection_config "$service"

    [[ -n "$RELEASE_REPO" ]] || return 1

    local selected_ref
    prompt_release_ref "$service" "$RELEASE_REPO" "$PRIMARY_BRANCH"
    selected_ref="${SELECTED_RELEASE_REF:-}"
    [[ -n "$selected_ref" ]] || die "No release selected for ${service}."

    if [[ -f .env ]]; then
        set_env_var .env "$ENV_REF_VAR" "$selected_ref"
        success "${ENV_REF_VAR} set to '$selected_ref' in .env"
    else
        warn ".env not found; using ${ENV_REF_VAR}='$selected_ref' for this run only."
    fi

    export "${ENV_REF_VAR}=$selected_ref"
    info "${service} release source is controlled via ${ENV_REF_VAR} (GitHub ref)."
}

# Ensure a release-managed service has a local checkout at the selected ref.
# Primary branch deploys are fast-forwarded. Tags are checked out detached.
# Other refs can resolve to remote branches or any fetchable Git ref.
sync_local_repo_to_selected_ref() {
    local service="$1"
    local src_dir="$2"
    local repo="$3"
    local primary_branch="$4"
    local env_ref_var="$5"
    local selected_ref="${!env_ref_var:-}"

    [[ -n "$service" && -n "$src_dir" && -n "$repo" && -n "$primary_branch" && -n "$env_ref_var" ]] \
        || die "sync_local_repo_to_selected_ref called with missing arguments."
    [[ -n "$selected_ref" ]] || die "No selected ref found in ${env_ref_var} for ${service}."

    clone_if_missing "$src_dir" "https://github.com/${repo}"
    [[ -d "$src_dir/.git" ]] || die "Expected git repository at ${src_dir}, but none was found."

    if [[ -n "$(git -C "$src_dir" status --porcelain)" ]]; then
        die "Local repo ${src_dir} has uncommitted changes. Commit/stash them before updating ${service}."
    fi

    info "Fetching latest refs for ${service} in ${src_dir} ..."
    git -C "$src_dir" fetch --prune --tags origin

    if [[ "$selected_ref" == "$primary_branch" ]]; then
        info "Checking out branch '${primary_branch}' in ${src_dir} ..."
        if git -C "$src_dir" show-ref --verify --quiet "refs/heads/${primary_branch}"; then
            git -C "$src_dir" checkout "$primary_branch"
        else
            git -C "$src_dir" checkout -b "$primary_branch" --track "origin/${primary_branch}"
        fi

        info "Fast-forwarding '${primary_branch}' in ${src_dir} ..."
        git -C "$src_dir" pull --ff-only --recurse-submodules origin "$primary_branch"
        git -C "$src_dir" submodule update --init --recursive
        success "${service} is now on latest '${primary_branch}'."
        return
    fi

    if git -C "$src_dir" rev-parse -q --verify "refs/tags/${selected_ref}" &>/dev/null; then
        info "Checking out tag '${selected_ref}' in ${src_dir} ..."
        git -C "$src_dir" checkout --detach "refs/tags/${selected_ref}"
        git -C "$src_dir" submodule update --init --recursive
        success "${service} is now checked out at tag '${selected_ref}'."
        return
    fi

    if git -C "$src_dir" rev-parse -q --verify "refs/remotes/origin/${selected_ref}" &>/dev/null; then
        info "Checking out branch '${selected_ref}' in ${src_dir} ..."
        if git -C "$src_dir" show-ref --verify --quiet "refs/heads/${selected_ref}"; then
            git -C "$src_dir" checkout "$selected_ref"
            git -C "$src_dir" branch --set-upstream-to="origin/${selected_ref}" "$selected_ref" >/dev/null 2>&1 || true
        else
            git -C "$src_dir" checkout -b "$selected_ref" --track "origin/${selected_ref}"
        fi

        info "Fast-forwarding '${selected_ref}' in ${src_dir} ..."
        git -C "$src_dir" pull --ff-only --recurse-submodules origin "$selected_ref"
        git -C "$src_dir" submodule update --init --recursive
        success "${service} is now on latest '${selected_ref}'."
        return
    fi

    info "Attempting to fetch arbitrary ref '${selected_ref}' in ${src_dir} ..."
    if git -C "$src_dir" fetch --recurse-submodules origin "$selected_ref"; then
        git -C "$src_dir" checkout --detach FETCH_HEAD
        git -C "$src_dir" submodule update --init --recursive
        success "${service} is now checked out at ref '${selected_ref}'."
        return
    fi

    die "Selected ref '${selected_ref}' could not be resolved as a tag, remote branch, or fetchable Git ref."
}

cmd_update() {
    local service="${1:-}"
    [[ -z "$service" ]] && die "Usage: $0 update <service>"

    info "Updating service: $service"

    if select_and_apply_release_ref "$service"; then
        load_env
    fi

    local src_dir
    src_dir=$(service_source_dir "$service")
    if [[ -n "$RELEASE_REPO" ]]; then
        [[ -n "$src_dir" ]] || die "No local source directory configured for release-managed service '$service'."
        sync_local_repo_to_selected_ref "$service" "$src_dir" "$RELEASE_REPO" "$PRIMARY_BRANCH" "$ENV_REF_VAR"
    elif [[ -n "$src_dir" && -d "$src_dir/.git" ]]; then
        info "Pulling latest code in $src_dir ..."
        git -C "$src_dir" pull --ff-only --recurse-submodules
        success "Code updated in $src_dir"
    else
        info "No local source directory for '$service' — image will be rebuilt from its Dockerfile."
    fi

    info "Rebuilding image for $service (no cache)..."
    export_source_versions
    $COMPOSE_CMD build --no-cache "$service"
    success "Image rebuilt for $service."

    info "Restarting $service ..."
    $COMPOSE_CMD up -d --force-recreate "$service"
    success "Service '$service' updated and restarted."
}

# ──────────────────────────────────────────────────────────────────────────────
# release command — one version number for the whole of SEAD
# ──────────────────────────────────────────────────────────────────────────────
# A SEAD release is a tag on this repository, named YYYY-MM.N. The commit it points at
# pins everything kept here - compose.yml, router, sead_idp, the image tags - and its
# sead-release.env pins the services built from repositories of their own.
# See releases/README.md.
RELEASE_NAME_PATTERN='^[0-9]{4}-[0-9]{2}\.[0-9]+$'

# The services a release pins, by their compose names. set_release_selection_config
# knows each one's repository and the .env variable holding its ref.
RELEASE_SERVICES=(client json_api_server sead_query_api)

# The manifest variable holding the commit a service's tag was released at.
release_commit_var() { echo "${ENV_REF_VAR%_RELEASE}_COMMIT"; }

# The commit a tag points at on GitHub, peeled through an annotated tag.
# Prints nothing when the tag does not exist.
remote_tag_commit() {
    local repo="$1" tag="$2" refs line
    refs="$(git ls-remote --tags "https://github.com/${repo}" "refs/tags/${tag}" "refs/tags/${tag}^{}")" || return 1
    line="$(grep -m1 -F "refs/tags/${tag}^{}" <<< "$refs" || grep -m1 -F "refs/tags/${tag}" <<< "$refs" || true)"
    echo "${line%%$'\t'*}"
}

# Brings every service the release pins to its pinned version: checks that each tag
# still points where it did when the release was cut, syncs the local checkout the
# image is built from to it, and records the refs in .env.
apply_release_refs() {
    [[ -f "$RELEASE_MANIFEST" ]] || die "No ${RELEASE_MANIFEST} in this checkout - there is no release to apply."
    [[ -f .env ]] || die ".env not found. Install the stack first: $0 install"

    local service ref commit actual src_dir

    # Every tag is checked before any checkout is touched, so a moved tag stops the
    # deploy with the stack still as it was.
    for service in "${RELEASE_SERVICES[@]}"; do
        set_release_selection_config "$service"
        ref="$(manifest_value "$ENV_REF_VAR")"
        commit="$(manifest_value "$(release_commit_var)")"
        [[ -n "$ref" && -n "$commit" ]] \
            || die "${RELEASE_MANIFEST} does not pin ${service} (${ENV_REF_VAR} and $(release_commit_var))."

        info "Checking ${service} ${ref} on GitHub ..."
        actual="$(remote_tag_commit "$RELEASE_REPO" "$ref")" \
            || die "Could not reach https://github.com/${RELEASE_REPO} to check ${service} ${ref}."
        [[ -n "$actual" ]] || die "${RELEASE_REPO} has no tag ${ref}, which this release pins ${service} to."
        [[ "$actual" == "$commit" ]] \
            || die "Tag ${ref} of ${RELEASE_REPO} points at ${actual:0:12}, but the release pins ${commit:0:12}. The tag has been moved since the release was cut; refusing to build something other than what was released."
    done

    for service in "${RELEASE_SERVICES[@]}"; do
        set_release_selection_config "$service"
        ref="$(manifest_value "$ENV_REF_VAR")"
        commit="$(manifest_value "$(release_commit_var)")"
        export "${ENV_REF_VAR}=${ref}"

        src_dir="$(service_source_dir "$service")"
        sync_local_repo_to_selected_ref "$service" "$src_dir" "$RELEASE_REPO" "$PRIMARY_BRANCH" "$ENV_REF_VAR"
        [[ "$(git -C "$src_dir" rev-parse HEAD)" == "$commit" ]] \
            || die "${src_dir} is at $(git -C "$src_dir" rev-parse --short HEAD) after checking out ${ref}, not at the released ${commit:0:12}."

        set_env_var .env "$ENV_REF_VAR" "$ref"
        success "${service} pinned to ${ref} (${commit:0:12})"
    done
}

# Records in .env which release the stack now runs, and which it ran before - the
# release to deploy again to roll back.
record_applied_release() {
    local release previous
    release="$(manifest_value SEAD_RELEASE)"
    previous="$(get_env_var .env SEAD_RELEASE)"
    if [[ -n "$previous" && "$previous" != "$release" ]]; then
        set_env_var .env SEAD_PREVIOUS_RELEASE "$previous"
    fi
    set_env_var .env SEAD_RELEASE "$release"
    export SEAD_RELEASE="$release"
}

# ── The release's database ───────────────────────────────────────────────────
# Everything in the SEAD database comes from sead_change_control, so a release brings its
# schema by rebuilding the database at the sqitch tag it pins - the import import-db
# runs - not by migrating it. The rebuild goes into a database of its own while the old
# one keeps serving, and the two are swapped by renaming them; the old one is kept as
# <name>_prev until the next rebuild. A rebuild only happens when the database is not at
# the pinned tag, or when the release brings a new PostgreSQL major version: that cannot
# start on the old version's data directory, which is then set aside (and kept) and the
# rebuild starts from an empty one.
PG_DATA_DIR="postgresql/mounts/pg-data-volume"
PG_DOCKERFILE="postgresql/docker/Dockerfile"
DB_REBUILD_NAME="${DB_IMPORT_TARGET_DB}_next"
DB_PREVIOUS_NAME="${DB_IMPORT_TARGET_DB}_prev"

# The running postgresql container, for commands that stream into or out of it.
pg_container() {
    local container
    container="$(service_container "$DB_IMPORT_SERVICE" || true)"
    [[ -n "$container" ]] || die "The ${DB_IMPORT_SERVICE} container is not running."
    echo "$container"
}

# psql as postgres in the maintenance database, for what has to happen outside the
# databases it acts on.
psql_admin() {
    $CONTAINER_TOOL exec -i "$(pg_container)" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qtA "$@"
}

# Waits until PostgreSQL takes connections over TCP. The image's entrypoint initialises
# a new data directory with a server that listens on the socket only, so TCP is up once
# initialisation is over and the real server runs.
wait_for_postgres() {
    local retries=60
    until service_exec "$DB_IMPORT_SERVICE" pg_isready -q -h 127.0.0.1 -U postgres; do
        retries=$((retries - 1))
        [[ $retries -gt 0 ]] || die "PostgreSQL did not come up. See: $0 logs ${DB_IMPORT_SERVICE}"
        sleep 5
    done
}

# The PostgreSQL major version the release's image is built on.
release_pg_major() {
    local major
    major="$(sed -nE 's/^FROM[[:space:]]+[^[:space:]]*postgis:([0-9]+)-.*/\1/p' "$PG_DOCKERFILE" 2>/dev/null | tail -n1 || true)"
    [[ -n "$major" ]] || die "Could not tell the PostgreSQL version from the FROM line of ${PG_DOCKERFILE}."
    echo "$major"
}

# The PostgreSQL major version the data directory was made by: what the running server
# says, or its PG_VERSION file, which is owned by the container's user.
data_pg_major() {
    local version
    version="$(psql_value 'show server_version_num' 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
        echo $((version / 10000))
        return
    fi
    if [[ "$CONTAINER_TOOL" == podman ]]; then
        podman unshare cat "$PG_DATA_DIR/PG_VERSION" 2>/dev/null || true
    else
        cat "$PG_DATA_DIR/PG_VERSION" 2>/dev/null || true
    fi
}

# Brings the container's sead_change_control up to date: the plans that say where the
# database should be, and the changes a rebuild deploys, have to include the release's tag.
update_container_change_control() {
    info "Updating sead_change_control in the ${DB_IMPORT_SERVICE} container ..."
    $CONTAINER_TOOL exec "$(pg_container)" git -C /sead_change_control pull --quiet --ff-only \
        || die "Could not update sead_change_control in the ${DB_IMPORT_SERVICE} container."
}

# The sqitch projects that have the tag in their plan but not in the database.
pending_schema_projects() {
    local tag="$1" planned deployed project
    planned="$($CONTAINER_TOOL exec "$(pg_container)" bash -c \
        "cd /sead_change_control && for p in \$(grep -v '^#' projects.txt | grep -v '^[[:space:]]*\$'); do grep -q '^${tag} ' \"\$p/sqitch.plan\" && echo \"\$p\"; done; true")"
    [[ -n "$planned" ]] || die "No sqitch project in sead_change_control has the tag ${tag} in its plan."
    deployed="$(psql_value "select distinct project from sqitch.tags where tag = '${tag}'" || true)"
    for project in $planned; do
        grep -qxF "$project" <<< "$deployed" || echo "$project"
    done
}

# Sets DB_AT_TAG=1 when the database is at the tag: every project whose plan has it has
# it deployed, and no later tag is. A release pinning an older tag than the database's
# (a rollback) is not at it. (A variable rather than a return status: called in a
# condition, the function would run without set -e.)
check_database_tag() {
    local tag="$1" latest pending
    DB_AT_TAG=0
    [[ "$(psql_value "select to_regclass('sqitch.tags') is not null" || true)" == "t" ]] || return 0
    latest="$(psql_value 'select max(tag) from sqitch.tags' || true)"
    [[ "$latest" == "$tag" ]] || return 0
    pending="$(pending_schema_projects "$tag")"
    [[ -z "$pending" ]] || return 0
    DB_AT_TAG=1
}

# GADM boundaries are loaded by their own import, not by sead_change_control, so a
# rebuilt database lacks them. They are copied over from the database being replaced
# when it has them. Sets GADM_COPIED=1 when it did.
copy_gadm_into_rebuild() {
    local container
    GADM_COPIED=0
    container="$(pg_container)"
    [[ "$(psql_value "select count(*) from pg_tables where schemaname = 'gadm'" || true)" =~ ^[1-9] ]] || return 0
    info "Copying the GADM boundaries into ${DB_REBUILD_NAME} ..."
    $CONTAINER_TOOL exec "$container" bash -c \
        "set -o pipefail; pg_dump -U postgres -n gadm '${DB_IMPORT_TARGET_DB}' | psql -U postgres -d '${DB_REBUILD_NAME}' -v ON_ERROR_STOP=1 -q >/dev/null" \
        || die "Copying the GADM boundaries failed. ${DB_IMPORT_TARGET_DB} is untouched."
    GADM_COPIED=1
}

# Puts the rebuilt database in the place of the one in use, which becomes <name>_prev
# (replacing the one before). Connections are refused while the names change, so nothing
# reconnects in between.
swap_rebuilt_database() {
    info "Swapping ${DB_REBUILD_NAME} in as ${DB_IMPORT_TARGET_DB}; the database it replaces is kept as ${DB_PREVIOUS_NAME} ..."
    local failed=0
    psql_admin <<EOSQL || failed=1
DROP DATABASE IF EXISTS ${DB_PREVIOUS_NAME} WITH (FORCE);
ALTER DATABASE ${DB_IMPORT_TARGET_DB} WITH ALLOW_CONNECTIONS false;
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
 WHERE datname IN ('${DB_IMPORT_TARGET_DB}', '${DB_REBUILD_NAME}') AND pid <> pg_backend_pid();
ALTER DATABASE ${DB_IMPORT_TARGET_DB} RENAME TO ${DB_PREVIOUS_NAME};
ALTER DATABASE ${DB_REBUILD_NAME} RENAME TO ${DB_IMPORT_TARGET_DB};
EOSQL
    if (( failed )); then
        if [[ -z "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '${DB_IMPORT_TARGET_DB}'" || true)" ]]; then
            die "Swapping the databases failed half-way: there is no ${DB_IMPORT_TARGET_DB}. Put the old one back, in psql as postgres: ALTER DATABASE ${DB_PREVIOUS_NAME} RENAME TO ${DB_IMPORT_TARGET_DB}; ALTER DATABASE ${DB_IMPORT_TARGET_DB} WITH ALLOW_CONNECTIONS true;"
        fi
        psql_admin -c "ALTER DATABASE ${DB_IMPORT_TARGET_DB} WITH ALLOW_CONNECTIONS true" || true
        die "Swapping the databases failed; ${DB_IMPORT_TARGET_DB} is still the old one, and ${DB_REBUILD_NAME} the rebuild."
    fi
    success "${DB_IMPORT_TARGET_DB} is now the database rebuilt at $(manifest_value SEAD_CHANGE_CONTROL_RELEASE)."
}

# A new major version cannot start on the old one's data directory: it is set aside -
# kept, for going back - and the new version starts on an empty one, which its image
# initialises with the SEAD roles and an empty sead_staging.
set_aside_pg_data() {
    local from="$1" old_data
    old_data="${PG_DATA_DIR}.pg${from}.$(date +%Y%m%d_%H%M%S)"
    warn "PostgreSQL ${from} -> $(release_pg_major): the site has no database until the rebuild is done."
    info "Stopping PostgreSQL ${from}; its data directory is kept as ${old_data} ..."
    $COMPOSE_CMD stop "$DB_IMPORT_SERVICE"
    mv "$PG_DATA_DIR" "$old_data"
    mkdir -p "$PG_DATA_DIR"
    PG_SET_ASIDE="$old_data"
}

# Starts the release's PostgreSQL and rebuilds the database at the pinned tag if it is
# not there. Sets DB_REBUILT=1 when it rebuilt it.
bring_database_to_release() {
    local tag from to
    DB_REBUILT=0
    PG_SET_ASIDE=""
    tag="$(manifest_value SEAD_CHANGE_CONTROL_RELEASE)"
    to="$(release_pg_major)"
    from="$(data_pg_major)"

    if [[ -n "$from" && "$from" != "$to" ]]; then
        (( from < to )) || die "The database is PostgreSQL ${from}, newer than the release's ${to}. Refusing to downgrade it."
        set_aside_pg_data "$from"
    fi
    info "Starting PostgreSQL ${to} ..."
    $COMPOSE_CMD up -d --no-deps "$DB_IMPORT_SERVICE"
    wait_for_postgres

    if [[ -z "$tag" ]]; then
        warn "The release pins no schema tag; leaving the database as it is."
        return 0
    fi
    update_container_change_control
    if [[ -z "$PG_SET_ASIDE" ]]; then
        check_database_tag "$tag"
        if (( DB_AT_TAG )); then
            success "Database schema is at ${tag}, as the release pins."
            return 0
        fi
    fi

    info "Rebuilding the database at ${tag} as ${DB_REBUILD_NAME}; ${DB_IMPORT_TARGET_DB} keeps serving meanwhile ..."
    $CONTAINER_TOOL exec "$(pg_container)" bash -c \
        "cd /sead_change_control && ./bin/deploy-staging --port 5432 --user ${DB_IMPORT_USER} --create-database --on-conflict drop --source-type empty --target-db-name ${DB_REBUILD_NAME} --deploy-to-tag '${tag}' --ignore-git-tags --host postgresql" \
        || die "Rebuilding the database at ${tag} failed. ${DB_IMPORT_TARGET_DB} is untouched; ${DB_REBUILD_NAME} holds what the rebuild got to."
    apply_database_access "$DB_REBUILD_NAME"
    copy_gadm_into_rebuild
    swap_rebuilt_database
    set_env_var .env SEAD_CHANGE_CONTROL_RELEASE "$tag"
    DB_REBUILT=1
}

# What the services cached from the database it replaced: the query API's facet results
# in Redis, and the JSON API server's documents in Mongo, rebuilt in the background once
# it is up. GADM boundaries the rebuild could not copy are imported in the background.
refresh_after_rebuild() {
    info "Flushing the query API's Redis cache ..."
    $CONTAINER_TOOL exec "$(service_container redis_cache)" redis-cli FLUSHALL >/dev/null \
        || warn "Could not flush Redis; flush it by hand: $0 shell redis_cache"

    (( GADM_COPIED )) || start_gadm_import_background

    local container retries=60 health=""
    container="$(service_container json_api_server || true)"
    while [[ -n "$container" ]] && (( retries-- > 0 )); do
        health="$($CONTAINER_TOOL inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
        [[ "$health" == healthy ]] && break
        sleep 5
    done
    if [[ "$health" == healthy ]]; then
        start_preload_jas_background
    else
        warn "json_api_server is not healthy yet; rebuild its cache when it is: $0 preload-jas --background"
    fi
}

# Builds and starts the release this checkout carries, and brings the database to it.
# Run by 'release deploy' once it has checked out the release's tag, or by hand on a
# checkout already there.
cmd_release_apply() {
    local release at_tag
    release="$(manifest_value SEAD_RELEASE)"
    [[ -n "$release" ]] || die "No SEAD_RELEASE in ${RELEASE_MANIFEST} - there is no release to apply."

    at_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
    if [[ "$at_tag" != "$release" ]]; then
        warn "This checkout is not at the tag ${release}, so what is kept in this repository"
        warn "(compose.yml, router, ...) may differ from the release. To deploy exactly ${release}:"
        warn "  $0 release deploy ${release}"
    fi

    info "Applying SEAD release ${release}"
    check_release_env

    apply_release_refs
    record_applied_release
    load_env

    pull_non_build_images
    info "Building images..."
    compose_build

    GADM_COPIED=0
    bring_database_to_release

    info "Starting services..."
    $COMPOSE_CMD up -d
    success "Services started."

    if (( DB_REBUILT )); then
        refresh_after_rebuild
    fi
    [[ -z "$PG_SET_ASIDE" ]] || info "PostgreSQL's previous data directory is kept as ${PG_SET_ASIDE}; remove it once the release is known to be good."
    success "SEAD ${release} deployed."
    info "Check it with: $0 versions"
}

# A release deploy run in the background, so that it outlives the SSH session it was
# started from. Its log, and the PID while it runs, are under logs/.
RELEASE_DEPLOY_LOG_LINK="logs/release-deploy-latest.log"
RELEASE_DEPLOY_PID_FILE="logs/release-deploy.pid"

release_deploy_running_pid() {
    local pid
    pid="$(cat "$RELEASE_DEPLOY_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
    return 0
}

start_release_deploy_background() {
    local release="$1" pid log
    pid="$(release_deploy_running_pid)"
    [[ -z "$pid" ]] || die "A release deploy is already running (PID ${pid}). Follow it with: $0 release log --follow"

    mkdir -p logs
    log="logs/release-deploy-${release}-$(date +%Y%m%d_%H%M%S).log"
    # The last line of the log is the deploy's exit status, which 'release log' returns.
    nohup bash -c '"$1" release deploy "$2"; status=$?; echo "Release deploy finished with exit status ${status}"; exit "$status"' \
        _ "$SCRIPT_DIR/deploy.sh" "$release" > "$log" 2>&1 < /dev/null &
    echo $! > "$RELEASE_DEPLOY_PID_FILE"
    ln -sfn "$(basename "$log")" "$RELEASE_DEPLOY_LOG_LINK"
    success "Deploying SEAD ${release} in the background (PID $!)."
    info "Log: ${SCRIPT_DIR}/${log}"
    info "Follow it with: $0 release log --follow"
}

# Shows the latest release deploy's log, following it while the deploy runs, and exits
# with the deploy's status once it has finished.
cmd_release_log() {
    local follow=0 pid status
    [[ "${1:-}" == "--follow" || "${1:-}" == "-f" ]] && follow=1
    [[ -e "$RELEASE_DEPLOY_LOG_LINK" ]] || die "No release deploy has been run in the background here."

    pid="$(release_deploy_running_pid)"
    if (( follow )) && [[ -n "$pid" ]]; then
        tail -n +1 -F --pid="$pid" "$RELEASE_DEPLOY_LOG_LINK" 2>/dev/null
    else
        cat "$RELEASE_DEPLOY_LOG_LINK"
        [[ -n "$pid" ]] && { info "Still running (PID ${pid})."; return 0; }
    fi

    status="$(sed -n 's/^Release deploy finished with exit status \([0-9]*\)$/\1/p' "$RELEASE_DEPLOY_LOG_LINK" | tail -n1)"
    [[ -n "$status" ]] || { warn "The deploy ended without recording its status."; return 1; }
    return "$status"
}

# Checks out a release's tag of this repository and applies it.
cmd_release_deploy() {
    local release="${1:-}"
    [[ "$release" =~ $RELEASE_NAME_PATTERN ]] || die "Usage: $0 release deploy <YYYY-MM.N> [--background], e.g. $0 release deploy 2026-10.0"
    if [[ "${2:-}" == "--background" ]]; then
        start_release_deploy_background "$release"
        return
    fi

    info "Fetching SEAD release tags ..."
    git fetch --quiet --tags origin
    git rev-parse -q --verify "refs/tags/${release}^{commit}" >/dev/null \
        || die "There is no SEAD release ${release}: no such tag here or on origin."
    check_release_env "$release"

    # In prod mode the override file sits renamed to .disabled, which git sees as a
    # tracked file deleted. Put it back for the checkout, and away again after.
    local override_parked=0
    if [[ ! -f compose.override.yml && -f compose.override.yml.disabled ]]; then
        mv compose.override.yml.disabled compose.override.yml
        override_parked=1
    fi
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        git status --short --untracked-files=no
        (( override_parked )) && mv compose.override.yml compose.override.yml.disabled
        die "This checkout has uncommitted changes (above). A release deploys what was committed - commit or stash them first."
    fi

    info "Checking out SEAD release ${release} ..."
    git checkout --quiet --detach "refs/tags/${release}"
    (( override_parked )) && mv compose.override.yml compose.override.yml.disabled

    # The release's own deploy.sh applies it - that is the one that knows what it needs.
    # Bash keeps reading this script through the file it opened, which git has replaced
    # rather than rewritten, so this copy is not disturbed on its way here.
    exec "$SCRIPT_DIR/deploy.sh" release apply
}

# Writes the release manifest. Its format is what manifest_value reads: one KEY=value
# per line, no quotes.
write_release_manifest() {
    local release="$1" service
    {
        cat <<EOF
# SEAD release manifest - written by './deploy.sh release cut'. See releases/README.md.
#
# Pins every SEAD service built from a repository of its own to a tag, and the commit
# that tag pointed at when the release was cut. Everything kept in this repository is
# pinned by the commit this file is in, which carries the tag ${release}.

SEAD_RELEASE=${release}
EOF
        for service in "${RELEASE_SERVICES[@]}"; do
            set_release_selection_config "$service"
            echo
            echo "# ${service} - https://github.com/${RELEASE_REPO}"
            echo "${ENV_REF_VAR}=${CUT_REFS[$service]}"
            echo "$(release_commit_var)=${CUT_COMMITS[$service]}"
        done
        cat <<EOF

# The sqitch tag the database schema is deployed to (sead_change_control).
# A release never changes the database by itself; see './deploy.sh import-db'.
SEAD_CHANGE_CONTROL_RELEASE=${CUT_SCHEMA_TAG}
EOF
    } > "$RELEASE_MANIFEST"
}

# Asks which tag of each service a new release pins, writes the manifest, and commits
# and tags it. Pushing is left to the operator.
cmd_release_cut() {
    local release="${1:-}"
    [[ "$release" =~ $RELEASE_NAME_PATTERN ]] || die "Usage: $0 release cut <YYYY-MM.N>, e.g. $0 release cut 2026-10.0"
    [[ -t 0 ]] || die "'release cut' asks which tag of each service to pin; run it in a terminal."

    git rev-parse -q --verify "refs/tags/${release}" >/dev/null && die "Release ${release} already exists (tag ${release})."
    [[ -z "$(git ls-remote --tags origin "refs/tags/${release}")" ]] || die "Release ${release} already exists on origin."

    declare -gA CUT_REFS=() CUT_COMMITS=()
    local service ref commit
    for service in "${RELEASE_SERVICES[@]}"; do
        set_release_selection_config "$service"
        while true; do
            prompt_release_ref "$service" "$RELEASE_REPO" "$PRIMARY_BRANCH" "$(manifest_value "$ENV_REF_VAR")"
            ref="$SELECTED_RELEASE_REF"
            commit="$(remote_tag_commit "$RELEASE_REPO" "$ref" || true)"
            [[ -n "$commit" ]] && break
            warn "'${ref}' is not a tag of ${RELEASE_REPO}. A release pins tags only, since branches move - tag ${service} first, or pick a tag."
        done
        CUT_REFS[$service]="$ref"
        CUT_COMMITS[$service]="$commit"
    done

    prompt_db_deploy_tag
    CUT_SCHEMA_TAG="$SELECTED_DB_DEPLOY_TAG"

    write_release_manifest "$release"

    echo
    info "SEAD ${release}:"
    for service in "${RELEASE_SERVICES[@]}"; do
        printf '  %-20s %-14s %s\n' "$service" "${CUT_REFS[$service]}" "${CUT_COMMITS[$service]:0:12}"
    done
    printf '  %-20s %s\n' "database schema" "$CUT_SCHEMA_TAG"

    if [[ -n "$(git status --porcelain --untracked-files=no -- . ":(exclude)${RELEASE_MANIFEST}")" ]]; then
        echo
        warn "This checkout has other uncommitted changes. They will not be part of ${release} -"
        warn "the release is the commit made here, on top of $(git rev-parse --short HEAD)."
    fi

    echo
    local answer
    read -rp "Commit ${RELEASE_MANIFEST} and tag it ${release}? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        info "Left ${RELEASE_MANIFEST} written but uncommitted."
        return 0
    fi

    git add "$RELEASE_MANIFEST"
    git commit --quiet -m "Release SEAD ${release}" -- "$RELEASE_MANIFEST"
    git tag -a "$release" -m "SEAD ${release}"
    success "Committed and tagged ${release}."
    info "Write the release notes in releases/${release}/, then publish the release with:"
    info "  git push origin HEAD refs/tags/${release}"
}

cmd_release() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        cut)    cmd_release_cut "$@" ;;
        deploy) cmd_release_deploy "$@" ;;
        apply)  cmd_release_apply ;;
        log)    cmd_release_log "$@" ;;
        ""|help|--help|-h)
            cat <<EOF
Usage: $0 release <command> [args...]

Commands:
  cut <YYYY-MM.N>     Make a new SEAD release: pick the tag of each service it
                      pins, write ${RELEASE_MANIFEST}, then commit and tag it.
  deploy <YYYY-MM.N> [--background]
                      Check out that release's tag of this repository, then build
                      and start it, and rebuild the database at the schema it
                      pins if it is not there. --background runs it detached,
                      logging under logs/.
  apply               Build and start the release this checkout carries, and
                      bring the database to it.
  log [--follow]      Show the latest background deploy's log; --follow follows
                      it until the deploy ends, and exits with its status.

See releases/README.md.
EOF
            ;;
        *) die "Unknown release command: ${subcommand}" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Simple stack/service wrappers
# ──────────────────────────────────────────────────────────────────────────────
cmd_up() {
    info "Starting services..."
    $COMPOSE_CMD up -d "$@"
    success "Services started."
}

cmd_down() {
    info "Stopping services..."
    if $COMPOSE_CMD down "$@"; then
        success "Stack stopped."
    else
        warn "compose down returned non-zero (possible rootless netns cleanup bug). Pruning networks..."
        $CONTAINER_TOOL network prune -f
        success "Network cleanup done."
    fi
}

cmd_restart() {
    if [[ -n "${1:-}" ]]; then
        info "Restarting service: $1"
        $COMPOSE_CMD restart "$1"
    else
        info "Restarting all services..."
        cmd_down
        cmd_up
    fi
}

cmd_status() {
    $COMPOSE_CMD ps
}

cmd_logs() {
    $COMPOSE_CMD logs --tail=100 -f "$@"
}

# The SEAD services are built from their checkouts here. Each image records which
# version of its checkout it was built from, passed in as <PREFIX>_SOURCE_VERSION
# (SBC_SOURCE_VERSION, ...), which compose.yml hands to the build as SOURCE_VERSION.
export_source_versions() {
    local service src_dir
    for service in "${RELEASE_SERVICES[@]}"; do
        set_release_selection_config "$service"
        src_dir="$(service_source_dir "$service")"
        [[ -d "$src_dir/.git" ]] || continue
        export "${ENV_REF_VAR%_RELEASE}_SOURCE_VERSION=$(git -C "$src_dir" describe --tags --always --dirty='*')"
    done
}

# Compose builds every buildable service in parallel and interleaves their output into
# one stream, so a failing step is printed without saying which Dockerfile it came from.
# These helpers turn that back into an actionable message: name the image, explain the
# failure where its shape is recognisable, and retry only when a retry can actually help.

# How many Dockerfiles contain the failing step. 1 means the image is pinpointed;
# anything else means the step text is not unique and only a serial rebuild can say
# which service it was.
FAILING_DOCKERFILE_MATCHES=0

# The step text in "building at STEP ..." (podman) or "ERROR ... RUN ..." (docker) is
# copied verbatim from the Dockerfile, so it can be grepped back to the file it came
# from. That is the mapping the interleaved output loses.
identify_failing_dockerfile() {
    local log="$1" step needle file matches=""
    FAILING_DOCKERFILE_MATCHES=0
    step="$(sed -n 's/.*building at STEP "\(.*\)".*/\1/p' "$log" | tail -n1)"
    [[ -n "$step" ]] || step="$(sed -n 's|.*process "/bin/sh -c \(.*\)" did not complete.*|RUN \1|p' "$log" | tail -n1)"
    [[ -n "$step" ]] || return 1

    info "Failing build step: ${step}"

    # Both engines flatten a multi-line RUN onto one line before printing it, so the
    # step text never matches the Dockerfile literally. Normalise both sides - drop
    # line continuations, collapse runs of whitespace - and compare those.
    needle="$(printf '%s' "${step#RUN }" | tr -s '[:space:]' ' ')"
    while IFS= read -r file; do
        if tr '\n' ' ' <"$file" | sed 's/\\ / /g' | tr -s '[:space:]' ' ' | grep -qF "$needle"; then
            matches+="  ${file#$SCRIPT_DIR/}"$'\n'
            FAILING_DOCKERFILE_MATCHES=$((FAILING_DOCKERFILE_MATCHES + 1))
        fi
    done < <(find "$SCRIPT_DIR" -name 'Dockerfile*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)

    if [[ "$FAILING_DOCKERFILE_MATCHES" -gt 1 ]]; then
        info "That step is not unique - it appears in:"
        printf '%s' "$matches" | while IFS= read -r m; do info "$m"; done
    elif [[ -n "$matches" ]]; then
        info "That step comes from:"
        printf '%s' "$matches" | while IFS= read -r m; do info "$m"; done
    else
        warn "No Dockerfile in this checkout contains that step - the image may be built"
        warn "from a source directory cloned during deployment."
    fi
}

# Distinguishes the two apt failures that look alike in the log but need opposite
# responses. A stale package index is worth one cache-free retry; a base image whose
# release has left Debian support is not - no amount of rebuilding brings the archive
# back, and only a newer FROM fixes it.
classify_build_failure() {
    local log="$1"
    if grep -qE "Release file .* (is not valid yet|expired)|Repository .* changed its|no longer has a Release file" "$log"; then
        echo "eol-base-image"
    elif grep -qE "404 +Not Found|Failed to fetch|has no installation candidate|Unable to locate package" "$log"; then
        echo "stale-apt-index"
    else
        echo "other"
    fi
}

compose_build() {
    local log_dir="$SCRIPT_DIR/logs"
    local log_file="${log_dir}/build_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$log_dir"
    export_source_versions

    if $COMPOSE_CMD build "$@" 2>&1 | tee "$log_file"; then
        rm -f "$log_file"
        return 0
    fi

    echo
    warn "Build failed. Full output: ${log_file}"
    identify_failing_dockerfile "$log_file" || \
        warn "Could not read the failing step from the build output."

    case "$(classify_build_failure "$log_file")" in
        stale-apt-index)
            # apt asked for a package version the mirror no longer carries, which means
            # the index it read is older than the archive. That happens when 'apt-get
            # update' sits in its own layer: the layer is reused while the archive moves
            # on. Discarding the cache re-runs the update against today's archive.
            warn "This looks like a stale apt index (a cached 'apt-get update' layer)."
            warn "Retrying without the build cache. This rebuilds every layer and is slow."
            COMPOSE_PARALLEL_LIMIT=1 $COMPOSE_CMD build --no-cache "$@" 2>&1 | tee "$log_file" && {
                rm -f "$log_file"
                warn "The retry succeeded, but the Dockerfile above still has the bug that"
                warn "caused this: put 'apt-get update' and 'apt-get install' in one RUN."
                return 0
            }
            die "Build still failed without the cache. See ${log_file}"
            ;;
        eol-base-image)
            error "The base image's Debian release is out of support: its archive is gone,"
            error "so this build cannot succeed as written. Rebuilding will not help."
            if [[ "$FAILING_DOCKERFILE_MATCHES" -ne 1 ]]; then
                # The step text appears in several Dockerfiles, so it does not say which
                # image failed. A serial rebuild fails again on the same step, but under
                # one service's name; cached layers make getting there quick.
                warn "Rebuilding serially to name the service - this will fail again."
                COMPOSE_PARALLEL_LIMIT=1 $COMPOSE_CMD build "$@" 2>&1 | tee "$log_file" || true
            fi
            die "Update the FROM line in the Dockerfile above, then build again. See ${log_file}"
            ;;
        *)
            # Nothing recognisable, so rebuild serially rather than guessing. Cached
            # layers make that near-instant for the images that already succeeded, and
            # the error then lands at the end of a single service's output.
            warn "Rebuilding one service at a time so the failure can be attributed..."
            COMPOSE_PARALLEL_LIMIT=1 $COMPOSE_CMD build "$@" 2>&1 | tee "$log_file" \
                || die "Build failed. See ${log_file}"
            ;;
    esac
}

cmd_build() {
    info "Building images..."
    compose_build "$@"
    success "Build complete."
}

cmd_shell() {
    local service="${1:-}"
    [[ -z "$service" ]] && die "Usage: $0 shell <service>"
    $COMPOSE_CMD exec "$service" /bin/bash 2>/dev/null \
        || $COMPOSE_CMD exec "$service" /bin/sh
}

# ──────────────────────────────────────────────────────────────────────────────
# Database / cache maintenance commands
# ──────────────────────────────────────────────────────────────────────────────
cmd_import_db() {
    local deploy_tag="${1:-}"
    info "Re-importing the PostgreSQL database..."
    run_database_import "$deploy_tag"
}

# Loads GADM administrative boundaries into the gadm schema, inside the postgresql
# container (which carries ogr2ogr for exactly this). The archive is fetched on first run
# and cached in the mounted data directory, so later runs re-use it.
run_gadm_import() {
    $COMPOSE_CMD exec -T \
        -e "GADM_DATA_DIR=${GADM_DATA_DIR}" \
        -e "PGPASSWORD=${DATABASE_PASSWORD}" \
        "$DB_IMPORT_SERVICE" bash -c \
        "${GADM_IMPORT_SCRIPT} --host postgresql --port 5432 --user ${DB_IMPORT_USER} --database ${DB_IMPORT_TARGET_DB} --drop"
}

# The fetch is over a gigabyte and the dissolve is the heaviest database work in the whole
# install, so this runs detached: everything else can finish and be seen to have worked,
# and this carries on in the background with its own log.
start_gadm_import_background() {
    local gadm_log_dir="$SCRIPT_DIR/logs"
    local gadm_log_file="${gadm_log_dir}/gadm_import_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$gadm_log_dir"

    info "Starting GADM boundary import in background..."
    nohup $COMPOSE_CMD exec -T \
        -e "GADM_DATA_DIR=${GADM_DATA_DIR}" \
        -e "PGPASSWORD=${DATABASE_PASSWORD}" \
        "$DB_IMPORT_SERVICE" bash -c \
        "${GADM_IMPORT_SCRIPT} --host postgresql --port 5432 --user ${DB_IMPORT_USER} --database ${DB_IMPORT_TARGET_DB} --drop" \
        >"$gadm_log_file" 2>&1 < /dev/null &
    local gadm_pid=$!
    success "GADM import started in background (PID: ${gadm_pid})."
    info "It downloads ~1.4 GB on first run and then loads levels 0-2; expect it to take a while."
    info "Follow progress with: tail -f ${gadm_log_file}"
}

start_preload_jas_background() {
    local preload_log_dir="$SCRIPT_DIR/logs"
    local preload_log_file="${preload_log_dir}/preload_jas_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$preload_log_dir"

    info "Starting JSON API Server cache preload in background..."
    nohup bash preload_jas.sh >"$preload_log_file" 2>&1 < /dev/null &
    local preload_pid=$!
    success "JAS cache preload started in background (PID: ${preload_pid})."
    info "Follow progress with: tail -f ${preload_log_file}"
}

cmd_import_gadm() {
    [[ $# -eq 0 ]] || die "Usage: $0 import-gadm"
    info "Importing GADM boundary data..."
    run_gadm_import
    success "GADM import complete."
}

cmd_preload_jas() {
    local mode="${1:-}"
    [[ $# -le 1 ]] || die "Usage: $0 preload-jas [--background]"

    case "$mode" in
        "" )
            info "Preloading JSON API Server MongoDB cache..."
            bash preload_jas.sh
            success "JAS preload complete."
            ;;
        --background|-b)
            start_preload_jas_background
            ;;
        *)
            die "Usage: $0 preload-jas [--background]"
            ;;
    esac
}

cmd_flush_cache() {
    info "Flushing JAS graph cache..."
    bash flush_jas_graph_cache.sh
}

# ──────────────────────────────────────────────────────────────────────────────
# Version reporting
# ──────────────────────────────────────────────────────────────────────────────
# "Version" means something different for each part of the stack, so each part is
# reported in its own terms: a git description for the services built from our own
# repositories, the applied sqitch tag for the database, and whatever the program
# itself reports for everything pulled ready-made.
#
# Checkout and container are shown side by side because they drift apart. In dev the
# source directories are bind-mounted, so the running code *is* the checkout; in prod
# it is baked into the image, and an image built before the last update runs an older
# release than the checkout suggests. That difference is the usual explanation for a
# deployment that behaves like a version nobody has any more.

# service | source directory in this repo | where that source sits in the container
SEAD_SERVICE_SPECS=(
    "client|sead_browser_client|/sead_browser_client"
    "json_api_server|json_api_server|/json_api_server"
    "sead_query_api|sead_query_api|/workspace"
    "sead_agent|sead_agent|/sead_agent"
    "postgresql_mcp|postgres_mcp|/app"
)

SUPPORTING_SERVICES=(router postgrest mongo redis_cache maria-db matomo mongo-express)

version_row()     { printf "  %-20s %-38s %s\n" "$1" "$2" "$3" | sed 's/[[:space:]]*$//'; }
version_heading() { echo; echo -e "${CYAN}$1${NC}"; }

compose_project_name() { echo "${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"; }

# The container currently running a compose service; empty when the service is down.
# Looked up by compose label rather than by name, which every compose implementation
# spells differently.
service_container() {
    $CONTAINER_TOOL ps \
        --filter "label=com.docker.compose.project=$(compose_project_name)" \
        --filter "label=com.docker.compose.service=$1" \
        --format '{{.Names}}' 2>/dev/null | head -n1
}

# Runs a command inside a service's container. Takes argv rather than a shell line
# because some images (postgrest) carry no shell at all; pass `sh -c '...'` explicitly
# where a pipeline is needed.
service_exec() {
    local service="$1"; shift
    local container
    container="$(service_container "$service" || true)"
    [[ -n "$container" ]] || return 1
    $CONTAINER_TOOL exec "$container" "$@" 2>/dev/null
}

# The image reference a service is running, and the day that image was built.
service_image() {
    $CONTAINER_TOOL ps \
        --filter "label=com.docker.compose.project=$(compose_project_name)" \
        --filter "label=com.docker.compose.service=$1" \
        --format '{{.Image}}' 2>/dev/null | head -n1
}

image_build_date() {
    local image="$1"
    [[ -n "$image" ]] || return 0
    $CONTAINER_TOOL image inspect "$image" --format '{{.Created}}' 2>/dev/null | cut -c1-10
}

short_image_name() { echo "${1#docker.io/}" | sed 's|^library/||'; }

# True when a host directory of this deployment is mounted into the service's
# container, i.e. the container runs the checkout live instead of a copy in the image.
service_mounts_source() {
    local container
    container="$(service_container "$1" || true)"
    [[ -n "$container" ]] || return 1
    $CONTAINER_TOOL inspect "$container" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -qx "${SCRIPT_DIR}/$2"
}

# git describe of a checkout, with a * when the working tree has uncommitted changes.
git_version() {
    local dir="$1" desc branch
    [[ -d "$dir/.git" ]] || return 1
    desc="$(git -C "$dir" describe --tags --always --dirty='*' 2>/dev/null || true)"
    [[ -n "$desc" ]] || return 1
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ "$branch" == "HEAD" ]] && branch="detached"
    echo "${desc} (${branch})"
}

# The `version` field of a package.json, without assuming node or jq is available.
read_pkg_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1
}

# What a checkout in this repo calls itself: its git description when it is a
# repository of its own, otherwise the version in its package.json.
source_version() {
    local dir="$1" version
    [[ -d "$dir" ]] || { echo "not present"; return; }
    version="$(git_version "$dir" || true)"
    [[ -n "$version" ]] || version="$(read_pkg_version "${dir}/package.json" || true)"
    echo "${version:-unknown}"
}

# The same question asked of the running container, which in prod holds a copy made
# when the image was built.
container_version() {
    local service="$1" path="$2" version
    # Baked in at build time by export_source_versions; images copy their source
    # without .git, so there is nothing to describe inside them
    version="$(service_exec "$service" printenv SOURCE_VERSION || true)"
    [[ -n "$version" ]] || version="$(service_exec "$service" sh -c "git -C '${path}' describe --tags --always --dirty='*' 2>/dev/null" || true)"
    [[ -n "$version" ]] || version="$(service_exec "$service" sh -c \
        "sed -n 's/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' '${path}/package.json' 2>/dev/null | head -n1" || true)"
    echo "$version"
}

# Version of a third-party service, asked of the program itself rather than read off
# the image tag - compose.yml pins exact tags, but router's nginx comes from its own build
# and an image already present may be one a looser tag pulled.
supporting_version() {
    case "$1" in
        router)        service_exec router sh -c 'nginx -v 2>&1' | sed -n 's|.*nginx/||p' ;;
        postgrest)     service_exec postgrest postgrest --version | sed -n 's/PostgREST //p' ;;
        mongo)         service_exec mongo mongod --version | sed -n 's/^db version v\{0,1\}//p' | head -n1 ;;
        redis_cache)   service_exec redis_cache redis-server --version | sed -n 's/.*v=\([0-9.]*\).*/\1/p' ;;
        maria-db)      service_exec maria-db sh -c 'mariadbd --version 2>/dev/null || mysqld --version' \
                           | sed -n 's/.*Ver \([0-9][^ ]*\).*/\1/p' | cut -d- -f1 ;;
        matomo)        service_exec matomo sh -c "sed -n \"s/.*VERSION = '\([^']*\)'.*/\1/p\" core/Version.php | head -n1" ;;
        mongo-express) service_exec mongo-express sh -c \
                           'sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" /app/package.json | head -n1' ;;
    esac
}

# Reads one value from the database. Fails quietly when postgresql is down.
psql_value() {
    service_exec postgresql psql -U "$DB_IMPORT_USER" -d "${DATABASE_NAME:-$DB_IMPORT_TARGET_DB}" -tAc "$1"
}

cmd_versions() {
    local engine_version compose_version image built version checked_out running note

    echo
    echo -e "${GREEN}SEAD deployment versions${NC}"

    # ── This deployment ──────────────────────────────────────────────────────
    version_heading "Deployment"
    version_row "sead-deployment" "$(source_version .)" \
        "project $(compose_project_name), ${DEPLOY_MODE:-dev} mode"
    engine_version="$($CONTAINER_TOOL --version 2>/dev/null | head -n1 || true)"
    compose_version="$($COMPOSE_CMD version --short 2>/dev/null | head -n1 || true)"
    version_row "container engine" "${engine_version:-unknown}" \
        "${compose_version:+compose ${compose_version}}"

    # ── The SEAD release, and anything running other than what it pins ───────
    version_heading "SEAD release"
    local release at_tag pinned ref_var service
    release="$(manifest_value SEAD_RELEASE)"
    if [[ -z "$release" ]]; then
        version_row "this checkout" "no release" "no ${RELEASE_MANIFEST}"
    else
        at_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
        version_row "this checkout" "$release" \
            "$([[ "$at_tag" == "$release" ]] && echo "at its tag" || echo "not at tag ${release}")"
        version_row "applied" "${SEAD_RELEASE:-none}" \
            "${SEAD_PREVIOUS_RELEASE:+previous ${SEAD_PREVIOUS_RELEASE}}"
        for service in "${RELEASE_SERVICES[@]}"; do
            set_release_selection_config "$service"
            ref_var="$ENV_REF_VAR"
            pinned="$(manifest_value "$ref_var")"
            if [[ "${!ref_var:-}" == "$pinned" ]]; then
                version_row "$service" "$pinned" "as released"
            else
                version_row "$service" "${!ref_var:-unset}" "not as released: ${release} pins ${pinned}"
            fi
        done
    fi

    # ── Services built from our own repositories ─────────────────────────────
    version_heading "SEAD services"
    version_row "" "checked out" "running"
    local spec dir path
    for spec in "${SEAD_SERVICE_SPECS[@]}"; do
        IFS='|' read -r service dir path <<< "$spec"
        checked_out="$(source_version "$dir")"

        if [[ -z "$(service_container "$service" || true)" ]]; then
            running="not running"
        elif service_mounts_source "$service" "$dir"; then
            # The container reads the checkout directly, so there is no second version
            # to report - only the reminder that a rebuild is not what updates it.
            running="live from checkout (bind mount)"
        else
            version="$(container_version "$service" "$path")"
            image="$(service_image "$service" || true)"
            built="$(image_build_date "$image" || true)"
            running="${version:-unknown}${built:+, image built ${built}}"
        fi

        version_row "$service" "$checked_out" "$running"
    done

    # ── The database and what has been loaded into it ────────────────────────
    version_heading "Database"
    if ! psql_value 'select 1' >/dev/null 2>&1; then
        version_row "PostgreSQL" "not running" ""
    else
        version="$(psql_value "select split_part(current_setting('server_version'), ' ', 1)" || true)"
        image="$(service_image postgresql || true)"
        built="$(image_build_date "$image" || true)"
        version_row "PostgreSQL" "${version:-unknown}" \
            "${DATABASE_NAME:-$DB_IMPORT_TARGET_DB}${built:+, image built ${built}}"

        # The schema's own version is the last sqitch tag applied by sead_change_control.
        if [[ "$(psql_value "select to_regclass('sqitch.tags') is not null" || true)" == "t" ]]; then
            version="$(psql_value 'select max(tag) from sqitch.tags' || true)"
            note="$(psql_value "select to_char(max(committed_at), 'YYYY-MM-DD') from sqitch.changes" || true)"
            pinned="$(manifest_value SEAD_CHANGE_CONTROL_RELEASE)"
            if [[ -n "$pinned" && "$version" != "$pinned" ]]; then
                note="${note:+deployed ${note}, }not as released: pins ${pinned}"
            else
                note="${note:+deployed ${note}}"
            fi
            version_row "schema" "${version:-untagged}" "$note"
        else
            version_row "schema" "not deployed" "no sqitch registry in this database"
        fi

        if [[ "$(psql_value "select to_regclass('gadm.adm_0') is not null" || true)" == "t" ]]; then
            note="$(psql_value "select (select count(*) from gadm.adm_0)||' countries, '
                || (select count(*) from gadm.adm_1)||' adm1, '
                || (select count(*) from gadm.adm_2)||' adm2'" || true)"
            version_row "GADM boundaries" "loaded" "$note"
        else
            version_row "GADM boundaries" "not loaded" "./deploy.sh import-gadm"
        fi
    fi
    version_row "sead_change_control" "$(source_version sead_change_control)" "checkout used for imports"

    # ── Everything pulled ready-made ─────────────────────────────────────────
    version_heading "Supporting services"
    for service in "${SUPPORTING_SERVICES[@]}"; do
        if [[ -z "$(service_container "$service" || true)" ]]; then
            version_row "$service" "not running" ""
            continue
        fi
        version="$(supporting_version "$service" || true)"
        image="$(service_image "$service" || true)"
        built="$(image_build_date "$image" || true)"
        note="$(short_image_name "$image")"
        [[ "$image" == *"/sead-"* || "$image" == *"sead_"* ]] && note="${note}${built:+, built ${built}}"
        version_row "$service" "${version:-unknown}" "$note"
    done
    echo
}

# ──────────────────────────────────────────────────────────────────────────────
# Remote targets — SSH identities for per-instance deployments
# ──────────────────────────────────────────────────────────────────────────────
remote_config_file() {
    echo "${SEAD_REMOTE_TARGETS_FILE:-${HOME}/.config/sead-deployment/targets.conf}"
}

expand_home_path() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        echo "$HOME"
    elif [[ "$path" == "~/"* ]]; then
        echo "${HOME}/${path#"~/"}"
    else
        echo "$path"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

require_remote_config() {
    local config
    config="$(remote_config_file)"
    [[ -f "$config" ]] || die "Remote target config not found: ${config}. Run '$0 remote init-config' first."
}

remote_target_sections() {
    local config
    config="$(remote_config_file)"
    [[ -f "$config" ]] || return 0
    awk '
        /^[[:space:]]*(#|;|$)/ { next }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            section=$0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            print section
        }
    ' "$config"
}

remote_target_value() {
    local target="$1"
    local key="$2"
    local config
    config="$(remote_config_file)"
    [[ -f "$config" ]] || return 0

    awk -v target="$target" -v wanted="$key" '
        function trim(value) {
            gsub(/^[[:space:]]+/, "", value)
            gsub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*(#|;|$)/ { next }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            section=$0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            next
        }
        section == target {
            equals=index($0, "=")
            if (equals == 0) {
                next
            }
            key=trim(substr($0, 1, equals - 1))
            value=trim(substr($0, equals + 1))
            if (key == wanted) {
                print value
                exit
            }
        }
    ' "$config"
}

remote_target_required_value() {
    local target="$1"
    local key="$2"
    local value
    value="$(remote_target_value "$target" "$key")"
    [[ -n "$value" ]] || die "Target '${target}' is missing required '${key}' in $(remote_config_file)."
    echo "$value"
}

remote_ssh_destination() {
    local target="$1"
    local ssh_host host user
    ssh_host="$(remote_target_value "$target" ssh_host)"
    if [[ -n "$ssh_host" ]]; then
        echo "$ssh_host"
        return
    fi

    host="$(remote_target_required_value "$target" host)"
    user="$(remote_target_value "$target" user)"
    if [[ -n "$user" && "$host" != *@* ]]; then
        echo "${user}@${host}"
    else
        echo "$host"
    fi
}

remote_ssh() {
    local target="$1"
    shift

    require_remote_config
    command -v ssh &>/dev/null || die "ssh is required for remote commands."

    local dest identity port
    dest="$(remote_ssh_destination "$target")"
    identity="$(remote_target_value "$target" identity_file)"
    port="$(remote_target_value "$target" port)"

    local ssh_opts=(-o BatchMode=yes)
    if [[ -n "$identity" ]]; then
        identity="$(expand_home_path "$identity")"
        [[ -f "$identity" ]] || die "Identity file for target '${target}' does not exist: ${identity}"
        ssh_opts+=(-i "$identity" -o IdentitiesOnly=yes)
    fi
    if [[ -n "$port" ]]; then
        ssh_opts+=(-p "$port")
    fi

    ssh "${ssh_opts[@]}" "$dest" "$@"
}

remote_deploy_command() {
    local target="$1"
    shift

    local path quoted_path remote_cmd arg
    path="$(remote_target_required_value "$target" path)"
    quoted_path="$(shell_quote "$path")"
    remote_cmd="cd ${quoted_path} && ./deploy.sh"
    for arg in "$@"; do
        remote_cmd+=" $(shell_quote "$arg")"
    done

    remote_ssh "$target" "$remote_cmd"
}

cmd_remote_init_config() {
    local config config_dir
    config="$(remote_config_file)"
    config_dir="$(dirname "$config")"

    if [[ -f "$config" ]]; then
        warn "Remote target config already exists: ${config}"
        return 0
    fi

    if [[ ! -d "$config_dir" ]]; then
        install -d -m 700 "$config_dir"
    fi
    umask 077
    cat > "$config" <<'EOF'
# SEAD remote deployment targets.
#
# Keep secrets and private keys out of this file. Prefer ssh_host aliases from
# ~/.ssh/config. If you do not use aliases, set host, user, and identity_file.

[prod]
name=browser.sead.se
role=stable production
ssh_host=sead-prod
path=/home/sead-browser/sead-deployment
domain=browser.sead.se

[super]
name=super.sead.se
role=next stable
ssh_host=sead-super
path=/home/sead-super/sead-deployment
domain=super.sead.se

[staging]
name=staging.sead.se
role=testing
ssh_host=sead-staging
path=/home/sead-staging/sead-deployment
domain=staging.sead.se
EOF
    chmod 600 "$config"
    success "Created ${config}"
    warn "Edit it to match the real SSH host aliases, Unix users, and checkout paths."
}

cmd_remote_targets() {
    require_remote_config

    local target name role domain dest path
    printf '%-10s %-18s %-18s %-24s %s\n' "TARGET" "NAME" "ROLE" "SSH" "PATH"
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        name="$(remote_target_value "$target" name)"
        role="$(remote_target_value "$target" role)"
        domain="$(remote_target_value "$target" domain)"
        dest="$(remote_ssh_destination "$target")"
        path="$(remote_target_value "$target" path)"
        printf '%-10s %-18s %-18s %-24s %s\n' "$target" "${name:-$domain}" "$role" "$dest" "$path"
    done < <(remote_target_sections)
}

cmd_remote_check() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "Usage: $0 remote check <target>"

    require_remote_config

    local path quoted_path domain
    path="$(remote_target_required_value "$target" path)"
    quoted_path="$(shell_quote "$path")"
    domain="$(remote_target_value "$target" domain)"

    info "Checking SSH access and deployment checkout for target '${target}'${domain:+ (${domain})}..."
    remote_ssh "$target" "set -e; echo \"remote-host=\$(hostname)\"; cd ${quoted_path}; echo \"deploy-path=\$(pwd)\"; test -x ./deploy.sh; ./deploy.sh versions"
}

cmd_remote() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        init-config) cmd_remote_init_config ;;
        targets|list) cmd_remote_targets ;;
        check) cmd_remote_check "$@" ;;
        status)
            [[ -n "${1:-}" ]] || die "Usage: $0 remote status <target>"
            remote_deploy_command "$1" status
            ;;
        versions)
            [[ -n "${1:-}" ]] || die "Usage: $0 remote versions <target>"
            remote_deploy_command "$1" versions
            ;;
        deploy)
            [[ -n "${1:-}" && -n "${2:-}" ]] || die "Usage: $0 remote deploy <target> <release>"
            # Started detached on the target, so a dropped connection does not stop it
            # halfway; this end only follows the log.
            remote_deploy_command "$1" release deploy "$2" --background
            remote_deploy_command "$1" release log --follow
            ;;
        logs)
            [[ -n "${1:-}" ]] || die "Usage: $0 remote logs <target>"
            remote_deploy_command "$1" release log --follow
            ;;
        ""|help|--help|-h)
            cat <<EOF
Usage: $0 remote <command> [args...]

Commands:
  init-config       Create $(remote_config_file) with prod/super/staging targets.
  targets           List configured remote targets.
  check <target>    Test SSH access, checkout path, and remote deploy.sh versions.
  status <target>   Run './deploy.sh status' on the target.
  versions <target> Run './deploy.sh versions' on the target.
  deploy <target> <release>
                    Start './deploy.sh release deploy <release>' detached on the
                    target, then follow its log. Interrupting this, or losing the
                    connection, leaves the deploy running.
  logs <target>     Follow the target's latest release deploy log, until it ends.

Targets are read from $(remote_config_file).
EOF
            ;;
        *) die "Unknown remote command: ${subcommand}" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
SEAD Deployment Utility (using: $CONTAINER_TOOL compose)

Usage: $0 <command> [args...]

Commands:
  install              Perform a fresh installation of the entire SEAD stack.
                       Clones repos, generates .env, builds images, starts
                       services, imports the database, and preloads JAS cache.
                       Prompts for unique per-instance values
                       (COMPOSE_PROJECT_NAME, DOMAIN, and published host ports)
                       so multiple stacks can safely share one host.
                       Installs the SEAD release in sead-release.env, or, if
                       you decline it, prompts for release refs for
                       'client' (SBC_RELEASE) and 'json_api_server'
                       (JAS_RELEASE), and 'sead_query_api'
                       (SEAD_QUERY_API_RELEASE).
                       If prod mode is chosen, compose.override.yml is
                       renamed to compose.override.yml.disabled.

  update <service>     Sync local source to the selected release ref (or pull
                       latest for non-release services), rebuild the image
                       without cache, and restart the service.
                                             For 'client', you'll be prompted for master, the 5 most
                                             recent GitHub releases, or any Git ref, and SBC_RELEASE
                                             in .env is updated.
                                             For 'json_api_server', you'll be prompted for main, the
                                             5 most recent GitHub releases, or any Git ref, and
                                             JAS_RELEASE in .env is updated.
                                             For 'sead_query_api', you'll be prompted for main, the
                                             5 most recent GitHub releases, or any Git ref, and
                                             SEAD_QUERY_API_RELEASE in .env is updated.
                       Examples:
                         $0 update client
                         $0 update json_api_server
                         $0 update sead_query_api
                         $0 update router

  build [service...]   Build (or rebuild) Docker images.
                       Omit service name to build all images.

  up [service...]      Start all services (or specific ones) in detached mode.
  down                 Stop and remove all containers.
  restart [service]    Restart all services, or just one named service.
  status               Show running status of all containers.
  versions             Report what is installed and running, and at which version:
                       the checked-out SEAD repositories, the version each running
                       container reports, the schema tag applied to the database,
                       and the third-party services behind it.
  release cut <YYYY-MM.N>
                       Make a new SEAD release: pick the tag each service is pinned
                       to, write sead-release.env, then commit and tag it.
  release deploy <YYYY-MM.N> [--background]
                       Check out that release of this repository, verify every
                       pinned tag and that .env has every variable it needs, then
                       build and start it. A database not at the schema tag the
                       release pins is rebuilt at it beside the one in use, then
                       swapped in (the old one is kept as sead_staging_prev). A new
                       PostgreSQL major version starts on a fresh data directory;
                       the old one is kept. --background runs it detached, logging
                       under logs/.
  release apply        Build and start the release this checkout carries, and
                       bring the database to it.
  release log [--follow]
                       Show (or follow) the latest background release deploy.
                       See releases/README.md.

  logs [service]       Tail logs (100 lines) from all services or a specific one.
  shell <service>      Open an interactive shell inside a running container.

  import-db [tag]      Re-import the PostgreSQL database via sead_change_control.
  import-gadm          Fetch and load GADM administrative boundaries into the gadm
                       schema. Runs in the foreground; install/import-db run it detached.
                       Prompts for a deploy tag (default: the release's, now
                       ${DEFAULT_DB_DEPLOY_TAG}) and tries
                       to list available tags from GitHub releases:
                       https://github.com/humlab-sead/sead_change_control
  preload-jas [--background]
                       Preload the JSON API Server MongoDB cache from PostgreSQL.
                       Use --background (or -b) to start it detached and return
                       immediately, writing logs under ./logs/.
  flush-cache          Flush the JAS graph cache via the REST API.

  generate-env         Generate .env (and sead_authority_service/.env) from
                       the example files, optionally importing matching values
                       from an old .env path, then auto-filling passwords and
                       secrets that remain empty.
  generate-env --update [<YYYY-MM.N>]
                       Add the variables .env lacks from .env-example (that
                       release's, when one is named), with the example's values,
                       generated secrets and prompted host ports. Nothing already
                       in .env changes; a backup is saved first.

  sp-keys [--force]    Generate the SAML Service Provider's signing and encryption
                       keys for DOMAIN into router/mounts/shibboleth-keys/, unless
                       they exist. Install runs this. Online, the certificates are
                       part of the server's SWAMID registration: replacing them
                       (--force) means updating the registration.

  rotate-secrets       Overwrite ALL passwords and secrets in the existing .env
                       with freshly generated cryptographically random values.
                       A timestamped backup (.env.bak.YYYYMMDD_HHMMSS) is saved
                       first. You will be prompted to confirm before any changes
                       are made.

  remote <command>     Manage remote SEAD targets over SSH. Start with:
                         $0 remote init-config
                         $0 remote targets
                         $0 remote check super

Environment variables:
  CONTAINER_TOOL       Override the container engine (podman | docker).
                       Default: podman if available, otherwise docker.
  SEAD_REMOTE_TARGETS_FILE
                       Override the remote target config path.
                       Default: ~/.config/sead-deployment/targets.conf
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────
load_env

command="${1:-}"
shift || true

case "$command" in
    install)      cmd_install ;;
    update)       cmd_update "$@" ;;
    build)        cmd_build "$@" ;;
    up)           cmd_up "$@" ;;
    down)         cmd_down "$@" ;;
    restart)      cmd_restart "${1:-}" ;;
    status)       cmd_status ;;
    versions)     cmd_versions ;;
    release)      cmd_release "$@" ;;
    logs)         cmd_logs "$@" ;;
    shell)        cmd_shell "$@" ;;
    import-db)    cmd_import_db "${1:-}" ;;
    import-gadm)  shift 2>/dev/null || true; cmd_import_gadm "$@" ;;
    preload-jas)  cmd_preload_jas "$@" ;;
    flush-cache)  cmd_flush_cache ;;
    generate-env)    cmd_generate_env "$@" ;;
    rotate-secrets)  cmd_rotate_secrets ;;
    sp-keys)         cmd_sp_keys "$@" ;;
    remote)          cmd_remote "$@" ;;
    help|--help|-h)  usage ;;
    "")           usage ;;
    *)            error "Unknown command: $command"; echo; usage; exit 1 ;;
esac
