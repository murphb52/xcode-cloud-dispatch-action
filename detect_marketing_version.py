"""Detect the app's marketing version for the Xcode Cloud dispatch action.

Version detection is informational only, so this script never fails the build.
It prints the version (or an empty string) to stdout and reports problems as
GitHub Actions ::warning:: annotations on stderr, then exits 0.

Sources, in order:
  1. pubspec.yaml                      (Flutter)
  2. Info.plist given by INFO_PLIST_PATH, when it holds a literal version
  3. project.pbxproj MARKETING_VERSION (project given by PROJECT_PATH, or auto-detected)
  4. *.xcconfig MARKETING_VERSION      (projects that keep build settings in xcconfig files)

A value such as "$(MARKETING_VERSION)" is a build-setting reference, not a
version, so it is skipped and the next source is tried.
"""

import collections
import os
import plistlib
import re
import sys

SKIPPED_DIRECTORIES = {".git", "Pods", "Carthage", "node_modules", "build", ".build", "DerivedData"}
MARKETING_VERSION_PATTERN = re.compile(r"^\s*MARKETING_VERSION(?:\[[^\]]*\])?\s*=\s*(.+?)\s*;?\s*$")


def warn(message):
    sys.stderr.write(f"::warning::{message}\n")


def clean_value(raw_value):
    return raw_value.strip().strip('";').strip()


def is_literal_version(value):
    return bool(value) and "$(" not in value and "${" not in value


def version_from_pubspec(pubspec_path="pubspec.yaml"):
    if not os.path.isfile(pubspec_path):
        return ""
    with open(pubspec_path, encoding="utf-8") as pubspec:
        for line in pubspec:
            if line.startswith("version:"):
                return line[len("version:"):].split("+")[0].strip()
    return ""


def version_from_info_plist(info_plist_path):
    if not info_plist_path:
        return ""
    if not os.path.isfile(info_plist_path):
        warn(f"info_plist_path '{info_plist_path}' does not exist; trying other version sources.")
        return ""
    try:
        with open(info_plist_path, "rb") as plist_file:
            value = str(plistlib.load(plist_file).get("CFBundleShortVersionString", "")).strip()
    except Exception as error:
        warn(f"Could not read '{info_plist_path}': {error}. Trying other version sources.")
        return ""
    return value if is_literal_version(value) else ""


def marketing_versions_in_file(file_path):
    versions = []
    try:
        with open(file_path, encoding="utf-8", errors="replace") as build_settings_file:
            for line in build_settings_file:
                match = MARKETING_VERSION_PATTERN.match(line)
                if match and is_literal_version(clean_value(match.group(1))):
                    versions.append(clean_value(match.group(1)))
    except OSError as error:
        warn(f"Could not read '{file_path}': {error}.")
    return versions


def find_project_directory(project_path):
    if project_path:
        if os.path.isfile(project_path):
            return os.path.dirname(project_path)
        if os.path.isdir(project_path):
            return project_path
        warn(f"project_path '{project_path}' does not exist; trying other version sources.")
        return ""
    for directory, subdirectories, _ in os.walk("."):
        subdirectories[:] = [name for name in subdirectories if name not in SKIPPED_DIRECTORIES]
        for name in sorted(subdirectories):
            if name.endswith(".xcodeproj"):
                return os.path.join(directory, name)
        if directory.count(os.sep) >= 2:
            subdirectories[:] = []
    return ""


def most_common(versions):
    if not versions:
        return ""
    return collections.Counter(versions).most_common(1)[0][0]


def version_from_project(project_path):
    project_directory = find_project_directory(project_path)
    pbxproj_path = os.path.join(project_directory, "project.pbxproj")
    if project_directory and os.path.isfile(pbxproj_path):
        return most_common(marketing_versions_in_file(pbxproj_path))
    return ""


def version_from_xcconfig_files(root="."):
    versions = []
    for directory, subdirectories, file_names in os.walk(root):
        subdirectories[:] = [name for name in subdirectories if name not in SKIPPED_DIRECTORIES]
        for name in sorted(file_names):
            if name.endswith(".xcconfig"):
                versions += marketing_versions_in_file(os.path.join(directory, name))
    return most_common(versions)


def detect_marketing_version(project_path, info_plist_path):
    return (
        version_from_pubspec()
        or version_from_info_plist(info_plist_path)
        or version_from_project(project_path)
        or version_from_xcconfig_files()
    )


def main():
    try:
        version = detect_marketing_version(
            os.environ.get("PROJECT_PATH", "").strip(),
            os.environ.get("INFO_PLIST_PATH", "").strip(),
        )
    except Exception as error:
        warn(f"Marketing version detection failed ({error}); continuing without it.")
        version = ""
    if not version:
        warn("Could not detect a marketing version; continuing without it.")
    print(version)


if __name__ == "__main__":
    main()
