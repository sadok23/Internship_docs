#!/usr/bin/env python3
"""
FreeIPA → Komodo user group sync
Only syncs groups prefixed with 'komodo-'
"""

import requests
import ldap3

# ── Config ─────────────────────────────────────────────────────────────────
LDAP_HOST     = "20.0.0.104"
LDAP_BIND_DN  = "uid=admin,cn=users,cn=accounts,dc=asteroidea,dc=co"
LDAP_PASS     = "Asteroidea4711$%!"
LDAP_BASE     = "cn=groups,cn=accounts,dc=asteroidea,dc=co"

KOMODO_URL        = "http://20.0.0.104:9120"
KOMODO_API_KEY    = "K_Ngp3FWstNcnJSY4ii6DqD971vRekhn5hcitVm2rA_K"
KOMODO_API_SECRET = "S_hulU0bqO7v4aqouRKPGVz68yo6C9NaJKcXxiHrzQ_S"
# ───────────────────────────────────────────────────────────────────────────


def komodo(path, payload):
    resp = requests.post(
        f"{KOMODO_URL}/{path}",
        headers={
            "Content-Type": "application/json",
            "X-Api-Key": KOMODO_API_KEY,
            "X-Api-Secret": KOMODO_API_SECRET,
        },
        json=payload,
    )
    if not resp.ok:
        print(f"  [ERROR] {resp.status_code} on {path}: {resp.text}")
        resp.raise_for_status()
    return resp.json()


def get_freeipa_groups(conn):
    conn.search(
        LDAP_BASE,
        "(&(objectClass=ipausergroup)(cn=komodo-*))",
        attributes=["cn", "member"]
    )
    groups = {}
    for entry in conn.entries:
        name = str(entry.cn)
        members = []
        for member_dn in entry.member:
            parts = str(member_dn).split(",")
            for part in parts:
                if part.startswith("uid="):
                    members.append(part[4:].lower())
                    break
        groups[name] = members
    return groups


def get_komodo_users():
    users = komodo("read", {"type": "ListUsers", "params": {}})
    return {u["username"].lower(): u["_id"]["$oid"] for u in users}


def get_komodo_groups():
    groups = komodo("read", {"type": "ListUserGroups", "params": {}})
    return {g["name"]: g for g in groups}


def create_komodo_group(name):
    print(f"  [+] Creating group: {name}")
    komodo("write", {"type": "CreateUserGroup", "params": {"name": name}})


def update_komodo_group(name, user_ids):
    print(f"  [~] Updating members of '{name}': {user_ids}")
    komodo("write", {
        "type": "SetUsersInUserGroup",
        "params": {
            "user_group": name,
            "users": user_ids,
        }
    })

def main():
    print("Connecting to FreeIPA LDAP...")
    server = ldap3.Server(LDAP_HOST, get_info=ldap3.ALL)
    conn = ldap3.Connection(server, LDAP_BIND_DN, LDAP_PASS, auto_bind=True)

    print("Fetching FreeIPA groups (komodo-* only)...")
    ipa_groups = get_freeipa_groups(conn)
    conn.unbind()

    print("Fetching Komodo users...")
    komodo_users = get_komodo_users()

    print("Fetching Komodo groups...")
    komodo_groups = get_komodo_groups()

    print(f"\nFreeIPA groups to sync: {list(ipa_groups.keys())}")
    print(f"Komodo users available: {list(komodo_users.keys())}\n")

    if not ipa_groups:
        print("No komodo-* groups found in FreeIPA. Create groups with 'komodo-' prefix to sync.")
        return

    for group_name, ipa_members in ipa_groups.items():
        print(f"Processing group: {group_name}")

        if group_name not in komodo_groups:
            create_komodo_group(group_name)

        matched_ids = []
        for username in ipa_members:
            if username in komodo_users:
                matched_ids.append(komodo_users[username])
            else:
                print(f"  [!] '{username}' not in Komodo yet (needs to log in first via OIDC)")

        update_komodo_group(group_name, matched_ids)

    print("\nSync complete.")


if __name__ == "__main__":
    main()
