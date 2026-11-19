import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


class ServiceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="multi2api test ")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.mod = self.root / "module"
        self.data = self.root / "data"
        self.env = {**os.environ, "MULTI2API_DATA_DIR": str(self.data)}
        self.mod.mkdir()
        shutil.copyfile(ROOT / "ctl.sh", self.mod / "ctl.sh")
        for directory in ("backends", "configs"):
            shutil.copytree(ROOT / directory, self.mod / directory)
        self.bin = self.mod / "bin/opencode2api"
        self.bin.parent.mkdir()
        # The controller manages native executables. Exercise it without QEMU
        # or a phone by swapping just the backend's exec command in this copy.
        shutil.copy2(shutil.which("sleep"), self.bin)
        self.adapter = self.mod / "backends/opencode2api.sh"
        with self.adapter.open("a") as f:
            f.write('\nbackend_exec() { exec "$BIN" 120; }\n')
        self.addCleanup(self.ctl, "stop")
        self.pidfile = self.data / "run/opencode2api.pid"

    def command(self, *args):
        return ["sh", str(self.mod / "ctl.sh"), *args]

    def ctl(self, *args, check=True):
        return subprocess.run(self.command(*args), env=self.env, text=True,
                              capture_output=True, check=check, timeout=30)

    def test_init_is_idempotent(self):
        self.ctl("init")
        config = self.data / "config.json"
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.data.stat().st_mode), 0o700)
        self.assertEqual(json.loads(config.read_text())["listen"], "127.0.0.1:3101")
        config.write_text('{"listen":"127.0.0.1:4321"}\n')
        self.ctl("init")
        self.assertEqual(json.loads(config.read_text())["listen"], "127.0.0.1:4321")

    def test_lifecycle_and_parallel_start(self):
        self.assertEqual(self.ctl("status", check=False).returncode, 1)
        with subprocess.Popen(self.command("start"), env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as second:
            first_out = self.ctl("start", "opencode2api").stdout
            second_out, err = second.communicate(timeout=30)
            self.assertEqual(second.returncode, 0, err)
        self.assertIn("already running", first_out + second_out)
        first_pid = self.pidfile.read_text().split()[0]
        self.assertIn(first_pid, self.ctl("status").stdout)
        self.ctl("restart")
        second_pid = self.pidfile.read_text().split()[0]
        self.assertNotEqual(first_pid, second_pid)
        self.ctl("stop")
        self.assertFalse(self.pidfile.exists())
        self.assertIn("stopped", self.ctl("logs").stdout)

    def test_stop_does_not_kill_unmanaged_or_stale_pid(self):
        self.ctl("init")
        with subprocess.Popen([str(self.bin), "120"]) as other:
            try:
                boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
                tick = Path(f"/proc/{other.pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
                for pid_contents in (f"{other.pid} 0 {boot}\n", f"{other.pid} {tick} old-boot\n"):
                    self.pidfile.write_text(pid_contents)
                    self.ctl("stop")
                    self.assertIsNone(other.poll())
                    self.assertFalse(self.pidfile.exists())
            finally:
                other.terminate()

    def test_failed_start_disabled_and_unknown_backend(self):
        self.bin.unlink()
        self.assertIn("missing", self.ctl("start", check=False).stderr)
        shutil.copy2(shutil.which("false"), self.bin)
        self.assertEqual(self.ctl("start", check=False).returncode, 1)
        self.assertFalse(self.pidfile.exists())
        (self.mod / "disable").touch()
        self.assertIn("disabled", self.ctl("start", check=False).stderr)
        self.assertIn("Unknown backend", self.ctl("start", "capy2api", check=False).stderr)


class PackageTests(unittest.TestCase):
    def test_shell_syntax(self):
        for filename in ("boot-completed.sh", "ctl.sh", "customize.sh", "backends/opencode2api.sh",
                         "scripts/build-android.sh"):
            subprocess.run(["sh", "-n", filename], cwd=ROOT, check=True)

    @staticmethod
    def write_elf_stub(path, interpreter=b""):
        # A synthetic ELF header for testing archive layout on any host.
        header = bytearray(64)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, 183)
        if interpreter:
            interpreter += b"\x00"
            struct.pack_into("<Q", header, 32, 64)
            struct.pack_into("<HH", header, 54, 56, 1)
            header += struct.pack("<II6Q", 3, 0, 120, 0, 0, len(interpreter), 0, 0)
        path.write_bytes(header + interpreter)

    def test_zip_contains_no_local_config(self):
        with tempfile.TemporaryDirectory() as output:
            binary = Path(output) / "opencode2api"
            self.write_elf_stub(binary, b"/system/bin/linker64")
            result = subprocess.check_output([sys.executable, "scripts/package.py", "--binary", str(binary),
                                              "--output-dir", output], cwd=ROOT, text=True).strip()
            with ZipFile(result) as package:
                self.assertIsNone(package.testzip())
                self.assertIn("module.prop", package.namelist())
                self.assertIn("boot-completed.sh", package.namelist())
                self.assertNotIn("config.json", package.namelist())
                self.assertEqual(json.loads(package.read("configs/opencode2api.example.json"))["server_keys"], [])
                self.assertEqual(package.read("bin/opencode2api"), binary.read_bytes())

    def test_packager_rejects_static_linux_binary(self):
        with tempfile.TemporaryDirectory() as output:
            binary = Path(output) / "opencode2api"
            self.write_elf_stub(binary)
            result = subprocess.run([sys.executable, "scripts/package.py", "--binary", str(binary)],
                                    cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("bionic", result.stderr)


if __name__ == "__main__":
    unittest.main()
