#!/bin/bash
# ============================================================
# delete_stopped_vms.sh
# Deletes all non-running VMs on a Proxmox node (pve3)
# Runs a dry-run first, then asks for confirmation before deleting
# ============================================================

NODE="pve3"
DRY_RUN=true

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}========================================"
echo -e " Proxmox Non-Running VM Cleanup"
echo -e " Node: ${NODE}"
echo -e "========================================${NC}"
echo ""

# ── Collect non-running VMs (status != running) ──────────────
mapfile -t STOPPED_VMS < <(
  pvesh get /nodes/${NODE}/qemu --output-format json 2>/dev/null \
  | python3 -c "
import sys, json
vms = json.load(sys.stdin)
for vm in vms:
    if vm.get('status') != 'running' and vm.get('template') != 1:
        print(f\"{vm['vmid']}|{vm.get('name','<no-name>')}|{vm.get('status','unknown')}\")
"
)

if [ ${#STOPPED_VMS[@]} -eq 0 ]; then
  echo -e "${GREEN}✔ No non-running VMs found on ${NODE}. Nothing to do.${NC}"
  exit 0
fi

# ── Dry-run: list what would be deleted ──────────────────────
echo -e "${YELLOW}[DRY-RUN] The following VMs are NOT running and would be deleted:${NC}"
echo ""
printf "  %-8s %-30s %-12s\n" "VMID" "NAME" "STATUS"
printf "  %-8s %-30s %-12s\n" "--------" "------------------------------" "------------"

for entry in "${STOPPED_VMS[@]}"; do
  IFS='|' read -r vmid name status <<< "$entry"
  printf "  %-8s %-30s %-12s\n" "$vmid" "$name" "$status"
done

echo ""
echo -e "${RED}⚠  WARNING: Deletion is permanent and includes VM disks!${NC}"
echo ""

# ── Confirmation prompt ───────────────────────────────────────
read -r -p "Type 'yes' to proceed with deletion, or anything else to cancel: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo ""
  echo -e "${GREEN}Aborted. No VMs were deleted.${NC}"
  exit 0
fi

# ── Perform deletion ──────────────────────────────────────────
echo ""
echo -e "${CYAN}Starting deletion...${NC}"
echo ""

SUCCESS=0
FAILED=0

for entry in "${STOPPED_VMS[@]}"; do
  IFS='|' read -r vmid name status <<< "$entry"

  echo -n "  Deleting VMID ${vmid} (${name})... "

  # Stop the VM forcefully just in case status is 'paused' or similar
  qm stop "$vmid" --skiplock 1 &>/dev/null

  # Destroy VM and its associated disks
  if qm destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1 2>/dev/null; then
    echo -e "${GREEN}✔ Deleted${NC}"
    ((SUCCESS++))
  else
    echo -e "${RED}✘ Failed (check logs: journalctl -u pvedaemon)${NC}"
    ((FAILED++))
  fi
done

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "  Done.  ${GREEN}Deleted: ${SUCCESS}${NC}  |  ${RED}Failed: ${FAILED}${NC}"
echo -e "${CYAN}========================================${NC}"
