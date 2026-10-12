"""Integration tests for the monitor using temporary fake power and lid inputs."""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT / "Resources" / "power-monitor.sh"


class PowerMonitorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="lid-awake-test-")
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.support = self.root / "support"
        self.bin.mkdir()
        self.support.mkdir()
        (self.support / "override-active").write_text("0\n")
        self.state_file = self.root / "enabled"
        self.state_file.write_text("1\n")
        self.write("power", "AC Power")
        self.write("lid", "Yes")
        self.write("sleep-disabled", "0")
        self.write("ticks", "0")
        self.write("ioreg-count", "0")
        self.write("sleepnow-count", "0")
        self.write("changes", "")
        self.install_stubs()
        self.monitor = self.root / "power-monitor.sh"
        self.monitor.write_text(self.make_test_copy())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, value: str) -> None:
        (self.root / name).write_text(value)

    def make_test_copy(self) -> str:
        source = MONITOR.read_text()
        replacements = {
            "pmset=/usr/bin/pmset": f"pmset={shlex.quote(str(self.bin / 'pmset'))}",
            "ioreg=/usr/sbin/ioreg": f"ioreg={shlex.quote(str(self.bin / 'ioreg'))}",
            "sleep_bin=/bin/sleep": f"sleep_bin={shlex.quote(str(self.bin / 'tick'))}",
            'support_dir="/Library/Application Support/Lid Awake (Public Build)"': f"support_dir={shlex.quote(str(self.support))}",
            '/usr/sbin/chown root:wheel "$temporary" || return 1': ": # ownership is irrelevant in the private test directory",
        }
        for old, new in replacements.items():
            if source.count(old) != 1:
                raise AssertionError(f"Expected exactly one test seam for {old!r}")
            source = source.replace(old, new, 1)
        return source

    def install_stubs(self) -> None:
        pmset = r'''#!/bin/sh
set -eu
case "${1-}:${2-}" in
    -g:batt)
        source=$(cat "$TEST_ROOT/power")
        printf "Now drawing from '%s'\n" "$source"
        ;;
    -g:everything)
        printf 'System-wide power settings:\nCurrently in use:\n SleepDisabled %s\nINVOKE:\n' "$(cat "$TEST_ROOT/sleep-disabled")"
        ;;
    -a:disablesleep)
        printf '%s\n' "$3" >> "$TEST_ROOT/changes"
        printf '%s\n' "$3" > "$TEST_ROOT/sleep-disabled"
        ;;
    sleepnow:)
        count=$(cat "$TEST_ROOT/sleepnow-count")
        count=$((count + 1))
        printf '%s\n' "$count" > "$TEST_ROOT/sleepnow-count"
        if [ -f "$TEST_ROOT/fail-sleep-once" ]; then
            /bin/rm -f "$TEST_ROOT/fail-sleep-once"
            exit 1
        fi
        ;;
    *)
        echo "unexpected pmset args: $*" >&2
        exit 64
        ;;
esac
'''
        ioreg = r'''#!/bin/sh
set -eu
count=$(cat "$TEST_ROOT/ioreg-count")
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_ROOT/ioreg-count"
if [ "$SCENARIO" = retry-lid-read ] && [ "$count" -eq 1 ]; then
    exit 1
fi
if [ "$SCENARIO" = reconnect ] && [ "$count" -eq 1 ]; then
    printf 'AC Power' > "$TEST_ROOT/power"
fi
printf '    | "AppleClamshellState" = %s\n' "$(cat "$TEST_ROOT/lid")"
'''
        tick = r'''#!/bin/sh
set -eu
count=$(cat "$TEST_ROOT/ticks")
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_ROOT/ticks"
case "$SCENARIO:$count" in
    unplug-sleep:1|retry-lid-read:1|retry-sleep:1|lid-open:1|reconnect:1)
        printf 'Battery Power' > "$TEST_ROOT/power"
        ;;
esac
case "$SCENARIO:$count" in
    lid-open:1) printf 'No' > "$TEST_ROOT/lid" ;;
    disable:1) printf '0\n' > "$TEST_ROOT/enabled" ;;
esac
if [ "$count" -ge "$STOP_AFTER_TICKS" ]; then
    /bin/kill -TERM "$PPID"
fi
/bin/sleep 0.01
'''
        for name, content in (("pmset", pmset), ("ioreg", ioreg), ("tick", tick)):
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o755)

    def run_monitor(self, scenario: str, stop_after_ticks: int = 4) -> None:
        env = os.environ.copy()
        env.update(
            TEST_ROOT=str(self.root),
            SCENARIO=scenario,
            STOP_AFTER_TICKS=str(stop_after_ticks),
        )
        process = subprocess.Popen(
            ["/bin/sh", str(self.monitor), str(self.state_file)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            _, stderr = process.communicate()
            self.fail(f"monitor did not stop within the test window: {stderr}")
        self.assertEqual(process.returncode, -signal.SIGTERM, stderr)

    def test_unplug_with_closed_lid_restores_sleep_and_requests_sleep_once(self) -> None:
        self.run_monitor("unplug-sleep")
        self.assertEqual((self.root / "sleep-disabled").read_text().strip(), "0")
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "1")
        self.assertEqual((self.support / "status").read_text().strip(), "battery")
        self.assertFalse((self.support / "pending-lid-sleep").exists())

    def test_transient_lid_read_failure_preserves_and_retries_sleep_request(self) -> None:
        self.run_monitor("retry-lid-read")
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "1")
        self.assertGreaterEqual(int((self.root / "ioreg-count").read_text()), 3)
        self.assertFalse((self.support / "pending-lid-sleep").exists())

    def test_failed_sleep_request_is_retried(self) -> None:
        (self.root / "fail-sleep-once").touch()
        self.run_monitor("retry-sleep")
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "2")
        self.assertFalse((self.support / "pending-lid-sleep").exists())

    def test_open_lid_clears_unplug_sleep_request(self) -> None:
        self.run_monitor("lid-open")
        self.assertEqual((self.root / "sleep-disabled").read_text().strip(), "0")
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "0")
        self.assertFalse((self.support / "pending-lid-sleep").exists())

    def test_reconnected_power_clears_request_and_restores_awake_mode(self) -> None:
        self.run_monitor("reconnect", stop_after_ticks=2)
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "0")
        self.assertEqual((self.root / "sleep-disabled").read_text().strip(), "1")
        self.assertFalse((self.support / "pending-lid-sleep").exists())

    def test_turning_switch_off_restores_the_saved_setting(self) -> None:
        self.run_monitor("disable", stop_after_ticks=2)
        self.assertEqual((self.root / "enabled").read_text().strip(), "0")
        self.assertEqual((self.root / "sleep-disabled").read_text().strip(), "0")
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "0")

    def test_unplug_sleep_and_disable_preserve_a_preexisting_sleep_override(self) -> None:
        self.write("sleep-disabled", "1")
        self.run_monitor("unplug-sleep")
        self.assertEqual((self.root / "sleepnow-count").read_text().strip(), "1")
        self.assertEqual((self.root / "sleep-disabled").read_text().strip(), "0")
        self.assertEqual((self.support / "baseline").read_text().strip(), "1")

        self.state_file.write_text("0\n")
        self.run_monitor("settle", stop_after_ticks=1)
        self.assertEqual((self.root / "sleep-disabled").read_text().strip(), "1")
        self.assertEqual((self.support / "override-active").read_text().strip(), "0")


if __name__ == "__main__":
    unittest.main()
