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
    wandb_key = {}
    wandb_entity = {}
    for p, pconf in git_projects_raw.items():
        pconf = pconf or {}
        git_user_allow_push[p] = pconf.get("git_user_allow_push", True)
        git_owner[p] = pconf.get("git_owner", "")
        wandb_key[p] = pconf.get("wandb_api_key", "")
        wandb_entity[p] = pconf.get("wandb_entity", "")
    print(f"GIT_PROJECT_LIST={bash_list(git_projects)}")
    for p in git_projects:
        val = "true" if git_user_allow_push.get(p, True) else "false"
        print(f"GIT_USER_ALLOW_PUSH_{p}={val}")
        print(f"GIT_OWNER_{p}={bash_quote(git_owner[p])}")
        # Per-project wandb creds → container env via docker.sh (persistent login).
        if wandb_key[p]:
            print(f"WANDB_API_KEY_{p}={bash_quote(wandb_key[p])}")
        if wandb_entity[p]:
            print(f"WANDB_ENTITY_{p}={bash_quote(wandb_entity[p])}")

    # ── Submodules (keyed by parent_sub) ──
    # users.yaml stores [path] as the full relative path (already includes the
    # submodule name — yaml_to_bash.py / worklog_setup.sh resolve it), so pass
    # it through verbatim. Mirrors the SUBMODULE_* vars in configuration.sh.
    all_submodules = {}
    project_submodules = {}
    for p, pconf in git_projects_raw.items():
        pconf = pconf or {}
        subs = pconf.get("submodules", {}) or {}
        if not subs:
            continue
        project_submodules[p] = []
        for sname, sconf in subs.items():
            sconf = sconf or {}
            if not sconf.get("enabled", True):
                continue
            all_submodules[(p, sname)] = {
                "parent": p,
                "path": sconf.get("path", ""),
                "git_owner": sconf.get("git_owner", ""),
                "git_user_allow_push": sconf.get("git_user_allow_push", False),
            }
            project_submodules[p].append(sname)
        if not project_submodules[p]:
            del project_submodules[p]
    if all_submodules:
        combined_keys = [f"{p}_{s}" for (p, s) in all_submodules]
        print(f"SUBMODULE_LIST={bash_list(combined_keys)}")
        for p, subs in project_submodules.items():
            print(f'GIT_SUBMODULES_{p}={bash_quote(" ".join(subs))}')
        for (p, sname), sconf in all_submodules.items():
            print(bash_assoc_array(f"SUBMODULE_{p}_{sname}", sconf))
    else:
        print("SUBMODULE_LIST=()")

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
