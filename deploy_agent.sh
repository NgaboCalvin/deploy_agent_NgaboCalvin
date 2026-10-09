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

# --------------------------------------------------------------------------
# Directory creation and file deployment
# --------------------------------------------------------------------------

# Build the deployment directory tree. reports/ is created empty on purpose:
# the application creates its log files there on the first marking session.
create_project_structure() {
    local project_dir="$1"

    # mkdir -p on each path separately so I can report exactly which one
    # failed instead of losing the detail in a single combined command.
    if ! mkdir -p "$project_dir"; then
        fail "Could not create project directory: $project_dir"
        return 1
    fi
    if ! mkdir -p "$project_dir/Helpers"; then
        fail "Could not create Helpers directory: $project_dir/Helpers"
        return 1
    fi
    if ! mkdir -p "$project_dir/reports"; then
        fail "Could not create reports directory: $project_dir/reports"
        return 1
    fi

    # archives/ holds the copies made by the archive feature and
    # attendance/ + absent/ hold the archived logs themselves. They are not
    # used by the application, so the application paths above stay untouched.
    if ! mkdir -p "$project_dir/archives/attendance" "$project_dir/archives/absent"; then
        fail "Could not create archives directories under: $project_dir/archives"
        return 1
    fi

    success "Created directory structure in $project_dir"
    return 0
}

# Copy the genuine application and configuration from templates/. The template
# files themselves are never modified.
copy_templates() {
    local project_dir="$1"

    if ! cp "$TEMPLATE_APP" "$project_dir/attendance_checker.py"; then
        fail "Could not copy attendance_checker.py into $project_dir"
        return 1
    fi
    success "Copied attendance_checker.py to $project_dir/attendance_checker.py"

    if ! cp "$TEMPLATE_CONFIG" "$project_dir/Helpers/config.json"; then
        fail "Could not copy config.json into $project_dir/Helpers"
        return 1
    fi
    success "Copied config.json to $project_dir/Helpers/config.json"
    return 0
}

# Set and then confirm the permissions the assignment asks for. I read the
# permissions back with ls so I report the real result, not an assumption.
apply_permissions() {
    local project_dir="$1"
    local app_mode config_mode

    # The application is launched directly by an instructor, so it is
    # executable for everyone.
    if ! chmod 755 "$project_dir/attendance_checker.py"; then
        fail "Could not set permissions on attendance_checker.py"
        return 1
    fi
    app_mode="$(ls -l "$project_dir/attendance_checker.py" | cut -c1-10)"
    if [ "$app_mode" != "-rwxr-xr-x" ]; then
        fail "attendance_checker.py has unexpected permissions: $app_mode (expected -rwxr-xr-x)"
        return 1
    fi
    success "attendance_checker.py permissions: $app_mode (755)"

    # config.json holds class policy settings, so it is kept to the owner.
    if ! chmod 600 "$project_dir/Helpers/config.json"; then
        fail "Could not set permissions on Helpers/config.json"
        return 1
    fi
    config_mode="$(ls -l "$project_dir/Helpers/config.json" | cut -c1-10)"
    if [ "$config_mode" != "-rw-------" ]; then
        fail "Helpers/config.json has unexpected permissions: $config_mode (expected -rw-------)"
        return 1
    fi
    success "Helpers/config.json permissions: $config_mode (600)"
    return 0
}
