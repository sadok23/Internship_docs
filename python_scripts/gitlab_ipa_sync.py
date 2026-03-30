#!/usr/bin/env python3
import gitlab
import ldap3
import re

# --- CONFIGURATION ---
# GitLab Details
GITLAB_URL = 'http://20.0.0.132:8080'  # Update to your GitLab IP/Port
GITLAB_TOKEN = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXx'

# FreeIPA Details (based on your docker run command)
LDAP_HOST = '20.0.0.104'
LDAP_BIND_DN = 'uid=admin,cn=users,cn=accounts,dc=asteroidea,dc=co'
LDAP_PASS = 'Asteroidea4711$%!'
LDAP_BASE = 'cn=groups,cn=accounts,dc=asteroidea,dc=co'

# Access Level Mapping
ROLE_LEVELS = {
    'developper': 30, # Note: used your spelling 'developper' to match your group naming
    'maintainer': 40,
    'owner':      50,
    'reporter':   20,
    'guest':      10
}

# Initialize Clients
gl = gitlab.Gitlab(GITLAB_URL, private_token=GITLAB_TOKEN)
server = ldap3.Server(LDAP_HOST, get_info=ldap3.ALL)
conn = ldap3.Connection(server, LDAP_BIND_DN, LDAP_PASS, auto_bind=True)

def sync():
    # 1. Search for groups following the 'gitlab-' pattern
    # The filter ensures we only grab IPA user groups matching your prefix
    conn.search(LDAP_BASE, '(&(objectClass=ipausergroup)(cn=gitlab-*))', attributes=['cn', 'member'])
    
    project_memberships = {}

    for entry in conn.entries:
        cn = str(entry.cn)
        parts = cn.split('-')
        
        # Format: gitlab-[project]-[role]
        if len(parts) < 3: 
            continue
        
        # This handles project names that might contain hyphens (e.g., gitlab-my-app-owner)
        # It takes everything between 'gitlab' and the last part (the role)
        project_name = "-".join(parts[1:-1])
        role_key = parts[-1]
        
        if role_key not in ROLE_LEVELS:
            print(f"Skipping group {cn}: Role '{role_key}' not in ROLE_LEVELS mapping.")
            continue

        level = ROLE_LEVELS[role_key]

        if project_name not in project_memberships:
            project_memberships[project_name] = {}

        # Extract UIDs from the 'member' attribute (which contains full DN strings)
        for member_dn in entry.member:
            match = re.search(r'uid=([^,]+)', member_dn)
            if match:
                username = match.group(1)
                # Ensure we keep the highest permission if user is in multiple groups for one project
                current_level = project_memberships[project_name].get(username, 0)
                if level > current_level:
                    project_memberships[project_name][username] = level

    # 2. Reconcile with GitLab
    for project, members in project_memberships.items():
        try:
            # Get existing group or create it
            try:
                # We check by path/slug
                group = None
                groups = gl.groups.list(search=project)
                for g in groups:
                    if g.path == project:
                        group = g
                        break
                
                if not group:
                    raise gitlab.exceptions.GitlabGetError("Not found")

            except gitlab.exceptions.GitlabGetError:
                group = gl.groups.create({'name': project.capitalize(), 'path': project})
                print(f"Created new GitLab group: {project}")

            print(f"Syncing GitLab Group: {project}")
            
            # Fetch current members from GitLab
            gl_members = {m.username: m.id for m in group.members.list(all=True)}

            # Add or Update members based on FreeIPA data
            for username, level in members.items():
                if username == 'admin' or username == 'root': 
                    continue # Safety: don't touch the main admin accounts
                
                if username in gl_members:
                    member = group.members.get(gl_members[username])
                    if member.access_level != level:
                        member.access_level = level
                        member.save()
                        print(f"  ^ Updated {username} access level to {level}")
                else:
                    # Find the user ID in GitLab (requires user to have logged in once via LDAP)
                    users = gl.users.list(username=username)
                    if users:
                        group.members.create({'user_id': users[0].id, 'access_level': level})
                        print(f"  + Added {username} with level {level}")
                    else:
                        print(f"  ! User {username} exists in IPA but not in GitLab. (First login required)")

            # Remove users who are no longer in the FreeIPA gitlab-* groups for this project
            for gl_user, mem_id in gl_members.items():
                if gl_user not in ['root', 'admin'] and gl_user not in members:
                    group.members.delete(mem_id)
                    print(f"  - Removed {gl_user} from group {project}")

        except Exception as e:
            print(f"Error processing project {project}: {e}")

    conn.unbind()

if __name__ == "__main__":
    sync()
