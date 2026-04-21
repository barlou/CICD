#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# rollback.sh — restores previous deployment state on the server
#
# Called automatically by _verify.yml when verification fails.
# Reads context from deploy_env.sh (same as deploy.sh).
#
# Rollback strategy per component:
#   method/business → restored from .backup copy taken before deploy
#   jars/           → VERSION file restored, directory stays (idempotent)
#   utils/          → VERSION file restored, directory stays (idempotent)
#   airflow/        → VERSION file restored, setup.sh re-run if exists
#   module dir      → restored from .backup copy taken before deploy
# ─────────────────────────────────────────────────────────────────────────────

if [ ! -f ~/deploy_env.sh ]; then
    echo "::error::deploy_env.sh not found - cannot determine rollback context"
    exit 1
fi

source ~/deploy_env.sh 

DEPLOY_BASE=~/deployments
MODULE_DIR="$DEPLOY_BASE/$MODULE_NAME"
LOG_FILE="/tmp/rollback_${MODULE_NAME}_${DEPLOYMENT_ID}.log"
BACKUP_DIR="$DEPLOY_BASE/.backups/$DEPLOYMENT_ID"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Rollback starting ==="
echo "  Module      : $MODULE_NAME"
echo "  Deployment  : $DEPLOYMENT_ID"
echo "  Backup dir  : $BACKUP_DIR"

# Validate backup exists
if [ ! -d "$BACKUP_DIR" ]; then 
    echo "::error::No backup found at $BACKUP_DIR - cannot rollback"
    echo "This means deploy.sh didn't complete the backup step"
    echo "Manual intervention required"
    exit 1
fi

echo "Backup found:"
find "$BACKUP_DIR" -maxdepth 2 -type d | sort

ROLLBACK_ERRORS=()

# Rollback module directory 
rollback_module() {
    local backup="$BACKUP_DIR/module"

    if [ ! -d "$backup" ]; then
        echo "  [SKIP] No module backup found - may have been first deploy"
        return 0
    fi

    echo "--- Rolling back module: $MODULE_NAME ---"
    rm -rf "$MODULE_DIR"
    cp -r "$backup" "$MODULE_DIR"
    echo "  [OK] module restored from backup"
}

# Rollback method/business
rollback_method() {
    local backup="$BACKUP_DIR/method_business"
    
    if [[ "$NEED_METHOD" != "true" ]]; then
        echo "  [SKIP] method not required"
        return 0
    fi 

    if [ ! -d "$backup" ]; then
        echo "  [SKIP] No method/business backup found"
        return 0
    fi

    echo "--- Rolling back method/business ---"
    rm -rf "$DEPLOY_BASE/method/business"
    mkdir -p "$DEPLOY_BASE/method"
    cp -r "$backup" "$DEPLOY_BASE/method/business"
    echo "  [OK] method/business restored from backup"
}

# Rollback jars version 
# Jars files themselves are not removed - only version is rolled back
# so the next deploy all will re-install the correct version 
rollback_jars() {
    local backup_version="$BACKUP_DIR/jars_VERSION"

    if [[ "$NEED_JARS" != "true" ]]; then
        echo "  [SKIP] jars not required"
        return 0
    fi

    if [ ! -f "$backup_version" ]; then
        echo "  [SKIP] No jars VERSION backup - was first install"
        return 0
    fi

    echo "--- Rolling back jars VERSION ---"
    PREV_VERSION=$(cat "$backup_version")
    echo "$PREV_VERSION" > "$DEPLOY_BASE/jars/VERSION"
    echo "  [OK] jars VERSION restored to $PREV_VERSION"
    echo "  NOTES: Next deploy will re-install jars at required version"
}

# Rollback utils VERSION
rollback_tools() {
    local backup_version="$BACKUP_DIR/utils_VERSION"

    if [[ "$NEED_TOOLS" != "true" || "$SKIP_TOOLS" == "true" ]]; then
        echo "  [SKIP] tools not changed in this deployment"
        return 0 
    fi

    if [ ! -f "$backup_version" ]; then
        echo "  [SKIP] No utils VERSION backup - was first install"
        return 0
    fi

    echo "--- Rolling back utils VERSION ---"
    PREV_VERSION=$(cat "$backup_version")
    echo "$PREV_VERSION" > "$DEPLOY_BASE/utils/VERSION"
    echo "  [OK] utils VERSION restored to $PREV_VERSION"
}

# Rollback airflow VERSION
rollback_airflow() {
    local backup_version="$BACKUP_DIR/airflow_VERSION"
    local backup_dir="$BACKUP_DIR/airflow"

    if [[ "$NEED_AIRFLOW" != "true" || "$SKIP_AIRFLOW" == "true" ]]; then 
        echo "  [SKIP] airflow not changed in this deployment"
        return 0
    fi

    if [ ! -d "$backup_dir" ]; then
        echo "  [SKIP] No airflow backup - was first install"
        return 0
    fi 

    echo "--- Rolling back airflow ---"
    rm -rf "$DEPLOY_BASE/airflow"
    cp -r "$backup_dir" "$DEPLOY_BASE/airflow"

    if [ -f "$backup_version" ]; then 
        PREV_VERSION=$(cat "$backup_version")
        echo "$PREV_VERSION" > "$DEPLOY_BASE/airflow/VERSION"
        echo "  [OK] airflow restored to version $PREV_VERSION" 
    fi

    # Re-run setup if present 
    if [ -f "$DEPLOY_BASE/airflow/setup.sh" ]; then
        echo "  Re-running airflow/setup.sh .."
        chmod +x "$DEPLOY_BASE/airflow/setup.sh"
        bash "$DEPLOY_BASE/airflow/setup.sh" "$AIRFLOW_ID" "$ENVIRONMENT" || \
            echo "  WARNING: airflow/setup.sh failed during rollback"
    fi
}

# Execute rollback
rollback_module
rollback_method
rollback_jars
rollback_tools
rollback_airflow

if [ ${#ROLLBACK_ERRORS[@]} -gt 0 ]; then 
    echo "=== Rollback completed with errors ==="
    for e in "${ROLLBACK_ERRORS[@]}"; do
        echo "  ::warning::$e"
    done 
else
    echo "=== Rollback completed cleanly ==="
fi

# Cleanup backup after succesfull rollback 
echo ""
echo "--- Cleaning ---"
rm -rf "$BACKUP_DIR"
echo "  Backup removed: $BACKUP_DIR"

echo ""
echo "ROLLBACK COMPLETED SUCCESSFULLY"
echo "Previous state has been restored for $MODULE_NAME"