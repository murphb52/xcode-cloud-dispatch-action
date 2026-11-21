import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "detect_marketing_version.py")


def write(root, relative_path, content):
    path = os.path.join(root, relative_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(content, bytes) else "w"
    with open(path, mode) as file:
        file.write(content)


def run_detector(root, project_path="", info_plist_path=""):
    environment = dict(os.environ, PROJECT_PATH=project_path, INFO_PLIST_PATH=info_plist_path)
    result = subprocess.run(
        [sys.executable, "-I", os.path.abspath(SCRIPT)],
        cwd=root, env=environment, capture_output=True, text=True,
    )
    return result.returncode, result.stdout.strip(), result.stderr


class DetectMarketingVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = self.directory.name

    def tearDown(self):
        self.directory.cleanup()

    def test_xcconfig_project_without_pbxproj_version(self):
        # Mirrors BabyTracker: pbxproj has no MARKETING_VERSION, xcconfigs do.
        write(self.root, "Baby Tracker.xcodeproj/project.pbxproj", "CURRENT_PROJECT_VERSION = 91;\n")
        write(self.root, "Config/App.xcconfig", "MARKETING_VERSION = 1.0.3\n")
        write(self.root, "Config/Tests.xcconfig", "MARKETING_VERSION = 1.0.3\n")
        code, version, _ = run_detector(self.root)
        self.assertEqual((code, version), (0, "1.0.3"))

    def test_pbxproj_version(self):
        write(self.root, "App.xcodeproj/project.pbxproj", '\t\t\t\tMARKETING_VERSION = "2.1.0";\n')
        self.assertEqual(run_detector(self.root)[:2], (0, "2.1.0"))

    def test_pbxproj_wins_over_xcconfig(self):
        write(self.root, "App.xcodeproj/project.pbxproj", "MARKETING_VERSION = 2.0.0;\n")
        write(self.root, "App.xcconfig", "MARKETING_VERSION = 9.9.9\n")
        self.assertEqual(run_detector(self.root)[1], "2.0.0")

    def test_explicit_project_path(self):
        write(self.root, "ios/Runner.xcodeproj/project.pbxproj", "MARKETING_VERSION = 3.0.0;\n")
        self.assertEqual(run_detector(self.root, project_path="ios/Runner.xcodeproj")[1], "3.0.0")

    def test_pubspec_strips_build_number(self):
        write(self.root, "pubspec.yaml", "name: app\nversion: 1.4.0+27\n")
        self.assertEqual(run_detector(self.root)[1], "1.4.0")

    def test_literal_info_plist_version(self):
        write(self.root, "Info.plist", plistlib.dumps({"CFBundleShortVersionString": "4.5.6"}))
        self.assertEqual(run_detector(self.root, info_plist_path="Info.plist")[1], "4.5.6")

    def test_info_plist_build_setting_reference_falls_through(self):
        write(self.root, "Info.plist", plistlib.dumps({"CFBundleShortVersionString": "$(MARKETING_VERSION)"}))
        write(self.root, "App.xcconfig", "MARKETING_VERSION = 1.0.3\n")
        self.assertEqual(run_detector(self.root, info_plist_path="Info.plist")[1], "1.0.3")

    def test_missing_info_plist_warns_and_falls_through(self):
        write(self.root, "App.xcconfig", "MARKETING_VERSION = 1.0.3\n")
        code, version, stderr = run_detector(self.root, info_plist_path="Nope/Info.plist")
        self.assertEqual((code, version), (0, "1.0.3"))
        self.assertIn("::warning::", stderr)

    def test_nothing_found_exits_zero_with_warning(self):
        code, version, stderr = run_detector(self.root)
        self.assertEqual((code, version), (0, ""))
        self.assertIn("::warning::", stderr)

    def test_unreadable_plist_does_not_fail(self):
        write(self.root, "Info.plist", "not a plist")
        code, version, stderr = run_detector(self.root, info_plist_path="Info.plist")
        self.assertEqual((code, version), (0, ""))
        self.assertIn("::warning::", stderr)

    def test_bad_project_path_does_not_fail(self):
        code, _, stderr = run_detector(self.root, project_path="missing.xcodeproj")
        self.assertEqual(code, 0)
        self.assertIn("missing.xcodeproj", stderr)

    def test_pods_xcconfig_is_ignored(self):
        write(self.root, "Pods/Target Support Files/x.xcconfig", "MARKETING_VERSION = 7.7.7\n")
        self.assertEqual(run_detector(self.root)[1], "")

    def test_xcconfig_comments_and_references_are_ignored(self):
        write(self.root, "App.xcconfig", "// MARKETING_VERSION = 8.8.8\nMARKETING_VERSION = $(BASE_VERSION)\nMARKETING_VERSION = 1.2.3\n")
        self.assertEqual(run_detector(self.root)[1], "1.2.3")


if __name__ == "__main__":
    unittest.main()
