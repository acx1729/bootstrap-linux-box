#!/bin/bash

# ==============================================================================
# Script Name: create_k3d_cluster.sh
# Description: Creates a k3d cluster, verifies its status, and exports its
#              kubeconfig to a shared location. Validates that a specified
#              target user exists and belongs to the required shared group.
#
# Usage:       bash create_k3d_cluster.sh <cluster_name> <target_username>
# Arguments:
#   <cluster_name>    (Required) The name for the new k3d cluster.
#   <target_username> (Required) The username of the intended owner/manager,
#                       who must exist and be in the SHARED_ACCESS_GROUP.
#
# Example:
#   bash create_k3d_cluster.sh my-shared-cluster anil
# ==============================================================================

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

# --- Configuration & Variables ---
# ** IMPORTANT: Set this to the desired shared directory path **
readonly SHARED_KUBECONFIG_DIR="/usr/local/share/kubeconfig"
# Group that should have read access to the shared kubeconfig and that the target user must belong to
readonly SHARED_ACCESS_GROUP="sudo"

# Check if required arguments are provided early
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <cluster_name> <target_username>" >&2
    echo "ERROR: Missing required arguments." >&2
    exit 1
fi

# Assign arguments to variables and make TARGET_USER readonly
CLUSTER_NAME="$1"
readonly TARGET_USER="$2" # Make the target user constant after assignment

readonly MAX_CHECK_ATTEMPTS=5
readonly CHECK_WAIT_SECONDS=5

# --- Functions ---

# Function to print error messages and exit
error_exit() {
    echo "ERROR: $1" >&2
    exit "${2:-1}" # Default exit code 1
}

# Function to print usage instructions (already called if args missing)
usage() {
    echo "Usage: $0 <cluster_name> <target_username>"
    echo "  <cluster_name>    : Name for the new k3d cluster (required)."
    echo "  <target_username> : User who should manage this cluster (must exist and be in '$SHARED_ACCESS_GROUP' group)."
    exit 1
}

# --- Pre-flight Checks ---

# 1. Validate cluster name format (basic check)
if [[ "$CLUSTER_NAME" =~ [^a-zA-Z0-9\-] ]]; then
    error_exit "Cluster name '$CLUSTER_NAME' is invalid. Use only letters, numbers, and hyphens."
fi

# 2. Check if target user exists
echo "INFO: Checking if target user '$TARGET_USER' exists..."
if ! id "$TARGET_USER" &>/dev/null; then
    error_exit "Target user '$TARGET_USER' does not exist on the system."
fi
echo "INFO: Target user '$TARGET_USER' found."

# 3. Check if the shared access group exists
echo "INFO: Checking if shared access group '$SHARED_ACCESS_GROUP' exists..."
if ! getent group "$SHARED_ACCESS_GROUP" &>/dev/null; then
    error_exit "The specified shared access group '$SHARED_ACCESS_GROUP' does not exist on the system."
fi
echo "INFO: Shared access group '$SHARED_ACCESS_GROUP' found."

# 4. Check if target user is a member of the shared access group
echo "INFO: Checking if target user '$TARGET_USER' is a member of group '$SHARED_ACCESS_GROUP'..."
if ! groups "$TARGET_USER" | grep -q "\b${SHARED_ACCESS_GROUP}\b"; then
    error_exit "Target user '$TARGET_USER' is NOT a member of the required group '$SHARED_ACCESS_GROUP'."
fi
echo "INFO: Target user '$TARGET_USER' is a member of '$SHARED_ACCESS_GROUP'."

# 5. Check if k3d command exists
if ! command -v k3d &> /dev/null; then
    error_exit "'k3d' command not found. Please install k3d first."
fi

# 6. Check if kubectl command exists
if ! command -v kubectl &> /dev/null; then
    error_exit "'kubectl' command not found. Please install kubectl first."
fi

# 7. Check Docker daemon connectivity and permissions (for the user RUNNING the script)
echo "INFO: Checking Docker daemon connectivity for the current user ($(whoami))..."
# Use 'docker ps' as a lightweight check requiring connection & permission
if ! docker ps > /dev/null 2>&1; then
    # If that fails, try 'docker info' for more detailed error potential
    if ! docker info > /dev/null 2>&1; then
        error_exit "Cannot connect to the Docker daemon or insufficient permissions for user '$(whoami)'. Please ensure Docker is installed, running, and that the user running this script has permissions (Hint: Add user to 'docker' group and log out/in: 'sudo usermod -aG docker $(whoami)')."
    fi
fi
echo "INFO: Docker daemon is accessible by user '$(whoami)'."

# 8. Check if cluster already exists
echo "INFO: Checking if cluster '$CLUSTER_NAME' already exists..."
if k3d cluster list | grep -q "^${CLUSTER_NAME}\s"; then
    error_exit "A k3d cluster named '$CLUSTER_NAME' already exists."
fi
echo "INFO: Cluster '$CLUSTER_NAME' does not exist yet."

# 9. Check and potentially create shared directory with correct permissions
echo "INFO: Checking shared kubeconfig directory '$SHARED_KUBECONFIG_DIR'..."
if [[ ! -d "$SHARED_KUBECONFIG_DIR" ]]; then
    echo "INFO: Shared directory does not exist. Attempting to create it with sudo..."
    # Attempt to create with sudo
    if ! sudo mkdir -p "$SHARED_KUBECONFIG_DIR"; then
        error_exit "Failed to create shared directory '$SHARED_KUBECONFIG_DIR'. Check permissions or create it manually."
    fi
    echo "INFO: Created shared directory '$SHARED_KUBECONFIG_DIR'."
    # Set permissions suitable for sharing (e.g., root owner, shared group, group write/execute)
    echo "INFO: Setting ownership (root:$SHARED_ACCESS_GROUP) and permissions (770) on '$SHARED_KUBECONFIG_DIR'..."
    if ! sudo chown "root:$SHARED_ACCESS_GROUP" "$SHARED_KUBECONFIG_DIR"; then
         error_exit "Failed to set group ownership on '$SHARED_KUBECONFIG_DIR' to '$SHARED_ACCESS_GROUP'. Check group name and permissions."
    fi
    if ! sudo chmod 770 "$SHARED_KUBECONFIG_DIR"; then # rwxrwx---
         error_exit "Failed to set permissions (770) on '$SHARED_KUBECONFIG_DIR'. Check permissions."
    fi
else
    echo "INFO: Shared directory '$SHARED_KUBECONFIG_DIR' already exists."
    # Optional: Verify existing directory permissions/ownership if needed
fi
echo "INFO: Shared directory is ready."

# --- Main Execution ---

# 1. Create the k3d cluster
echo "--- Creating k3d cluster '$CLUSTER_NAME' ---"
# k3d cluster create automatically updates the current user's kubeconfig and sets the context
if ! k3d cluster create "$CLUSTER_NAME"; then
    error_exit "Failed to create k3d cluster '$CLUSTER_NAME'. Check k3d logs above."
fi
echo "INFO: k3d cluster create command completed for '$CLUSTER_NAME'."
echo "INFO: Waiting a few seconds for cluster components to initialize..."
sleep 10 # Give cluster a moment to start up before checking

# 2. Verify cluster status using kubectl
echo "--- Verifying cluster '$CLUSTER_NAME' status ---"
echo "INFO: Attempting to connect using kubectl (will retry up to $MAX_CHECK_ATTEMPTS times)..."

attempt=1
verified=false
while [[ $attempt -le $MAX_CHECK_ATTEMPTS ]]; do
    echo "INFO: Attempt $attempt of $MAX_CHECK_ATTEMPTS..."
    # Use 'kubectl get nodes' as a basic health check. k3d should have set the context.
    if kubectl get nodes > /dev/null 2>&1; then
        echo "INFO: Successfully connected to cluster '$CLUSTER_NAME' and listed nodes."
        verified=true
        break # Exit loop on success
    else
        echo "WARN: Attempt $attempt failed to connect or list nodes."
        if [[ $attempt -lt $MAX_CHECK_ATTEMPTS ]]; then
            echo "INFO: Waiting $CHECK_WAIT_SECONDS seconds before retrying..."
            sleep $CHECK_WAIT_SECONDS
        fi
    fi
    ((attempt++))
done

# Check if verification failed after all attempts
if [[ "$verified" != "true" ]]; then
    error_exit "Failed to verify cluster '$CLUSTER_NAME' is running after $MAX_CHECK_ATTEMPTS attempts. Use 'kubectl cluster-info' or 'kubectl get nodes' to diagnose."
fi

# 3. Export Kubeconfig to Shared Location
echo "--- Exporting Kubeconfig for '$CLUSTER_NAME' ---"
SHARED_KUBECONFIG_FILE="${SHARED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml"
echo "INFO: Exporting config to '$SHARED_KUBECONFIG_FILE'..."

# Get config using k3d and write using sudo tee to handle permissions
if ! k3d kubeconfig get "$CLUSTER_NAME" | sudo tee "$SHARED_KUBECONFIG_FILE" > /dev/null; then
    error_exit "Failed to get or write kubeconfig for cluster '$CLUSTER_NAME' to '$SHARED_KUBECONFIG_FILE'."
fi

# Set ownership and permissions for the shared file
echo "INFO: Setting permissions on '$SHARED_KUBECONFIG_FILE' (Owner: root, Group: $SHARED_ACCESS_GROUP, Mode: 640)..."
if ! sudo chown "root:$SHARED_ACCESS_GROUP" "$SHARED_KUBECONFIG_FILE"; then
    # Changed from WARN to ERROR for stricter permission enforcement
    error_exit "Failed to set ownership on '$SHARED_KUBECONFIG_FILE'. Check group name and permissions."
fi
if ! sudo chmod 640 "$SHARED_KUBECONFIG_FILE"; then # rw-r-----
    # Changed from WARN to ERROR
    error_exit "Failed to set permissions (640) on '$SHARED_KUBECONFIG_FILE'. Check permissions."
fi

echo "INFO: Kubeconfig exported successfully."

# --- Completion ---
echo ""
echo "--- Cluster '$CLUSTER_NAME' created, verified, and config shared successfully! ---"
echo "Validated for target user: $TARGET_USER (member of '$SHARED_ACCESS_GROUP')"
echo ""
echo "== For the user who ran this script ($(whoami)) =="
echo "Your kubectl context should have been automatically switched to 'k3d-$CLUSTER_NAME'."
echo "You can verify with: kubectl config current-context"
echo "If needed, switch manually using: kubectl config use-context k3d-$CLUSTER_NAME"
echo ""
echo "== For user '$TARGET_USER' and other users in the '$SHARED_ACCESS_GROUP' group =="
echo "Shared Kubeconfig location: $SHARED_KUBECONFIG_FILE"
echo "They can access the cluster using:"
echo "  export KUBECONFIG=$SHARED_KUBECONFIG_FILE"
echo "  kubectl get nodes"
echo ""
# Optional: Display node info from the final successful check
echo "--- Cluster Nodes ---"
kubectl get nodes -o wide
echo "---------------------"

exit 0 # Success
