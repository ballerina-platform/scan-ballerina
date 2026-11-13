# SonarQube

This page covers how the action resolves the `sonarqube` settings of each package and runs the SonarQube scan. See the [README](../README.md#sonarqube-1) for the fields of `platform-config.sonarqube`.

## How settings are resolved

Each setting of a package is resolved field by field: its `packages` item, then the platform level, then the package's `Scan.toml` and properties file. Paths in `platform-config` are relative to the repository root. Paths in `Scan.toml` are relative to the folder of `Scan.toml`, or to the package for a remote one, as `bal scan` resolves them.

- **Platform plugin:** `plugin-path` or `plugin-version`, otherwise the `path` of the `sonarqube` `[[platform]]` entry in `Scan.toml` (a relative path or an `https` URL), otherwise the newest version this release knows to work with the installed scan tool. An absolute path fails, since it points to one machine. A `plugin-path` or `plugin-version` in an item replaces both platform-level fields.
- **Properties file:** `properties-file`, otherwise `sonarProjectPropertiesPath` in `Scan.toml`, otherwise `sonar-project.properties` in the package root, if it exists. Like `bal scan`, a relative `sonarProjectPropertiesPath` is looked up next to `Scan.toml` first, then in the package, so a `Scan.toml` shared through `configPath` can name each package's own properties file.
- **Server and token:** an item that sets `host-url` must also set `token`, so a token is never sent to a server it was not configured for. For the same reason, a package that takes its server URL from `sonar.host.url` in its properties file must set its own `token` under `packages`: the platform-level token goes only to a `host-url` in `platform-config`. Every URL must be `https`, including one from the properties file.
- **Project:** each package is a separate SonarQube analysis, so packages on the same server need different project keys. `project-key` and `project-name` at the platform level are for a scan of one package, counted after `exclude-paths`: with more packages they fail, so set them for each package under `packages`. With one package, setting the same field at the platform level and in its item also fails.

The action passes the settings to SonarScanner through the `SONAR_HOST_URL`, `SONAR_TOKEN` and `SONAR_SCANNER_JSON_PARAMS` environment variables of each package's `bal scan` process, never on the command line. SonarScanner gives them precedence over the properties file, and keeps the file's other settings.

## Platform plugin

The platform plugin is published to GitHub Packages, which needs a token with `read:packages` even for public packages. Give the job `packages: read`, or set `plugin-path` to a JAR in the repository or an `https` URL.

## Workspaces

SonarQube is not supported for workspaces yet, and a workspace in `paths` fails the step when `sonarqube` is selected. `bal scan` reports each member of a workspace in its own SonarScanner run, all with the one project key of the process, so each member's analysis would replace the previous one.

Instead, list the member package directories in `paths`, rather than the workspace or a directory above it, so that the workspace's `Ballerina.toml` is not found. `exclude-paths` does not help here, since excluding the workspace directory also excludes its members. For a member without a `Scan.toml` of its own, the `Scan.toml` the SonarQube scan writes starts from a copy of the workspace's, so its `[rule]`, `[analysis]` and `[suppression]` settings still apply. Workspaces are fully supported for the SARIF file.

## Forks and Dependabot

Runs for pull requests from forks, such as `pull_request` and `pull_request_review` runs, get no secrets. Runs triggered by Dependabot on any event other than `pull_request_target` and `workflow_run` get only Dependabot secrets, not Actions secrets, so store the SonarQube token as a Dependabot secret too to analyze them.

Fork runs get a read-only `GITHUB_TOKEN`. Dependabot runs get a read-only `GITHUB_TOKEN` by default, and a workflow can grant `security-events: write` through the `permissions` key. In such a run, the action skips SonarQube with a warning when a token is empty, and still produces the SARIF file.

The action still tries the upload to code scanning, which accepts uploads with a read-only token from `pull_request` runs, and from other runs whose token can write security events. When the upload fails in such a run on an event other than `pull_request`, the action reports it as skipped with a warning instead of failing. In a `pull_request` run, a failed upload fails the step, since it is not caused by the read-only token. Save the SARIF file with `artifacts: true` and upload it from a trusted `workflow_run` workflow.

## Excluded files

With `exclude-tests: true`, `bal scan` leaves the test sources out, so SonarQube receives no findings in them either. `exclude-paths` is applied to the SARIF file only, so SonarQube receives each package's findings before it. Use `sonar.exclusions` to keep the same files out of SonarQube.

## Cache

SonarScanner downloads its scanner engine and every analyzer the server has installed, including the Ballerina language plugin. The action keeps them, and the SonarScanner CLI, in the GitHub Actions cache, so later jobs and runs restore them instead of downloading them again. See [How it works](how-it-works.md#sonarscanner-cache).
