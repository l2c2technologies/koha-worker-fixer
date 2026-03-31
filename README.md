# koha-worker-fix
A diagnostic and recovery script for Koha background worker daemons on multi-tenant Debian/Ubuntu installations managed by L2C2 Technologies.

---

## Background

Koha's background job processing relies on two queues: `default` and `long_tasks`. Each queue is served by a `background_jobs_worker.pl` process managed by the `daemon` utility. Under certain failure conditions -- most commonly a worker crash on a freshly restored database instance, or an unclean shutdown -- the worker dies but leaves behind stale `.pid` and `.clientpid` files in `/var/run/koha/<instance>/`.

When `koha-common` or `koha-worker` attempts to start the worker, it calls `is_worker_running`, which finds the stale pidfiles and returns true. The start is silently skipped. The queue remains unserved and background jobs (MARC staging, import, patron bulk operations) sit at 0% indefinitely with status "Not started".

This script detects and repairs that condition across any set of instances.

---

## Requirements

- Must be run as `root` (or via `sudo`)
- `koha-list`, `koha-worker`, and `daemon` must be available in `PATH`
- `/etc/default/koha-common` must be present (standard on package installs)
- Tested on Koha 24.x, Debian 12 / Ubuntu 22.04+

---

## Installation

```bash
sudo cp koha-worker-fix.sh /usr/local/sbin/
sudo chmod 750 /usr/local/sbin/koha-worker-fix.sh
```

---

## Usage

```bash
# specific instance
sudo koha-worker-fix.sh <instance>

# multiple instances
sudo koha-worker-fix.sh <instance1> <instance2> <instance3>

# all enabled instances
sudo koha-worker-fix.sh
```

---

## What it checks

For each instance and each queue (`default`, `long_tasks`):

| Check | Detail |
|-------|--------|
| `.pid` file | Exists, non-empty, and PID is alive (`kill -0`) |
| `.clientpid` file | Exists, non-empty, and PID is alive (`kill -0`) |

State is classified as:

| State | Meaning |
|-------|---------|
| `running` | Both pidfiles present and both PIDs alive |
| `stale` | Pidfiles present but one or both PIDs are dead |
| `missing` | No pidfiles found |

---

## What it fixes

1. On `stale`: stops the daemon gracefully, purges the stale pidfiles, restarts
2. On `missing`: starts the worker directly
3. Tries `koha-worker --start` first (standard path, reads `/etc/default/koha-common`)
4. Falls back to a direct `daemon` invocation with explicit `KOHA_CONF` and `PERL5LIB` if `koha-worker` fails
5. Re-verifies state after each fix attempt
6. Dumps the last 10 lines of `worker-error.log` and `worker-output.log` on failure

---

## Example output

Healthy instance:

```
koha-worker debugger -- queues: default long_tasks
Instances: library
--- instance: library ---
[ OK ]  Worker [default] running
[ OK ]  Worker [long_tasks] running
[ OK ]  All workers healthy, no action taken
[ OK ]  All done.
```

Stale pidfile repaired:

```
koha-worker debugger -- queues: default long_tasks
Instances: library
--- instance: library ---
[ OK ]  Worker [default] running
[WARN]  Worker [long_tasks] has stale pidfiles -- cleaning up
[WARN]  Removed stale pidfile: /var/run/koha/library/library-koha-worker-long_tasks.pid
[WARN]  Removed stale clientpid: /var/run/koha/library/library-koha-worker-long_tasks.clientpid
[INFO]  Attempting: koha-worker --start --queue long_tasks library
[ OK ]  Started via koha-worker
[ OK ]  Worker [long_tasks] confirmed running after fix
[ OK ]  All done.
```

---

## Why the fallback exists

On instances provisioned from a restored database dump (rather than a fresh `koha-create`), the instance user environment is not always fully initialised before `koha-common` first starts. The `background_jobs_worker.pl` process needs `KOHA_CONF` and `PERL5LIB` in its environment. `koha-worker` reads these from `/etc/default/koha-common` and the instance config, but if the worker exits with code 2 (Perl compilation failure) the pidfiles are still written, causing all subsequent `koha-worker --start` calls to bail with "already running". The fallback injects the env vars directly via `daemon -- /usr/bin/env`.

---

## Author
Indranil Das Gupta
