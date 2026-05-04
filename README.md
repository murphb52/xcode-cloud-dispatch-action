# Xcode Cloud Dispatcher

A GitHub Action that triggers an Xcode Cloud build through the App Store Connect API for Flutter and native iOS projects. It detects the marketing version, returns the Apple-assigned build number, and can produce a direct App Store Connect build URL when you provide your team and app identifiers.

## Quick Install

Run this from the root of the GitHub repository where you want to use the action:

```bash
curl -fsSL https://raw.githubusercontent.com/murphb52/xcode-cloud-dispatch-action/main/install.sh | bash
```

The installer will:

- verify that you are inside a git repository with GitHub CLI access
- guide you through the required App Store Connect and Xcode Cloud values
- store sensitive values as GitHub Actions secrets
- store non-sensitive values as GitHub Actions variables
- generate `.github/workflows/xcode-cloud-dispatch.yml`
- optionally create a branch, commit the workflow, push it, and open a PR

## Safer Install

If you want to inspect the script before running it:

```bash
curl -fsSL -o ./install-xcode-cloud-dispatch.sh https://raw.githubusercontent.com/murphb52/xcode-cloud-dispatch-action/main/install.sh
less ./install-xcode-cloud-dispatch.sh
bash ./install-xcode-cloud-dispatch.sh
```

## Prerequisites

- `git`
- GitHub CLI (`gh`)
- Authenticated GitHub CLI session
  Docs: https://docs.github.com/en/github-cli/github-cli/using-multiple-accounts
- An App Store Connect API key with access to App Store Connect and Xcode Cloud
  Docs: https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api
- An Xcode Cloud workflow ID
  Overview: https://developer.apple.com/app-store-connect/api/

## What The Installer Configures

The installer configures:

- GitHub Actions secrets:
  - `APPSTORE_KEY_ID`
  - `APPSTORE_ISSUER_ID`
  - `APPSTORE_PRIVATE_KEY`
- GitHub Actions variables:
  - `XCODE_CLOUD_WORKFLOW_ID`
  - `XCODE_CLOUD_PROJECT_PATH`, if provided
  - `XCODE_CLOUD_INFO_PLIST_PATH`, if provided
  - `APPSTORE_TEAM_ID`, if provided
  - `APPSTORE_APP_ID`, if provided
- A PR comment workflow at `.github/workflows/xcode-cloud-dispatch.yml`

The generated workflow listens for `/build` comments on pull requests, rejects forked PRs with a clear explanation, checks out the pull request head commit, dispatches Xcode Cloud, and updates the original comment with either the build details or a failure link to the Actions logs.

## Required Values

The installer will prompt for these required values and explain where to get each one:

- `APPSTORE_KEY_ID`
  The App Store Connect API key ID.
  Docs: https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- `APPSTORE_ISSUER_ID`
  The App Store Connect API issuer ID.
  Docs: https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api
- `APPSTORE_PRIVATE_KEY`
  The contents of the `.p8` private key.
  The installer supports reading from a local file or a hidden terminal paste.
- `XCODE_CLOUD_WORKFLOW_ID`
  The Xcode Cloud workflow identifier to dispatch.
  Overview: https://developer.apple.com/app-store-connect/api/

## Optional Values

You can provide or skip these optional values:

- `APPSTORE_TEAM_ID`
  Used to generate a direct App Store Connect build URL.
- `APPSTORE_APP_ID`
  Used to generate a direct App Store Connect build URL.
- `XCODE_CLOUD_PROJECT_PATH`
  Path to a `.xcodeproj` if you want the action to read `MARKETING_VERSION` from `project.pbxproj`.
- `XCODE_CLOUD_INFO_PLIST_PATH`
  Path to an `Info.plist` if your version is hardcoded there.

Before prompting for the project-related values, the installer tries to detect:

- `.xcodeproj` candidates
- `.xcworkspace` candidates
- `Info.plist` candidates
- a bundle identifier from `Info.plist`
- the marketing version from `pubspec.yaml` for Flutter projects
- otherwise, `MARKETING_VERSION` from the Xcode project

Detected values are suggestions only. The installer asks whether to use one, enter a value manually, or skip it.

## Usage After Installation

Once the workflow is merged into the repository default branch, comment:

```text
/build
```

on a pull request in the repository. The workflow will trigger this action, and the original comment will be updated with the result.

## Fork Limitation

The generated workflow rejects pull requests from forks. Xcode Cloud dispatch expects the branch to exist in the repository linked to the Xcode Cloud workflow, so fork-based PRs are not supported by this setup.

## Secret Handling

The installer stores sensitive values only in GitHub Actions secrets. It does not write the App Store Connect private key to disk. If you choose the file-based input path, the script reads the `.p8` file into memory and passes it directly to `gh secret set`.

## Manual Setup

If you prefer to configure everything yourself, create a workflow file such as `.github/workflows/xcode-cloud-dispatch.yml` in your repository and use the action directly.

```yaml
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
    if: ${{ github.event.issue.pull_request && github.event.comment.body == '/build' }}
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
            core.setOutput('is_fork', isFork ? 'true' : 'false');

      - name: Reject fork pull requests
        if: ${{ steps.pr.outputs.is_fork == 'true' }}
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.issues.updateComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              comment_id: context.payload.comment.id,
              body: [
                '/build',
                '',
                '> Xcode Cloud dispatch only supports pull requests whose head branch exists in the repository linked to the Xcode Cloud workflow.',
                '> Pull requests from forks are not supported by this workflow.',
              ].join('\n'),
            });

      - name: Check out pull request commit
        if: ${{ steps.pr.outputs.is_fork != 'true' }}
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.pr.outputs.head_sha }}

      - name: Trigger Xcode Cloud
        id: xcode
        if: ${{ steps.pr.outputs.is_fork != 'true' }}
        uses: murphb52/xcode-cloud-dispatch-action@main
        with:
          apple_key_id: ${{ secrets.APPSTORE_KEY_ID }}
          apple_issuer_id: ${{ secrets.APPSTORE_ISSUER_ID }}
          apple_private_key: ${{ secrets.APPSTORE_PRIVATE_KEY }}
          workflow_id: ${{ vars.XCODE_CLOUD_WORKFLOW_ID }}
          project_path: ${{ vars.XCODE_CLOUD_PROJECT_PATH }}
          info_plist_path: ${{ vars.XCODE_CLOUD_INFO_PLIST_PATH }}
          branch: ${{ steps.pr.outputs.head_ref }}
          team_id: ${{ vars.APPSTORE_TEAM_ID }}
          app_id: ${{ vars.APPSTORE_APP_ID }}
```

## Inputs

| Input | Description | Required | Default |
| :--- | :--- | :---: | :--- |
| `apple_key_id` | App Store Connect API Key ID | Yes | - |
| `apple_issuer_id` | App Store Connect Issuer ID | Yes | - |
| `apple_private_key` | The content of the `.p8` private key file | Yes | - |
| `workflow_id` | The Xcode Cloud workflow ID from App Store Connect | Yes | - |
| `project_path` | Path to your `.xcodeproj`. Used to read `MARKETING_VERSION` from `project.pbxproj`. | No | Auto-detected by the action when omitted |
| `info_plist_path` | Path to your `Info.plist` for hardcoded `CFBundleShortVersionString` projects. | No | - |
| `branch` | Branch name to build. If omitted, Xcode Cloud uses the workflow default branch. | No | - |
| `team_id` | App Store Connect Team ID for deep-linking | No | - |
| `app_id` | Apple App ID for deep-linking | No | - |

## Outputs

| Output | Description |
| :--- | :--- |
| `build_number` | The build number assigned by Apple |
| `marketing_version` | The detected marketing version |
| `build_url` | A direct link to the build summary or general App Store Connect dashboard |
