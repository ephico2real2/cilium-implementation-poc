#!/usr/bin/env python3
"""Usage: test_key_isolation.py <compose.yaml>   (needs podman and the lab's images; certs/ and
secrets/ generated; starts nothing of the lab's)

Keys and secrets are kept apart by UID alone: the tls and secrets volumes hold every
component's copy, each readable only by its owner. So:
  1. no bind mount reaches the CA's private key (certs/ca/ca.key);
  2. the services that mount tls or secrets each run as a different UID;
  3. no service that can read past file modes (DAC_READ_SEARCH, DAC_OVERRIDE) mounts them;
  4. every long-running service has a UID of its own (mq-client shares the queue manager's
     1001 by design and mounts none of its volumes; init is a one-shot root);
  5. init-volumes.sh still works with only the mounts and the hardening compose gives it (read-only
     root, its capabilities), and twice in a row, as on every `podman compose up` of a lab that
     already exists: the second run leaves the same owners and modes and nothing of an older
     layout behind (run in a throwaway container, named volumes replaced by tmpfs).
Exits with the number of failed checks.
"""
import json
import pathlib
import subprocess
import sys

SHARED = {"tls", "secrets"}
READ_PAST_MODES = {"DAC_READ_SEARCH", "CAP_DAC_READ_SEARCH", "DAC_OVERRIDE", "CAP_DAC_OVERRIDE"}
UID_EXEMPT = {"init", "mq-client"}


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def uid_of(service: dict) -> str:
    user = service.get("user") or run("podman", "image", "inspect", service["image"], "--format", "{{.Config.User}}").strip()
    user = user.split(":")[0]
    return {"": "0", "root": "0", "nobody": "65534"}.get(user, user)


def main() -> int:
    compose = pathlib.Path(sys.argv[1]).resolve()
    config = json.loads(run("podman", "compose", "-f", str(compose), "--profile", "tools", "config", "--format", "json"))
    services = config["services"]
    failures = []

    for name, svc in services.items():
        for vol in svc.get("volumes", []):
            if vol["type"] != "bind":
                continue
            src = pathlib.Path(vol["source"])
            if src.name == "ca.key" or (src.is_dir() and any(src.rglob("ca.key"))):
                failures.append(f"1. {name} mounts {src}, which holds the CA's private key")

    for volume in sorted(SHARED):
        users = {}
        for name, svc in services.items():
            if name == "init":
                continue  # the one-shot writer of every copy
            if any(v["type"] == "volume" and v["source"] == volume for v in svc.get("volumes", [])):
                users.setdefault(uid_of(svc), []).append(name)
                caps = set(svc.get("cap_add", []))
                if caps & READ_PAST_MODES:
                    failures.append(f"3. {name} mounts {volume} with {sorted(caps & READ_PAST_MODES)}")
        for uid, names in users.items():
            if len(names) > 1:
                failures.append(f"2. {volume}: {', '.join(sorted(names))} all run as UID {uid}")

    owners = {}
    for name, svc in services.items():
        if name not in UID_EXEMPT:
            owners.setdefault(uid_of(svc), []).append(name)
    for uid, names in owners.items():
        if len(names) > 1:
            failures.append(f"4. {', '.join(sorted(names))} share UID {uid}")

    init = services["init"]
    args = ["podman", "run", "--rm", "--network", "none"]
    # init's own hardening, so a capability it needs and lacks fails here, not on the next rebuild.
    if init.get("read_only"):
        args.append("--read-only")
    args += [f"--cap-drop={cap}" for cap in init.get("cap_drop", [])]
    args += [f"--cap-add={cap}" for cap in init.get("cap_add", [])]
    args += [f"--security-opt={opt}" for opt in init.get("security_opt", [])]
    targets = []
    for vol in init["volumes"]:
        if vol["type"] == "bind":
            args += ["-v", f"{vol['source']}:{vol['target']}:ro"]
        else:
            args += ["--tmpfs", vol["target"]]
            targets.append(vol["target"])
    script = next(v["target"] for v in init["volumes"] if v["target"].endswith("init-volumes.sh"))
    # Owners and modes of everything init writes; a store's own files under data/ are not init's.
    snapshot = f"find {' '.join(targets)} -maxdepth 2 ! -path '*/data/*' -exec stat -c '%a %u %n' {{}} + | sort"
    # Between the runs: a store writes as its own UID inside its 0700 data folder, and a lab
    # from before pg-secrets left a root-owned /secrets/postgres.
    probe = f"""
sh {script} >/dev/null || {{ echo "first run failed"; exit 1; }}
first="$({snapshot})"
mkdir -m 0700 /stores/tempo/data/blocks && chown 10004 /stores/tempo/data/blocks
mkdir -p /secrets/postgres && echo old > /secrets/postgres/postgres-password && chmod 0500 /secrets/postgres
sh {script} >/dev/null || {{ echo "second run failed"; exit 1; }}
second="$({snapshot})"
[ "$first" = "$second" ] || {{ echo "second run differs:"; echo "$second" | grep -vxF -e "$first"; exit 1; }}
ls -n /tls/ca/ca.crt /pg-secrets/postgres/postgres-password >/dev/null && ! ls -d /secrets/postgres 2>/dev/null
"""
    result = subprocess.run([*args, init["image"], "sh", "-c", probe], capture_output=True, text=True)
    if result.returncode != 0:
        failures.append(f"5. init-volumes.sh with compose's mounts and hardening, run twice: exit "
                        f"{result.returncode}: {(result.stdout + result.stderr).strip()[:300]}")

    for line in failures:
        print("FAIL ", line)
    print(f"failures: {len(failures)}")
    return len(failures)


if __name__ == "__main__":
    sys.exit(main())
