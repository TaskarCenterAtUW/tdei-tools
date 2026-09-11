#!/usr/bin/env python3
"""Aggregate public GitHub repository changelogs for selected organizations.

The script uses GitHub's public REST API without authentication by default and
writes a Markdown document. A token can be supplied through
``GITHUB_TOKEN`` to avoid the lower unauthenticated API rate limit.

Only release sections dated for the requested report date are included. When no
date is supplied, the previous UTC calendar day is used. HTML-commented
templates and headings inside fenced code blocks are ignored while parsing
changelogs.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from concurrent.futures import ThreadPoolExecutor
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, cast
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


DEFAULT_ORGANIZATIONS = ("TaskarCenterAtUW", "OpenSidewalks", "AccessMap")
OUTPUT_DIRECTORY = Path(__file__).resolve().parent
GITHUB_API_URL = "https://api.github.com"
MAX_WORKERS = 8
MAX_RETRIES = 3
HEADING_PATTERN = re.compile(r"^\s{0,3}(#{1,6})\s+(.+?)\s*$")
DATE_PATTERNS = ("%Y-%m-%d", "%Y/%m/%d", "%Y-%b-%d", "%Y-%B-%d")
DATE_TOKEN_PATTERN = re.compile(
    r"\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{4}-[A-Za-z]+-\d{1,2}"
)
DATE_ONLY_LINE_PATTERN = re.compile(
    r"^\s*\d{4}[-/]\d{1,2}[-/]\d{1,2}\s*$|"
    r"^\s*\d{4}-[A-Za-z]+-\d{1,2}\s*$"
)
DATE_ONLY_PATTERN = re.compile(
    r"^[\s`*_()\[\]]*"
    r"(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{4}-[A-Za-z]+-\d{1,2})"
    r"[\s`*_()\[\]]*$"
)
HTML_COMMENT_PATTERN = re.compile(r"<!--.*?(?:-->|$)", re.DOTALL)
FENCE_PATTERN = re.compile(r"^\s{0,3}(`{3,}|~{3,})")


class GitHubApiError(RuntimeError):
    """Raised when GitHub cannot provide the requested data."""

    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


@dataclass(frozen=True)
class RepositoryChangelog:
    """A repository and its changelog content."""

    organization: str
    name: str
    html_url: str
    changelog_url: str
    content: str


def parse_date(value: str) -> date:
    """Parse an ISO date supplied on the command line."""
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"invalid date {value!r}; expected YYYY-MM-DD"
        ) from exc


def changelog_date(heading: str) -> date | None:
    """Return a release date found in a Markdown heading, if any."""
    for token_match in DATE_TOKEN_PATTERN.finditer(heading):
        token = token_match.group()
        for pattern in DATE_PATTERNS:
            try:
                return datetime.strptime(token, pattern).date()
            except ValueError:
                continue
    return None


def remove_html_comments(content: str) -> str:
    """Remove HTML comments, including multiline commented-out sections."""
    return HTML_COMMENT_PATTERN.sub("", content)


def find_headings(lines: list[str]) -> list[tuple[int, int, str]]:
    """Find Markdown headings outside fenced code blocks."""
    headings: list[tuple[int, int, str]] = []
    fence_marker: str | None = None
    fence_length = 0
    for index, line in enumerate(lines):
        fence_match = FENCE_PATTERN.match(line)
        if fence_match:
            marker = fence_match.group(1)[0]
            marker_length = len(fence_match.group(1))
            if fence_marker is None:
                fence_marker = marker
                fence_length = marker_length
            elif marker == fence_marker and marker_length >= fence_length:
                fence_marker = None
            continue
        if fence_marker is None:
            heading_match = HEADING_PATTERN.match(line)
            if heading_match:
                headings.append(
                    (index, len(heading_match.group(1)), heading_match.group(2))
                )
    return headings


def filter_changelog(content: str, report_date: date) -> str | None:
    """Keep release sections dated ``report_date``.

    HTML comments are removed first so commented-out templates are ignored.
    Headings inside fenced code blocks are also ignored. Changelogs use several
    heading levels and date formats, including dates on the line immediately
    after a release heading. A release section extends through its nested
    headings until the next heading at the same or higher level. Changelogs
    without a section dated for the report date are omitted.
    """
    lines = remove_html_comments(content).splitlines()
    sections: list[tuple[int, int]] = []
    headings = find_headings(lines)

    parent_indexes: list[int | None] = []
    parent_stack: list[int] = []
    next_boundary_indexes: list[int | None] = [None] * len(headings)
    boundary_stack: list[int] = []
    for heading_index, (_, level, _) in enumerate(headings):
        while parent_stack and headings[parent_stack[-1]][1] >= level:
            parent_stack.pop()
        parent_indexes.append(parent_stack[-1] if parent_stack else None)
        parent_stack.append(heading_index)

    for heading_index in range(len(headings) - 1, -1, -1):
        level = headings[heading_index][1]
        while (
            boundary_stack
            and headings[boundary_stack[-1]][1] > level
        ):
            boundary_stack.pop()
        if boundary_stack:
            next_boundary_indexes[heading_index] = boundary_stack[-1]
        boundary_stack.append(heading_index)

    for heading_index, (start, _, title) in enumerate(headings):
        release_date = changelog_date(title)
        if release_date is None and start + 1 < len(lines):
            next_line = lines[start + 1]
            if DATE_ONLY_LINE_PATTERN.fullmatch(next_line):
                release_date = changelog_date(next_line)
        if release_date != report_date:
            continue

        section_start = start
        if release_date is not None and DATE_ONLY_PATTERN.fullmatch(title):
            parent_index = parent_indexes[heading_index]
            if parent_index is not None:
                section_start = headings[parent_index][0]

        next_boundary_index = next_boundary_indexes[heading_index]
        end = (
            headings[next_boundary_index][0]
            if next_boundary_index is not None
            else len(lines)
        )
        sections.append((section_start, end))

    sections.sort()

    merged_sections: list[tuple[int, int]] = []
    for start, end in sections:
        if merged_sections and start < merged_sections[-1][1]:
            previous_start, previous_end = merged_sections[-1]
            merged_sections[-1] = (previous_start, max(previous_end, end))
        else:
            merged_sections.append((start, end))

    if not sections:
        return None

    selected_lines: list[str] = []
    for start, end in merged_sections:
        section = lines[start:end]
        while section and not section[-1].strip():
            section.pop()
        if selected_lines and section:
            selected_lines.extend(("", ""))
        selected_lines.extend(section)
    filtered_content = "\n".join(selected_lines).strip()
    return filtered_content or None


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Aggregate CHANGELOG.md files from public GitHub repositories."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help=(
            "Output Markdown path (default: "
            f"{OUTPUT_DIRECTORY / 'CHANGELOG-YYYY-MM-DD.md'})"
        ),
    )
    parser.add_argument(
        "--date",
        dest="report_date",
        type=parse_date,
        default=datetime.now(timezone.utc).date() - timedelta(days=1),
        help=(
            "UTC date whose release sections should be included and used for the "
            "default output filename (default: previous UTC calendar day)"
        ),
    )
    parser.add_argument(
        "--organizations",
        nargs="+",
        default=list(DEFAULT_ORGANIZATIONS),
        metavar="ORG",
        help="Organizations to scan (default: the three project organizations)",
    )
    return parser.parse_args(argv)


def github_request(api_url: str, path: str, token: str | None) -> Any:
    """Make a GitHub API request and decode its JSON response."""
    url = f"{api_url.rstrip('/')}/{path.lstrip('/')}"
    body = request_bytes(
        url,
        token,
        {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        path,
    )
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise GitHubApiError(
            f"GitHub returned invalid JSON for {path}") from exc


def request_bytes(
    url: str,
    token: str | None,
    headers: dict[str, str],
    description: str,
) -> bytes:
    """Fetch bytes with bounded retries for transient HTTP failures."""
    request_headers = {
        "User-Agent": "tdei-tools-changelog-aggregator", **headers}
    for attempt in range(MAX_RETRIES):
        request = Request(url, headers=request_headers)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urlopen(request, timeout=60) as response:
                return response.read()
        except HTTPError as exc:
            details = exc.read().decode("utf-8", errors="replace")
            retryable = exc.code in {429, 500, 502, 503, 504} or (
                exc.code == 403
                and exc.headers.get("X-RateLimit-Remaining") == "0"
            )
            if not retryable or attempt == MAX_RETRIES - 1:
                raise GitHubApiError(
                    f"GitHub request failed ({exc.code}) for {description}: "
                    f"{details}",
                    status_code=exc.code,
                ) from exc
            retry_after = exc.headers.get("Retry-After")
            try:
                delay = min(float(retry_after),
                            30.0) if retry_after else 2**attempt
            except ValueError:
                delay = 2**attempt
            time.sleep(delay)
        except URLError as exc:
            if attempt == MAX_RETRIES - 1:
                raise GitHubApiError(
                    f"Could not reach GitHub for {description}: {exc}"
                ) from exc
            time.sleep(2**attempt)

    raise AssertionError("request retry loop exited unexpectedly")


def list_public_repositories(
    api_url: str, organization: str, token: str | None
) -> list[dict[str, Any]]:
    """Return all public, non-archived repositories in an organization."""
    repositories: list[dict[str, Any]] = []
    page = 1
    while True:
        result = github_request(
            api_url,
            f"orgs/{quote(organization)}/repos?type=public&per_page=100&page={page}",
            token,
        )
        if not isinstance(result, list):
            raise GitHubApiError(
                f"GitHub returned an unexpected repository list for {organization}"
            )
        repository_items = cast(list[Any], result)
        if not repository_items:
            return repositories
        repositories.extend(
            repository
            for item in repository_items
            if isinstance(item, dict)
            for repository in [cast(dict[str, Any], item)]
            if repository.get("name")
            and repository.get("html_url")
            and not repository.get("archived", False)
            and not repository.get("disabled", False)
        )
        if len(repository_items) < 100:
            return repositories
        page += 1


def fetch_changelog(
    api_url: str,
    organization: str,
    repository: dict[str, Any],
    token: str | None,
    report_date: date,
) -> RepositoryChangelog | None:
    """Fetch a repository's root ``CHANGELOG.md``, if it exists."""
    repository_name = repository.get("name")
    repository_url = repository.get("html_url")
    if not isinstance(repository_name, str) or not isinstance(repository_url, str):
        return None
    path = (
        f"repos/{quote(organization)}/{quote(repository_name)}"
        "/contents/CHANGELOG.md"
    )
    try:
        response = github_request(api_url, path, token)
    except GitHubApiError as exc:
        if exc.status_code == 404:
            return None
        raise

    if not isinstance(response, dict):
        return None
    response_data = cast(dict[str, Any], response)
    if response_data.get("type") != "file":
        return None

    encoded_content = response_data.get("content")
    if encoded_content:
        try:
            normalized_content = re.sub(r"\s+", "", str(encoded_content))
            content = base64.b64decode(
                normalized_content, validate=True
            ).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError) as exc:
            raise GitHubApiError(
                f"Invalid CHANGELOG.md content for {organization}/{repository_name}"
            ) from exc
    else:
        download_url = response_data.get("download_url")
        if not isinstance(download_url, str) or not download_url:
            raise GitHubApiError(
                f"GitHub returned no content URL for {organization}/{repository_name}"
            )
        try:
            content = request_bytes(
                download_url,
                token,
                {"Accept": "application/vnd.github.raw+json"},
                f"{organization}/{repository_name}/CHANGELOG.md",
            ).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise GitHubApiError(
                f"Invalid UTF-8 CHANGELOG.md content for "
                f"{organization}/{repository_name}"
            ) from exc
    filtered_content = filter_changelog(content, report_date)
    if filtered_content is None:
        return None

    return RepositoryChangelog(
        organization=organization,
        name=repository_name,
        html_url=repository_url,
        changelog_url=str(
            response_data.get(
                "html_url", f"{repository_url}/blob/HEAD/CHANGELOG.md"
            )
        ),
        content=filtered_content,
    )


def collect_changelogs(
    api_url: str,
    organizations: list[str],
    token: str | None,
    report_date: date,
) -> list[RepositoryChangelog]:
    """Collect changelogs, preserving organization and repository sort order."""
    changelogs: list[RepositoryChangelog] = []
    for organization in sorted(organizations, key=str.casefold):
        repositories = list_public_repositories(api_url, organization, token)
        sorted_repositories = sorted(
            repositories, key=lambda item: str(item.get("name", "")).casefold()
        )
        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            futures = [
                executor.submit(
                    fetch_changelog,
                    api_url,
                    organization,
                    repository,
                    token,
                    report_date,
                )
                for repository in sorted_repositories
            ]
            changelogs.extend(
                changelog
                for future in futures
                if (changelog := future.result()) is not None
            )
    return changelogs


def output_path_for(report_date: date, output: Path | None) -> Path:
    """Return the requested output path, or the dated default path."""
    return output or OUTPUT_DIRECTORY / f"CHANGELOG-{report_date.isoformat()}.md"


def render_markdown(
    changelogs: list[RepositoryChangelog], report_date: date, generated_at: datetime
) -> str:
    """Render the aggregate Markdown document."""
    lines = [
        f"# Changelog Aggregator - {report_date.isoformat()}",
        "",
        "<!-- This file is generated by tdei-tools/utilities/aggregate_changelogs.py. -->",
        f"_Generated: {generated_at.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}_",
        "",
    ]
    current_organization: str | None = None
    if not changelogs:
        lines.extend(["No new `CHANGELOG.md` entries were found.", ""])

    for changelog in changelogs:
        if changelog.organization != current_organization:
            current_organization = changelog.organization
            lines.extend([f"## {current_organization}", ""])
        quoted_content = "\n".join(
            f"> {line}" if line else ">"
            for line in changelog.content.splitlines()
        )
        lines.extend(
            [
                f"### [{changelog.name}]({changelog.html_url})",
                "",
                f"[View `CHANGELOG.md` on GitHub]({changelog.changelog_url})",
                "",
                quoted_content,
                "",
                "---",
                "",
            ]
        )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    """Run the changelog aggregation."""
    args = parse_args(argv)
    output_path = output_path_for(args.report_date, args.output)
    token = os.environ.get("GITHUB_TOKEN")
    try:
        changelogs = collect_changelogs(
            GITHUB_API_URL, args.organizations, token, args.report_date
        )
        output = render_markdown(
            changelogs, args.report_date, datetime.now(timezone.utc)
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output, encoding="utf-8", newline="\n")
    except (GitHubApiError, UnicodeDecodeError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Wrote {len(changelogs)} changelog(s) to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
