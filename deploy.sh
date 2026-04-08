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
#   logs [service]       Tail logs (all services or specific one)
#   shell <service>      Open an interactive shell inside a container
#   import-db            Re-import the PostgreSQL database
#   preload-jas          Preload the JSON API Server MongoDB cache
#   flush-cache          Flush the JAS graph cache via the REST API
#   generate-env         Generate .env from .env-example
#   rotate-secrets       Overwrite ALL secrets in .env with fresh random values

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# Container engine detection
# ──────────────────────────────────────────────────────────────────────────────
detect_container_engine() {
    if command -v podman &>/dev/null; then
        echo "podman"
    elif command -v docker &>/dev/null; then
        echo "docker"
    else
        echo ""
    fi
}

CONTAINER_TOOL="${CONTAINER_TOOL:-$(detect_container_engine)}"
if [[ -z "$CONTAINER_TOOL" ]]; then
    echo "ERROR: Neither podman nor docker found. Please install one of them." >&2
    exit 1
fi

# In prod mode the override file is excluded so COMPOSE_CMD gets explicit -f flags.
# DEPLOY_MODE is read from .env (set during install); default to dev if unset.
# Can also be forced on the command line: DEPLOY_MODE=prod ./deploy.sh up
build_compose_cmd() {
    if [[ "${DEPLOY_MODE:-dev}" == "prod" ]]; then
        echo "$CONTAINER_TOOL compose -f docker-compose.yml"
    else
        echo "$CONTAINER_TOOL compose"
    fi
}
COMPOSE_CMD="$(build_compose_cmd)"

# Keep docker-compose.override.yml aligned with DEPLOY_MODE during install.
# In prod mode, the override file is renamed to ".disabled".
# In dev mode, a disabled override file is restored back to its active name.
sync_override_file_for_mode() {
    local override_file="docker-compose.override.yml"
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

# Database import defaults
SEAD_CHANGE_CONTROL_REPO="humlab-sead/sead_change_control"
DEFAULT_DB_DEPLOY_TAG="@2026.04"
DB_IMPORT_TARGET_DB="sead_staging"
DB_IMPORT_USER="sead_master"
DB_IMPORT_SERVICE="postgresql"

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

    # Rebuild COMPOSE_CMD now that DEPLOY_MODE may have been loaded/overridden.
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
            source_path="$HOME/${source_path#~/}"
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
cmd_generate_env() {
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

    local api_url="https://api.github.com/repos/${repo}/releases?per_page=100"
    local response http_code release_json

    if ! response="$(curl -sS -L -w $'\n%{http_code}' "$api_url")"; then
        warn "Failed to fetch release list from ${api_url} (network/curl error)."
        return 1
    fi

    http_code="${response##*$'\n'}"
    release_json="${response%$'\n'*}"

    if ! [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
        warn "Failed to fetch release list for ${repo}: unexpected HTTP status '${http_code}'."
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
            warn "Failed to fetch release list for ${repo} (HTTP ${http_code}): ${api_message}"
        else
            warn "Failed to fetch release list for ${repo} (HTTP ${http_code})."
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
        warn "No release tags found in GitHub response for ${repo}."
        return 1
    fi
    printf '%s\n' "${tags[@]}"
}

# Prompt the operator to choose a ref to deploy.
# Includes the primary branch and available GitHub release tags.
# Usage: prompt_release_ref <service_name> <repo> <primary_branch>
prompt_release_ref() {
    local service_name="$1"
    local repo="$2"
    local primary_branch="$3"

    [[ -n "$service_name" && -n "$repo" && -n "$primary_branch" ]] || die "prompt_release_ref called with missing arguments."

    SELECTED_RELEASE_REF=""

    local options=("$primary_branch")
    local releases=()

    if mapfile -t releases < <(fetch_github_release_tags "$repo") && [[ ${#releases[@]} -gt 0 ]]; then
        options+=("${releases[@]}")
    else
        warn "Could not fetch release list from GitHub for ${repo}. Falling back to '${primary_branch}' only."
    fi

    echo
    echo -e "${CYAN}Select ${service_name} release to deploy:${NC}"
    local idx
    for idx in "${!options[@]}"; do
        if [[ "${options[$idx]}" == "$primary_branch" ]]; then
            echo "  $((idx + 1))) ${options[$idx]} (branch)"
        else
            echo "  $((idx + 1))) ${options[$idx]} (release)"
        fi
    done

    local choice selected
    while true; do
        read -rp "Enter choice [1-${#options[@]}] (default: 1 ${primary_branch}): " choice
        choice="${choice:-1}"

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            selected="${options[$((choice - 1))]}"
            break
        fi

        echo "Please enter a number between 1 and ${#options[@]}."
    done

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
    $COMPOSE_CMD exec "$DB_IMPORT_SERVICE" bash -lc "git -C /sead_change_control pull --ff-only"

    info "Running database import command inside the ${DB_IMPORT_SERVICE} container..."
    $COMPOSE_CMD exec "$DB_IMPORT_SERVICE" bash -lc \
        "cd /sead_change_control && ./bin/deploy-staging --port 5432 --user ${DB_IMPORT_USER} --create-database --on-conflict drop --source-type empty --target-db-name ${DB_IMPORT_TARGET_DB} --deploy-to-tag '${deploy_tag}' --ignore-git-tags --host postgresql"

    info "Applying extensions, passwords, and grants..."
    $COMPOSE_CMD exec -T "$DB_IMPORT_SERVICE" psql -h postgresql -U "$DB_IMPORT_USER" -d "$DB_IMPORT_TARGET_DB" -v ON_ERROR_STOP=1 <<-EOSQL
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

    success "Database import complete."
}

# ──────────────────────────────────────────────────────────────────────────────
# install command
# ──────────────────────────────────────────────────────────────────────────────
cmd_install() {
    info "Starting fresh SEAD installation using $CONTAINER_TOOL"

    # Prerequisites
    for tool in git curl; do
        command -v "$tool" &>/dev/null || die "Required tool '$tool' not found. Please install it."
    done

    # Ask for deployment mode
    echo
    echo -e "${CYAN}Select deployment mode:${NC}"
    echo "  1) prod  — production build, docker-compose.override.yml is disabled"
    echo "  2) dev   — development mode, docker-compose.override.yml is active"
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

    # Generate .env if not already present
    cmd_generate_env

    [[ -f .env ]] || die ".env is missing. Run './deploy.sh generate-env' to create it."

    # Let the operator choose release refs for services that support release-based deploys.
    select_and_apply_release_ref "client"
    select_and_apply_release_ref "json_api_server"

    # Reload env so variables (DOMAIN, DATABASE_USER, etc.) are available in this shell
    load_env

    echo
    warn "Please review .env now (especially DOMAIN and COMPOSE_PROJECT_NAME)."
    warn "Press ENTER to continue with the build, or Ctrl-C to abort."
    read -r

    # Pull image-based services explicitly before local builds.
    pull_non_build_images

    # Build all images
    info "Building Docker images (this may take several minutes)..."
    $COMPOSE_CMD build
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

    # Preload JSON API Server MongoDB cache
    info "Preloading JSON API Server cache (this may take a long time)..."
    bash preload_jas.sh
    success "JAS cache preloaded."

    # Final restart so all services pick up the populated database
    info "Restarting all services..."
    cmd_down
    $COMPOSE_CMD up -d
    success "Stack restarted."

    # Re-load env to get fresh DOMAIN / WEB_PORT values
    load_env
    echo
    success "Installation complete!"
    info "The stack should now be available at http://${DOMAIN:-localhost}:${WEB_PORT:-80}"
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

cmd_update() {
    local service="${1:-}"
    [[ -z "$service" ]] && die "Usage: $0 update <service>"

    info "Updating service: $service"

    if select_and_apply_release_ref "$service"; then
        load_env
    fi

    local src_dir
    src_dir=$(service_source_dir "$service")
    if [[ -z "$RELEASE_REPO" && -n "$src_dir" && -d "$src_dir/.git" ]]; then
        info "Pulling latest code in $src_dir ..."
        git -C "$src_dir" pull --recurse-submodules
        success "Code updated in $src_dir"
    elif [[ -z "$RELEASE_REPO" ]]; then
        info "No local source directory for '$service' — image will be rebuilt from its Dockerfile."
    fi

    info "Rebuilding image for $service (no cache)..."
    $COMPOSE_CMD build --no-cache "$service"
    success "Image rebuilt for $service."

    info "Restarting $service ..."
    $COMPOSE_CMD up -d --force-recreate "$service"
    success "Service '$service' updated and restarted."
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

cmd_build() {
    info "Building images..."
    $COMPOSE_CMD build "$@"
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

cmd_preload_jas() {
    info "Preloading JSON API Server MongoDB cache..."
    bash preload_jas.sh
    success "JAS preload complete."
}

cmd_flush_cache() {
    info "Flushing JAS graph cache..."
    bash flush_jas_graph_cache.sh
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
                       During install, you'll be prompted for release refs for
                       'client' (SBC_RELEASE) and 'json_api_server'
                       (JAS_RELEASE).
                       If prod mode is chosen, docker-compose.override.yml is
                       renamed to docker-compose.override.yml.disabled.

  update <service>     Pull latest code (if a local repo exists), rebuild the
                       image without cache, and restart the service.
                       For 'client', you'll be prompted for a GitHub release
                       tag (or master), and SBC_RELEASE in .env is updated.
                       For 'json_api_server', you'll be prompted for a GitHub
                       release tag (or main), and JAS_RELEASE in .env is updated.
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
  logs [service]       Tail logs (100 lines) from all services or a specific one.
  shell <service>      Open an interactive shell inside a running container.

  import-db [tag]      Re-import the PostgreSQL database via sead_change_control.
                       Prompts for a deploy tag (default: @2026.04) and tries
                       to list available tags from GitHub releases:
                       https://github.com/humlab-sead/sead_change_control
  preload-jas          Preload the JSON API Server MongoDB cache from PostgreSQL.
  flush-cache          Flush the JAS graph cache via the REST API.

  generate-env         Generate .env (and sead_authority_service/.env) from
                       the example files, optionally importing matching values
                       from an old .env path, then auto-filling passwords and
                       secrets that remain empty.

  rotate-secrets       Overwrite ALL passwords and secrets in the existing .env
                       with freshly generated cryptographically random values.
                       A timestamped backup (.env.bak.YYYYMMDD_HHMMSS) is saved
                       first. You will be prompted to confirm before any changes
                       are made.

Environment variables:
  CONTAINER_TOOL       Override the container engine (podman | docker).
                       Default: podman if available, otherwise docker.
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
    logs)         cmd_logs "$@" ;;
    shell)        cmd_shell "$@" ;;
    import-db)    cmd_import_db "${1:-}" ;;
    preload-jas)  cmd_preload_jas ;;
    flush-cache)  cmd_flush_cache ;;
    generate-env)    cmd_generate_env ;;
    rotate-secrets)  cmd_rotate_secrets ;;
    help|--help|-h)  usage ;;
    "")           usage ;;
    *)            error "Unknown command: $command"; echo; usage; exit 1 ;;
esac
