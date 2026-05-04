#!/usr/bin/env bash

set -euo pipefail

WORKFLOW_PATH=".github/workflows/xcode-cloud-dispatch.yml"
DEFAULT_INSTALL_BRANCH="chore/add-xcode-cloud-dispatch"
DEFAULT_COMMIT_MESSAGE="Add Xcode Cloud PR comment workflow"
DEFAULT_PR_TITLE="Add Xcode Cloud PR comment workflow"
DEFAULT_PR_BODY="This PR adds a GitHub Actions workflow that starts an Xcode Cloud build when someone comments \`/build\` on a pull request."
ACTION_REPOSITORY="${ACTION_REPOSITORY:-murphb52/xcode-cloud-dispatch-action}"
ACTION_REF="${ACTION_REF:-main}"

GH_CLI_DOCS_URL="https://docs.github.com/en/github-cli/github-cli/using-multiple-accounts"
GH_ACTIONS_SECRETS_URL="https://docs.github.com/en/actions/how-tos/security-for-github-actions/security-guides/using-secrets-in-github-actions?tool=cli"
GH_ACTIONS_VARIABLES_URL="https://docs.github.com/en/actions/learn-github-actions/variables"
ASC_API_HELP_URL="https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api"
ASC_API_KEYS_URL="https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api"
ASC_API_OVERVIEW_URL="https://developer.apple.com/app-store-connect/api/"

REPO_ROOT=""
REPO_SLUG=""
REPO_URL=""
DEFAULT_BRANCH=""
CURRENT_BRANCH=""
PRIVATE_KEY_CONTENT=""
WORKFLOW_OVERWRITTEN="no"
CREATED_BRANCH="no"
COMMITTED_CHANGES="no"
PUSHED_BRANCH="no"
OPENED_PR="no"
PR_URL=""

APPSTORE_KEY_ID=""
APPSTORE_ISSUER_ID=""
XCODE_CLOUD_WORKFLOW_ID=""
APPSTORE_TEAM_ID=""
APPSTORE_APP_ID=""
XCODE_CLOUD_PROJECT_PATH=""
XCODE_CLOUD_INFO_PLIST_PATH=""
DETECTED_BUNDLE_ID=""
DETECTED_MARKETING_VERSION=""
DETECTED_WORKSPACE_PATH=""
USE_COLOR=0
COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_BLUE=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""

setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    USE_COLOR=1
    COLOR_RESET="$(printf '\033[0m')"
    COLOR_BOLD="$(printf '\033[1m')"
    COLOR_DIM="$(printf '\033[2m')"
    COLOR_BLUE="$(printf '\033[34m')"
    COLOR_GREEN="$(printf '\033[32m')"
    COLOR_YELLOW="$(printf '\033[33m')"
    COLOR_RED="$(printf '\033[31m')"
    COLOR_CYAN="$(printf '\033[36m')"
  fi
}

tty_print() {
  printf "%s" "$*" >/dev/tty
}

tty_println() {
  printf "%s\n" "$*" >/dev/tty
}

section() {
  tty_println ""
  tty_println "${COLOR_BOLD}${COLOR_BLUE}== $* ==${COLOR_RESET}"
}

success() {
  tty_println "${COLOR_GREEN}$*${COLOR_RESET}"
}

die() {
  tty_println ""
  tty_println "${COLOR_RED}${COLOR_BOLD}Error:${COLOR_RESET} ${COLOR_RED}$*${COLOR_RESET}"
  exit 1
}

info() {
  tty_println "${COLOR_CYAN}$*${COLOR_RESET}"
}

warn() {
  tty_println "${COLOR_YELLOW}${COLOR_BOLD}Warning:${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

prompt_line() {
  local prompt="$1"
  local value=""
  while true; do
    tty_print "$prompt"
    IFS= read -r value </dev/tty || die "Unable to read from the terminal."
    value="$(trim "$value")"
    if [ -n "$value" ]; then
      printf "%s" "$value"
      return 0
    fi
    warn "A value is required."
  done
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""
  tty_print "$prompt [$default_value]: "
  IFS= read -r value </dev/tty || die "Unable to read from the terminal."
  value="$(trim "$value")"
  if [ -z "$value" ]; then
    printf "%s" "$default_value"
  else
    printf "%s" "$value"
  fi
}

prompt_optional() {
  local prompt="$1"
  local value=""
  tty_print "$prompt"
  IFS= read -r value </dev/tty || die "Unable to read from the terminal."
  printf "%s" "$(trim "$value")"
}

confirm() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local answer=""
  local suffix="[Y/n]"

  if [ "$default_answer" = "n" ]; then
    suffix="[y/N]"
  fi

  while true; do
    tty_print "$prompt $suffix "
    IFS= read -r answer </dev/tty || die "Unable to read from the terminal."
    answer="$(trim "$answer")"

    if [ -z "$answer" ]; then
      answer="$default_answer"
    fi

    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

restore_tty() {
  if [ -n "${SAVED_TTY_SETTINGS:-}" ]; then
    stty "$SAVED_TTY_SETTINGS" < /dev/tty >/dev/null 2>&1 || true
  fi
}

read_private_key_from_paste() {
  local line=""
  local key=""

  tty_println ""
  tty_println "Paste the full App Store Connect private key."
  tty_println "Finish by entering a line that contains only EOF."
  tty_println "Input will be hidden."

  SAVED_TTY_SETTINGS="$(stty -g < /dev/tty)"
  trap restore_tty EXIT
  stty -echo < /dev/tty

  while IFS= read -r line </dev/tty; do
    if [ "$line" = "EOF" ]; then
      break
    fi
    key="${key}${line}"$'\n'
  done

  restore_tty
  trap - EXIT
  SAVED_TTY_SETTINGS=""
  tty_println ""

  key="${key%$'\n'}"
  [ -n "$key" ] || die "The private key cannot be empty."
  PRIVATE_KEY_CONTENT="$key"
}

read_private_key_from_file() {
  local key_path=""

  while true; do
    key_path="$(prompt_line "Path to the .p8 file: ")"
    if [ ! -f "$key_path" ]; then
      warn "File not found: $key_path"
      continue
    fi

    PRIVATE_KEY_CONTENT="$(cat "$key_path")"
    PRIVATE_KEY_CONTENT="${PRIVATE_KEY_CONTENT%$'\n'}"
    [ -n "$PRIVATE_KEY_CONTENT" ] || die "The private key file is empty."
    return 0
  done
}

prompt_private_key() {
  local method=""

  section "App Store Connect private key"
  tty_println "Where to get it:"
  tty_println "- App Store Connect API help: $ASC_API_HELP_URL"
  tty_println "- API key details: $ASC_API_KEYS_URL"
  tty_println "This value will be stored as the GitHub Actions secret APPSTORE_PRIVATE_KEY."

  while true; do
    tty_println ""
    tty_println "Choose how to provide the private key:"
    tty_println "1. Read from a local .p8 file"
    tty_println "2. Paste into the terminal without echo"
    tty_print "Selection [1/2]: "
    IFS= read -r method </dev/tty || die "Unable to read from the terminal."
    method="$(trim "$method")"

    case "$method" in
      1) read_private_key_from_file; return 0 ;;
      2) read_private_key_from_paste; return 0 ;;
      *) warn "Choose 1 or 2." ;;
    esac
  done
}

append_choice() {
  local -n target_array="$1"
  local candidate="$2"
  if [ -n "$candidate" ]; then
    target_array+=("$candidate")
  fi
}

pick_candidate_or_manual() {
  local label="$1"
  local manual_prompt="$2"
  local -n candidates_ref="$3"
  local choice=""
  local idx=1

  tty_println ""
  tty_println "$label is optional."

  if [ "${#candidates_ref[@]}" -eq 0 ]; then
    tty_println "No detected values were found."
    if confirm "Enter a value manually?" "n"; then
      printf "%s" "$(prompt_line "$manual_prompt")"
    else
      printf "%s" ""
    fi
    return 0
  fi

  tty_println "Detected candidates:"
  for candidate in "${candidates_ref[@]}"; do
    tty_println "$idx. $candidate"
    idx=$((idx + 1))
  done
  tty_println "m. Enter a value manually"
  tty_println "s. Skip"

  while true; do
    tty_print "Choose a value: "
    IFS= read -r choice </dev/tty || die "Unable to read from the terminal."
    choice="$(trim "$choice")"

    if [ "$choice" = "m" ] || [ "$choice" = "M" ]; then
      printf "%s" "$(prompt_line "$manual_prompt")"
      return 0
    fi

    if [ "$choice" = "s" ] || [ "$choice" = "S" ] || [ -z "$choice" ]; then
      printf "%s" ""
      return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates_ref[@]}" ]; then
      printf "%s" "${candidates_ref[$((choice - 1))]}"
      return 0
    fi

    warn "Choose one of the listed options."
  done
}

show_intro() {
  section "Xcode Cloud Dispatch installer"
  tty_println "This script will:"
  tty_println "- verify Git and GitHub CLI access"
  tty_println "- collect required App Store Connect and Xcode Cloud values"
  tty_println "- store secrets with GitHub Actions secrets"
  tty_println "- store non-secret values with GitHub Actions variables"
  tty_println "- generate $WORKFLOW_PATH"
  tty_println "- optionally help you branch, commit, push, and open a PR"
  tty_println ""
  tty_println "Reference links:"
  tty_println "- GitHub CLI auth: $GH_CLI_DOCS_URL"
  tty_println "- GitHub Actions secrets: $GH_ACTIONS_SECRETS_URL"
  tty_println "- GitHub Actions variables: $GH_ACTIONS_VARIABLES_URL"
  tty_println "- App Store Connect API setup: $ASC_API_HELP_URL"
  tty_println "- App Store Connect API keys: $ASC_API_KEYS_URL"
  tty_println "- Xcode Cloud/App Store Connect API overview: $ASC_API_OVERVIEW_URL"
}

preflight_checks() {
  command_exists git || die "git is required."
  command_exists gh || die "GitHub CLI is required. Install it first: $GH_CLI_DOCS_URL"

  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO_ROOT" ] || die "Run this script from inside a git repository."
  cd "$REPO_ROOT"

  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run 'gh auth login'. Docs: $GH_CLI_DOCS_URL"

  REPO_SLUG="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  [ -n "$REPO_SLUG" ] || die "The current directory is not associated with a GitHub repository that GitHub CLI can access."

  REPO_URL="$(gh repo view --json url --jq '.url')"
  DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')"
  CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH="HEAD"
  fi

  if [ -f "$WORKFLOW_PATH" ]; then
    if confirm "$WORKFLOW_PATH already exists. Overwrite it?" "n"; then
      WORKFLOW_OVERWRITTEN="yes"
    else
      die "Installation cancelled."
    fi
  fi
}

detect_marketing_version() {
  local project_path="$1"
  local version=""

  if [ -f "pubspec.yaml" ]; then
    version="$(grep '^version:' pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//' | cut -d'+' -f1 | tr -d '[:space:]' || true)"
  fi

  if [ -z "$version" ] && [ -n "$project_path" ] && [ -f "$project_path/project.pbxproj" ]; then
    version="$(grep 'MARKETING_VERSION' "$project_path/project.pbxproj" | grep -v '^[[:space:]]*//' | head -1 | cut -d'=' -f2 | tr -d ';"[:space:]' || true)"
  fi

  printf "%s" "$version"
}

detect_bundle_id_from_plist() {
  local plist_path="$1"
  local bundle_id=""

  if [ ! -f "$plist_path" ]; then
    printf "%s" ""
    return 0
  fi

  if [ -x /usr/libexec/PlistBuddy ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null || true)"
  elif command_exists plutil; then
    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist_path" 2>/dev/null || true)"
  fi

  printf "%s" "$bundle_id"
}

detect_project_values() {
  local -a workspace_candidates=()
  local -a project_candidates=()
  local -a plist_candidates=()

  while IFS= read -r path; do
    append_choice workspace_candidates "$path"
  done < <(find . \
    \( -path './.git' -o -path './Pods' -o -path './build' -o -path './.build' -o -path './node_modules' \) -prune \
    -o -type d -name '*.xcworkspace' -print 2>/dev/null | sed 's|^\./||' | sort)

  while IFS= read -r path; do
    append_choice project_candidates "$path"
  done < <(find . \
    \( -path './.git' -o -path './Pods' -o -path './build' -o -path './.build' -o -path './node_modules' \) -prune \
    -o -type d -name '*.xcodeproj' -print 2>/dev/null | sed 's|^\./||' | sort)

  while IFS= read -r path; do
    append_choice plist_candidates "$path"
  done < <(find . \
    \( -path './.git' -o -path './Pods' -o -path './build' -o -path './.build' -o -path './node_modules' \) -prune \
    -o -type f -name 'Info.plist' -print 2>/dev/null | sed 's|^\./||' | sort)

  section "Project detection"
  tty_println "The next values are optional. You can use a detected value, enter your own, or skip each one."

  if [ "${#workspace_candidates[@]}" -gt 0 ]; then
    DETECTED_WORKSPACE_PATH="${workspace_candidates[0]}"
    tty_println ""
    tty_println "Detected .xcworkspace path(s):"
    for path in "${workspace_candidates[@]}"; do
      tty_println "- $path"
    done
    tty_println "Note: the action uses XCODE_CLOUD_PROJECT_PATH, so workspace detection is informational."
  fi

  XCODE_CLOUD_PROJECT_PATH="$(pick_candidate_or_manual \
    "XCODE_CLOUD_PROJECT_PATH" \
    "Project path (.xcodeproj): " \
    project_candidates)"

  XCODE_CLOUD_INFO_PLIST_PATH="$(pick_candidate_or_manual \
    "XCODE_CLOUD_INFO_PLIST_PATH" \
    "Info.plist path: " \
    plist_candidates)"

  if [ -n "$XCODE_CLOUD_INFO_PLIST_PATH" ]; then
    DETECTED_BUNDLE_ID="$(detect_bundle_id_from_plist "$XCODE_CLOUD_INFO_PLIST_PATH")"
  fi

  DETECTED_MARKETING_VERSION="$(detect_marketing_version "$XCODE_CLOUD_PROJECT_PATH")"

  tty_println ""
  tty_println "Detected metadata"
  if [ -n "$DETECTED_BUNDLE_ID" ]; then
    tty_println "- Bundle identifier: $DETECTED_BUNDLE_ID"
  else
    tty_println "- Bundle identifier: not detected"
  fi

  if [ -n "$DETECTED_MARKETING_VERSION" ]; then
    tty_println "- Marketing version: $DETECTED_MARKETING_VERSION"
  else
    tty_println "- Marketing version: not detected"
  fi
}

prompt_required_values() {
  section "Required values"
  tty_println "APPSTORE_KEY_ID"
  tty_println "- What it is: the App Store Connect API key ID."
  tty_println "- Where to get it: $ASC_API_KEYS_URL"
  tty_println "- Stored as: GitHub Actions secret APPSTORE_KEY_ID"
  APPSTORE_KEY_ID="$(prompt_line "App Store Connect API Key ID: ")"

  tty_println ""
  tty_println "APPSTORE_ISSUER_ID"
  tty_println "- What it is: the App Store Connect API issuer ID."
  tty_println "- Where to get it: $ASC_API_HELP_URL"
  tty_println "- Stored as: GitHub Actions secret APPSTORE_ISSUER_ID"
  APPSTORE_ISSUER_ID="$(prompt_line "App Store Connect API Issuer ID: ")"

  prompt_private_key

  tty_println ""
  tty_println "XCODE_CLOUD_WORKFLOW_ID"
  tty_println "- What it is: the Xcode Cloud workflow identifier to dispatch."
  tty_println "- Where to get it: App Store Connect Xcode Cloud workflow details or the App Store Connect API overview: $ASC_API_OVERVIEW_URL"
  tty_println "- Stored as: GitHub Actions variable XCODE_CLOUD_WORKFLOW_ID"
  XCODE_CLOUD_WORKFLOW_ID="$(prompt_line "Xcode Cloud workflow ID: ")"
}

prompt_optional_values() {
  section "Optional values"
  tty_println "APPSTORE_TEAM_ID"
  tty_println "- Optional. Used to generate a direct App Store Connect build URL."
  tty_println "- Often visible in App Store Connect URLs after /teams/."
  tty_println "- App Store Connect overview: $ASC_API_OVERVIEW_URL"
  APPSTORE_TEAM_ID="$(prompt_optional "App Store Connect team ID (leave blank to skip): ")"

  tty_println ""
  tty_println "APPSTORE_APP_ID"
  tty_println "- Optional. Used to generate a direct App Store Connect build URL."
  tty_println "- Often visible in App Store Connect app URLs or API responses."
  tty_println "- App Store Connect overview: $ASC_API_OVERVIEW_URL"
  APPSTORE_APP_ID="$(prompt_optional "App Store Connect app ID (leave blank to skip): ")"
}

set_secret() {
  local name="$1"
  local value="$2"
  printf "%s" "$value" | gh secret set "$name" --repo "$REPO_SLUG"
}

set_variable() {
  local name="$1"
  local value="$2"
  gh variable set "$name" --repo "$REPO_SLUG" --body "$value"
}

configure_github() {
  section "Configuring GitHub"
  tty_println "Configuring GitHub Actions secrets and variables for $REPO_SLUG"

  set_secret "APPSTORE_KEY_ID" "$APPSTORE_KEY_ID"
  set_secret "APPSTORE_ISSUER_ID" "$APPSTORE_ISSUER_ID"
  set_secret "APPSTORE_PRIVATE_KEY" "$PRIVATE_KEY_CONTENT"

  set_variable "XCODE_CLOUD_WORKFLOW_ID" "$XCODE_CLOUD_WORKFLOW_ID"

  if [ -n "$XCODE_CLOUD_PROJECT_PATH" ]; then
    set_variable "XCODE_CLOUD_PROJECT_PATH" "$XCODE_CLOUD_PROJECT_PATH"
  fi

  if [ -n "$XCODE_CLOUD_INFO_PLIST_PATH" ]; then
    set_variable "XCODE_CLOUD_INFO_PLIST_PATH" "$XCODE_CLOUD_INFO_PLIST_PATH"
  fi

  if [ -n "$APPSTORE_TEAM_ID" ]; then
    set_variable "APPSTORE_TEAM_ID" "$APPSTORE_TEAM_ID"
  fi

  if [ -n "$APPSTORE_APP_ID" ]; then
    set_variable "APPSTORE_APP_ID" "$APPSTORE_APP_ID"
  fi

  success "GitHub Actions secrets and variables configured."
}

generate_workflow() {
  mkdir -p "$(dirname "$WORKFLOW_PATH")"

  cat > "$WORKFLOW_PATH" <<EOF
name: Xcode Cloud PR Comment Dispatch

on:
  issue_comment:
    types:
      - created

permissions:
  contents: read
  pull-requests: read
  issues: write

jobs:
  dispatch:
    if: \${{ github.event.issue.pull_request && github.event.comment.body == '/build' }}
    runs-on: ubuntu-latest

    steps:
      - name: Fetch pull request details
        id: pr
        uses: actions/github-script@v7
        with:
          script: |
            const pullRequest = await github.request(context.payload.issue.pull_request.url, {
              headers: {
                accept: 'application/vnd.github+json',
              },
            });

            const pr = pullRequest.data;
            const isFork = pr.head.repo.full_name !== pr.base.repo.full_name;

            core.setOutput('head_ref', pr.head.ref);
            core.setOutput('head_sha', pr.head.sha);
            core.setOutput('head_repo', pr.head.repo.full_name);
            core.setOutput('base_repo', pr.base.repo.full_name);
            core.setOutput('is_fork', isFork ? 'true' : 'false');

      - name: Reject fork pull requests
        if: \${{ steps.pr.outputs.is_fork == 'true' }}
        uses: actions/github-script@v7
        with:
          script: |
            const body = [
              '/build',
              '',
              '> Xcode Cloud dispatch only supports pull requests whose head branch exists in the repository linked to the Xcode Cloud workflow.',
              '> Pull requests from forks are not supported by this workflow.',
            ].join('\\n');

            await github.rest.issues.updateComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              comment_id: context.payload.comment.id,
              body,
            });

      - name: Check out pull request commit
        if: \${{ steps.pr.outputs.is_fork != 'true' }}
        uses: actions/checkout@v4
        with:
          ref: \${{ steps.pr.outputs.head_sha }}

      - name: Trigger Xcode Cloud
        id: xcode
        if: \${{ steps.pr.outputs.is_fork != 'true' }}
        uses: ${ACTION_REPOSITORY}@${ACTION_REF}
        with:
          apple_key_id: \${{ secrets.APPSTORE_KEY_ID }}
          apple_issuer_id: \${{ secrets.APPSTORE_ISSUER_ID }}
          apple_private_key: \${{ secrets.APPSTORE_PRIVATE_KEY }}
          workflow_id: \${{ vars.XCODE_CLOUD_WORKFLOW_ID }}
          project_path: \${{ vars.XCODE_CLOUD_PROJECT_PATH }}
          info_plist_path: \${{ vars.XCODE_CLOUD_INFO_PLIST_PATH }}
          branch: \${{ steps.pr.outputs.head_ref }}
          team_id: \${{ vars.APPSTORE_TEAM_ID }}
          app_id: \${{ vars.APPSTORE_APP_ID }}

      - name: Update comment with success details
        if: \${{ success() && steps.pr.outputs.is_fork != 'true' }}
        uses: actions/github-script@v7
        env:
          BRANCH_NAME: \${{ steps.pr.outputs.head_ref }}
          MARKETING_VERSION: \${{ steps.xcode.outputs.marketing_version }}
          BUILD_NUMBER: \${{ steps.xcode.outputs.build_number }}
          BUILD_URL: \${{ steps.xcode.outputs.build_url }}
        with:
          script: |
            const lines = [
              '/build',
              '',
              '> Xcode Cloud build started successfully.',
              \`> Branch: \\\`\${process.env.BRANCH_NAME}\\\`\`,
            ];

            if (process.env.MARKETING_VERSION) {
              lines.push(\`> Marketing version: \\\`\${process.env.MARKETING_VERSION}\\\`\`);
            }

            lines.push(\`> Build number: \\\`\${process.env.BUILD_NUMBER}\\\`\`);
            lines.push(\`> Build URL: \${process.env.BUILD_URL}\`);

            await github.rest.issues.updateComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              comment_id: context.payload.comment.id,
              body: lines.join('\\n'),
            });

      - name: Update comment with failure details
        if: \${{ failure() && steps.pr.outputs.is_fork != 'true' }}
        uses: actions/github-script@v7
        with:
          script: |
            const runUrl = \`\${context.serverUrl}/\${context.repo.owner}/\${context.repo.repo}/actions/runs/\${context.runId}\`;
            const body = [
              '/build',
              '',
              '> Xcode Cloud dispatch failed.',
              \`> Review the GitHub Actions logs: \${runUrl}\`,
            ].join('\\n');

            await github.rest.issues.updateComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              comment_id: context.payload.comment.id,
              body,
            });
EOF
}

maybe_create_branch() {
  local branch_name=""

  if ! confirm "Create a new branch for $WORKFLOW_PATH?" "y"; then
    return 0
  fi

  branch_name="$(prompt_with_default "Branch name" "$DEFAULT_INSTALL_BRANCH")"

  if [ "$CURRENT_BRANCH" = "$branch_name" ]; then
    info "Already on branch $branch_name."
    CREATED_BRANCH="yes"
    CURRENT_BRANCH="$branch_name"
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    if confirm "Local branch $branch_name already exists. Switch to it?" "y"; then
      git switch "$branch_name" >/dev/null 2>&1 || git checkout "$branch_name"
      CURRENT_BRANCH="$branch_name"
      CREATED_BRANCH="yes"
      return 0
    fi
    warn "Skipping branch creation."
    return 0
  fi

  git switch -c "$branch_name" >/dev/null 2>&1 || git checkout -b "$branch_name"
  CURRENT_BRANCH="$branch_name"
  CREATED_BRANCH="yes"
}

maybe_commit_changes() {
  local commit_message=""

  if ! confirm "Commit $WORKFLOW_PATH?" "y"; then
    return 0
  fi

  commit_message="$(prompt_with_default "Commit message" "$DEFAULT_COMMIT_MESSAGE")"
  git add "$WORKFLOW_PATH"
  git commit -m "$commit_message"
  COMMITTED_CHANGES="yes"
}

maybe_push_branch() {
  if ! confirm "Push the current branch to origin?" "y"; then
    return 0
  fi

  if [ "$CURRENT_BRANCH" = "HEAD" ]; then
    die "Cannot push from a detached HEAD."
  fi

  git push -u origin "$CURRENT_BRANCH"
  PUSHED_BRANCH="yes"
}

maybe_open_pr() {
  local pr_title=""
  local pr_body=""

  if ! confirm "Open a pull request in $REPO_SLUG?" "n"; then
    return 0
  fi

  if [ "$CURRENT_BRANCH" = "HEAD" ]; then
    die "Cannot open a pull request from a detached HEAD."
  fi

  if [ "$PUSHED_BRANCH" != "yes" ]; then
    if confirm "Opening a pull request requires a pushed branch. Push it now?" "y"; then
      if [ "$CURRENT_BRANCH" = "HEAD" ]; then
        die "Cannot push from a detached HEAD."
      fi
      git push -u origin "$CURRENT_BRANCH"
      PUSHED_BRANCH="yes"
    else
      warn "Skipping pull request creation."
      return 0
    fi
  fi

  pr_title="$(prompt_with_default "Pull request title" "$DEFAULT_PR_TITLE")"
  pr_body="$(prompt_with_default "Pull request body" "$DEFAULT_PR_BODY")"
  PR_URL="$(gh pr create --repo "$REPO_SLUG" --base "$DEFAULT_BRANCH" --head "$CURRENT_BRANCH" --title "$pr_title" --body "$pr_body")"
  OPENED_PR="yes"
}

print_summary() {
  section "Installation summary"
  tty_println "- Repository: $REPO_SLUG"
  tty_println "- Repository URL: $REPO_URL"
  tty_println "- Default branch: $DEFAULT_BRANCH"
  tty_println "- Current branch: $CURRENT_BRANCH"
  tty_println "- Workflow path: $WORKFLOW_PATH"
  tty_println "- Existing workflow overwritten: $WORKFLOW_OVERWRITTEN"
  tty_println "- Secret configured: APPSTORE_KEY_ID"
  tty_println "- Secret configured: APPSTORE_ISSUER_ID"
  tty_println "- Secret configured: APPSTORE_PRIVATE_KEY"
  tty_println "- Variable configured: XCODE_CLOUD_WORKFLOW_ID"

  if [ -n "$XCODE_CLOUD_PROJECT_PATH" ]; then
    tty_println "- Variable configured: XCODE_CLOUD_PROJECT_PATH=$XCODE_CLOUD_PROJECT_PATH"
  else
    tty_println "- Variable skipped: XCODE_CLOUD_PROJECT_PATH"
  fi

  if [ -n "$XCODE_CLOUD_INFO_PLIST_PATH" ]; then
    tty_println "- Variable configured: XCODE_CLOUD_INFO_PLIST_PATH=$XCODE_CLOUD_INFO_PLIST_PATH"
  else
    tty_println "- Variable skipped: XCODE_CLOUD_INFO_PLIST_PATH"
  fi

  if [ -n "$APPSTORE_TEAM_ID" ]; then
    tty_println "- Variable configured: APPSTORE_TEAM_ID=$APPSTORE_TEAM_ID"
  else
    tty_println "- Variable skipped: APPSTORE_TEAM_ID"
  fi

  if [ -n "$APPSTORE_APP_ID" ]; then
    tty_println "- Variable configured: APPSTORE_APP_ID=$APPSTORE_APP_ID"
  else
    tty_println "- Variable skipped: APPSTORE_APP_ID"
  fi

  tty_println "- Created branch: $CREATED_BRANCH"
  tty_println "- Committed workflow: $COMMITTED_CHANGES"
  tty_println "- Pushed branch: $PUSHED_BRANCH"
  tty_println "- Opened pull request: $OPENED_PR"

  if [ -n "$PR_URL" ]; then
    tty_println "- Pull request URL: $PR_URL"
  fi

  tty_println ""
  success "Secrets were stored in GitHub Actions secrets only."
  tty_println "${COLOR_DIM}The App Store Connect private key was kept in memory and was not written to disk.${COLOR_RESET}"
  tty_println "${COLOR_BOLD}After the workflow is merged into the repository default branch, comment /build on a pull request to trigger Xcode Cloud.${COLOR_RESET}"
}

main() {
  setup_colors
  show_intro
  preflight_checks
  detect_project_values
  prompt_required_values
  prompt_optional_values
  configure_github
  generate_workflow
  maybe_create_branch
  maybe_commit_changes
  maybe_push_branch
  maybe_open_pr
  print_summary
}

main "$@"
