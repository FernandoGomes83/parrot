"""Exercise the real installer in isolated directories, with local release fixtures."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASSET = "parrot-macos-arm64.tar.gz"


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / "bin"
        self.runtime = self.root / "lib"
        self.fake = self.root / "tools"
        for path in (self.bin, self.runtime, self.fake):
            path.mkdir()
        source = (ROOT / "scripts/install.sh").read_text()
        source = source.replace('INSTALL_DIR="/usr/local/bin"', f'INSTALL_DIR="{self.bin}"')
        source = source.replace('RUNTIME_DIR="/usr/local/lib/parrot"', f'RUNTIME_DIR="{self.runtime}"')
        self.installer = self.root / "install.sh"
        self.installer.write_text(source)
        self.tool("launchctl", "#!/bin/sh\nexit 1\n")
        self.tool("gh", '#!/bin/sh\nexit "${TEST_ATTESTATION_EXIT:-0}"\n')
        self.tool("curl", '''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
url = next(arg for arg in sys.argv if arg.startswith("https://"))
destination = sys.argv[sys.argv.index("-o") + 1]
shutil.copyfile(Path(os.environ["TEST_RELEASE_DIR"]) / url.rsplit("/", 1)[-1], destination)
''')
        self.env = dict(os.environ, PATH=f"{self.fake}:{os.environ['PATH']}",
                        PARROT_VERSION="v0.4.0", PARROT_REQUIRE_ATTESTATION="1",
                        TEST_RELEASE_DIR=str(self.root))

    def tool(self, name, body):
        path = self.fake / name
        path.write_text(body)
        path.chmod(0o755)

    def archive(self, names, symlink=False):
        with tarfile.open(self.root / ASSET, "w:gz") as archive:
            for name in names:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o755 if name == "parrot" else 0o644
                if symlink:
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "/tmp/should-never-be-followed"
                    archive.addfile(entry)
                else:
                    content = b"#!/bin/sh\necho fixture\n" if name == "parrot" else b"fixture shaders"
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
        digest = hashlib.sha256((self.root / ASSET).read_bytes()).hexdigest()
        (self.root / f"{ASSET}.sha256").write_text(f"{digest}  {ASSET}\n")

    def install(self):
        return subprocess.run(["sh", str(self.installer)], env=self.env,
                              capture_output=True, text=True)

    def testInstallsExecutableAndMatchingShadersTogether(self):
        self.archive(["parrot", "mlx.metallib"])
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.bin / "parrot").is_symlink())
        self.assertEqual((self.bin / "parrot").resolve(), self.runtime / "v0.4.0" / "parrot")
        self.assertEqual((self.runtime / "v0.4.0" / "mlx.metallib").read_bytes(), b"fixture shaders")

    def testLegacySingleFileReleaseRemainsInstallable(self):
        self.archive(["parrot"])
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.bin / "parrot").is_file())
        self.assertFalse((self.bin / "parrot").is_symlink())

    def testRejectsUnexpectedArchiveMember(self):
        self.archive(["parrot", "unexpected.txt"])
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.bin / "parrot").exists())

    def testRejectsLinksInArchive(self):
        self.archive(["parrot"], symlink=True)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.bin / "parrot").is_symlink())

    def testRejectsChecksumMismatch(self):
        self.archive(["parrot", "mlx.metallib"])
        (self.root / ASSET).write_bytes(b"corrupt download")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.bin / "parrot").exists())

    def testRequiredProvenanceFailureStopsInstallation(self):
        self.archive(["parrot", "mlx.metallib"])
        self.env["TEST_ATTESTATION_EXIT"] = "1"
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.bin / "parrot").exists())


if __name__ == "__main__":
    unittest.main()
