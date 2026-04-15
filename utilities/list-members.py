#!/usr/bin/env python3

# Name: List Members Script
# Version: 2.0.0
# Date: 2026-04-14
# License: CC-BY-ND 4.0 International
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington

"""
Exports a CSV of member names and email addresses for a TDEI project group.

Interactive inputs:
    - Environment (dev, stage, prod) - defaults to prod
    - TDEI username
    - TDEI password
    - Project group ID

Output:
    local-storage/members_<project_group_id>.csv

Prerequisites:
    - A TDEI Portal account with Point of Contact (poc) role on the target
      project group. Only poc users are authorized to view member details.
    - Python 3.10+ with the 'requests' package installed.

Usage:
    python list-members.py
"""

import csv
import getpass
import os
import sys

import requests

# Environment configuration
ENV_API_URLS: dict[str, str] = {
    "dev": "https://portal-api-dev.tdei.us",
    "stage": "https://portal-api-stage.tdei.us",
    "prod": "https://portal-api.tdei.us",
}

VALID_ENVS = ("dev", "stage", "prod")

# ANSI color codes for terminal output
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
DIM = "\033[2m"
RESET = "\033[0m"


def prompt_environment() -> str:
    """Prompt for and validate the target environment."""
    print(f"{CYAN}Enter the environment (dev, stage, or prod){RESET}")
    print(f"  {DIM}Press Enter to default to 'prod'{RESET}")
    env = input("> ").strip().lower()

    if env == "":
        env = "prod"
        print("  Defaulting to 'prod'")

    if env not in VALID_ENVS:
        print(
            f"Error: Invalid environment '{env}'. "
            f"Must be one of: {', '.join(VALID_ENVS)}",
            file=sys.stderr,
        )
        sys.exit(1)

    return env


def prompt_credentials() -> tuple[str, str]:
    """Prompt for TDEI username and password."""
    print(f"\n{CYAN}Enter your TDEI username:{RESET}")
    username = input("> ").strip()
    if not username:
        print("Error: Username cannot be empty.", file=sys.stderr)
        sys.exit(1)

    print(f"{CYAN}Enter your TDEI password:{RESET}")
    password = getpass.getpass("> ")
    if not password:
        print("Error: Password cannot be empty.", file=sys.stderr)
        sys.exit(1)

    return username, password


def prompt_project_group_id() -> str:
    """Prompt for the project group ID."""
    print(f"\n{CYAN}Enter a project group ID{RESET}")
    print(f"  {DIM}Example: d02ef2fd-37b1-4924-af1a-f23dc1d9549e{RESET}")
    group_id = input("> ").strip()
    if not group_id:
        print("Error: Project group ID cannot be empty.", file=sys.stderr)
        sys.exit(1)

    return group_id


def get_output_path(project_group_id: str) -> str:
    """Build the output file path under local-storage/."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    output_dir = os.path.join(repo_root, "local-storage")
    os.makedirs(output_dir, exist_ok=True)
    return os.path.join(output_dir, f"members_{project_group_id}.csv")


def authenticate(base_url: str, username: str, password: str) -> str:
    """Authenticate with the TDEI Portal API and return a bearer token.

    Raises SystemExit on authentication failure or network error.
    """
    print("\nAuthenticating...")
    url = f"{base_url}/api/v1/authenticate"
    payload = {"username": username, "password": password}

    try:
        resp = requests.post(url, json=payload, timeout=30)
        resp.raise_for_status()
    except requests.exceptions.HTTPError as exc:
        status = exc.response.status_code if exc.response is not None else 0
        print(
            f"Error: Authentication failed (HTTP {status}).",
            file=sys.stderr,
        )
        if status == 401:
            print("  Check your username and password.", file=sys.stderr)
        sys.exit(1)
    except requests.exceptions.RequestException as exc:
        print(f"Error: Could not reach TDEI API: {exc}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    token = data.get("access_token")
    if not token:
        print(
            "Error: Authentication response did not include an access token.",
            file=sys.stderr,
        )
        sys.exit(1)

    return token


def fetch_members(
    base_url: str, project_group_id: str, token: str
) -> list[dict]:
    """Fetch all members of a project group, handling pagination.

    Requires a valid bearer token from an account with the poc role on the
    target project group.
    """
    print("Fetching project group members...")
    url = f"{base_url}/api/v1/project-group/{project_group_id}/users"
    headers = {"Authorization": f"Bearer {token}"}
    all_members: list[dict] = []
    page = 1
    page_size = 50

    while True:
        params = {"searchText": "", "page_no": page, "page_size": page_size}
        try:
            resp = requests.get(
                url, headers=headers, params=params, timeout=30
            )
            resp.raise_for_status()
        except requests.exceptions.HTTPError as exc:
            status = exc.response.status_code if exc.response is not None else 0
            print(
                f"Error: Failed to fetch members (HTTP {status}).",
                file=sys.stderr,
            )
            if status == 401:
                print(
                    "  Session expired or invalid token. Try again.",
                    file=sys.stderr,
                )
            elif status == 403:
                print(
                    "  Only a Point of Contact (poc) can view member details.",
                    file=sys.stderr,
                )
            elif status == 404:
                print(
                    "  Project group not found. Verify the project group ID.",
                    file=sys.stderr,
                )
            sys.exit(1)
        except requests.exceptions.RequestException as exc:
            print(
                f"Error: Could not reach TDEI API: {exc}", file=sys.stderr
            )
            sys.exit(1)

        data = resp.json()

        if isinstance(data, list):
            members = data
        elif isinstance(data, dict):
            members = data.get(
                "users", data.get("data", data.get("items", []))
            )
            if isinstance(members, dict):
                members = [members]
        else:
            members = []

        if not members:
            break

        all_members.extend(members)

        if len(members) < page_size:
            break

        page += 1

    return all_members


def write_csv(members: list[dict], output_path: str) -> None:
    """Write member data to a CSV file.

    Columns: Name, Email, Roles
    Prompts before overwriting an existing file.
    """
    if os.path.exists(output_path):
        overwrite = (
            input(f"File '{output_path}' already exists. Overwrite? (y/n): ")
            .strip()
            .lower()
        )
        if overwrite != "y":
            print("Operation canceled.")
            sys.exit(0)

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Name", "Email", "Roles"])

        for member in members:
            first = member.get("first_name", "").strip()
            last = member.get("last_name", "").strip()
            name = f"{first} {last}".strip()
            email = member.get("email", "").strip()
            roles = ", ".join(member.get("roles", []))
            writer.writerow([name, email, roles])


def main() -> None:
    print("TDEI List Members Script v2.0.0")
    print()

    # Environment
    env = prompt_environment()
    base_url = ENV_API_URLS[env]

    # Credentials
    username, password = prompt_credentials()
    token = authenticate(base_url, username, password)

    # Clear password from memory
    del password

    # Project group(s) — loop to allow multiple exports
    project_group_id = None
    while True:
        if project_group_id is None:
            project_group_id = prompt_project_group_id()

        output_path = get_output_path(project_group_id)
        members = fetch_members(base_url, project_group_id, token)

        if not members:
            print(f"{YELLOW}No members found for this project group.{RESET}")
        else:
            write_csv(members, output_path)
            print(
                f"\n{GREEN}Success! Exported {len(members)} member(s) to '{output_path}'.{RESET}"
            )

        print(f"\n{CYAN}Enter another project group ID, or 'exit' to quit:{RESET}")
        next_input = input("> ").strip()
        if next_input.lower() == "exit" or next_input == "":
            break

        project_group_id = next_input


if __name__ == "__main__":
    main()
