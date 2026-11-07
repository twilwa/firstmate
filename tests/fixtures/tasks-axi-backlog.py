"""Non-delegating tasks-axi fixture: JSON stands in for an explicitly addressed br DB."""
import json
import os
from pathlib import Path
import re
import sys

args = sys.argv[1:]
if args == ["--version"]:
    print("tasks-axi 99.0.0")
    sys.exit(0)
if "--help" in args:
    print("mv <id> [<id>...] --to <path> --to-backend <backend> --json --effort --archive-body")
    sys.exit(0)
command = args.pop(0)


def flag(name, default=None):
    if name not in args:
        return default
    index = args.index(name)
    args.pop(index)
    return args.pop(index)


backend = flag("--backend", os.environ.get("TASKS_AXI_BACKEND", "markdown"))
path = Path(flag("--file", os.environ.get("TASKS_AXI_BEADS_PATH", "data/backlog.md")))
if backend == "beads" and path.suffix != ".db":
    path /= "beads.db"
if backend == "beads" and not path.is_absolute():
    path = Path.cwd() / path
if os.environ.get("FM_TEST_AXI_LOG"):
    with open(os.environ["FM_TEST_AXI_LOG"], "a") as log:
        log.write(json.dumps({"command": command, "backend": backend, "path": str(path), "args": args}) + "\n")


def load(store, kind):
    if not store.exists():
        return {}
    if kind == "beads":
        return json.loads(store.read_text())
    tasks = {}
    state = "queued"
    current = None
    for line in store.read_text().splitlines():
        if line.startswith("## "):
            state = {"## In flight": "in_flight", "## Queued": "queued", "## Done": "done"}[line]
            current = None
        match = re.match(r"- \[[ x]\] ([^ ]+) - (.*)", line)
        if match:
            current = match[1]
            tasks[current] = {"state": state, "title": match[2], "body": []}
        elif current and line.startswith("  "):
            tasks[current]["body"].append(line)
    return tasks


def save(store, kind, tasks):
    store.parent.mkdir(parents=True, exist_ok=True)
    if kind == "beads":
        store.write_text(json.dumps(tasks))
        return
    lines = []
    for state, heading in [("in_flight", "In flight"), ("queued", "Queued"), ("done", "Done")]:
        lines.append("## " + heading)
        for key, task in tasks.items():
            if task["state"] == state:
                lines.append("- [ ] " + key + " - " + task["title"])
                lines.extend(task["body"])
        lines.append("")
    store.write_text("\n".join(lines))


if command == os.environ.get("FM_TEST_AXI_FAIL_COMMAND") and (
    not os.environ.get("FM_TEST_AXI_FAIL_KEY")
    or os.environ["FM_TEST_AXI_FAIL_KEY"] in load(path, backend)
):
    print("error: fixture backend unavailable\ncode: IO_ERROR", file=sys.stderr)
    sys.exit(1)

tasks = load(path, backend)
if command == "show":
    if args[0] not in tasks:
        print("error: task not found\ncode: NOT_FOUND", file=sys.stderr)
        sys.exit(1)
    print("task:\n  id: " + args[0] + "\n  state: " + tasks[args[0]]["state"])
elif command == "list":
    save(path, backend, tasks)
    print("tasks: []")
elif command == "render":
    # Controlled fixtures use this single native project-config setting. No
    # parent discovery, real br invocation or installed CLI delegation occurs.
    config = Path.cwd() / ".tasks.toml"
    mirror = re.search(r'^mirror = "([^"]+)"$', config.read_text(), re.MULTILINE) if config.exists() else None
    if mirror is None:
        print("error: backend beads does not support render without beads.mirror\ncode: UNSUPPORTED", file=sys.stderr)
        sys.exit(1)
    save(Path(mirror[1]), "markdown", tasks)
elif command == "mv":
    target = Path(flag("--to"))
    target_backend = flag("--to-backend", backend)
    if target_backend == "beads" and target.suffix != ".db":
        target /= "beads.db"
    destination = load(target, target_backend)
    for key in args:
        if key not in tasks or key in destination:
            sys.exit("invalid move")
    for key in args:
        destination[key] = tasks.pop(key)
    save(target, target_backend, destination)
    save(path, backend, tasks)
    print("moved: " + " ".join(args))
elif command == "rm":
    del tasks[args[0]]
    save(path, backend, tasks)
else:
    sys.exit("unsupported fixture command: " + command)
