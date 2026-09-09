# Rollout Toolkit

A portable shell tool for applying Blue Yonder WMS rollout packages to a repository, or any directory. Supports a dry run preview, a full undo, and a hotfix mode for hotfix based deployments.

## The problem

Blue Yonder WMS customers ship changes as rollout packages: a manifest of directives plus the files those directives reference. This tool only acts on two of those directives, `REPLACE` and `REMOVE`; everything else in a manifest is ignored.

A lot of organizations don't keep their code repositories in sync with their actual LES environment. A rollout gets applied live, the checkout never catches up, and eventually nobody's sure what the repository reflects. This tool applies the same rollout package against any directory to bring it back in sync, with a `--dry-run` preview and a full `--undo`. It also has a hotfix mode, for organizations, particularly those on Blue Yonder SaaS, that deploy through a hotfix process instead of a plain rollout.

## Install

```sh
git clone https://github.com/ahmadharis/rollouttoolkit.git
cd rollouttoolkit
```

bash 3.2 or newer, POSIX utilities only, no GNU-only flags. Runs unmodified on macOS, Linux, and on Windows through Git Bash. One script plus a `lib/` folder of plain shell files, copy it anywhere and run it.

## What it does

- Applies a rollout's `REPLACE` and `REMOVE` directives to a target directory. Everything else in a manifest is ignored.
- Full planning pass before anything is written, so `--dry-run` shows the exact plan a real run would execute.
- `--undo` reverses `REPLACE` directives. Removals can't be undone, there's nothing to restore from.
- Two resolution modes, `rollout` (default) and `hotfix`, set once in a config file. See "The two modes" below.
- A standalone `--combine` command rebuilds a table's consolidated csv on demand. See "Manual load data consolidation" below.
- One timestamped log file per run, never overwritten. One line per directive, with the outcome and which rule decided the destination.

## Walkthrough

This builds the smallest possible rollout and applies it.

**1. Build a rollout.** A rollout is a directory containing a manifest file named after the directory itself, plus the files it delivers under `pkg/`.

```sh
mkdir -p my-rollout/pkg/src/cmdsrc/reorder
cat > my-rollout/pkg/src/cmdsrc/reorder/reorder_check.mcmd <<'EOF'
<command>
<name>reorder check</name>
<description>basic sample reorder check</description>
<type>Local Syntax</type>
<local-syntax>
<![CDATA[
publish data
 where status = 'ok'
]]>
</local-syntax>
</command>
EOF
printf 'REPLACE pkg/src/cmdsrc/reorder/reorder_check.mcmd $LESDIR/src/cmdsrc/reorder/reorder_check.mcmd\n' > my-rollout/my-rollout
```

One `REPLACE` directive: take the file from the rollout and place it at `$LESDIR/src/cmdsrc/reorder/reorder_check.mcmd` in the target. With no config file present, `TYPE` defaults to `rollout`, so `$LESDIR` is substituted for the target directory and the rest of the path is used as written.

**2. Preview it.** Any directory works as a target here, it doesn't need to be a real repository.

```sh
mkdir -p my-target
./apply-rollout.sh --dry-run my-rollout my-target
```

```
== plan ==
actions planned  : 1
  by settings    : 0   (the REFS variable)
  by manifest    : 1   (everything else, verbatim)

== execution ==
my-rollout:1 REPLACE would place [manifest] .../my-target/src/cmdsrc/reorder/reorder_check.mcmd

== summary ==
replaced         : 1
```

Nothing was written. `my-target/src/cmdsrc` doesn't exist on disk yet.

**3. Apply it.**

```sh
./apply-rollout.sh my-rollout my-target
cat my-target/src/cmdsrc/reorder/reorder_check.mcmd
```

**4. Undo it.**

```sh
./apply-rollout.sh --undo my-rollout my-target
ls my-target/src/cmdsrc/reorder/reorder_check.mcmd   # No such file or directory
```

Setting `TYPE=hotfix` in a config file changes that resolution logic to be convention aware. See below.

## Usage

```
apply-rollout.sh [options] <package_dir> <target_dir>
apply-rollout.sh --combine <paths...> --folders <a,b> [--target-version <v>]

Options:
  --dry-run              report what would happen; change nothing
  --undo                 reverse a rollout (REPLACE only; REMOVE cannot be undone)
  --version <N>          rewrite year-leading version values in bundle
                         declarations, in transit. Modifies apply, dry run
                         or undo, it has no standalone form
  --combine <paths...>   manual load-data consolidation, processing no directives
  --folders <list>       with --combine: the table folders to rebuild (required)
  --target-version <v>   with --combine: write here instead of the highest version
  -h, --help             print usage and exit

Exit status:
  0  completed with no failed actions
  1  completed, but one or more actions failed
  2  setup error: usage, missing package, no manifest, unwritable log, escaping path
```

## The two modes

Set `TYPE` explicitly in `apply-rollout.conf`. Leaving it blank means `rollout`. An unrecognized value is a setup error, refused before anything is touched. The rollout package itself is never rewritten; only how the tool resolves and processes it changes.

| | `rollout` (default) | `hotfix` |
|---|---|---|
| A path the manifest names | Placed exactly as written, `$VAR` substituted for the target directory | Checked against what the target already declares in its build file and patch config; corrected if it no longer fits |
| A csv delivered into a `bootstraponly` or `safetoload` style folder | Placed like any other file | Placed like any other file, then that folder's csv is rebuilt from scratch under `db/upgrade/<latest>`, from every csv now in the folder |
| REFS style paths (webclient references) | Placed under `REFSDIR_ROOT` / `REFSDIR_WEB` / `REFSDIR_DEPLOY` | Read from the target's own build file and patch config |

## Manual load data consolidation

`--combine` runs the same csv rebuild used automatically under hotfix, but manually, without applying a rollout. Point it at a base path holding table folders and name which ones to rebuild:

```sh
./apply-rollout.sh --combine /opt/app/LES/db/data/bootstraponly --folders les_mls_cat,les_opt_ath
```

This rebuilds `les_mls_cat.csv` and `les_opt_ath.csv` from every csv now in each folder, and writes both into the highest version directory under `db/upgrade`. Both `--combine` and `--folders` are required. There's no default base path and no "every folder" default. It never deletes anything, and `--dry-run` works here too.

Useful after hand editing a record file directly.

## Configuration

See `apply-rollout.conf.example`, every key is documented in place. Every key defaults safely to blank, you only need to set what applies to your destination. Copy it to `apply-rollout.conf` next to the script.

### Custom REFS placement (rollout)

Say your target keeps its webclient references under `refs/` instead of the tool's default `webclient/`:

```
TYPE=rollout
REFSDIR_ROOT=refs
REFSDIR_WEB=web
REFSDIR_DEPLOY=deploy
```

A manifest path like `$REFSDIR/web/a/b.js` now lands at `/opt/app/LES/refs/web/a/b.js` instead of the default `/opt/app/LES/webclient/web/a/b.js`.

### Excluding one tree from consolidation (hotfix)

Say your target runs the hotfix process and has a `widget_retired_queue` tree that shouldn't get a consolidated csv of its own:

```
TYPE=hotfix
LOG_DIR=/var/log/rollout
COMBINE_EXCLUDE=widget_retired_queue
```

`REFSDIR_ROOT` / `REFSDIR_WEB` / `REFSDIR_DEPLOY` aren't set, they're inert under hotfix, since the refs root and layout are read from the target's own build file and patch config instead. `COMBINE_EXCLUDE` keeps `widget_retired_queue` from getting a consolidated csv built, its files still get delivered normally. `COMBINE_PATHS` isn't set either, it only saves typing a base path that's already being passed on the `--combine` command line.

## Tests

```sh
tests/run.sh              # run everything
tests/run.sh combine      # run only tests whose filename contains "combine"
```

A small dependency free suite in plain bash. Each `tests/test_*.sh` builds its own fixture in a temp directory, runs an isolated copy of the tool against it, checks the output and exit code, and cleans up. `tests/run.sh` runs all of them and exits non-zero if anything failed.

Covered: literal resolution under rollout, removals, `--dry-run` leaving the tree untouched, collision detection, an apply then undo round trip, both classes of setup error, the combine rebuild and its header mismatch handling, its required arguments, its refusal to sweep a whole tree by default, and the hotfix path correction itself, exercised against a real minimal build file and patch config.

## License

MIT, see LICENSE.
