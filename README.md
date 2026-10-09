# Attendance Tracker Deployment Agent

A Bash menu script that deploys, runs and archives an interactive Python
attendance tracker for a class.

## Project overview

This repository holds the deployment agent I wrote for the summative
assignment, plus the three original template files it deploys from. The agent
itself is one script, `deploy_agent.sh`. Everything a user creates lives in a
separate `attendance_tracker_<name>` directory that the script generates, so
the repository stays clean and each class gets its own isolated copy of the
application.

## Why I built the script

Marking attendance is repetitive. Every time I start a new class I would
otherwise have to create the folder tree by hand, copy three files into the
right places, decide how many students are on the roster, set permissions and
then remember where the logs end up. Every one of those steps is easy to get
slightly wrong, and a mistake in the configuration silently produces wrong
attendance percentages.

I wanted one program that does the setup consistently, refuses to destroy
work I care about, and cleans up after itself if something goes wrong halfway
through.

## What the script automates

- Checks that `python3` and `zip` are installed, and shows the Python version.
- Creates the exact directory tree the application expects.
- Copies the genuine `attendance_checker.py`, `config.json` and `assets.csv`
  out of `templates/`.
- Builds the roster either by copying sample students or by generating a fresh
  one.
- Sets `total_sessions` so it matches the roster that was chosen.
- Optionally updates the alert thresholds.
- Sets file permissions and then reads them back to confirm the result.
- Runs the real application so a deployment is proven to work.
- Archives logs into timestamped files without deleting the originals.
- Handles Ctrl+C and Ctrl+Z during a deployment by zipping up the partial
  project instead of leaving it behind.

## Project structure

The repository itself:

```
deploy_agent_NgaboCalvin/
├── deploy_agent.sh          # the whole agent
├── README.md
├── .gitignore
├── templates/
│   ├── attendance_checker.py
│   ├── assets.csv
│   └── config.json
└── tests/
    └── test_deploy_agent.sh # test harness
```

A deployed project looks like this:

```
attendance_tracker_<name>/
├── attendance_checker.py    # the application, at the project root
├── Helpers/
│   ├── assets.csv           # the student roster
│   └── config.json          # thresholds and session count
├── reports/                 # empty at first, filled by the app
├── archives/
│   ├── attendance/
│   └── absent/
```

The application reads `Helpers/config.json` and `Helpers/assets.csv` from
paths relative to its own location and writes `reports/attendance.log` and
`reports/absent.log`, so the layout above is fixed and I do not move things
around.

## Prerequisites

- macOS or Linux
- Bash (I developed against the Bash 3.2 that ships with macOS)
- `python3` (Python 3.9.6 on my machine)
- `zip` (ships with macOS)
- Git, to clone the repository

I did not use Homebrew or install any extra packages. The script targets Bash
3.2, so it avoids Bash 4 features such as associative arrays and `mapfile`.

## How to clone the repository

```bash
git clone https://github.com/NgaboCalvin/deploy_agent_NgaboCalvin.git
cd deploy_agent_NgaboCalvin
```

## How to make the script executable

```bash
chmod +x deploy_agent.sh
```

The executable bit is already committed, so a fresh clone should not need this.
Running it is the check:

```bash
ls -l deploy_agent.sh
```

You should see `-rwxr-xr-x`.

## How to start the script

From the repository root:

```bash
./deploy_agent.sh
```

## How to use the menu

The menu appears when the script starts:

```
==================================================
  Attendance Tracker Deployment Agent
==================================================
  1. Deploy a new project
  2. Run an existing project
  3. Archive generated logs
  4. Exit
==================================================
Choose an option (1-4):
```

Type the number and press Enter. Anything else is rejected with a message and
the menu comes back. Option 4, and also `q` or `quit`, ends the script.

## How to deploy a project

Choose option 1 and follow the prompts:

1. **Dependency check.** The script runs `python3 --version`, prints the
   result, and confirms `zip` is available. If either one is missing it stops
   and tells me what to install. It never installs anything on its own.
2. **Template check.** All three template files must exist and be readable.
3. **Project name.** I type a name such as `intro_linux`. The directory
   becomes `attendance_tracker_intro_linux`.
4. **Existing project check.** If that directory already exists, the script
   lists exactly what would be removed and asks before touching anything.
   Answering `n` leaves the project completely alone and nothing is deployed.
5. **Directory structure.** The tree in the overview is created.
6. **Roster choice.** Option A copies sample students, option B generates new
   ones.
7. **Threshold question.** I can keep the defaults or enter new ones.
8. **Permissions.** Applied and then read back with `ls` to confirm.
9. **Run.** The deployment finishes by running `python3 attendance_checker.py`
   from inside the new project directory, so I can mark a real session
   straight away.

## How the sample-roster option works

Choosing A reads `templates/assets.csv`, keeps the header row exactly as it
is, and asks how many students to copy. The count must be a whole number
between 1 and the number of students in the sample file, which is 10. The
script prints that maximum rather than making me guess.

The rows are copied with `awk`, which keeps them byte-for-byte identical,
including each student's existing attendance and absence counts. After
copying, the script counts the rows in the new file and compares that to what
was requested, so a partial copy is reported as a failure instead of being
passed off as success.

## How the fresh-roster option works

Choosing B asks how many students to generate, between 1 and 35. That maximum
comes from two Bash arrays in the script holding sample names and email
addresses, which is the limit I chose for the built-in data.

Each generated row starts at `0` for both counts, and every email address is
unique. The names contain no commas, quotes or newlines, so they cannot break
the CSV structure. As with option A, the row count is verified afterwards.

## Why total_sessions is 5 for the sample and 1 for a fresh roster

This is the part that was easiest to get wrong, so it is worth being precise.

The application compares each student's recorded sessions against
`total_sessions - 1` and prints a note for every student when they disagree.

- The supplied sample roster has ten students who have each already attended
  four sessions (4+0, 1+3, 2+2, 3+1 and so on). The next session is therefore
  session five, so the sample deployment sets `"total_sessions": 5`.
- A generated roster has every count at zero, because nothing has been
  recorded yet. The next session is session one, so a fresh deployment sets
  `"total_sessions": 1`.

The template `config.json` ships with `total_sessions: 5` because it was
written for the sample data. I do not edit the template. The script sets the
value on the *deployed* copy only, choosing 5 or 1 to match the roster that
was actually created, so the two can never disagree.

## How to update warning and failure thresholds

At deployment the script explains what the two thresholds mean and asks
whether I want to change them. The defaults are `warning = 75` and
`failure = 50`. Declining leaves them exactly as the template had them.

If I agree, it asks for the warning value and then the failure value. Typing
`cancel` at either prompt backs out and keeps the defaults.

## Input validation and threshold relationships

Only whole numbers from 0 to 100 inclusive are accepted. Empty input,
`abc`, `-1`, `3.5` and `101` are all rejected, and the script asks again
rather than giving up on the first mistake.

The relationship between the two values is enforced too. The warning alert is
the less severe one, so `warning` must be greater than or equal to `failure`.
Entering a warning of 40 with a failure of 60 is refused, because a student at
50% would trigger the "please be careful" warning and the "will fail" alert at
the same time.

Project names are validated the same way. Only letters, digits, dots, dashes
and underscores are allowed, a name cannot start with a dot, and `..` is
rejected. That is what prevents `../../etc` or `a/b` from building a path
outside the repository.

## File permissions and why config.json uses chmod 600

`attendance_checker.py` gets `chmod 755`. It is the program an instructor
runs, so it needs to be executable.

`Helpers/config.json` gets `chmod 600`, meaning only the owner can read and
write it. It holds class policy settings such as the failure threshold and
the run mode. Keeping it owner-only avoids anyone else on a shared machine
editing the pass mark out of the configuration, and it does not contain
anything that needs to be world-readable.

Rather than assume the commands worked, the script runs `ls -l` afterwards
and compares the result against the expected string, so a failed `chmod` is
reported as an error.

## How to run an existing project

Choose option 2, type the project name, and the script:

- validates the name,
- confirms the directory exists,
- checks that `attendance_checker.py`, `Helpers/assets.csv` and
  `Helpers/config.json` are all present, naming whichever one is missing,
- changes into the project root and runs `python3 attendance_checker.py`.

The program's output goes straight to the terminal so I can mark students. The
script runs it inside a subshell, which means the menu still works from the
repository root when the program exits.

## How to archive attendance and absence logs

Choose option 3 and type the project name. The script looks for:

```
attendance_tracker_<name>/reports/attendance.log
attendance_tracker_<name>/reports/absent.log
```

Each one that exists is copied to:

```
attendance_tracker_<name>/archives/attendance/attendance_YYYYMMDD_HHMMSS.log
attendance_tracker_<name>/archives/absent/absent_YYYYMMDD_HHMMSS.log
```

The full relative destination path is printed for each successful archive.

## Timestamped filenames and archive directories

The timestamp comes from `date '+%Y%m%d_%H%M%S'`, for example
`20260115_093045`.

Two archive runs inside the same second would otherwise produce the same
filename and the second would overwrite the first. The script checks whether
the destination already exists and, if it does, appends `_1`, then `_2`, and
so on. The timestamp pattern is kept intact and no archive is ever lost.

## What happens when one or both logs are missing

Neither log is assumed to exist.

- **Only `attendance.log`:** it is archived and a warning notes that
  `absent.log` was skipped. This is the normal case for a session where every
  student was present, because the application never creates `absent.log` when
  there are no absences to record.
- **Only `absent.log`:** it is archived and `attendance.log` is reported as
  skipped.
- **Neither log:** the script prints a message saying there is nothing to
  archive and returns without creating an archive directory. It does not
  crash.

The original files in `reports/` are never renamed or deleted. Archiving is a
copy, so the running log stays intact and can be archived again later.

## How SIGINT and SIGTSTP handling works

While a deployment is in progress the script installs traps for `SIGINT` and
`SIGTSTP`:

```bash
trap 'handle_deployment_interrupt SIGINT'  INT
trap 'handle_deployment_interrupt SIGTSTP' TSTP
```

Both signals run the same handler, because the assignment treats an
interrupted deployment as a stop rather than something to resume later. That
is the difference from the normal meaning of Ctrl+Z: instead of suspending the
process, it cleans up and exits.

The guard is a variable called `DEPLOY_IN_PROGRESS`. It is set to `yes` right
before the first file is created and reset by `remove_deployment_traps` once
the deployment finishes, before the interactive application starts. When the
handler runs and finds `DEPLOY_IN_PROGRESS` is not `yes`, it prints a short
note and returns without deleting anything. That is what keeps Ctrl+C during
the Python marking session, or at the menu, from being mistaken for an
interrupted deployment.

Only the deployment shell script traps these signals. `attendance_checker.py`
is not modified in any way.

If `zip` fails, or produces a file that is empty or not a readable archive, the
handler says so and **keeps the partial directory**. Deleting it in that case
would throw away the only remaining copy. It only removes the directory once
the archive has been confirmed.

The handler also removes its own trap on entry, so a second Ctrl+C cannot
interrupt the archive it is currently writing.

## How the interruption ZIP file is named

```
attendance_tracker_<name>_archive.zip
```

For a project named `intro_linux` interrupted mid-deployment, the archive is
`attendance_tracker_intro_linux_archive.zip`. It is a real zip file created
with `zip -r`, which is what the `.zip` extension promises.

## What the interruption ZIP contains

Everything that had been created at the moment of interruption, with the
project directory as the top-level entry:

```
attendance_tracker_ctrl/
attendance_tracker_ctrl/attendance_checker.py
attendance_tracker_ctrl/Helpers/
attendance_tracker_ctrl/Helpers/config.json
attendance_tracker_ctrl/reports/
attendance_tracker_ctrl/archives/
attendance_tracker_ctrl/archives/attendance/
attendance_tracker_ctrl/archives/absent/
```

Check it yourself with:

```bash
unzip -l attendance_tracker_intro_linux_archive.zip
```

## What happens to the incomplete directory after a successful archive

It is removed, because that is what the assignment asks for and the archive
now holds a copy of everything in it. The order matters: archive, confirm the
archive is readable, and only then delete. If any step before the deletion
fails, the directory stays and the script says where to find it.

A directory that existed before this deployment and that the user chose to
keep is never touched, because the handler only ever removes the directory
named in `CURRENT_DEPLOY_DIR`, which is set during the current deployment.

## How to test normal deployment

```bash
./deploy_agent.sh
```

Choose 1, enter a name such as `trial`, pick a roster, keep the default
thresholds, and mark every student. The deployment should end with a summary
of the directory structure and a finished marking session.

## How to test the sample-roster and fresh-roster paths

Sample roster: choose 1, then A, and ask for fewer students than the sample
has. Confirm the row count afterwards:

```bash
wc -l attendance_tracker_trial/Helpers/assets.csv
grep total_sessions attendance_tracker_trial/Helpers/config.json
```

The sample path must show `total_sessions` of 5.

Fresh roster: deploy again with a new name, choose B, and check that every
count is zero and that `total_sessions` is 1:

```bash
cat attendance_tracker_trial2/Helpers/assets.csv
grep total_sessions attendance_tracker_trial2/Helpers/config.json
```

## How to test threshold updates

Deploy and answer `y` to the threshold question. Enter a valid pair such as
85 and 60, then:

```bash
grep -A2 thresholds attendance_tracker_trial/Helpers/config.json
```

The warning and failure lines should have changed and the rest of the file
should be untouched. To test rejection, enter `abc` and then `150`; both
should be refused and the script should ask again.

## How to test log archival

After marking a session with at least one absence, choose option 3 and enter
the project name. Then:

```bash
find attendance_tracker_trial/archives -type f
ls attendance_tracker_trial/reports/
```

The archives should be listed with timestamps, and `reports/` should still
contain the original logs.

## How to test Ctrl+C and Ctrl+Z during deployment

Start the script, choose 1, give a name, choose A, and then press Ctrl+C (or
Ctrl+Z) at the "How many of them should I copy?" prompt. The deployment
pauses there for input, which makes it an easy moment to interrupt.

You should see:

```
==================================================
  [WARN] DEPLOYMENT INTERRUPTED (SIGINT)
==================================================
  [WARN] Deployment was interrupted. Archiving the partial project...
  [OK] Archived the partial project to attendance_tracker_<name>_archive.zip
  [OK] Removed the incomplete directory attendance_tracker_<name>

Cleanup finished. Exiting with status 130.
```

Then confirm the archive:

```bash
unzip -l attendance_tracker_<name>_archive.zip
ls -d attendance_tracker_<name>
```

The archive should list the partial files, and the second command should
report "No such file or directory" because the directory was removed.

Ctrl+Z does the same thing here rather than suspending the process.

## How to inspect file permissions

```bash
ls -l attendance_tracker_trial/attendance_checker.py
ls -l attendance_tracker_trial/Helpers/config.json
```

Expect `-rwxr-xr-x` for the application and `-rw-------` for the
configuration.

## How I verified the deployed directory structure

With `find`, which lists the whole tree:

```bash
find attendance_tracker_trial | sort
```

and with `ls -lR` when I want to see the permissions at the same time. I also
compare the deployed application against the original:

```bash
cmp templates/attendance_checker.py attendance_tracker_trial/attendance_checker.py
```

which prints nothing when the two files are identical.

## Running the tests

```bash
bash tests/test_deploy_agent.sh
```

The harness creates a throwaway directory under `$TMPDIR`, runs every test
there, and deletes it when it finishes. Nothing is created in the repository.
To keep the directory for inspection:

```bash
KEEP_TEST_DIR=1 bash tests/test_deploy_agent.sh
```

It exits 0 when everything passes and 1 if anything fails.

## Troubleshooting

**"python3 is not installed."** Install Python 3 and make sure it is on your
PATH. On Debian or Ubuntu, `sudo apt install python3`.

**"zip is not installed."** On Debian or Ubuntu, `sudo apt install zip`. It is
already present on macOS.

**"Missing template file."** The `templates/` directory is incomplete. Restore
it from the repository; the script never modifies those files.

**"The project name cannot start with a dot"** or similar. Use a name made of
letters, digits, dashes, dots or underscores.

**"No project directory found."** The name does not match an existing
deployment. The directory name includes the `attendance_tracker_` prefix, so
type only the part after it.

**"The project is incomplete: X is missing."** A required file was deleted
from a deployed project. Deploy again and accept the replacement.

**"The attendance checker exited with status 1."** The program ran out of
input part way through a session, which happens if stdin is closed. The
roster and logs stay consistent; mark the remaining students on the next run.

**Ctrl+Z suspends instead of cleaning up.** A suspended job can be resumed
with `fg`. The handler only runs while the deployment is in progress; outside
that window Ctrl+Z keeps its normal meaning.

## Testing results

I ran `bash tests/test_deploy_agent.sh` on macOS with Bash 3.2.57 and Python
3.9.6. All 118 checks passed.

What that covers:

- `bash -n deploy_agent.sh` reports no syntax errors.
- The dependency check finds `python3`, prints its version, and finds `zip`.
- Project name validation rejects empty names, `..`, `../etc`, `a/b`, spaces,
  leading dots, backslashes and embedded `..`, and accepts ordinary names.
- Numeric validation rejects empty, non-numeric, negative, decimal and
  out-of-range threshold input, and accepts 0 to 100.
- A sample deployment creates the exact directory tree, with `reports/` empty.
- The deployed `attendance_checker.py` is byte-for-byte identical to the
  template, confirmed with `cmp`.
- The deployed config matches the template apart from `total_sessions`.
- A sample roster of 4 keeps the header, has exactly 4 rows, and the rows
  match the source file.
- The sample deployment has `total_sessions` 5; the fresh deployment has 1.
- A fresh roster has every count at 0 and all-unique email addresses.
- `attendance_checker.py` is `-rwxr-xr-x` and `Helpers/config.json` is
  `-rw-------`, both after deployment and after a config rewrite.
- Threshold edits change only the intended lines, survive the 600 mode, and
  malformed JSON is caught by the validator.
- Invalid thresholds are rejected, the script re-asks, `cancel` keeps the
  defaults, and a warning below the failure threshold is not applied.
- Declining an overwrite returns "no" and changes nothing on disk.
- The genuine application runs: a three-student session exits 0, reports
  "Marked 3 students", writes both log files, and updates the roster counts.
- Archiving works with both logs, with only `attendance.log`, with only
  `absent.log`, and with neither. Archive names and directories are correct,
  originals are preserved, archived copies match, and two archives with the
  same timestamp do not overwrite each other.
- The interruption handler exits 130, creates a readable
  `<project>_archive.zip`, contains the partial files, and removes the
  directory only after the archive succeeds.
- A real `kill -INT` and a real `kill -TSTP` delivered to a live process each
  trigger the same cleanup.
- Typing an actual Ctrl+C and an actual Ctrl+Z into a pseudo-terminal running
  the real script each interrupt the deployment, produce the archive, remove
  the directory, and exit 130.
- Ctrl+C while no deployment is in progress leaves existing projects
  untouched.

Things I could not verify here:

- **ShellCheck was not run.** It is not installed on my machine, and I chose
  not to install extra packages. The harness prints a SKIP line saying so
  rather than pretending it ran.
- **Real multi-user permission failures were not forced.** I did not try to
  deploy into a directory where `mkdir` or `chmod` genuinely fails. The error
  paths are written and the results are checked with `ls -l`, but they were
  not exercised on a real permission error.

## Demonstration video

I plan to show the menu, one full deployment using the sample roster, one
using the fresh roster, a threshold update, log archival, and a Ctrl+C during
deployment that produces the interruption ZIP.

Demonstration video: [Paste my video link here]
