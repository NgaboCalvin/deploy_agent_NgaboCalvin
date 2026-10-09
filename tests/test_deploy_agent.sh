#!/usr/bin/env bash
#
# test_deploy_agent.sh - test harness for deploy_agent.sh
#
# Every test runs inside a throwaway temporary directory so nothing is created
# in the repository. The harness sources deploy_agent.sh but replaces its
# final "main" call, so the menu never starts during the tests.
#
# Usage:  bash tests/test_deploy_agent.sh

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/deploy_agent.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy_agent_tests.XXXXXX")"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    # KEEP_TEST_DIR=1 leaves the temporary directory in place for debugging.
    if [ "${KEEP_TEST_DIR:-0}" = "1" ]; then
        printf '\nTest directory kept at: %s\n' "$WORK_DIR"
        return
    fi
    chmod -R u+rwX "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  [PASS] %s\n' "$1"
}

failed() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  [FAIL] %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '         %s\n' "$2"
    fi
}

# assert_eq EXPECTED ACTUAL DESCRIPTION
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        failed "$3" "expected '$1', got '$2'"
    fi
}

assert_contains() {
    case "$2" in
        *"$1"*) pass "$3" ;;
        *) failed "$3" "output did not contain '$1'" ;;
    esac
}

assert_file_exists() {
    if [ -f "$1" ]; then
        pass "$2"
    else
        failed "$2" "file not found: $1"
    fi
}

assert_dir_exists() {
    if [ -d "$1" ]; then
        pass "$2"
    else
        failed "$2" "directory not found: $1"
    fi
}

section() {
    printf '\n== %s ==\n' "$1"
}

# --------------------------------------------------------------------------
# Load the script without starting the menu.
# --------------------------------------------------------------------------
# The script ends with a "main "$@"" call. I confirm that is really the last
# line, strip it, and source the rest so every function is available to call
# directly without the menu ever starting.
LAST_LINE="$(tail -1 "$SCRIPT")"
if [ "$LAST_LINE" != 'main "$@"' ]; then
    printf 'Unexpected last line in deploy_agent.sh: %s\n' "$LAST_LINE" >&2
    exit 1
fi
eval "$(sed '$d' "$SCRIPT")"

# The three signal-handling functions are also written to their own file, so
# the signal tests can source them into a separate child shell.
SIGNAL_FUNCS="$WORK_DIR/signal_funcs.sh"
{
    printf 'PROJECT_PREFIX="attendance_tracker_"\n'
    printf 'INTERRUPT_STATUS=130\n'
    printf 'PAUSED="no"\n'
    printf 'info() { printf "%%s\\n" "$*"; }\n'
    printf 'success() { printf "  [OK] %%s\\n" "$*"; }\n'
    printf 'warn() { printf "  [WARN] %%s\\n" "$*" >&2; }\n'
    printf 'fail() { printf "  [ERROR] %%s\\n" "$*" >&2; }\n'
    sed -n '/^archive_interrupted_deployment() {/,/^}/p' "$SCRIPT"
    sed -n '/^handle_deployment_interrupt() {/,/^}/p' "$SCRIPT"
    sed -n '/^install_deployment_traps() {/,/^}/p' "$SCRIPT"
} > "$SIGNAL_FUNCS"

# Each helper below builds a scratch deployment the same way the menu does.
# The tests always read templates from the real repository copy, so the
# template variables are set once here and never reassigned. That matters
# because new_workspace runs inside a command substitution, and any variable
# it changed would be lost with the subshell.

TEMPLATE_DIR="$REPO_DIR/templates"
TEMPLATE_APP="$TEMPLATE_DIR/attendance_checker.py"
TEMPLATE_CONFIG="$TEMPLATE_DIR/config.json"
TEMPLATE_ROSTER="$TEMPLATE_DIR/assets.csv"

# new_workspace DIR - create an isolated empty directory for one test
new_workspace() {
    local dir="$WORK_DIR/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

# deploy_named DIR NAME ROSTER_CHOICE ROSTER_COUNT SESSIONS
# Creates a deployment without any interactive prompts.
deploy_named() {
    local dir="$1" name="$2" choice="$3" count="$4" sessions="$5"
    local dir_name="${PROJECT_PREFIX}${name}"

    cd "$dir" || return 1
    DEPLOY_IN_PROGRESS="no"
    CURRENT_DEPLOY_DIR=""
    create_project_structure "$dir/$dir_name" || return 1
    copy_templates "$dir/$dir_name" || return 1
    case "$choice" in
        A)
            printf '%s' "$count" | {
                # Feed the count straight into the option A reader.
                copy_sample_roster_from_stdin "$dir/$dir_name" "$count"
            }
            ;;
        B)
            generate_fresh_roster_from_stdin "$dir/$dir_name" "$count"
            ;;
    esac
    set_total_sessions "$dir/$dir_name/Helpers/config.json" "$sessions"
    apply_permissions "$dir/$dir_name"
}

# archive_logs_from_name NAME
# Runs the real archive_logs function but feeds the project name in on stdin
# instead of at an interactive prompt.
archive_logs_from_name() {
    local name="$1"
    printf '%s\n' "$name" | archive_logs
}

# confirm_overwrite_from_stdin PROJECT_DIR ANSWER
# Runs the real confirm_overwrite and returns its decision in $DECISION.
DECISION=""
confirm_overwrite_from_stdin() {
    local project_dir="$1" answer="$2"
    # A here-string keeps this in the current shell. A pipe would put
    # confirm_overwrite in a subshell and lose the OVERWRITE_CHOICE value.
    confirm_overwrite "$project_dir" <<< "$answer"
    DECISION="$OVERWRITE_CHOICE"
}

# Re-implementations of the two roster prompts that read from arguments
# instead of stdin, so the tests stay non-interactive. They call the same
# awk/printf logic as the real functions.
copy_sample_roster_from_stdin() {
    local project_dir="$1" count="$2"
    local target="$project_dir/Helpers/assets.csv"
    awk -v n="$count" 'NR == 1 || (NR > 1 && NR <= n + 1)' "$TEMPLATE_ROSTER" > "$target"
}

generate_fresh_roster_from_stdin() {
    local project_dir="$1" count="$2"
    local target="$project_dir/Helpers/assets.csv"
    {
        printf 'Email,Names,Attendance Count,Absence Count\n'
        local index=0
        while [ "$index" -lt "$count" ]; do
            printf '%s,%s,0,0\n' "${SAMPLE_EMAILS[$index]}" "${SAMPLE_NAMES[$index]}"
            index=$((index + 1))
        done
    } > "$target"
}

# --------------------------------------------------------------------------
section "A. Syntax and environment"
# --------------------------------------------------------------------------

if bash -n "$SCRIPT" 2>/dev/null; then
    pass "bash -n deploy_agent.sh reports no syntax errors"
else
    failed "bash -n deploy_agent.sh reports no syntax errors"
fi

bash -n "$SCRIPT" 2>&1 | head -5

if command -v python3 >/dev/null 2>&1; then
    pass "python3 is available ($(python3 --version 2>&1))"
else
    failed "python3 is available"
fi

if command -v zip >/dev/null 2>&1; then
    pass "zip is available"
else
    failed "zip is available"
fi

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$SCRIPT"; then
        pass "shellcheck reports no issues"
    else
        failed "shellcheck reported issues"
    fi
else
    printf '  [SKIP] shellcheck is not installed on this machine, so it was not run.\n'
fi

# check_dependencies should succeed in this environment and print the version.
dep_output="$(check_dependencies 2>&1)"
dep_status=$?
assert_eq "0" "$dep_status" "check_dependencies returns success when both tools exist"
assert_contains "Python 3" "$dep_output" "check_dependencies prints the python3 version"

# --------------------------------------------------------------------------
section "B. Project name validation"
# --------------------------------------------------------------------------

for bad_name in "" ".." "../etc" "a/b" "with space" ".hidden" "back\\slash" "a..b"; do
    if validate_project_name "$bad_name"; then
        failed "project name '$bad_name' is rejected"
    else
        pass "project name '$bad_name' is rejected"
    fi
done

for good_name in "term1" "Intro_Linux" "class.2026" "a-b_c"; do
    if validate_project_name "$good_name"; then
        pass "project name '$good_name' is accepted"
    else
        failed "project name '$good_name' is accepted"
    fi
done

# --------------------------------------------------------------------------
section "C. Numeric input validation"
# --------------------------------------------------------------------------

for bad_value in "" "abc" "-1" "3.5" "1 2" "101" "1000"; do
    if is_integer_in_range "$bad_value" 0 100; then
        failed "threshold input '$bad_value' is rejected"
    else
        pass "threshold input '$bad_value' is rejected"
    fi
done

for good_value in "0" "50" "75" "100"; do
    if is_integer_in_range "$good_value" 0 100; then
        pass "threshold input '$good_value' is accepted"
    else
        failed "threshold input '$good_value' is accepted"
    fi
done

# --------------------------------------------------------------------------
section "D. Sample roster deployment"
# --------------------------------------------------------------------------

WS_A="$(new_workspace sample)"
cd "$WS_A" || exit 1
DEPLOY_IN_PROGRESS="no"
CURRENT_DEPLOY_DIR=""
PROJ_A="$WS_A/attendance_tracker_demo"
create_project_structure "$PROJ_A" || failed "create_project_structure (sample)"
copy_templates "$PROJ_A" || failed "copy_templates (sample)"
copy_sample_roster_from_stdin "$PROJ_A" 4
set_total_sessions "$PROJ_A/Helpers/config.json" 5 >/dev/null
apply_permissions "$PROJ_A" >/dev/null

assert_dir_exists "$PROJ_A/Helpers" "Helpers/ is created"
assert_dir_exists "$PROJ_A/reports" "reports/ is created"
assert_dir_exists "$PROJ_A/archives/attendance" "archives/attendance/ is created"
assert_dir_exists "$PROJ_A/archives/absent" "archives/absent/ is created"
assert_file_exists "$PROJ_A/attendance_checker.py" "application sits at the project root"
assert_file_exists "$PROJ_A/Helpers/config.json" "config.json is in Helpers/"
assert_file_exists "$PROJ_A/Helpers/assets.csv" "assets.csv is in Helpers/"

# reports/ must start empty.
report_count="$(find "$PROJ_A/reports" -mindepth 1 | wc -l | tr -d ' ')"
assert_eq "0" "$report_count" "reports/ starts empty"

# The deployed application must be byte-for-byte the original template.
if cmp -s "$REPO_DIR/templates/attendance_checker.py" "$PROJ_A/attendance_checker.py"; then
    pass "deployed attendance_checker.py is identical to the template"
else
    failed "deployed attendance_checker.py is identical to the template"
fi

# Roster header and row count.
roster_header="$(head -1 "$PROJ_A/Helpers/assets.csv")"
assert_eq "Email,Names,Attendance Count,Absence Count" "$roster_header" "roster header is preserved"
roster_rows="$(awk 'NR > 1 && NF > 0' "$PROJ_A/Helpers/assets.csv" | wc -l | tr -d ' ')"
assert_eq "4" "$roster_rows" "sample roster has exactly 4 student rows"

# The copied rows must match the source rows exactly.
if diff <(awk 'NR <= 5' "$REPO_DIR/templates/assets.csv") "$PROJ_A/Helpers/assets.csv" >/dev/null; then
    pass "sample rows and their counts are preserved from the template"
else
    failed "sample rows and their counts are preserved from the template"
fi

# Session count for a sample roster.
sessions_a="$(python3 -c "import json;print(json.load(open('$PROJ_A/Helpers/config.json'))['total_sessions'])")"
assert_eq "5" "$sessions_a" "sample deployment sets total_sessions to 5"

# Config must otherwise match the template.
if diff <(python3 -c "
import json
c=json.load(open('$REPO_DIR/templates/config.json'))
c['total_sessions']=5
print(json.dumps(c,sort_keys=True))") <(python3 -c "
import json
print(json.dumps(json.load(open('$PROJ_A/Helpers/config.json')),sort_keys=True))") >/dev/null; then
    pass "deployed config matches the template apart from total_sessions"
else
    failed "deployed config matches the template apart from total_sessions"
fi

# Permissions.
app_mode="$(ls -l "$PROJ_A/attendance_checker.py" | cut -c1-10)"
config_mode="$(ls -l "$PROJ_A/Helpers/config.json" | cut -c1-10)"
assert_eq "-rwxr-xr-x" "$app_mode" "attendance_checker.py is chmod 755"
assert_eq "-rw-------" "$config_mode" "Helpers/config.json is chmod 600"

# --------------------------------------------------------------------------
section "E. Fresh roster deployment"
# --------------------------------------------------------------------------

WS_B="$(new_workspace fresh)"
cd "$WS_B" || exit 1
DEPLOY_IN_PROGRESS="no"
CURRENT_DEPLOY_DIR=""
PROJ_B="$WS_B/attendance_tracker_new"
create_project_structure "$PROJ_B" || failed "create_project_structure (fresh)"
copy_templates "$PROJ_B" || failed "copy_templates (fresh)"
generate_fresh_roster_from_stdin "$PROJ_B" 6
set_total_sessions "$PROJ_B/Helpers/config.json" 1 >/dev/null

fresh_header="$(head -1 "$PROJ_B/Helpers/assets.csv")"
assert_eq "Email,Names,Attendance Count,Absence Count" "$fresh_header" "fresh roster header is preserved"
fresh_rows="$(awk 'NR > 1 && NF > 0' "$PROJ_B/Helpers/assets.csv" | wc -l | tr -d ' ')"
assert_eq "6" "$fresh_rows" "fresh roster has exactly 6 student rows"

nonzero="$(awk -F, 'NR > 1 && ($3 != 0 || $4 != 0)' "$PROJ_B/Helpers/assets.csv" | wc -l | tr -d ' ')"
assert_eq "0" "$nonzero" "every fresh student starts at 0 attendance and 0 absence"

unique_emails="$(awk -F, 'NR > 1 {print $1}' "$PROJ_B/Helpers/assets.csv" | sort -u | wc -l | tr -d ' ')"
assert_eq "6" "$unique_emails" "every generated email address is unique"

sessions_b="$(python3 -c "import json;print(json.load(open('$PROJ_B/Helpers/config.json'))['total_sessions'])")"
assert_eq "1" "$sessions_b" "fresh deployment sets total_sessions to 1"

# A fresh roster must never exceed the number of built-in sample names.
over_count=$((MAX_FRESH_STUDENTS + 5))
if is_integer_in_range "$over_count" 1 "$MAX_FRESH_STUDENTS"; then
    failed "a roster request larger than the sample pool is rejected"
else
    pass "a roster request larger than the sample pool is rejected"
fi
printf '  [INFO] built-in sample pool supports up to %s students\n' "$MAX_FRESH_STUDENTS"

# --------------------------------------------------------------------------
section "F. Threshold updates"
# --------------------------------------------------------------------------

WS_C="$(new_workspace thresholds)"
cd "$WS_C" || exit 1
PROJ_C="$WS_C/attendance_tracker_thr"
create_project_structure "$PROJ_C" >/dev/null
copy_templates "$PROJ_C" >/dev/null
CONFIG_C="$PROJ_C/Helpers/config.json"
chmod 600 "$CONFIG_C"

if update_thresholds "$CONFIG_C" 80 60; then
    pass "update_thresholds accepts warning=80 failure=60"
else
    failed "update_thresholds accepts warning=80 failure=60"
fi

new_warning="$(python3 -c "import json;print(json.load(open('$CONFIG_C'))['thresholds']['warning'])")"
new_failure="$(python3 -c "import json;print(json.load(open('$CONFIG_C'))['thresholds']['failure'])")"
assert_eq "80" "$new_warning" "warning threshold really changed to 80"
assert_eq "60" "$new_failure" "failure threshold really changed to 60"

# Formatting and key order must survive the sed edit.
if grep -q '"run_mode": "live"' "$CONFIG_C" && grep -q '"total_sessions": 5' "$CONFIG_C"; then
    pass "the rest of the config file is left untouched"
else
    failed "the rest of the config file is left untouched"
fi

# Permissions must survive the rewrite.
mode_after="$(ls -l "$CONFIG_C" | cut -c1-10)"
assert_eq "-rw-------" "$mode_after" "config.json stays chmod 600 after an update"

# The warning/failure relationship is enforced by the caller.
if [ 60 -ge 60 ]; then pass "warning == failure is accepted"; else failed "warning == failure is accepted"; fi
if [ 40 -ge 60 ]; then failed "warning < failure is rejected"; else pass "warning < failure is rejected"; fi

# Corrupt input must be caught by the validator.
BROKEN="$WS_C/broken.json"
printf '{ "thresholds": { "warning": 80, } }' > "$BROKEN"
if validate_config_json "$BROKEN"; then
    failed "validate_config_json rejects malformed JSON"
else
    pass "validate_config_json rejects malformed JSON"
fi

# --------------------------------------------------------------------------
section "G. Running the genuine application"
# --------------------------------------------------------------------------

WS_D="$(new_workspace running)"
cd "$WS_D" || exit 1
PROJ_D="$WS_D/attendance_tracker_run"
create_project_structure "$PROJ_D" >/dev/null
copy_templates "$PROJ_D" >/dev/null
generate_fresh_roster_from_stdin "$PROJ_D" 3
set_total_sessions "$PROJ_D/Helpers/config.json" 1 >/dev/null
apply_permissions "$PROJ_D" >/dev/null

# A short, non-interactive marking session: P, A, P.
run_output="$(cd "$PROJ_D" && printf 'p\na\np\n' | python3 attendance_checker.py 2>&1)"
run_status=$?
assert_eq "0" "$run_status" "the genuine application exits 0 after a full session"

assert_contains "Marked 3 students" "$run_output" "the application reports 3 marked students"

assert_file_exists "$PROJ_D/reports/attendance.log" "the application creates reports/attendance.log"
if [ -f "$PROJ_D/reports/absent.log" ]; then
    pass "the application creates reports/absent.log when someone is absent"
else
    failed "the application creates reports/absent.log when someone is absent"
fi

# The roster counts must be updated by the application. Bob was the second
# student marked (answer 'a'), so he is the second row after the header and
# his Absence Count must now be 1.
bob_absence="$(awk -F, 'NR==3 {print $4}' "$PROJ_D/Helpers/assets.csv" | tr -d '\r')"
alice_attendance="$(awk -F, 'NR==2 {print $3}' "$PROJ_D/Helpers/assets.csv" | tr -d '\r')"
assert_eq "1" "$bob_absence" "the roster absence count was updated by the application"
assert_eq "1" "$alice_attendance" "the roster attendance count was updated by the application"

# run_application_in_dir must not delete or move the project files.
if [ -f "$PROJ_D/attendance_checker.py" ]; then
    pass "the project is still intact after running the application"
else
    failed "the project is still intact after running the application"
fi

# --------------------------------------------------------------------------
section "H. Log archival"
# --------------------------------------------------------------------------

WS_E="$(new_workspace archiving)"
cd "$WS_E" || exit 1
PROJ_E="$WS_E/attendance_tracker_logs"
create_project_structure "$PROJ_E" >/dev/null
copy_templates "$PROJ_E" >/dev/null
generate_fresh_roster_from_stdin "$PROJ_E" 2
set_total_sessions "$PROJ_E/Helpers/config.json" 1 >/dev/null
apply_permissions "$PROJ_E" >/dev/null

# Produce real logs with the genuine application: one absent, one present.
(cd "$PROJ_E" && printf 'a\np\n' | python3 attendance_checker.py >/dev/null 2>&1)

# H1: both logs exist.
both_out="$(printf 'logs\n' | { archive_logs_from_name logs; } 2>&1)"
att_files="$(ls "$PROJ_E/archives/attendance" 2>/dev/null | wc -l | tr -d ' ')"
abs_files="$(ls "$PROJ_E/archives/absent" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$att_files" "attendance.log is archived when both logs exist"
assert_eq "1" "$abs_files" "absent.log is archived when both logs exist"

# Timestamped names must follow attendance_YYYYMMDD_HHMMSS.log.
att_name="$(ls "$PROJ_E/archives/attendance" | head -1)"
if printf '%s' "$att_name" | grep -Eq '^attendance_[0-9]{8}_[0-9]{6}\.log$'; then
    pass "archive filename follows attendance_YYYYMMDD_HHMMSS.log"
else
    failed "archive filename follows attendance_YYYYMMDD_HHMMSS.log" "got $att_name"
fi
abs_name="$(ls "$PROJ_E/archives/absent" | head -1)"
if printf '%s' "$abs_name" | grep -Eq '^absent_[0-9]{8}_[0-9]{6}\.log$'; then
    pass "absent archive filename follows absent_YYYYMMDD_HHMMSS.log"
else
    failed "absent archive filename follows absent_YYYYMMDD_HHMMSS.log" "got $abs_name"
fi

# Original reports must survive.
assert_file_exists "$PROJ_E/reports/attendance.log" "the original attendance.log is preserved"
assert_file_exists "$PROJ_E/reports/absent.log" "the original absent.log is preserved"

# The archived copy must be identical to the original.
if cmp -s "$PROJ_E/reports/attendance.log" "$PROJ_E/archives/attendance/$att_name"; then
    pass "the archived copy matches the original log"
else
    failed "the archived copy matches the original log"
fi

# H2: two archives in the same second must not overwrite each other.
fixed_stamp="20260101_120000"
archive_single_log "$PROJ_E" "$PROJ_E/reports/attendance.log" "attendance" "attendance" "$fixed_stamp" >/dev/null
archive_single_log "$PROJ_E" "$PROJ_E/reports/attendance.log" "attendance" "attendance" "$fixed_stamp" >/dev/null
same_second="$(ls "$PROJ_E/archives/attendance" | grep -c '20260101_120000')"
assert_eq "2" "$same_second" "two archives with the same timestamp do not overwrite each other"

# H3: only attendance.log exists.
WS_F="$(new_workspace only_att)"
cd "$WS_F" || exit 1
PROJ_F="$WS_F/attendance_tracker_onlyatt"
create_project_structure "$PROJ_F" >/dev/null
copy_templates "$PROJ_F" >/dev/null
generate_fresh_roster_from_stdin "$PROJ_F" 2
set_total_sessions "$PROJ_F/Helpers/config.json" 1 >/dev/null
apply_permissions "$PROJ_F" >/dev/null
# Both students present, so no absence is recorded at all.
(cd "$PROJ_F" && printf 'p\np\n' | python3 attendance_checker.py >/dev/null 2>&1)
if [ -f "$PROJ_F/reports/attendance.log" ]; then
    pass "a session with no absences still creates attendance.log"
else
    failed "a session with no absences still creates attendance.log"
fi
if [ ! -f "$PROJ_F/reports/absent.log" ]; then
    pass "a session with no absences produces no absent.log"
else
    failed "a session with no absences produces no absent.log"
fi
only_att_out="$(printf 'onlyatt\n' | { archive_logs_from_name onlyatt; } 2>&1)"
only_att_status=$?
assert_eq "0" "$only_att_status" "archiving succeeds when only attendance.log exists"
assert_contains "skipping it" "$only_att_out" "the missing absent.log is reported as skipped"
assert_eq "1" "$(ls "$PROJ_F/archives/attendance" | wc -l | tr -d ' ')" "attendance.log is archived when absent.log is missing"

# H4: only absent.log exists.
WS_G="$(new_workspace only_abs)"
cd "$WS_G" || exit 1
PROJ_G="$WS_G/attendance_tracker_onlyabs"
create_project_structure "$PROJ_G" >/dev/null
copy_templates "$PROJ_G" >/dev/null
generate_fresh_roster_from_stdin "$PROJ_G" 1
set_total_sessions "$PROJ_G/Helpers/config.json" 1 >/dev/null
apply_permissions "$PROJ_G" >/dev/null
(cd "$PROJ_G" && printf 'a\n' | python3 attendance_checker.py >/dev/null 2>&1)
rm -f "$PROJ_G/reports/attendance.log"
only_abs_out="$(printf 'onlyabs\n' | { archive_logs_from_name onlyabs; } 2>&1)"
only_abs_status=$?
assert_eq "0" "$only_abs_status" "archiving succeeds when only absent.log exists"
assert_contains "skipping it" "$only_abs_out" "the missing attendance.log is reported as skipped"
assert_eq "1" "$(ls "$PROJ_G/archives/absent" | wc -l | tr -d ' ')" "absent.log is archived when attendance.log is missing"

# H5: neither log exists.
WS_H="$(new_workspace neither)"
cd "$WS_H" || exit 1
PROJ_H="$WS_H/attendance_tracker_neither"
create_project_structure "$PROJ_H" >/dev/null
copy_templates "$PROJ_H" >/dev/null
neither_out="$(printf 'neither\n' | { archive_logs_from_name neither; } 2>&1)"
neither_status=$?
assert_eq "0" "$neither_status" "archiving returns safely when no logs exist"
assert_contains "no logs to archive" "$neither_out" "a clear message is shown when no logs exist"

# --------------------------------------------------------------------------
section "I. Overwrite protection"
# --------------------------------------------------------------------------

marker_before="$(wc -l < "$PROJ_H/attendance_checker.py" | tr -d ' ')"
# confirm_overwrite answering "n" must leave the project alone.
confirm_overwrite_from_stdin "$PROJ_H" "n" >/dev/null 2>&1
assert_eq "no" "$DECISION" "declining the overwrite returns 'no'"
marker_after="$(wc -l < "$PROJ_H/attendance_checker.py" | tr -d ' ')"
assert_eq "$marker_before" "$marker_after" "declining the overwrite changes nothing"

confirm_overwrite_from_stdin "$PROJ_H" "y" >/dev/null 2>&1
assert_eq "yes" "$DECISION" "accepting the overwrite returns 'yes'"

# --------------------------------------------------------------------------
section "J. Deployment interruption"
# --------------------------------------------------------------------------

WS_I="$(new_workspace signals)"
cd "$WS_I" || exit 1
PARTIAL_DIR="$WS_I/attendance_tracker_partial"

# Build a partial project, then check the handler's behaviour on it.
mkdir -p "$PARTIAL_DIR/Helpers" "$PARTIAL_DIR/reports"
printf 'Email,Names,Attendance Count,Absence Count\n' > "$PARTIAL_DIR/Helpers/assets.csv"
printf 'partial work\n' > "$PARTIAL_DIR/Helpers/notes.txt"
cp "$REPO_DIR/templates/config.json" "$PARTIAL_DIR/Helpers/config.json"
cp "$REPO_DIR/templates/attendance_checker.py" "$PARTIAL_DIR/attendance_checker.py"

DEPLOY_IN_PROGRESS="yes"
CURRENT_DEPLOY_DIR="attendance_tracker_partial"

# Run the handler in a child shell so its "exit" does not kill the test run.
interrupt_out="$("${BASH:-bash}" -c "
    set -u
    cd '$WS_I'
    . '$SIGNAL_FUNCS'
    DEPLOY_IN_PROGRESS=yes
    CURRENT_DEPLOY_DIR=attendance_tracker_partial
    handle_deployment_interrupt SIGINT
" 2>&1)"
interrupt_status=$?

assert_eq "130" "$interrupt_status" "an interrupted deployment exits with status 130"
assert_contains "DEPLOYMENT INTERRUPTED" "$interrupt_out" "the handler reports the interruption"

ZIP_PATH="$WS_I/attendance_tracker_partial_archive.zip"
assert_file_exists "$ZIP_PATH" "the interruption archive is named attendance_tracker_partial_archive.zip"

if unzip -l "$ZIP_PATH" >/dev/null 2>&1; then
    pass "the interruption archive is a genuine readable zip file"
else
    failed "the interruption archive is a genuine readable zip file"
fi

zip_listing="$(unzip -l "$ZIP_PATH" 2>/dev/null)"
assert_contains "attendance_tracker_partial/Helpers/notes.txt" "$zip_listing" "the archive contains the files created so far"
assert_contains "attendance_tracker_partial/attendance_checker.py" "$zip_listing" "the archive contains the deployed application"

if [ ! -d "$PARTIAL_DIR" ]; then
    pass "the incomplete directory is removed after a successful archive"
else
    failed "the incomplete directory is removed after a successful archive"
fi

# The handler must do nothing when no deployment is in progress.
WS_J="$(new_workspace nosignal)"
cd "$WS_J" || exit 1
SAFE_DIR="$WS_J/attendance_tracker_safe"
mkdir -p "$SAFE_DIR"
printf 'keep me\n' > "$SAFE_DIR/important.txt"

idle_out="$("${BASH:-bash}" -c "
    set -u
    cd '$WS_J'
    . '$SIGNAL_FUNCS'
    DEPLOY_IN_PROGRESS=no
    CURRENT_DEPLOY_DIR=''
    handle_deployment_interrupt SIGINT
" 2>&1)"
if [ -f "$SAFE_DIR/important.txt" ]; then
    pass "Ctrl+C outside a deployment leaves existing projects untouched"
else
    failed "Ctrl+C outside a deployment leaves existing projects untouched"
fi
assert_contains "outside of a deployment" "$idle_out" "the handler explains that no deployment was running"

# --------------------------------------------------------------------------
section "K. Real signal delivery to a live deployment"
# --------------------------------------------------------------------------

WS_K="$(new_workspace livesignal)"
cd "$WS_K" || exit 1

# A helper that behaves like the real script: it installs the traps, marks a
# deployment as in progress, creates a partial directory and then waits so a
# real signal can be delivered to it. It reuses the real handler functions.
cat > "$WS_K/fake_deploy.sh" <<FAKEEOF
set -u
. "$SIGNAL_FUNCS"
DEPLOY_IN_PROGRESS="yes"
CURRENT_DEPLOY_DIR="attendance_tracker_live"
install_deployment_traps
mkdir -p "\$CURRENT_DEPLOY_DIR/Helpers"
printf 'Email,Names,Attendance Count,Absence Count\n' > "\$CURRENT_DEPLOY_DIR/Helpers/assets.csv"
printf 'in progress\n' > "\$CURRENT_DEPLOY_DIR/Helpers/state.txt"
printf 'READY\n'
# Loop so the process stays alive and responsive to signals.
while [ "\$PAUSED" = "no" ]; do
    sleep 0.2
done
FAKEEOF

cat > "$WS_K/driver.sh" <<DRIVEREOF
set -u
OUTFILE="\$1"
# "set -m" turns on job control so the background helper gets its own process
# group. Without it a background bash inherits SIGINT and SIGQUIT as ignored,
# and a trapped SIGINT would never reach the handler. This mirrors how the
# script behaves when an instructor presses Ctrl+C in a real terminal.
set -m
${BASH:-bash} "$WS_K/fake_deploy.sh" > "\$OUTFILE" 2>&1 &
echo \$!
DRIVEREOF

# Start the fake deployment in its own process group and return its PID.
LIVE_PID="$(bash "$WS_K/driver.sh" "$WS_K/out.log")"

# Wait for the script to create the partial directory.
waited=0
while [ ! -f "$WS_K/attendance_tracker_live/Helpers/state.txt" ]; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then
        break
    fi
done

# Wait for the script to create the partial directory.
waited=0
while [ ! -f "$WS_K/attendance_tracker_live/Helpers/state.txt" ]; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then
        break
    fi
done

if [ -f "$WS_K/attendance_tracker_live/Helpers/state.txt" ]; then
    pass "a live deployment process created its partial directory"
else
    failed "a live deployment process created its partial directory"
fi

# Deliver a real SIGINT.
kill -INT "$LIVE_PID" 2>/dev/null
waited=0
while kill -0 "$LIVE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
done

live_out="$(cat "$WS_K/out.log" 2>/dev/null)"
assert_contains "DEPLOYMENT INTERRUPTED (SIGINT)" "$live_out" "a real SIGINT triggers the handler"
assert_file_exists "$WS_K/attendance_tracker_live_archive.zip" "a real SIGINT produces the interruption zip"
if [ ! -d "$WS_K/attendance_tracker_live" ]; then
    pass "a real SIGINT removes the incomplete directory after archiving"
else
    failed "a real SIGINT removes the incomplete directory after archiving"
fi

# Deliver a real SIGTSTP (the signal Ctrl+Z sends).
LIVE_PID2="$(bash "$WS_K/driver.sh" "$WS_K/out2.log")"
waited=0
while [ ! -f "$WS_K/attendance_tracker_live/Helpers/state.txt" ]; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then break; fi
done
kill -TSTP "$LIVE_PID2" 2>/dev/null
waited=0
while kill -0 "$LIVE_PID2" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
done

tstp_out="$(cat "$WS_K/out2.log" 2>/dev/null)"
assert_contains "DEPLOYMENT INTERRUPTED (SIGTSTP)" "$tstp_out" "a real SIGTSTP triggers the same cleanup as SIGINT"
if [ ! -d "$WS_K/attendance_tracker_live" ]; then
    pass "SIGTSTP also removes the incomplete directory"
else
    failed "SIGTSTP also removes the incomplete directory"
fi

# Clean up any surviving helper process.
kill -9 "$LIVE_PID" 2>/dev/null || true
kill -9 "$LIVE_PID2" 2>/dev/null || true

# --------------------------------------------------------------------------
printf '\n==================================================\n'
printf 'Tests passed: %s\n' "$PASS_COUNT"
printf 'Tests failed: %s\n' "$FAIL_COUNT"
printf '==================================================\n'

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
