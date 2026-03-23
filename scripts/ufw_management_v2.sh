#!/bin/bash
# ============================================================
#  UFW Access Wizard
#  Manage SSH and container firewall rules interactively
# ============================================================

# ── Colors & styles ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

OK="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}!${NC}"

# ── Root check ───────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "\n  ${RED}${BOLD}Permission denied.${NC} Please run with sudo.\n"
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────
divider() {
  echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
}

header() {
  clear
  echo ""
  echo -e "  ${BOLD}${CYAN}┌─────────────────────────────────────────────────┐${NC}"
  echo -e "  ${BOLD}${CYAN}│${NC}          ${BOLD}UFW Access Wizard${NC}                        ${BOLD}${CYAN}│${NC}"
  echo -e "  ${BOLD}${CYAN}│${NC}  ${DIM}Manage SSH and container firewall rules${NC}          ${BOLD}${CYAN}│${NC}"
  echo -e "  ${BOLD}${CYAN}└─────────────────────────────────────────────────┘${NC}"
  echo ""
}

section() {
  echo ""
  echo -e "  ${BOLD}${BLUE}$1${NC}"
  divider
}

validate_ip() {
  local ip=$1
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
      [ "$octet" -gt 255 ] && return 1
    done
    return 0
  fi
  return 1
}

prompt_ip() {
  local ip
  while true; do
    printf "  \033[0;36m›\033[0m IP address: " >&2
    read -r ip
    if validate_ip "$ip"; then
      echo "$ip"
      return
    else
      echo -e "  ${FAIL} ${RED}Invalid IP format. Example: 192.168.1.10${NC}" >&2
    fi
  done
}

prompt() {
  local msg=$1
  local result
  printf "  \033[0;36m›\033[0m %s" "$msg" >&2
  read -r result
  echo "$result"
}

back_or_exit() {
  echo ""
  divider
  echo -e "  ${DIM}[M] Main menu   [Q] Quit${NC}"
  printf "\n  › "
  read -r nav
  case ${nav,,} in
    q) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
    *) main_menu ;;
  esac
}

ufw_numbered_rules() {
  ufw status numbered 2>/dev/null | awk '/^\[/'
}

# ── Main menu ────────────────────────────────────────────────
main_menu() {
  header

  local rule_count
  rule_count=$(ufw_numbered_rules | wc -l)
  local ufw_status
  ufw_status=$(ufw status | head -1 | awk '{print $2}')

  echo -e "  ${DIM}UFW:${NC} ${BOLD}${ufw_status}${NC}   ${DIM}Rules:${NC} ${BOLD}${rule_count}${NC}"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}1${NC}  Allow an IP to SSH"
  echo -e "  ${BOLD}2${NC}  Allow an IP to access container(s)"
  echo -e "  ${BOLD}3${NC}  Revoke all access for an IP"
  echo -e "  ${BOLD}4${NC}  Delete a specific rule"
  echo -e "  ${BOLD}5${NC}  List IPs with access"
  echo -e "  ${BOLD}6${NC}  Show raw UFW rules"
  echo -e "  ${BOLD}7${NC}  Exit"
  echo ""
  divider
  printf "\n  › Choose [1-7]: "
  read -r choice
  echo ""

  case $choice in
    1) allow_ssh ;;
    2) allow_container_access ;;
    3) revoke_ip ;;
    4) delete_rule ;;
    5) list_access ;;
    6) show_rules ;;
    7) echo -e "  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
    *) echo -e "  ${FAIL} ${RED}Invalid option.${NC}"; sleep 1; main_menu ;;
  esac
}

# ── 1. Allow SSH ─────────────────────────────────────────────
allow_ssh() {
  header
  section "Allow SSH Access"
  echo ""

  local ip
  ip=$(prompt_ip)

  if ufw status | grep -qF "from $ip"; then
    if ufw status | grep "from $ip" | grep -q '\b22\b'; then
      echo -e "\n  ${WARN} ${YELLOW}SSH rule already exists for ${BOLD}$ip${NC}"
    else
      ufw allow from "$ip" to any port 22 proto tcp comment "SSH - $ip" > /dev/null
      ufw reload > /dev/null
      echo -e "\n  ${OK} ${GREEN}SSH access granted to ${BOLD}$ip${NC}"
    fi
  else
    ufw allow from "$ip" to any port 22 proto tcp comment "SSH - $ip" > /dev/null
    ufw reload > /dev/null
    echo -e "\n  ${OK} ${GREEN}SSH access granted to ${BOLD}$ip${NC}"
  fi

  back_or_exit
}

# ── 2. Allow container access ────────────────────────────────
allow_container_access() {
  header
  section "Allow Container Access"
  echo ""

  local ip
  ip=$(prompt_ip)
  echo ""

  mapfile -t containers < <(docker ps --format '{{.Names}}')

  if [ ${#containers[@]} -eq 0 ]; then
    echo -e "  ${FAIL} ${RED}No running containers found.${NC}"
    back_or_exit
    return
  fi

  echo -e "  ${BOLD}Running containers:${NC}"
  echo ""

  local i=1
  for name in "${containers[@]}"; do
    local ports
    ports=$(docker inspect "$name" --format \
      '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} {{end}}{{end}}' \
      2>/dev/null | tr ' ' '\n' | grep -v '^$' | tr '\n' '  ')
    printf "  ${BOLD}%2d${NC}  %-25s ${DIM}%s${NC}\n" "$i" "$name" "$ports"
    ((i++))
  done

  echo ""
  printf "  ${BOLD}%2d${NC}  ${YELLOW}All containers${NC}\n" "$i"
  echo ""
  divider
  printf "\n  › Choose [1-%d]: " "$i"
  read -r sel
  echo ""

  if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
    echo -e "  ${FAIL} ${RED}Invalid selection.${NC}"
    back_or_exit
    return
  fi

  if [ "$sel" -eq "$i" ]; then
    for name in "${containers[@]}"; do
      _allow_container "$ip" "$name"
    done
  elif [ "$sel" -ge 1 ] && [ "$sel" -lt "$i" ]; then
    _allow_container "$ip" "${containers[$((sel-1))]}"
  else
    echo -e "  ${FAIL} ${RED}Invalid selection.${NC}"
    back_or_exit
    return
  fi

  ufw reload > /dev/null
  back_or_exit
}

# Uses container-side ports in ufw route rules.
# After Docker's DNAT, forwarded traffic destination is already the container
# port — so ufw route must match that, not the host published port.
_allow_container() {
  local ip=$1
  local name=$2

  # Read container-side ports (map keys: "3000/tcp", "80/tcp", etc.)
  mapfile -t container_ports < <(docker inspect "$name" \
    --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}}{{"\n"}}{{end}}{{end}}' \
    2>/dev/null | grep -v '^$')

  if [ ${#container_ports[@]} -eq 0 ]; then
    echo -e "  ${WARN} ${YELLOW}No published ports for '${BOLD}$name${NC}${YELLOW}'. Skipping.${NC}"
    return
  fi

  echo -e "  ${BOLD}$name${NC}"
  for cp in "${container_ports[@]}"; do
    local port proto
    port=$(echo "$cp" | cut -d'/' -f1)
    proto=$(echo "$cp" | cut -d'/' -f2)

    if ufw_numbered_rules | grep -qE "FWD.*${ip}.*${port}/${proto}|${port}/${proto}.*FWD.*${ip}"; then
      echo -e "    ${WARN} ${YELLOW}Route rule already exists for port $port/$proto${NC}"
    else
      ufw route allow proto "$proto" from "$ip" to any port "$port" \
        comment "$name - $ip" > /dev/null
      echo -e "    ${OK} ${GREEN}Allowed $ip → container:$port/$proto ($name)${NC}"
    fi
  done
}

# ── 3. Revoke all access for an IP ───────────────────────────
revoke_ip() {
  header
  section "Revoke All Access for an IP"
  echo ""

  local ip
  ip=$(prompt_ip)
  echo ""

  mapfile -t matched < <(ufw_numbered_rules | grep -F "$ip")

  if [ ${#matched[@]} -eq 0 ]; then
    echo -e "  ${WARN} ${YELLOW}No rules found for ${BOLD}$ip${NC}"
    back_or_exit
    return
  fi

  echo -e "  ${BOLD}Rules to be deleted:${NC}"
  echo ""
  for rule in "${matched[@]}"; do
    echo -e "  ${DIM}$rule${NC}"
  done
  echo ""
  divider
  echo ""
  echo -e "  ${RED}${BOLD}This will remove ${#matched[@]} rule(s) for $ip.${NC}"
  printf "  Type 'yes' to confirm: "
  read -r confirm

  if [ "$confirm" != "yes" ]; then
    echo -e "\n  ${WARN} ${YELLOW}Cancelled.${NC}"
    back_or_exit
    return
  fi

  local deleted=0
  while true; do
    mapfile -t current < <(ufw_numbered_rules | grep -F "$ip")
    [ ${#current[@]} -eq 0 ] && break
    local rule_num
    rule_num=$(echo "${current[0]}" | awk -F'[][]' '{print $2}' | tr -d ' ')
    yes | ufw delete "$rule_num" > /dev/null 2>&1
    ((deleted++))
  done

  ufw reload > /dev/null
  echo -e "\n  ${OK} ${GREEN}Removed ${BOLD}$deleted${NC}${GREEN} rule(s) for ${BOLD}$ip${NC}"

  back_or_exit
}

# ── 4. Delete a specific rule ─────────────────────────────────
delete_rule() {
  header
  section "Delete a Specific Rule"
  echo ""

  mapfile -t raw_rules < <(ufw_numbered_rules)

  if [ ${#raw_rules[@]} -eq 0 ]; then
    echo -e "  ${WARN} ${YELLOW}No UFW rules found.${NC}"
    back_or_exit
    return
  fi

  echo -e "  ${BOLD}Active rules:${NC}"
  echo ""

  local i=1
  for rule in "${raw_rules[@]}"; do
    printf "  \033[1m%2d\033[0m  %s\n" "$i" "$rule"
    ((i++))
  done

  local all_idx=$i
  echo ""
  printf "  \033[1m%2d\033[0m  \033[0;31mDelete ALL rules\033[0m\n" "$all_idx"
  printf "  \033[1m%2d\033[0m  \033[2mCancel\033[0m\n" "$((all_idx+1))"
  echo ""
  divider
  printf "\n  › Choose [1-%d]: " "$((all_idx+1))"
  read -r sel
  echo ""

  if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
    echo -e "  ${FAIL} ${RED}Invalid selection.${NC}"
    back_or_exit
    return
  fi

  if [ "$sel" -eq "$((all_idx+1))" ]; then
    echo -e "  ${WARN} ${YELLOW}Cancelled.${NC}"
    back_or_exit
    return
  fi

  if [ "$sel" -eq "$all_idx" ]; then
    echo -e "  ${RED}${BOLD}WARNING: This will delete ALL rules and reset UFW defaults.${NC}"
    printf "  Type 'yes' to confirm: "
    read -r confirm
    if [ "$confirm" = "yes" ]; then
      ufw --force reset > /dev/null
      ufw default deny incoming > /dev/null
      ufw default allow outgoing > /dev/null
      ufw default deny routed > /dev/null
      ufw --force enable > /dev/null
      echo -e "  ${OK} ${GREEN}All rules deleted. Defaults restored.${NC}"
    else
      echo -e "  ${WARN} ${YELLOW}Cancelled.${NC}"
    fi
    back_or_exit
    return
  fi

  if [ "$sel" -ge 1 ] && [ "$sel" -lt "$all_idx" ]; then
    local rule_line="${raw_rules[$((sel-1))]}"
    echo -e "  Deleting: ${DIM}$rule_line${NC}"
    printf "\n  Confirm? [y/N]: "
    read -r confirm
    if [[ ${confirm,,} == "y" ]]; then
      local rule_num
      rule_num=$(echo "$rule_line" | awk -F'[][]' '{print $2}' | tr -d ' ')
      yes | ufw delete "$rule_num" > /dev/null 2>&1
      ufw reload > /dev/null
      echo -e "\n  ${OK} ${GREEN}Rule deleted.${NC}"
    else
      echo -e "  ${WARN} ${YELLOW}Cancelled.${NC}"
    fi
  else
    echo -e "  ${FAIL} ${RED}Invalid selection.${NC}"
  fi

  back_or_exit
}

# ── 5. List IPs with access ───────────────────────────────────
list_access() {
  header
  section "IPs With Access"
  echo ""

  mapfile -t ips < <(
    ufw status | grep -E 'ALLOW|FWD' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^172\.|^10\.|^192\.168\.' \
    | sort -u
  )

  if [ ${#ips[@]} -eq 0 ]; then
    echo -e "  ${WARN} ${YELLOW}No IP-specific rules found.${NC}"
    back_or_exit
    return
  fi

  for ip in "${ips[@]}"; do
    echo -e "  ${BOLD}${CYAN}$ip${NC}"

    # SSH
    if ufw status | grep -F "$ip" | grep -q '22'; then
      echo -e "    ${OK}  SSH ${DIM}(port 22)${NC}"
    fi

    # Container route rules — match FWD lines, extract port and comment
    while IFS= read -r line; do
      if echo "$line" | grep -qE 'FWD'; then
        local port comment cname
        port=$(echo "$line" | grep -oE '[0-9]+/tcp|[0-9]+/udp' | head -1)
        comment=$(echo "$line" | sed 's/.*# //')
        cname=$(echo "$comment" | sed 's/ - .*//' | xargs 2>/dev/null || true)
        if [ -n "$port" ]; then
          if [ -n "$cname" ] && [ "$cname" != "$line" ]; then
            echo -e "    ${OK}  Container: ${BOLD}$cname${NC} ${DIM}→ port $port${NC}"
          else
            echo -e "    ${OK}  Container route: ${DIM}port $port${NC}"
          fi
        fi
      fi
    done < <(ufw status | grep -F "$ip")

    echo ""
  done

  divider
  echo -e "  ${DIM}${#ips[@]} IP(s) with active rules${NC}"

  back_or_exit
}

# ── 6. Show raw rules ─────────────────────────────────────────
show_rules() {
  header
  section "Raw UFW Rules"
  echo ""
  ufw status verbose
  echo ""
  back_or_exit
}

# ── Entry point ──────────────────────────────────────────────
main_menu
