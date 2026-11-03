"""Run the real generator entry in a sandbox, without GitHub or shared /tmp files.

Usage: python3 -m unittest discover -s tests -v
GENERATE_SH can point at a baseline script to reproduce the retry regression.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("GENERATE_SH", ROOT / "generate.sh"))

FAKE_GH = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
query = next(arg[6:] for arg in args if arg.startswith("query="))
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps(args) + "\n")
if "user(login:" not in query:
    print(json.dumps({"data": {"search": {"nodes": []}}}))
    sys.exit(0)
count_path = root / "attempts"
attempt = int(count_path.read_text()) + 1 if count_path.exists() else 1
count_path.write_text(str(attempt))
mode = os.environ["FIXTURE_MODE"]
status = {"recover": 502, "exhaust": 503, "401": 401, "403": 403, "429": 429}.get(mode)
if (mode == "recover" and attempt == 1) or mode in ("exhaust", "401", "403", "429", "syntax"):
    # gh can emit earlier pages before a later request fails; never reuse these.
    print('[{"data":{"user":{"repositories":{"nodes":[{"name":"stale"}]}}}}]')
    print('{"message":"failure"')
    if mode == "syntax":
        print('gh: Expected NAME, actual: RCURLY ("}")', file=sys.stderr)
    elif mode == "recover":
        print('gh: HTTP 502', file=sys.stderr)
    else:
        print('gh: Service unavailable (HTTP %s)' % status, file=sys.stderr)
    sys.exit(1)
nodes = [{"name": "repo-%02d" % i, "description": "Description %d" % i,
          "createdAt": "2025-01-%02dT00:00:00Z" % (i + 1),
          "stargazerCount": i, "url": "https://github.com/fixture/repo-%02d" % i,
          "homepageUrl": "https://example.test/%d" % i if i == 0 else "",
          "isArchived": False, "primaryLanguage": {"name": "Python"},
          "repositoryTopics": {"nodes": [{"topic": {"name": "fixture"}}]},
          "defaultBranchRef": {"target": {"history": {"totalCount": i + 20}}}}
         for i in range(23)]
# Model gh's documented cursor contract: --paginate alone cannot advance $cursor.
size = 20 if "first: 20," in query else 100
pages = [nodes[i:i + size] for i in range(0, len(nodes), size)]
if not ("$endCursor: String" in query and "after: $endCursor," in query):
    pages = pages[:1]
print(json.dumps([{"data": {"user": {"repositories": {
    "nodes": page, "pageInfo": {"hasNextPage": i < len(pages) - 1,
                                  "endCursor": "cursor-%d" % i}}}}}
    for i, page in enumerate(pages)]))
'''


class GenerateTest(unittest.TestCase):
    def run_generator(self, mode):
        temp = tempfile.TemporaryDirectory(prefix="test-generate-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        work = root / "work"
        work.mkdir()
        scratch = root / "scratch"
        scratch.mkdir()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        # Only relocate pre-existing fixed /tmp paths, not the production API logic.
        script = SOURCE.read_text().replace("/tmp/", str(scratch) + "/")
        (work / "generate.sh").write_text(script)
        for name in ("data.js", "history.js", "index.html"):
            shutil.copyfile(ROOT / name, work / name)
        (work / "history.jsonl").write_text('{"date":"2025-01-01","title":"Fixture"}\n')
        before = {name: (work / name).read_bytes()
                  for name in ("data.js", "history.js", "index.html")}
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        (bin_dir / "sleep").write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$FIXTURE_ROOT/sleeps"\n')
        (bin_dir / "sleep").chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   TMPDIR=str(scratch), FIXTURE_ROOT=str(root), FIXTURE_MODE=mode)
        result = subprocess.run(["bash", "generate.sh", "fixture"], cwd=work,
                                env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
        sleeps = (root / "sleeps").read_text().splitlines() if (root / "sleeps").exists() else []
        self.assertEqual(list(scratch.glob("portfolio-own.*")), [], "owned API temp files leaked")
        return root, work, before, result, calls, sleeps

    def assert_generated_data(self, work):
        text = (work / "data.js").read_text()
        repos_text, totals_text = text.removeprefix("window.REPOS = ").split(";\nwindow.TOTALS = ")
        repos = json.loads(repos_text)
        totals = json.loads(totals_text.removesuffix(";\n"))
        self.assertEqual(len(repos), 23, "must retain every page exactly once")
        self.assertEqual({r["name"] for r in repos}, {"repo-%02d" % i for i in range(23)})
        self.assertEqual(totals, {"projects": 23, "stars": sum(range(23)),
                                  "commits": sum(range(20, 43)), "since": 2025})
        first = next(r for r in repos if r["name"] == "repo-00")
        self.assertEqual(first, {"name": "repo-00", "description": "Description 0",
                                 "date": "2025-01-01", "stars": 0, "commits": 20,
                                 "lang": "Python", "url": "https://github.com/fixture/repo-00",
                                 "live": "https://example.test/0"})
        self.assertIn("Fixture", (work / "history.js").read_text())
        self.assertIn("Fixture", (work / "index.html").read_text())

    def test_success_retains_all_pages_and_fields(self):
        _, work, _, result, calls, sleeps = self.run_generator("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        own = calls[0]
        query = next(arg[6:] for arg in own if arg.startswith("query="))
        self.assertIn("$endCursor: String", query)
        self.assertIn("repositories(first: 20, after: $endCursor, privacy: PUBLIC, ownerAffiliations: OWNER, isFork: false, orderBy: {field: CREATED_AT, direction: DESC})", query)
        self.assertIn("pageInfo { hasNextPage endCursor }", query)
        self.assertIn("--paginate", own)
        self.assertIn("--slurp", own)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [])
        self.assert_generated_data(work)

    def test_partial_502_then_success(self):
        _, work, _, result, calls, sleeps = self.run_generator("recover")
        self.assertEqual(result.returncode, 0, "502 then success must recover:\n" + result.stderr)
        self.assertEqual(len(calls), 3, "two own attempts, then topic search")
        self.assertEqual(sleeps, ["2"])
        self.assert_generated_data(work)
        self.assertNotIn("parse error", result.stderr)

    def test_three_5xx_failures_preserve_existing_assets(self):
        _, work, before, result, calls, sleeps = self.run_generator("exhaust")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, ["2", "4"])
        self.assertIn("Failed to fetch own repositories", result.stderr)
        self.assertNotIn("parse error", result.stderr)
        self.assertEqual({name: (work / name).read_bytes() for name in before}, before)

    def test_non_retryable_errors_stop_immediately(self):
        for mode in ("401", "403", "429", "syntax"):
            with self.subTest(mode=mode):
                _, work, before, result, calls, sleeps = self.run_generator(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                self.assertEqual(sleeps, [])
                self.assertIn("Failed to fetch own repositories", result.stderr)
                self.assertNotIn("parse error", result.stderr)
                self.assertEqual({name: (work / name).read_bytes() for name in before}, before)


if __name__ == "__main__":
    unittest.main()
