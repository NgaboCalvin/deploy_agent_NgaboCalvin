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

# --------------------------------------------------------------------------
# Roster handling
# --------------------------------------------------------------------------

# Sample names and addresses used by the fresh roster option. They are plain
# arrays so the loop that writes the CSV stays easy to follow.
SAMPLE_NAMES=(
    "Alice Johnson" "Bob Smith" "Charlie Davis" "Diana Prince" "Ethan Cole"
    "Fatima Noor" "George Mensah" "Hannah Kim" "Ibrahim Osei" "Jasmine Lee"
    "Kevin Boateng" "Lucy Wanjiku" "Michael Otieno" "Naomi Achieng" "Peter Mwangi"
    "Queenie Adhiambo" "Samuel Kiptoo" "Theresa Njeri" "Victor Chege" "Winnie Atieno"
    "Yusuf Mohammed" "Zainab Hassan" "Andrew Kariuki" "Beatrice Naliaka" "Collins Barasa"
    "Deborah Wafula" "Edwin Sangare" "Fatuma Ali" "Gabriel Rotich" "Halima Yusuf"
    "Isaac Bett" "Judith Cheruiyot" "Kevin Mutua" "Lucy Akinyi" "Miriam Sang"
)

SAMPLE_EMAILS=(
    "alice@example.com" "bob@example.com" "charlie@example.com" "diana@example.com"
    "ethan@example.com" "fatima@example.com" "george@example.com" "hannah@example.com"
    "ibrahim@example.com" "jasmine@example.com" "kevin@example.com" "lucy@example.com"
    "michael@example.com" "naomi@example.com" "peter@example.com" "queenie@example.com"
    "samuel@example.com" "theresa@example.com" "victor@example.com" "winnie@example.com"
    "yusuf@example.com" "zainab@example.com" "andrew@example.com" "beatrice@example.com"
    "collins@example.com" "deborah@example.com" "edwin@example.com" "fatuma@example.com"
    "gabriel@example.com" "halima@example.com" "isaac@example.com" "judith@example.com"
    "kevin.mutua@example.com" "lucy.akinyi@example.com" "miriam@example.com"
)

# How many sample records the generate option can supply.
MAX_FRESH_STUDENTS="${#SAMPLE_NAMES[@]}"

# Count the student rows in templates/assets.csv (the header is not a student).
count_sample_students() {
    local rows
    rows="$(awk 'NR > 1 && NF > 0' "$TEMPLATE_ROSTER" | wc -l | tr -d ' ')"
    printf '%s' "$rows"
}

# Option A: copy the header plus the first N rows of the supplied sample
# roster. awk keeps the copy portable and preserves each row exactly.
copy_sample_roster() {
    local project_dir="$1"
    local available count

    available="$(count_sample_students)"
    if [ ! "$available" -gt 0 ] 2>/dev/null; then
        fail "The template roster $TEMPLATE_ROSTER has no student rows."
        return 1
    fi

    info "The supplied sample roster has $available students."
    info "How many of them should I copy? (1-$available)"

    while true; do
        IFS= read -r count || return 1
        if is_integer_in_range "$count" 1 "$available"; then
            break
        fi
        fail "Please enter a whole number between 1 and $available."
    done

    local target="$project_dir/Helpers/assets.csv"
    # NR == 1 copies the header, rows 2..count+1 copy the chosen students.
    if ! awk -v n="$count" 'NR == 1 || (NR > 1 && NR <= n + 1)' \
        "$TEMPLATE_ROSTER" > "$target"; then
        fail "Could not write the sample roster to $target"
        return 1
    fi

    # Confirm the file really has one header plus the requested rows.
    local written
    written="$(awk 'NR > 1 && NF > 0' "$target" | wc -l | tr -d ' ')"
    if [ "$written" != "$count" ]; then
        fail "Roster copy check failed: expected $count rows, found $written."
        return 1
    fi
    success "Copied the header and $count sample student rows to Helpers/assets.csv"
    return 0
}

# Option B: write a brand new roster. Every student starts at zero recorded
# sessions because this is the first session of a new class.
generate_fresh_roster() {
    local project_dir="$1"
    local count index

    info "I can generate up to $MAX_FRESH_STUDENTS students from built-in sample names."
    info "How many students would you like? (1-$MAX_FRESH_STUDENTS)"

    while true; do
        IFS= read -r count || return 1
        if is_integer_in_range "$count" 1 "$MAX_FRESH_STUDENTS"; then
            break
        fi
        fail "Please enter a whole number between 1 and $MAX_FRESH_STUDENTS."
    done

    local target="$project_dir/Helpers/assets.csv"
    {
        printf 'Email,Names,Attendance Count,Absence Count\n'
        index=0
        while [ "$index" -lt "$count" ]; do
            # The sample names contain no comma, quote or newline, so writing
            # them straight into the CSV cannot break the file structure.
            printf '%s,%s,0,0\n' "${SAMPLE_EMAILS[$index]}" "${SAMPLE_NAMES[$index]}"
            index=$((index + 1))
        done
    } > "$target" || {
        fail "Could not write the new roster to $target"
        return 1
    }

    local written
    written="$(awk 'NR > 1 && NF > 0' "$target" | wc -l | tr -d ' ')"
    if [ "$written" != "$count" ]; then
        fail "Roster check failed: expected $count rows, found $written."
        return 1
    fi
    success "Generated $count new student rows with attendance and absence counts of 0"
    return 0
}

# --------------------------------------------------------------------------
# Configuration updates
# --------------------------------------------------------------------------

# Validate the deployed config.json with Python's json module. I never trust a
# sed edit without checking the result still parses.
validate_config_json() {
    local config_file="$1"

    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$config_file" 2>/dev/null; then
        return 0
    fi

    local error
    error="$(python3 -c "import json,sys
try:
    json.load(open(sys.argv[1]))
except Exception as exc:
    print(exc)" "$config_file" 2>&1)"
    fail "The deployed config.json is not valid JSON: $error"
    return 1
}

# Edit the deployed config.json in place.
#
# macOS ships BSD sed, which needs an argument after -i ("sed -i ''"),
# while GNU sed treats that argument as the script. I write the new file to a
# temporary copy and move it over the original, which behaves identically on
# both systems and keeps the rest of the file untouched.
update_config_value() {
    local config_file="$1"
    local sed_script="$2"
    local temp_file="$config_file.tmp.$$"

    if ! sed -e "$sed_script" "$config_file" > "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        fail "sed failed while updating $config_file"
        return 1
    fi

    if [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        fail "The sed edit produced an empty $config_file"
        return 1
    fi

    # Moving a new file over the original resets its permissions, so I restore
    # the owner-only mode the deployment set earlier.
    if ! chmod 600 "$temp_file"; then
        rm -f "$temp_file"
        fail "Could not set permissions on the updated config copy"
        return 1
    fi

    if ! mv "$temp_file" "$config_file"; then
        rm -f "$temp_file"
        fail "Could not replace $config_file with the updated copy"
        return 1
    fi
    return 0
}

# Only the lines that hold the warning and failure numbers are rewritten, so
# the formatting and key order of the template survive.
update_thresholds() {
    local config_file="$1"
    local warning="$2"
    local failure="$3"

    if ! update_config_value "$config_file" '/"warning"/s/[0-9][0-9]*/'"$warning"'/'; then
        return 1
    fi
    if ! update_config_value "$config_file" '/"failure"/s/[0-9][0-9]*/'"$failure"'/'; then
        return 1
    fi

    if ! validate_config_json "$config_file"; then
        fail "Threshold update produced an invalid config.json, keeping the previous version."
        return 1
    fi
    success "Updated thresholds: warning=$warning, failure=$failure"
    return 0
}

# The sample roster already holds four sessions per student, so the next
# session is session five. A fresh roster has nothing recorded, so it is
# session one. Setting the wrong value here would make the application print
# a mismatch note for every single student.
set_total_sessions() {
    local config_file="$1"
    local sessions="$2"

    if ! update_config_value "$config_file" '/"total_sessions"/s/[0-9][0-9]*/'"$sessions"'/'; then
        return 1
    fi
    if ! validate_config_json "$config_file"; then
        fail "Could not set total_sessions, keeping the previous version."
        return 1
    fi
    success "Set total_sessions to $sessions"
    return 0
}

# Ask the instructor whether to change the alert thresholds, and keep asking
# until the values are valid or the user backs out.
ask_thresholds() {
    local config_file="$1"
    local answer warning failure

    info ""
    info "Default alert thresholds: warning=75, failure=50."
    info "  - A student below the warning threshold triggers a WARNING alert."
    info "  - A student below the failure threshold triggers a URGENT alert."
    info "  - The warning threshold is the less severe alert, so warning should be"
    info "    greater than or equal to failure."
    IFS= read -r -p "Do you want to update these thresholds? [y/N]: " answer || return 0

    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *)
            success "Keeping the deployed default thresholds."
            return 0
            ;;
    esac

    info ""
    IFS= read -r -p "Enter the new warning threshold (0-100): " warning || return 0
    if ! is_integer_in_range "$warning" 0 100; then
        fail "'$warning' is not a percentage between 0 and 100."
        return 1
    fi

    IFS= read -r -p "Enter the new failure threshold (0-100): " failure || return 0
    if ! is_integer_in_range "$failure" 0 100; then
        fail "'$failure' is not a percentage between 0 and 100."
        return 1
    fi

    if [ "$warning" -lt "$failure" ]; then
        fail "The warning threshold ($warning) is lower than the failure threshold ($failure)."
        fail "The warning alert is the less severe one, so warning must be >= failure."
        return 1
    fi

    update_thresholds "$config_file" "$warning" "$failure"
}
