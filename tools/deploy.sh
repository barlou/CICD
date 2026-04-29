#!/bin/bash
set -euo pipefail 

# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — runs on the server, sourced context from deploy_env.sh
#
# Directory structure managed:
#   ~/deployments/
#   ├── jars/              shared jars   — version pinned, skip if up to date
#   ├── utils/             TOOLS repo    — version pinned, skip if up to date
#   ├── airflow/           Airflow repo  — version pinned, skip if up to date
#   └── method/
#       └── business/      app method/   — always replaced
#   ~/deployments/<module>/
#       ├── config/        rendered config.json (from template + SSM)
#       ├── src/
#       └── tests/
# ─────────────────────────────────────────────────────────────────────────────

# Source runtime context from deploy_env.sh 
if [ ! -f ~/deploy_env.sh ]; then 
    echo "::error::deploy_env.sh not found in home directory"
    exit 1
fi

source ~/deploy_env.sh 

echo "=== Deployment starting ==="
echo "  Module:        $MODULE_NAME"
echo "  Environment:   $ENVIRONMENT"
echo "  Deployment ID: $DEPLOYMENT_ID"
echo "  SSM prefix:    $SSM_PREFIX"
echo ""
echo "  need jars:    $NEED_JARS,     skip jars:    ${SKIP_JARS:-false}"
echo "  need tools:   $NEED_TOOLS,    skip tools:   $SKIP_TOOLS"
echo "  need airflow: $NEED_AIRFLOW,  skip airflow: $SKIP_AIRFLOW"
echo "  need method:  $NEED_METHOD"

# Paths 
ARCHIVE="${MODULE_NAME}_deployment.tar.gz"
TEMP_DIR=~/temp_deployment_"$DEPLOYMENT_ID"
DEPLOY_BASE=~/deployments
MODULE_DIR="$DEPLOY_BASE/$MODULE_NAME"
LOG_FILE="/tmp/deploy_${MODULE_NAME}_${DEPLOYMENT_ID}.log"

# Trap - cleanup temp on exit regardless of success or failure 
cleanup() {
    echo "Cleaning up temp files..."
    rm -rf "$TEMP_DIR"
    rm -f ~/deploy_env.sh ~/deploy.sh ~/"$ARCHIVE"
}
trap cleanup EXIT

# Logging - tee all output to log file for verigy.yml to read 
exec > >(tee -a "$LOG_FILE") 2>&1

# Extract archive 
echo ""
echo "--- Extracting archive ---"
mkdir -p "$TEMP_DIR" "$DEPLOY_BASE"
tar -xzf ~/"$ARCHIVE" -C "$TEMP_DIR"

DEPLOY_ROOT="$TEMP_DIR/deployment"

echo "Archive contents:"
find "$DEPLOY_ROOT" -maxdepth 2 -type d | sort

# Locate module folder (case-insensitive)
MODULE_SOURCE=$(find "$DEPLOY_ROOT" -maxdepth 1 -type d -iname "$MODULE_NAME" | head -n 1)

if [ -z "$MODULE_SOURCE" ]; then
    echo "::error::Module folder '$MODULE_NAME' not found in archive"
    echo "Available folders:"
    find "$DEPLOY_ROOT" -maxdepth 1 -type d 
    exit 1
fi

echo "Module source: $MODULE_SOURCE"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# Fetch a single parameter from AWS SSM
# Fails loudly if the parameter is missing or returns empty —
# the original `|| echo ""` silently substituted empty strings into config.json.
fetch_ssm() {
    local param="$1"
    local value ssm_err
    if ! value=$(
        aws ssm get-parameter \
            --name            "$param" \
            --with-decryption \
            --region          "$SSM_REGION" \
            --query           "Parameter.value" \
            --output          text \
            2>/tmp/ssm_err_$$  
    ); then
        ssm_err=$(cat /tmp/ssm_err_$$ 2>/dev/null || true)
        rm -f /tmp/ssm_err_$$
        echo "::error::Failed to fetch SSM parameter: $param"
        echo "  AWS: $ssm_err"
        echo "  Run: python3 setup_ssm.py --env $ENVIRONMENT"
        exit 1 
    fi 
    rm -f /tmp/ssm_err_$$

    if [ -z "$value" ]; then 
        echo "::error::SSM parameter is empty: $param"
        exit 1
    fi

    printf '%s' "$value"
}

# Render config.template.json → config.json substituting {{ PLACEHOLDER }} tokens.
# Values come from env vars exported by fetch_all_secrets().
#
# Why Python and not sed?
#   sed treats `/`, `&`, `\` as special in the replacement string — a password
#   containing any of those silently corrupts the output. Python str.replace()
#   is byte-literal and handles any character safely.
#
# Values are passed via RENDER_SECRETS_JSON (env var) not as CLI args,
# so they don't appear in `ps aux` output.
render_config() {
    local template="$1"
    local output="$2"

    if [ ! -f "$template" ]; then
        echo "WARNING: No config template at $template - skipping render"
        return 0
    fi

    python3 - "$template" "$output"<<'PYEOF'
import json, re, os, sys

template_path = sys.argv[1]
output_path   = sys.argv[2]

with open(template_path, "r", encoding="utf-8") as fn:
    content = fn.read()

# Always-available substitutions
content = content.replace("{{ MODULE }}", os.environ.get("MODULE_NAME", ""))
content = content.replace("{{ DEPLOYMENT_DATE}}", os.environ.get("DEPLOYMENT_DATE", ""))

# Dynamic substitutions - every {{ KEY }} resolved from env 
placeholders = set(re.findall(r'\{\{\s*(\w+)\s*\}\}', content))
missing = []

for key in placeholders:
    value = os.environ.get(key, "")
    if not value:
        missing.append(key)
    else:
        content = content.replace("{{ " + key + " }}", value)
        content = content.replace("{{" + key + "}}", value)

if missing: 
     for m in missing: 
        print(f"WARNING: placeholders {{{m}}} has no value - check SSM path")
    sys.exit(1)

# Validate rendered output is valid JSON
try:
    json.loads(content)
except json.JSONDecodeError as e:
    print(f"ERROR: Rendered config.json is not valid JSON: {e}")
    sys.exit(1)

with open(output_path,  "w") as f: 
    f.write(content)

os.chmod(output_path, 0o600)
print(f"config.json written to {output_path}")
PYEOF
}

# Fetch all secrets from SSM and export them into the environment 
# so render_config() can resolve every placeholders 
fetch_all_secrets() {
    echo "--- Fetching secrets from SSM: ${SSM_PREFIX} ---"

    if [ -z "${SECRET_MAP_JSON:-}"] || ["$SECREt_MAP" == "{}" ]; then
        echo "::error::SECRET_MAP_JSON is empty."
        echo "  Check cicd.config.yml → secrets_map is declared"
        exit 1
    fi

    # Core secrets - extend this list as your template grows 
    # Pattern: export PLACEHOLDER_NAME=$(fetch_ssm "$SSM_PREFIX/ssm_key")
    export DEPLOYMENT_DATE
    DEPLOYMENT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    export MODULE="$MODULE_NAME"

    # Parse SECRET_MAP_JSON and fetch each secret dynamically
    # SECRET_MAP_JSON = {"PLACEHOLDER": "relative/ssm/path", ...}
    # Full SSM path = $SSM_PREFIX/$relative_path
    # = /$module/$environment/relative/path
    local = missing()

    while IFS=$'\t' read -r placeholder relative_path; do
        local ssm_path="$SSM_PREFIX/$relative_path"
        local value 

        value=$(fetch_ssm "$ssm_path") || {
            missing+=(" ❌ $placeholder → $ssm_path"
            continue)
        }

        export "$placeholder=$value"
        echo "  [OK] $placeholder ← $ssm_path"
    done < <(python3 -c "
import json, sys

try:
    secrets_map = json.loads('''$SECRET_MAP_JSON''')
except json.JSONDecodeError as e:
    printf(f'::error::SECRET_MAP_JSON is not valid JSON; {e}', file=sys.stderr)
    sys.exit(1)

for placeholder, relative_path in secrets_map.items():
    print(f'{placeholder}\t{relative_path}')
")
    if [ ${#missing[@]} -gt 0 ];
        echo ""
        echo "::error::Failed to fetch ${#missing[@]} secret(s) from SSM:"
        for m in "${#missing[@]}"; do
            echo "$m"
        done
        echo ""
        echo "To provision missing parameters, run:"
        echo "  python3 bootstrap.py --env $ENVIRONMENT --config cicd.config.yml"
        exit 1
    fi

    local count 
    count=$(python3 -c "import json, print(len(json.loads('''SECRET_MAP_JSON''')))")
}

# Backup of modules / airflow / tools - utils
create_backup () {
    echo "--- Creating backup before deploy ---"
    local backup_dir="$DEPLOY_BASE/.backups/$DEPLOYMENT_ID"
    mkdir -p "$backup_dir"

    # Backup module directory 
    if [ -d "$MODULE_DIR" ]; then 
        cp -r "$MODULE_DIR" "$backup_dir/module"
        echo "  [OK] module backed up"
    fi

    # Backup method/business 
    if [ -d "$DEPLOY_BASE/method/business" ]; then
        cp -r "$DEPLOY_BASE/method/business" "$backup_dir/method_business"
        echo "  [OK] method/business backed up"
    fi

    # Backup VERSION files only for jars/utils/airflow
    [ -f "$DEPLOY_BASE/jars/VERSION" ] && cp "$DEPLOY_BASE/jars/VERSION" "$backup_dir/jars_VERSION"
    [ -f "$DEPLOY_BASE/utils/VERSION" ] && cp "$DEPLOY_BASE/utils/VERSION" "$backup_dir/utils_VERSION"
    [ -f "$DEPLOY_BASE/airflow/VERSION" ] && cp "$DEPLOY_BASE/airflow/VERSION" "$backup_dir/airflow_VERSION"
    
    # Backup full airflow dir if being updated
    if [[ "$NEED_AIRFLOW" == "true" && "$SKIP_AIRFLOW" != "true" && -d "$DEPLOY_BASE/airflow" ]]; then
        cp -r "$DEPLOY_BASE/airflow" "$backup_dir/airflow"
        echo "  [OK] airflow backed up"
    fi

    echo "  Backup stored at: $backup_dir"
}

# Write VERSION file and log it 
write_version() {
    local dir="$1"
    local version="$2"
    echo "$version" > "$dir/VERSION"
    echo "  VERSION=$version written do dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMPONENT INSTALLS
# ─────────────────────────────────────────────────────────────────────────────

# jars - 
# _build.yml already did the version check - if jars.tar.gz is in the archive 
# it means it needs installing. VERSION file written after succesful extract 
install_jars() {
    local source="$DEPLOY_ROOT/jars.tar.gz"

    if [[ "$NEED_JARS" != "true" ]]; then 
        echo "  [SKIP] jars not required"
        return 0
    fi

    if [ ! -f "$source" ]; then 
        echo "  [SKIP] jars.tar.gz not in archive - server already up to date"
        return 0
    fi

    echo "--- Installing jars ---"
    mkdir -p "$DEPLOY_BASE/jars"
    tar -xzf "$source" -C "$DEPLOY_BASE"
    write_version "$DEPLOY_BASE/jars" "$JARS_VERSION"
    echo "  [OK] jars installed at version $JARS_VERSION"
}

# tools/utils 
# _build.yml already did the version check - if utils/ is in the archive 
# it means it needs installing 
install_tools() {
    local source="$DEPLOY_ROOT/utils"

    if [[ "$NEED_TOOLS" != "true" || "$SKIP_TOOLS" == "true" ]]; then 
        echo "  [SKIP] tools/utils - version $TOOLS_VERSION already on server"
        return 0
    fi

    if [ ! -d "$source" ]; then
        echo "  [SKIP] utils/ not in archive"
        return 0
    fi

    echo "--- Installing tools/utils ---"
    rm -rf "$DEPLOY_BASE/utils"
    cp -r "$source" "$DEPLOY_BASE/utils"
    write_version "$DEPLOY_BASE/utils" "$TOOLS_VERSION"
    echo "  [OK] utils installed at version $TOOLS_VERSION"
}

# Airflow
install_airflow() {
    local source="$DEPLOY_ROOT/airflow"

    if [[ "$NEED_AIRFLOW" != "true" || "$SKIP_AIRFLOW" == "true" ]]; then 
        echo "  [SKIP] airflow - version $AIRFLOW_VERSION already on server"
        return 0
    fi

    if [ ! -d "$source" ]; then 
        echo "  [SKIP] airflow/ not present in archive"
        return 0
    fi

    echo "--- Installing Airflow ---"
    rm -rf "$DEPLOY_BASE/airflow"
    cp -r "$source" "$DEPLOY_BASE/airflow"
    write_version "$DEPLOY_BASE/airflow" "$AIRFLOW_VERSION"

    # run airflow setup if the repo provide a setup script
    if [ -f "$DEPLOY_BASE/airflow/setup.sh" ]; then 
        echo "Running airflow/setup.sh..."
        chmod +x "$DEPLOY_BASE/airflow/setup.sh"
        bash "$DEPLOY_BASE/airflow/setup.sh" "$AIRFLOW_ID" "$ENVIRONMENT"
    fi

    echo "  [OK] airflow installed at version $AIRFLOW_VERSION (instance: $AIRFLOW_ID)"
}

# method/business
install_method() {
    local source="$DEPLOY_ROOT/method/business"

    if [[ "$NEED_METHOD" != "true" ]]; then 
        echo "  [SKIP] method not required"
        return 0
    fi

    if [ ! -d "$source" ]; then 
        echo "WARNING: method/business not found in archive"
        return 0
    fi 

    echo "--- Installing method/business (always refresh) ---"
    rm -rf "$DEPLOY_BASE/method/business"
    mkdir -p "$DEPLOY_BASE/method"
    cp -r "$source" "$DEPLOY_BASE/method/business"
    echo "  [OK] method/business deployed"
}

install_module() {
    echo "--- Installing module: $MODULE_NAME ---"

    rm -rf "$MODULE_DIR"
    cp -r "$MODULE_SOURCE" "$MODULE_DIR"

    # Render config.json from template using SSM-fetched access
    local template="$MODULE_DIR/config/config.template.json"
    local output="$MODULE_DIR/config/config.json"

    render_config "$template" "$output"

    # Also render config in method/business subdirs if present 
    for folder in Logs Result Archive; do
        local method_tmpl="$DEPLOY_BASE/method/business/$folder/config/config.template.json"
        local method_out="$DEPLOY_BASE/method/business/$folder/config/config.json"
        if [ -f "$method_tmpl" ]; then 
            render_config "$method_tmpl" "$method_out"
        fi
    done

    echo "  [OK] module $MODULE_NAME deployed to $MODULE_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTE
# ─────────────────────────────────────────────────────────────────────────────

fetch_all_secrets
create_backup
install_jars
install_tools
install_airflow
install_method
install_module


# Final structure 
echo ""
echo "=== Final deployment structure ==="
find "$DEPLOY_BASE" -maxdepth 3 -type d | sort 

# Success marker -  verify.yml checks for this string in the log 
echo ""
echo "DEPLOYMENT COMPLETED SUCCESSFULLY"
