#!/usr/bin/env python3
"""Convert users.yaml to bash variable declarations for exec scripts.

Usage:
    eval "$(python3 exec.py <users.yaml> <username>)"

Reads the specified user's configuration from users.yaml and outputs
bash variable declarations matching the user-scoped portion of configuration.sh:

    PROJECT_USER, DEFAULT_SOURCE_MNT_PATH, SSH_DEFAULT_KEY
    SERVER_LIST, SERVER_xxx (associative arrays)
    DOCKER_LIST, DOCKER_xxx (associative arrays)   ← user-only
    GIT_PROJECT_LIST                                ← user-only
    PROJECT_DOCKER_xxx                              ← user-only

DEFAULT_GIT_PROJECT_LIST and DEFAULT_DOCKER_LIST come from configuration.sh
(loaded separately) and are NOT redefined here — they are universal across users.
"""

import sys
from pathlib import Path

import yaml


def bash_quote(value):
    """Quote a value for bash, handling special characters."""
    if value is None:
        return '""'
    s = str(value)
    # Escape backslashes and double quotes
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


def bash_list(items):
    """Format a list as bash array: ("item1" "item2")."""
    if not items:
        return "()"
    return "(" + " ".join(bash_quote(i) for i in items) + ")"


def bash_assoc_array(name, data, skip_keys=None):
    """Format a dict as bash associative array declaration."""
    skip = skip_keys or set()
    pairs = []
    for k, v in data.items():
        if k in skip:
            continue
        if isinstance(v, list):
            pairs.append(f'[{k}]={bash_quote(" ".join(str(x) for x in v))}')
        elif isinstance(v, bool):
            pairs.append(f'[{k}]={"true" if v else "false"}')
        elif v is None:
            pairs.append(f'[{k}]=""')
        else:
            pairs.append(f'[{k}]={bash_quote(v)}')
    return f"declare -A {name}=({' '.join(pairs)})"


def main():
    if len(sys.argv) < 3:
        print("Usage: exec.py <users.yaml> <username>", file=sys.stderr)
        sys.exit(1)

    yaml_path = Path(sys.argv[1])
    username = sys.argv[2]

    if not yaml_path.exists():
        print(f"[ERROR] {yaml_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    if not data or username not in data:
        print(f"[ERROR] user '{username}' not found in {yaml_path}", file=sys.stderr)
        sys.exit(1)

    user = data[username]

    # ── Common ──
    print(f'PROJECT_USER={bash_quote(username)}')
    print(f'DEFAULT_SOURCE_MNT_PATH={bash_quote(user.get("default_source_mnt_path", ""))}')
    print(f'SSH_DEFAULT_KEY={bash_quote(user.get("ssh_default_key", "~/.ssh/id_ed25519"))}')

    # ── Git projects ──
    git_projects_raw = user.get("git_projects", {})
    git_projects = list(git_projects_raw.keys())
    git_user_allow_push = {}
    git_owner = {}
    for p, pconf in git_projects_raw.items():
        pconf = pconf or {}
        git_user_allow_push[p] = pconf.get("git_user_allow_push", True)
        git_owner[p] = pconf.get("git_owner", "")
    print(f"GIT_PROJECT_LIST={bash_list(git_projects)}")
    for p in git_projects:
        val = "true" if git_user_allow_push.get(p, True) else "false"
        print(f"GIT_USER_ALLOW_PUSH_{p}={val}")
        print(f"GIT_OWNER_{p}={bash_quote(git_owner[p])}")

    # ── Docker images ──
    docker_images = user.get("docker_images", {})
    print(f"DOCKER_LIST={bash_list(docker_images.keys())}")
    for img_name, img_conf in docker_images.items():
        print(bash_assoc_array(f"DOCKER_{img_name}", img_conf))

    # ── Project-Docker mapping ──
    project_docker = user.get("project_docker", {})
    for proj, images in project_docker.items():
        if isinstance(images, list):
            print(f'PROJECT_DOCKER_{proj}={bash_quote(" ".join(images))}')
        else:
            print(f'PROJECT_DOCKER_{proj}={bash_quote(images)}')

    # ── Servers ──
    servers = user.get("servers", {})
    print(f"SERVER_LIST={bash_list(servers.keys())}")
    for sname, sconf in servers.items():
        print(bash_assoc_array(f"SERVER_{sname}", sconf, skip_keys={"docker_containers"}))


if __name__ == "__main__":
    main()
