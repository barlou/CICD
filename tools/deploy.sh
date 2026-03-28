#!/bin/bash
set -e

MODULE_NAME="$1"
ENVIRONMENT="$2"
DEPLOYMENT_ID="$3"
FORCE_INSTALL="$4"

# 🧠 Normalize folder name: data_ingestion → Data_Ingestion (match archive structure)
NORMALIZED_MODULE_NAME="$(echo "$MODULE_NAME" | awk -F_ '{ for (i=1; i<=NF; i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); }1' OFS="_")"

echo "Starting deployment of $MODULE_NAME to $ENVIRONMENT"
echo "Normalized folder: $NORMALIZED_MODULE_NAME"
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Force install: $FORCE_INSTALL"

ARCHIVE="${NORMALIZED_MODULE_NAME}_deployment.tar.gz"
TEMP_DIR=~/temp_deployment_$DEPLOYMENT_ID
FINAL_BASE_DIR=~/deployments
FINAL_MODULE_DIR="$FINAL_BASE_DIR/$MODULE_NAME"
FINAL_METHOD_DIR="$FINAL_BASE_DIR/method"
FINAL_JARS_DIR="$FINAL_BASE_DIR/jars"
FINAL_AIRFLOW_DIR="$FINAL_BASE_DIR/airflow_schedule"

mkdir -p "$TEMP_DIR" "$FINAL_BASE_DIR"
tar -xzf "$ARCHIVE" -C "$TEMP_DIR"

# Paths inside the archive 
DEPLOY_ROOT="$TEMP_DIR/deployment"
MODULE_SOURCE="$DEPLOY_ROOT/$MODULE_NAME"
METHOD_SOURCE="$DEPLOY_ROOT/method"
JARS_SOURCE="$DEPLOY_ROOT/jars.tar.gz"
AIRFLOW_SOURCE="$DEPLOY_ROOT/airflow_schedule.tar.gz"

# Test archive extraction
echo "Archive extracted. Available folders in deployment root:"
ls -lh "$DEPLOY_ROOT"
# Dynamically detect module folder inside archive (case-insensitive)
ACTUAL_MODULE_FOLDER=$(find "$DEPLOY_ROOT" -maxdepth 1 -type d -iname "$MODULE_NAME" | head -n1)
echo "Actual module folder: $ACTUAL_MODULE_FOLDER"

if [ -z "$ACTUAL_MODULE_FOLDER" ]; then
    echo "❌ Could not find module folder matching '$MODULE_NAME' in archive!"
    echo "Available folders:"
    find "$DEPLOY_ROOT" -maxdepth 1 -type d
    exit 1
fi

# === Deploy jars/ only if not already present ===
if [ -f "$JARS_SOURCE" ]; then 
    if [ ! -d "$FINAL_JARS_DIR" ]; then 
        echo "Installing shared jars/ to $FINAL_BASE_DIR"
        cp -r "$JARS_SOURCE" "$FINAL_BASE_DIR"
        echo "Check folder on FINAL_BASE_DIR"
        ls $FINAL_BASE_DIR
        echo "Extracting jars.tar.gz..."
        tar -xzf "$FINAL_BASE_DIR/jars.tar.gz" -C "$FINAL_BASE_DIR"
        echo "Extracting file terminated."
        ls $FINAL_BASE_DIR
        rm -f "$FINAL_BASE_DIR/jars.tar.gz"
    else
        echo "jars/ already present, skipping installation"
    fi
else
    echo "jars/ directory not found in archive"
fi

# === Deploy airflow_schedule/ only if not already present ===
if [ -f "$AIRFLOW_SOURCE" ]; then 
    if [ ! -d "$FINAL_AIRFLOW_DIR" ]; then
        echo "Installing shared airflow_schedule/ to $FINAL_BASE_DIR"
        cp -r "$AIRFLOW_SOURCE" "$FINAL_BASE_DIR"
        echo "Checkl folder on FINAL_BASE_DIR"
        ls $FINAL_BASE_DIR
        echo "Extracting airflow_schedule.tar.gz..."
        tar -xzf "$FINAL_BASE_DIR/airflow_schedule.tar.gz" -C "$FINAL_BASE_DIR"
        echo "Extracting file terminated."
        ls $FINAL_BASE_DIR
        rm -f "$FINAL_BASE_DIR/airflow_schedule.tar.gz"
    else   
        echo "airflow_schedule/ already present, skipping installation"
    fi
else
    echo "airflow_schedule/ directory not found in archive"
fi

# === Deploy method/ only if not already present ===
if [ -d "$METHOD_SOURCE" ]; then 
    if [ ! -d "$FINAL_METHOD_DIR" ]; then 
        echo "Installing shared method/ to $FINAL_METHOD_DIR"
        cp -r "$METHOD_SOURCE" "$FINAL_METHOD_DIR"
    else
        echo "method/ already present, skipping installation"
    fi
else
    echo "method/ directory not found in archive"
fi

# === Deploy module ===
if [ -d "$MODULE_SOURCE" ]; then 
    echo "deploying module to $FINAL_MODULE_DIR"
    rm -rf "$FINAL_MODULE_DIR"
    cp -r "$MODULE_SOURCE" "$FINAL_MODULE_DIR"
else
    echo "Module folder $MODULE_SOURCE not found in archive"
    exit 1
fi

# === Log success marker === 
echo "DEPLOYMENT COMPLETED SUCCESSFULLY" > "/tmp/deploy_${MODULE_NAME}_${DEPLOYMENT_ID}.log"
echo "Deployment completed for $MODULE_NAME"
