#!/usr/bin/env python3
"""Static safety checks for the private-to-public sync workflow."""

from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "sync-to-public.yml"
TEST_SYNC_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "test-sync.yml"
WAIT_AND_MERGE = REPO_ROOT / ".github" / "scripts" / "wait-and-merge.sh"
FORCE_FULL_SCRIPT = (
    REPO_ROOT / ".github" / "scripts" / "force-full-direct-push.sh"
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


workflow = WORKFLOW.read_text(encoding="utf-8")
lines = workflow.splitlines()

try:
    on_start = lines.index("on:")
except ValueError:
    fail("sync workflow has no top-level 'on:' block")

on_end = next(
    (
        index
        for index in range(on_start + 1, len(lines))
        if lines[index] and not lines[index].startswith(" ")
    ),
    len(lines),
)
trigger_keys = [
    match.group(1)
    for line in lines[on_start + 1 : on_end]
    if (match := re.match(r"^  ([A-Za-z0-9_-]+):", line))
]
if trigger_keys != ["workflow_dispatch"]:
    fail(f"expected only workflow_dispatch trigger, found: {trigger_keys}")

if re.search(r"\bforce_full\b|\bFORCE_FULL\b", workflow):
    fail("sync workflow still exposes force_full")

if "additional_paths:" not in workflow:
    fail("sync workflow does not expose additional_paths")
if "assert-sync-scope.sh" not in workflow:
    fail("sync workflow does not validate the generated path scope")

if FORCE_FULL_SCRIPT.exists():
    fail("force-full-direct-push.sh still exists")

direct_main_push = re.compile(
    r"^\s*git\s+push\b[^\n]*(?:refs/heads/main|(?:^|\s)main(?:\s|$))"
)
for path in [
    *sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml")),
    *sorted((REPO_ROOT / ".github" / "scripts").glob("*.sh")),
]:
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if line.lstrip().startswith("#"):
            continue
        if direct_main_push.search(line):
            fail(f"direct push to public main remains at {path}:{line_number}")

create_pr = workflow.find("gh pr create")
save_marks = workflow.find("- name: Save marks cache")
merge_pr = workflow.rfind("wait-and-merge.sh", 0, save_marks)
if min(create_pr, merge_pr, save_marks) < 0:
    fail("incremental PR, in-run merge, or marks-save step is missing")
if not create_pr < merge_pr < save_marks:
    fail("marks must be saved only after the public PR is created and merged")

wait_and_merge_call = workflow[merge_pr:save_marks]
for required_env in [
    "SYNC_SCOPE_ASSERT_SCRIPT",
    "SYNC_SCOPE_PUBLIC_REPO",
    "SYNC_SCOPE_CONFIG",
    "SYNC_ADDITIONAL_PATHS",
]:
    if required_env not in workflow:
        fail(f"sync workflow does not pass {required_env} to the merge guard")

wait_and_merge = WAIT_AND_MERGE.read_text(encoding="utf-8")
test_sync_workflow = TEST_SYNC_WORKFLOW.read_text(encoding="utf-8")
if ".github/scripts/assert-sync-scope.sh" not in test_sync_workflow:
    fail("sync test workflow does not run when assert-sync-scope.sh changes")
if "--squash" in wait_and_merge:
    fail("wait-and-merge still permits orphan-history squash fallback")
if "assert-sync-scope.sh" not in wait_and_merge:
    fail("wait-and-merge does not recheck the generated path scope")
if "--match-head-commit" not in wait_and_merge:
    fail("wait-and-merge does not bind the merge to the guarded PR head")
if "baseRefName" not in wait_and_merge:
    fail("wait-and-merge does not bind the merge to public main")

print("PASS: sync workflow is manual-only, scoped, and has no direct-main publish path")
