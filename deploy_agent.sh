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

    # Keep asking until both values are valid, or until the user gives up and
    # types "cancel" (or just presses Enter at an empty prompt).
    info ""
    while true; do
        IFS= read -r -p "Enter the new warning threshold (0-100), or 'cancel': " warning || return 0
        case "$warning" in
            cancel|CANCEL|Cancel)
                info "Threshold update cancelled."
                return 0
                ;;
        esac
        if is_integer_in_range "$warning" 0 100; then
            break
        fi
        fail "'$warning' is not a percentage between 0 and 100."
    done

    while true; do
        IFS= read -r -p "Enter the new failure threshold (0-100), or 'cancel': " failure || return 0
        case "$failure" in
            cancel|CANCEL|Cancel)
                info "Threshold update cancelled."
                return 0
                ;;
        esac
        if is_integer_in_range "$failure" 0 100; then
            break
        fi
        fail "'$failure' is not a percentage between 0 and 100."
    done

    if [ "$warning" -lt "$failure" ]; then
        fail "The warning threshold ($warning) is lower than the failure threshold ($failure)."
        fail "The warning alert is the less severe one, so warning must be >= failure."
        info "Please run the update again with a warning value of $failure or higher."
        return 1
    fi

    update_thresholds "$config_file" "$warning" "$failure"
}

# --------------------------------------------------------------------------
# Signal handling for an in-progress deployment
# --------------------------------------------------------------------------

# Archive an interrupted deployment into <project>_archive.zip and remove the
# incomplete directory only once the archive is confirmed good.
#
# $1 is the incomplete directory name (relative to the working directory).
archive_interrupted_deployment() {
    local dir_name="$1"
    local project_dir="$PWD/$dir_name"
    local archive_file="$PWD/${dir_name}_archive.zip"

    warn "Deployment was interrupted. Archiving the partial project..."
    info "  Incomplete directory: $dir_name"
    info "  Archive file:        ${dir_name}_archive.zip"

    if [ ! -d "$project_dir" ]; then
        warn "No partial directory was created, so there is nothing to archive."
        return 0
    fi

    # -r recurses into the sub-directories, and -j/-x are not used so the
    # archive simply contains everything that was created so far.
    if ! zip -r -q "$archive_file" "$dir_name"; then
        fail "zip failed, so the partial directory $dir_name was KEPT."
        fail "Nothing was deleted: it is still the only copy of that work."
        return 1
    fi

    # Do not trust the exit status alone: confirm a readable zip file appeared.
    if [ ! -s "$archive_file" ]; then
        fail "The archive $archive_file is missing or empty."
        fail "The partial directory $dir_name was KEPT for safety."
        return 1
    fi
    if ! unzip -l "$archive_file" >/dev/null 2>&1; then
        fail "The archive $archive_file is not a readable zip file."
        fail "The partial directory $dir_name was KEPT for safety."
        return 1
    fi

    success "Archived the partial project to ${dir_name}_archive.zip"

    # The rubric requires the incomplete directory to be removed, but only
    # after the archive is known to be good.
    if ! rm -rf "$project_dir"; then
        fail "Could not remove the incomplete directory $dir_name"
        return 1
    fi
    success "Removed the incomplete directory $dir_name"
    return 0
}

# Shared handler for SIGINT and SIGTSTP.
#
# DEPLOY_IN_PROGRESS guards this: when it is "no" the signal belonged to the
# menu or to the interactive Python session, so the handler stays out of the
# way and lets the default behaviour happen.
handle_deployment_interrupt() {
    local signal_name="$1"

    # Disable the handler first so a second Ctrl+C cannot re-enter this code
    # while the archive is being written.
    trap - INT
    trap - TSTP

    if [ "$DEPLOY_IN_PROGRESS" != "yes" ] || [ -z "$CURRENT_DEPLOY_DIR" ]; then
        info ""
        warn "Received $signal_name outside of a deployment, ignoring."
        return 0
    fi

    info ""
    info "=================================================="
    warn "DEPLOYMENT INTERRUPTED ($signal_name)"
    info "=================================================="

    local dir_name="$CURRENT_DEPLOY_DIR"
    # Clear the state first so cleanup cannot run twice.
    DEPLOY_IN_PROGRESS="no"
    CURRENT_DEPLOY_DIR=""

    if archive_interrupted_deployment "$dir_name"; then
        info ""
        info "Cleanup finished. Exiting with status $INTERRUPT_STATUS."
        exit "$INTERRUPT_STATUS"
    fi

    fail "Interrupted deployment could not be archived cleanly."
    info "Please look at $dir_name or ${dir_name}_archive.zip before deleting anything."
    exit 1
}

# Install the deployment traps. They are removed again by
# remove_deployment_traps once the deployment finishes.
install_deployment_traps() {
    trap 'handle_deployment_interrupt SIGINT'  INT
    trap 'handle_deployment_interrupt SIGTSTP' TSTP
}

remove_deployment_traps() {
    trap - INT
    trap - TSTP
    DEPLOY_IN_PROGRESS="no"
    CURRENT_DEPLOY_DIR=""
}

# --------------------------------------------------------------------------
# Feature 1: deploy a new project
# --------------------------------------------------------------------------

# Ask the user for the project name and store it in PROJECT_NAME_CHOICE.
#
# I use a global variable rather than printing the answer, because the prompt
# messages and the answer would otherwise end up mixed together in the output.
ask_for_project_name() {
    PROJECT_NAME_CHOICE=""

    info ""
    info "The project directory will be named ${PROJECT_PREFIX}<name>"
    while true; do
        IFS= read -r -p "Enter the project name: " PROJECT_NAME_CHOICE || return 1
        if validate_project_name "$PROJECT_NAME_CHOICE"; then
            return 0
        fi
    done
}

# Ask whether an existing project may be replaced. The answer is stored in
# OVERWRITE_CHOICE ("yes" or "no") for the same reason as above.
confirm_overwrite() {
    local project_dir="$1"
    local answer

    OVERWRITE_CHOICE="no"

    info ""
    warn "A project already exists at: $project_dir"
    info "Replacing it will permanently remove:"
    info "  $project_dir/Helpers/     (roster and configuration)"
    info "  $project_dir/reports/     (recorded logs)"
    info "  $project_dir/archives/    (archived logs)"
    info "  $project_dir/attendance_checker.py"
    info "Nothing outside $project_dir will be touched."
    IFS= read -r -p "Replace it with a fresh deployment? [y/N]: " answer || return 0

    case "$answer" in
        [yY]|[yY][eE][sS]) OVERWRITE_CHOICE="yes" ;;
        *) OVERWRITE_CHOICE="no" ;;
    esac
    return 0
}

deploy_project() {
    local project_name project_dir dir_name sessions

    banner "Deploy a new attendance tracker project"

    if ! check_dependencies; then
        return 1
    fi
    if ! check_templates; then
        return 1
    fi

    ask_for_project_name || return 1
    project_name="$PROJECT_NAME_CHOICE"
    if [ -z "$project_name" ]; then
        fail "No project name was given."
        return 1
    fi

    dir_name="${PROJECT_PREFIX}${project_name}"
    project_dir="$PWD/$dir_name"

    if [ -e "$project_dir" ]; then
        confirm_overwrite "$project_dir"
        if [ "$OVERWRITE_CHOICE" != "yes" ]; then
            info ""
            success "Keeping the existing project unchanged. Nothing was deployed."
            return 0
        fi
        # Only now, after an explicit yes, is anything removed. The path was
        # built from a validated name, so it is always a child of this
        # directory and can never be the repository itself.
        if ! rm -rf "$project_dir"; then
            fail "Could not remove the existing project directory: $project_dir"
            return 1
        fi
        success "Removed the previous $dir_name"
    fi

    # From here on a Ctrl+C or Ctrl+Z must clean up a partial deployment.
    CURRENT_DEPLOY_DIR="$dir_name"
    DEPLOY_IN_PROGRESS="yes"
    install_deployment_traps

    if ! create_project_structure "$project_dir"; then
        remove_deployment_traps
        return 1
    fi

    if ! copy_templates "$project_dir"; then
        remove_deployment_traps
        return 1
    fi

    # The roster choice decides the session count, so ask before the config is
    # edited.
    info ""
    info "Which roster should this project use?"
    info "  A) Copy students from the supplied sample roster"
    info "  B) Generate a fresh roster from built-in sample names"
    local choice
    while true; do
        IFS= read -r -p "Choose A or B: " choice || { remove_deployment_traps; return 1; }
        case "$choice" in
            [aA]) sessions=5; break ;;
            [bB]) sessions=1; break ;;
            *) fail "Please enter A or B." ;;
        esac
    done

    local roster_ok="no"
    if [ "$sessions" -eq 5 ]; then
        if copy_sample_roster "$project_dir"; then
            roster_ok="yes"
        fi
    else
        if generate_fresh_roster "$project_dir"; then
            roster_ok="yes"
        fi
    fi

    if [ "$roster_ok" != "yes" ]; then
        fail "Could not build the roster, so the deployment is incomplete."
        remove_deployment_traps
        return 1
    fi

    if ! set_total_sessions "$project_dir/Helpers/config.json" "$sessions"; then
        remove_deployment_traps
        return 1
    fi

    if ! ask_thresholds "$project_dir/Helpers/config.json"; then
        fail "Threshold update was cancelled with an invalid value. Keeping the defaults."
    fi

    if ! apply_permissions "$project_dir"; then
        remove_deployment_traps
        return 1
    fi

    # Deployment is finished, so take the handlers back off before the
    # interactive application runs.
    remove_deployment_traps

    banner "Deployment complete"
    info "Project directory: $dir_name"
    info ""
    info "Directory structure:"
    info "  $dir_name/attendance_checker.py"
    info "  $dir_name/Helpers/assets.csv"
    info "  $dir_name/Helpers/config.json"
    info "  $dir_name/reports/        (empty until a session is recorded)"
    info "  $dir_name/archives/attendance/"
    info "  $dir_name/archives/absent/"
    info ""

    # The assignment requires the deployment flow to finish by running the
    # real application from inside the new project.
    run_application_in_dir "$project_dir"
    return $?
}

# --------------------------------------------------------------------------
# Feature 2: run an already deployed project
# --------------------------------------------------------------------------

# Launch the genuine application from inside a project directory. I use a
# subshell with cd so the menu keeps working from the repository root when
# the program exits.
run_application_in_dir() {
    local project_dir="$1"

    info ""
    info "Starting the attendance checker in $project_dir"
    info "Mark each student with 'P' for present or 'A' for absent."
    info ""

    ( cd "$project_dir" && python3 attendance_checker.py )
    local status=$?

    info ""
    if [ "$status" -eq 0 ]; then
        success "The attendance checker finished normally."
    else
        fail "The attendance checker exited with status $status."
        info "Common causes: no input available, or the roster was left mid-session."
    fi
    return "$status"
}

# Ask for a project name and confirm the three files the application needs.
run_application() {
    local project_name project_dir dir_name

    banner "Run an existing attendance tracker project"

    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 is not installed, so the project cannot be started."
        return 1
    fi

    ask_for_project_name || return 1
    dir_name="${PROJECT_PREFIX}${PROJECT_NAME_CHOICE}"
    if [ -z "$dir_name" ] || [ "$dir_name" = "$PROJECT_PREFIX" ]; then
        fail "No project name was given."
        return 1
    fi
    project_dir="$PWD/$dir_name"

    if [ ! -d "$project_dir" ]; then
        fail "No project directory found at: $project_dir"
        info "Use option 1 to deploy it first."
        return 1
    fi

    # Check each required file separately so the error names the missing one.
    local required
    for required in "attendance_checker.py" "Helpers/assets.csv" "Helpers/config.json"; do
        if [ ! -f "$project_dir/$required" ]; then
            fail "The project $dir_name is incomplete: $required is missing."
            info "Expected at: $project_dir/$required"
            return 1
        fi
    done

    success "All required files are present in $dir_name"
    run_application_in_dir "$project_dir"
}

# --------------------------------------------------------------------------
# Feature 3: archive generated logs
# --------------------------------------------------------------------------

# A timestamp that matches the required YYYYMMDD_HHMMSS pattern.
timestamp_now() {
    date '+%Y%m%d_%H%M%S'
}

# Copy one log into its archive directory without overwriting an existing file.
# Two archive runs inside the same second would otherwise produce the same
# name, so a numeric suffix is appended to the next one.
archive_single_log() {
    local project_dir="$1"
    local source_file="$2"
    local archive_subdir="$3"
    local base_name="$4"
    local stamp="$5"

    local archive_dir="$project_dir/archives/$archive_subdir"
    if ! mkdir -p "$archive_dir"; then
        fail "Could not create archive directory: $archive_dir"
        return 1
    fi

    local destination="$archive_dir/${base_name}_${stamp}.log"
    local suffix=1
    while [ -e "$destination" ]; do
        destination="$archive_dir/${base_name}_${stamp}_${suffix}.log"
        suffix=$((suffix + 1))
    done

    # cp keeps the original reports/ log untouched, as the assignment requires.
    if ! cp "$source_file" "$destination"; then
        fail "Could not archive $source_file"
        return 1
    fi

    # Print the full relative destination path, archives sub-directory included.
    success "Archived: ${project_dir#$PWD/}/archives/$archive_subdir/${base_name}_${stamp}.log"
    return 0
}

archive_logs() {
    local project_dir dir_name stamp

    banner "Archive generated logs"

    ask_for_project_name || return 1
    if [ -z "$PROJECT_NAME_CHOICE" ]; then
        fail "No project name was given."
        return 1
    fi
    dir_name="${PROJECT_PREFIX}${PROJECT_NAME_CHOICE}"
    project_dir="$PWD/$dir_name"

    if [ ! -d "$project_dir" ]; then
        fail "No project directory found at: $project_dir"
        return 1
    fi

    local attendance_log="$project_dir/reports/attendance.log"
    local absent_log="$project_dir/reports/absent.log"
    local found=0
    local archived=0

    # Either log may be missing. A session with no absences produces no
    # absent.log at all, so that is a normal case and not an error.
    if [ ! -f "$attendance_log" ]; then
        warn "No attendance.log found in $dir_name/reports/ - skipping it."
    fi
    if [ ! -f "$absent_log" ]; then
        warn "No absent.log found in $dir_name/reports/ - skipping it."
    fi

    if [ ! -f "$attendance_log" ] && [ ! -f "$absent_log" ]; then
        info ""
        info "There are no logs to archive in $dir_name."
        info "Run the attendance checker once so it can create reports/attendance.log."
        return 0
    fi

    stamp="$(timestamp_now)"
    info ""
    info "Using timestamp: $stamp"

    if [ -f "$attendance_log" ]; then
        found=1
        if archive_single_log "$project_dir" "$attendance_log" "attendance" "attendance" "$stamp"; then
            archived=$((archived + 1))
        else
            fail "attendance.log was not archived."
        fi
    fi

    if [ -f "$absent_log" ]; then
        found=1
        if archive_single_log "$project_dir" "$absent_log" "absent" "absent" "$stamp"; then
            archived=$((archived + 1))
        else
            fail "absent.log was not archived."
        fi
    fi

    info ""
    if [ "$found" -eq 1 ] && [ "$archived" -gt 0 ]; then
        success "Archived $archived log(s). The original files in reports/ were kept."
        return 0
    fi
    fail "No logs could be archived."
    return 1
}

# --------------------------------------------------------------------------
# Menu
# --------------------------------------------------------------------------

show_menu() {
    printf '\n'
    printf '%s\n' "=================================================="
    printf '%s\n' "  Attendance Tracker Deployment Agent"
    printf '%s\n' "=================================================="
    printf '%s\n' "  1. Deploy a new project"
    printf '%s\n' "  2. Run an existing project"
    printf '%s\n' "  3. Archive generated logs"
    printf '%s\n' "  4. Exit"
    printf '%s\n' "=================================================="
}

main() {
    local choice status

    # No traps are installed at menu level on purpose: outside a deployment
    # Ctrl+C should simply end the script as usual.
    while true; do
        show_menu
        IFS= read -r -p "Choose an option (1-4): " choice || {
            info ""
            info "Goodbye."
            return 0
        }

        case "$choice" in
            1)
                deploy_project
                status=$?
                if [ "$status" -ne 0 ]; then
                    fail "The deployment did not complete (status $status)."
                fi
                pause
                ;;
            2)
                run_application
                pause
                ;;
            3)
                archive_logs
                pause
                ;;
            4|q|Q|exit|quit)
                info ""
                info "Goodbye."
                return 0
                ;;
            *)
                fail "'$choice' is not one of the menu options."
                pause
                ;;
        esac
    done
}

main "$@"
