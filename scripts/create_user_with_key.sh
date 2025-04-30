#!/bin/bash

# ==============================================================================
# Script Name: create_user_with_key.sh
# Description: Creates a new user, sets up SSH access using a key from a URL
#              or local file, and optionally adds the user to a privileged group.
#              If no group is specified, it attempts to add the user to 'sudo'
#              or 'wheel' if they exist (prioritizing 'sudo').
#
# Usage:       sudo bash create_user_with_key.sh <username> <key_source> [privileged_group]
# Arguments:
#   <username>         (Required) The username for the new user.
#   <key_source>       (Required) The source of the SSH public key.
#                      Can be a URL (http:// or https://) or a local file path.
#   [privileged_group] (Optional) The name of an existing group to add the user
#                      to (e.g., 'sudo', 'wheel'). If omitted, defaults to
#                      'sudo' if available, otherwise 'wheel' if available.
#
# Examples:
#   sudo bash create_user_with_key.sh anil https://github.com/myuser.keys sudo
#   sudo bash create_user_with_key.sh bob /path/to/bob_key.pub
#   sudo bash create_user_with_key.sh clara https://example.com/clara.pub wheel
#   sudo bash create_user_with_key.sh dave https://example.com/dave.pub # Will try sudo, then wheel
# ==============================================================================

# --- Configuration & Variables ---
USERNAME="$1"
KEY_SOURCE="$2"
PRIVILEGED_GROUP_ARG="$3" # Store the original argument
TARGET_PRIVILEGED_GROUP="" # This will hold the group to actually add the user to

# --- Functions ---

# Function to print error messages and exit
error_exit() {
    echo "ERROR: $1" >&2
    # Clean up temp file before exiting, if it exists
    cleanup_temp_file
    exit "${2:-1}" # Default exit code 1
}

# Function to print usage instructions
usage() {
    echo "Usage: sudo $0 <username> <key_source> [privileged_group]"
    echo "  <username>         : Name for the new user (required)."
    echo "  <key_source>       : URL (http/https) or local file path of the SSH public key (required)."
    echo "  [privileged_group] : Optional existing group for sudo/wheel access."
    echo "                     If omitted, attempts 'sudo' then 'wheel'."
    exit 1
}

# Function to clean up temporary key file
cleanup_temp_file() {
    if [[ -n "$TEMP_KEY_FILE" ]] && [[ -f "$TEMP_KEY_FILE" ]]; then
        rm -f "$TEMP_KEY_FILE"
        TEMP_KEY_FILE="" # Clear variable after removal
    fi
}
# Ensure temp file is removed on script exit or interruption
trap cleanup_temp_file EXIT SIGINT SIGTERM

# --- Pre-flight Checks ---

# 1. Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
   error_exit "This script must be run as root. Use 'sudo'."
fi

# 2. Check if mandatory arguments are provided
if [[ -z "$USERNAME" ]] || [[ -z "$KEY_SOURCE" ]]; then
    echo "ERROR: Missing required arguments."
    usage
fi

# 3. Validate username format (basic check: no spaces, not empty)
if [[ "$USERNAME" =~ \ |\' ]]; then
    error_exit "Username cannot contain spaces."
fi

# 4. Check if user already exists
if id "$USERNAME" &>/dev/null; then
    error_exit "User '$USERNAME' already exists."
fi

# 5. Determine and validate the target privileged group
if [[ -n "$PRIVILEGED_GROUP_ARG" ]]; then
    # Group was explicitly provided
    if ! getent group "$PRIVILEGED_GROUP_ARG" &>/dev/null; then
        error_exit "Specified privileged group '$PRIVILEGED_GROUP_ARG' does not exist."
    fi
    TARGET_PRIVILEGED_GROUP="$PRIVILEGED_GROUP_ARG"
    echo "INFO: User will be added to the explicitly specified privileged group '$TARGET_PRIVILEGED_GROUP'."
else
    # Group was NOT provided, attempt auto-detection
    echo "INFO: No privileged group specified. Checking for 'sudo' and 'wheel'..."
    SUDO_EXISTS=$(getent group sudo &>/dev/null && echo "yes" || echo "no")
    WHEEL_EXISTS=$(getent group wheel &>/dev/null && echo "yes" || echo "no")

    if [[ "$SUDO_EXISTS" == "yes" ]]; then
        TARGET_PRIVILEGED_GROUP="sudo"
        echo "INFO: Found 'sudo' group. User will be added to '$TARGET_PRIVILEGED_GROUP'."
    elif [[ "$WHEEL_EXISTS" == "yes" ]]; then
        TARGET_PRIVILEGED_GROUP="wheel"
        echo "INFO: Found 'wheel' group (but not 'sudo'). User will be added to '$TARGET_PRIVILEGED_GROUP'."
    else
        echo "INFO: Neither 'sudo' nor 'wheel' group found. User will not be added to a default privileged group."
        TARGET_PRIVILEGED_GROUP="" # Ensure it's empty
    fi
fi

# 6. Check key source type and prerequisites
KEY_CONTENT=""
TEMP_KEY_FILE="" # Initialize here

if [[ "$KEY_SOURCE" == http://* ]] || [[ "$KEY_SOURCE" == https://* ]]; then
    echo "INFO: Key source is a URL: $KEY_SOURCE"
    # Check for curl or wget
    if command -v curl &>/dev/null; then
        echo "INFO: Using curl to download the key."
        TEMP_KEY_FILE=$(mktemp) || error_exit "Failed to create temporary file."
        # Added --fail to curl to make it exit non-zero on server errors (4xx, 5xx)
        if ! curl -fsSL --fail --connect-timeout 10 --retry 3 "$KEY_SOURCE" -o "$TEMP_KEY_FILE"; then
             error_exit "Failed to download key using curl from $KEY_SOURCE (Check URL and network)"
        fi
        KEY_CONTENT=$(<"$TEMP_KEY_FILE")
    elif command -v wget &>/dev/null; then
        echo "INFO: Using wget to download the key."
        TEMP_KEY_FILE=$(mktemp) || error_exit "Failed to create temporary file."
        if ! wget --timeout=10 --tries=3 -qO "$TEMP_KEY_FILE" "$KEY_SOURCE"; then
            error_exit "Failed to download key using wget from $KEY_SOURCE (Check URL and network)"
        fi
         KEY_CONTENT=$(<"$TEMP_KEY_FILE")
    else
        error_exit "Cannot download key from URL: 'curl' or 'wget' command not found."
    fi
    # Basic check if downloaded content is empty
    if [[ -z "$KEY_CONTENT" ]]; then
        error_exit "Downloaded key content is empty from $KEY_SOURCE"
    fi
elif [[ -f "$KEY_SOURCE" ]]; then
    echo "INFO: Key source is a local file: $KEY_SOURCE"
    if [[ ! -r "$KEY_SOURCE" ]]; then
        error_exit "Cannot read local key file: $KEY_SOURCE. Check permissions."
    fi
    KEY_CONTENT=$(<"$KEY_SOURCE")
    if [[ -z "$KEY_CONTENT" ]]; then
        error_exit "Local key file is empty: $KEY_SOURCE"
    fi
else
    error_exit "Key source '$KEY_SOURCE' is not a valid URL or an existing local file."
fi

# --- Main Execution ---

echo "--- Starting User Setup for '$USERNAME' ---"

# 1. Create the user with home directory
echo "[1/4] Creating user '$USERNAME'..."
# Use useradd without password options first
if ! useradd --create-home --shell /bin/bash "$USERNAME"; then
    error_exit "Failed to create user '$USERNAME'."
fi
# Immediately lock the password to prevent password login
if ! passwd -l "$USERNAME" > /dev/null; then
    # Don't necessarily exit, but warn the user. They might still be able to log in with key.
    echo "WARNING: Failed to lock password for user '$USERNAME'. Password login might still be possible." >&2
fi

USER_HOME=$(eval echo "~$USERNAME") # Get home directory path reliably
echo "User '$USERNAME' created with home directory $USER_HOME and password locked."

# 2. Set up SSH directory and authorized_keys file
echo "[2/4] Configuring SSH access..."
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"

# Create directory if it doesn't exist (useradd might not always create it depending on config)
if [[ ! -d "$SSH_DIR" ]]; then
    if ! mkdir "$SSH_DIR"; then
        error_exit "Failed to create SSH directory '$SSH_DIR'."
    fi
fi

if ! chmod 700 "$SSH_DIR"; then
    error_exit "Failed to set permissions on '$SSH_DIR'."
fi

# Append the fetched key content to authorized_keys
# Use tee to ensure atomicity and handle potential errors during write
echo "$KEY_CONTENT" | tee -a "$AUTH_KEYS_FILE" > /dev/null
# Check the status of tee, not echo
if [[ ${PIPESTATUS[1]} -ne 0 ]]; then
    error_exit "Failed to write key to '$AUTH_KEYS_FILE'."
fi


if ! chmod 600 "$AUTH_KEYS_FILE"; then
    error_exit "Failed to set permissions on '$AUTH_KEYS_FILE'."
fi

echo "SSH authorized key added."

# 3. Set correct ownership for the user's SSH directory and contents
echo "[3/4] Setting ownership for '$SSH_DIR'..."
if ! chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"; then
     error_exit "Failed to set ownership on '$SSH_DIR'."
fi
echo "Ownership set to '$USERNAME:$USERNAME'."

# 4. Grant privileges using the determined group
if [[ -n "$TARGET_PRIVILEGED_GROUP" ]]; then
    echo "[4/4] Adding user '$USERNAME' to group '$TARGET_PRIVILEGED_GROUP'..."
    if ! usermod -aG "$TARGET_PRIVILEGED_GROUP" "$USERNAME"; then
        error_exit "Failed to add user '$USERNAME' to group '$TARGET_PRIVILEGED_GROUP'."
    fi
    echo "User '$USERNAME' added to group '$TARGET_PRIVILEGED_GROUP'."
else
     echo "[4/4] Skipping privileged group addition (no explicit group provided and 'sudo'/'wheel' not found or applicable)."
fi

# --- Completion ---
# Clean up temporary file now that we're done with it
cleanup_temp_file

echo "--- User Setup Complete for '$USERNAME' ---"
echo "User '$USERNAME' can now log in using the provided SSH key."
if [[ -n "$TARGET_PRIVILEGED_GROUP" ]]; then
    echo "User '$USERNAME' has been granted privileges via the '$TARGET_PRIVILEGED_GROUP' group."
fi

exit 0 # Success
