#!/usr/bin/env bash
#
# deploy_agent.sh - deployment agent for the attendance tracker project.
#
# I wrote this script to do three jobs from one menu:
#   1. Deploy a new attendance_tracker_<name> project from templates/.
#   2. Run a project that is already deployed.
#   3. Archive the logs the application generates into reports/.
#
# The script targets macOS and Linux with the Bash that ships with macOS
# (3.2), so I avoid Bash 4 features such as associative arrays and mapfile.

set -u
set -o pipefail

# Where the genuine template files live, relative to this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
TEMPLATE_APP="$TEMPLATE_DIR/attendance_checker.py"
TEMPLATE_CONFIG="$TEMPLATE_DIR/config.json"
TEMPLATE_ROSTER="$TEMPLATE_DIR/assets.csv"

PROJECT_PREFIX="attendance_tracker_"

# Set to "yes" only while a deployment is really in progress. The SIGINT and
# SIGTSTP handlers use this so that Ctrl+C during the interactive Python
# marking session does not trigger deployment cleanup.
DEPLOY_IN_PROGRESS="no"
# Directory name of the deployment currently being created (not a full path,
# so a handler can never be tricked into escaping the working directory).
CURRENT_DEPLOY_DIR=""

# Exit status used when a deployment is interrupted.
INTERRUPT_STATUS=130

# --------------------------------------------------------------------------
# Small output helpers
# --------------------------------------------------------------------------

info() {
    printf '%s\n' "$*"
}

success() {
    printf '  [OK] %s\n' "$*"
}

warn() {
    printf '  [WARN] %s\n' "$*" >&2
}

fail() {
    printf '  [ERROR] %s\n' "$*" >&2
}

banner() {
    printf '%s\n' "--------------------------------------------------"
    printf '%s\n' "$1"
    printf '%s\n' "--------------------------------------------------"
}

# Wait for the user to press Enter so long messages stay readable.
pause() {
    printf '\nPress Enter to return to the menu...'
    IFS= read -r _pause_line || true
}

# --------------------------------------------------------------------------
# Input validation helpers
# --------------------------------------------------------------------------

# A project name may only contain letters, digits, underscores and dots, and
# it may not start with a dot. Anything else (slashes, "..", spaces) is
# rejected, which is what keeps the constructed path inside this directory.
validate_project_name() {
    local name="$1"

    if [ -z "$name" ]; then
        fail "The project name cannot be empty."
        return 1
    fi

    case "$name" in
        .*)
            fail "Invalid project name '$name': it cannot start with a dot."
            return 1
            ;;
    esac

    case "$name" in
        *[!A-Za-z0-9_.-]*)
            fail "Invalid project name '$name': use only letters, digits, dot, dash and underscore."
            return 1
            ;;
    esac

    case "$name" in
        *..*)
            fail "Invalid project name '$name': '..' is not allowed."
            return 1
            ;;
    esac

    return 0
}

# Accept only a whole number, with no sign and no spaces.
is_positive_integer() {
    local value="$1"
    case "$value" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    # Reject zero: every count I ask for must be at least 1.
    if [ "$value" -eq 0 ] 2>/dev/null; then
        return 1
    fi
    return 0
}

# Accept a whole number between min and max inclusive.
is_integer_in_range() {
    local value="$1" min="$2" max="$3"
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------
# Dependency checks
# --------------------------------------------------------------------------

# Both checks run before a deployment. I stop instead of installing anything
# automatically so the instructor keeps control of the machine.
check_dependencies() {
    local missing="no"

    banner "Checking required tools"

    if command -v python3 >/dev/null 2>&1; then
        # Show the real version string rather than just "found".
        if python3 --version; then
            success "python3 is available."
        else
            fail "python3 was found but 'python3 --version' failed."
            missing="yes"
        fi
    else
        fail "python3 is not installed. Install Python 3 and try again."
        missing="yes"
    fi

    if command -v zip >/dev/null 2>&1; then
        success "zip is available."
    else
        fail "zip is not installed. Install it (Debian/Ubuntu: sudo apt install zip, macOS: it ships with the system)."
        missing="yes"
    fi

    if [ "$missing" = "yes" ]; then
        fail "Deployment cannot continue until the missing tools are installed."
        return 1
    fi

    success "All required tools are present."
    return 0
}

# The templates must exist and be readable, otherwise deployment would copy
# nothing and fail half way through.
check_templates() {
    local file
    for file in "$TEMPLATE_APP" "$TEMPLATE_CONFIG" "$TEMPLATE_ROSTER"; do
        if [ ! -f "$file" ]; then
            fail "Missing template file: $file"
            return 1
        fi
        if [ ! -r "$file" ]; then
            fail "Template file is not readable: $file"
            return 1
        fi
    done
    success "All template files are present and readable."
    return 0
}
