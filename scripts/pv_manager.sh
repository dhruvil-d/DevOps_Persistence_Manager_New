#!/usr/bin/env bash
# =============================================================================
# pv_manager.sh – Persistent Volume Manager CLI
# =============================================================================
# A centralized tool for managing, backing up, restoring, and monitoring
# Kubernetes Persistent Volumes.
#
# USAGE:
#   ./scripts/pv_manager.sh <command> [options]
#
# COMMANDS:
#   list                  List all PVs and PVCs in the pv-manager namespace
#   status                Show PV/PVC binding and pod running status
#   backup                Backup /data from the app pod to a timestamped archive
#   restore <archive>     Restore /data in the app pod from a backup archive
#   monitor               Show storage + CPU/memory usage
#   schedule [on|off]     Apply or remove the scheduled backup CronJob
#   help                  Show this help message
#
# CI/CD INTEGRATION:
#   All commands are designed to be called from any CI/CD platform
#   (GitHub Actions, Jenkins, GitLab CI, CircleCI) without modification.
#   Set environment variables PV_NAMESPACE, PV_BACKUP_DIR to customize.
#
# EXIT CODES:
#   0 – success
#   1 – general error
#   2 – precondition failure (PVC not bound, pod not running, etc.)
#   3 – backup/restore failure
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION  (override via environment variables)
# ─────────────────────────────────────────────────────────────────────────────
NAMESPACE="${PV_NAMESPACE:-pv-manager}"
APP_LABEL="${PV_APP_LABEL:-app=pv-demo-app}"
BACKUP_DIR="${PV_BACKUP_DIR:-$(dirname "$0")/../backups}"
CRONJOB_MANIFEST="${PV_CRONJOB_MANIFEST:-$(dirname "$0")/../k8s/cronjob.yaml}"
LOCK_FILE="/tmp/pv_manager.lock"
LOG_PREFIX="[PV-MANAGER]"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-30s}"
LOG_FILE="${PV_LOG_FILE:-$(dirname "$0")/../logs/pv_manager.log}"
mkdir -p "$(dirname "$LOG_FILE")"

# ─────────────────────────────────────────────────────────────────────────────
# COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_to_file() {
  local level="$1"
  shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M')
  echo "[$ts] $level: $*" >> "$LOG_FILE"
}

info()    { echo -e "${CYAN}${LOG_PREFIX}${RESET} $*"; log_to_file "INFO" "$*"; }
success() { echo -e "${GREEN}${LOG_PREFIX} ✔${RESET} $*"; log_to_file "SUCCESS" "$*"; }
warn()    { echo -e "${YELLOW}${LOG_PREFIX} ⚠${RESET} $*" >&2; log_to_file "WARN" "$*"; }
error()   { echo -e "${RED}${LOG_PREFIX} ✘${RESET} $*" >&2; log_to_file "ERROR" "$*"; }
die()     { error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# STORAGE ALERTS
# ─────────────────────────────────────────────────────────────────────────────
check_storage_alert() {
  local pod="$1"
  local usage_pct
  usage_pct=$(kubectl exec -n "$NAMESPACE" "$pod" -- df /data 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
  if [[ -n "$usage_pct" && "$usage_pct" -ge 80 ]]; then
    warn "WARNING: PV usage above 80% (${usage_pct}%)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# LOCK FILE – prevents parallel CI/CD pipeline conflicts
# ─────────────────────────────────────────────────────────────────────────────
acquire_lock() {
  if [[ -e "$LOCK_FILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    # Check if the owning process is still alive
    if kill -0 "$existing_pid" 2>/dev/null; then
      die "Another pv_manager instance is running (PID $existing_pid). Aborting to prevent parallel conflicts."
    else
      warn "Stale lock file found (PID $existing_pid no longer running). Removing."
      rm -f "$LOCK_FILE"
    fi
  fi
  echo $$ > "$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# Always release lock on exit
trap release_lock EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PREREQUISITE CHECKS
# ─────────────────────────────────────────────────────────────────────────────
check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found in PATH. Please install kubectl and configure kubeconfig."
  fi
  
  # Test cluster connectivity
  if ! kubectl cluster-info --request-timeout="$KUBECTL_TIMEOUT" &>/dev/null; then
    die "Cannot reach Kubernetes cluster. Check kubeconfig and cluster status."
  fi
}

check_namespace() {
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    die "Namespace '$NAMESPACE' does not exist. Run: kubectl apply -f k8s/namespace.yaml"
  fi
}

# Returns the name of the first Running app pod, or exits with error
get_running_pod() {
  local pod
  pod=$(kubectl get pod -n "$NAMESPACE" \
        -l "$APP_LABEL" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -z "$pod" ]]; then
    error "No running pod found matching label '$APP_LABEL' in namespace '$NAMESPACE'."
    error "Possible causes:"
    error "  · Deployment not yet applied (kubectl apply -f k8s/deployment.yaml)"
    error "  · PVC not bound (run: ./pv_manager.sh status)"
    error "  · Image pull failure (check: kubectl describe pod -n $NAMESPACE)"
    exit 2
  fi
  echo "$pod"
}

# Verify PVC is bound before operations that depend on it
check_pvc_bound() {
  local pvc_status
  pvc_status=$(kubectl get pvc pv-manager-pvc -n "$NAMESPACE" \
               -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [[ "$pvc_status" != "Bound" ]]; then
    error "PVC 'pv-manager-pvc' is not Bound (current status: '${pvc_status:-NotFound}')."
    error "Possible causes:"
    error "  · PV not created yet (kubectl apply -f k8s/pv.yaml)"
    error "  · PVC not created yet (kubectl apply -f k8s/pvc.yaml)"
    error "  · Storage class mismatch between PV and PVC"
    exit 2
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: list
# ─────────────────────────────────────────────────────────────────────────────
cmd_list() {
  info "Listing Persistent Volumes (cluster-wide) and PVCs in namespace '$NAMESPACE'..."
  echo ""
  echo -e "${BOLD}── Persistent Volumes (cluster-scoped) ──────────────────────────────${RESET}"
  kubectl get pv \
    -o custom-columns='NAME:.metadata.name,CAPACITY:.spec.capacity.storage,ACCESS:.spec.accessModes[0],RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,CLAIM:.spec.claimRef.name' \
    2>/dev/null || warn "No PersistentVolumes found."

  echo ""
  echo -e "${BOLD}── Persistent Volume Claims (namespace: $NAMESPACE) ─────────────────${RESET}"
  kubectl get pvc -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,CAPACITY:.status.capacity.storage,ACCESS:.status.accessModes[0]' \
    2>/dev/null || warn "No PVCs found in namespace '$NAMESPACE'."
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: status
# ─────────────────────────────────────────────────────────────────────────────
cmd_status() {
  info "Checking cluster storage status..."
  echo ""

  # PV status
  local pv_status
  pv_status=$(kubectl get pv pv-manager-pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  echo -e "  PersistentVolume  pv-manager-pv  :  ${BOLD}$pv_status${RESET}"

  # PVC status
  local pvc_status
  pvc_status=$(kubectl get pvc pv-manager-pvc -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  echo -e "  PVC               pv-manager-pvc :  ${BOLD}$pvc_status${RESET}"

  # Pod status
  local pod_status
  pod_status=$(kubectl get pod -n "$NAMESPACE" -l "$APP_LABEL" \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")
  echo ""
  if [[ -z "$pod_status" ]]; then
    echo -e "  Pods: ${YELLOW}None found${RESET}"
  else
    echo -e "${BOLD}── Pod Status (namespace: $NAMESPACE) ─────────────────────────────────${RESET}"
    echo "$pod_status" | while IFS=$'\t' read -r name phase; do
      local colour="$GREEN"
      [[ "$phase" != "Running" ]] && colour="$RED"
      echo -e "  ${colour}${name}${RESET}  →  ${BOLD}${phase}${RESET}"
    done
  fi

  # CronJob status
  echo ""
  local cj_status
  cj_status=$(kubectl get cronjob pv-manager-backup-cron -n "$NAMESPACE" \
              -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || echo "NotScheduled")
  echo -e "  CronJob last run  :  ${BOLD}$cj_status${RESET}"
  echo ""

  # Overall assessment
  if [[ "$pvc_status" == "Bound" ]]; then
    success "Storage is healthy: PVC is Bound."
  else
    warn "Storage issue detected: PVC is not Bound."
    exit 2
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: backup
# ─────────────────────────────────────────────────────────────────────────────
cmd_backup() {
  acquire_lock

  check_pvc_bound
  local pod
  pod=$(get_running_pod)

  # Create backup directory
  mkdir -p "$BACKUP_DIR"

  # Timestamped archive name (ISO 8601 compact, avoids : in filenames)
  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  local archive="${BACKUP_DIR}/backup_${timestamp}.tar.gz"
  local staging="./.pv_backup_${timestamp}"

  info "Starting backup from pod '$pod' → '${archive}'"

  # ── Disk space pre-flight check ─────────────────────────────────
  local available_kb
  available_kb=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')
  if [[ "$available_kb" -lt 102400 ]]; then   # < 100 MB
    die "Insufficient disk space in '$BACKUP_DIR'. Available: ${available_kb}KB. Need at least 100MB."
  fi

  # ── Guard against existing archive (should not happen with timestamps) ───
  if [[ -e "$archive" ]]; then
    die "Archive '$archive' already exists. This should not happen with UTC timestamps."
  fi

  mkdir -p "$staging"

  # ── Copy data out of pod ─────────────────────────────────────────
  info "Copying /data from pod '$pod' (this may take a moment)..."
  local max_retries=3
  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    if kubectl cp "${NAMESPACE}/${pod}:/data" "${staging}/data" --retries=3 2>/tmp/pv_cp_err; then
      break
    fi
    warn "kubectl cp attempt ${attempt}/${max_retries} failed: $(cat /tmp/pv_cp_err)"
    if [[ "$attempt" -ge "$max_retries" ]]; then
      rm -rf "$staging"
      die "Network failure: kubectl cp failed after ${max_retries} attempts. Check pod/network status."
    fi
    sleep 5
  done

  # ── Compress ─────────────────────────────────────────────────────
  info "Compressing to archive..."
  if ! tar -czf "$archive" -C "$staging" data; then
    rm -rf "$staging" "$archive"
    die "tar compression failed."
  fi

  # ── Integrity verification ────────────────────────────────────────
  info "Verifying archive integrity..."
  if ! tar -tzf "$archive" > /dev/null 2>&1; then
    error "Archive integrity check FAILED. Removing corrupt file: $archive"
    rm -f "$archive"
    rm -rf "$staging"
    exit 3
  fi

  # ── Cleanup ──────────────────────────────────────────────────────
  rm -rf "$staging"

  local size
  size=$(du -sh "$archive" | cut -f1)
  success "Backup complete!"
  echo -e "  Archive : ${BOLD}$archive${RESET}"
  echo -e "  Size    : ${BOLD}$size${RESET}"
  echo -e "  Pod     : ${BOLD}$pod${RESET}"

  check_storage_alert "$pod"

  # ── Backup Retention Policy ──────────────────────────────────────
  info "Applying backup retention policy (keeping last 10 backups)..."
  ls -t "${BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: restore <archive>
# ─────────────────────────────────────────────────────────────────────────────
cmd_restore() {
  local archive="$1"

  acquire_lock

  # ── Validate archive path ─────────────────────────────────────────
  if [[ -z "$archive" ]]; then
    die "Usage: pv_manager.sh restore <path-to-backup.tar.gz>"
  fi
  if [[ ! -f "$archive" ]]; then
    die "Backup archive not found: '$archive'"
  fi

  # ── Integrity check before restore ───────────────────────────────
  info "Verifying backup archive integrity: $archive"
  if ! tar -tzf "$archive" > /dev/null 2>&1; then
    die "Archive '$archive' is corrupted or not a valid gzip tar. Restore aborted."
  fi

  check_pvc_bound
  local pod
  pod=$(get_running_pod)

  info "Restoring '$archive' → pod '$pod':/data"

  local staging="./.pv_restore_$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$staging"

  # ── Extract ───────────────────────────────────────────────────────
  info "Extracting archive..."
  if ! tar -xzf "$archive" -C "$staging"; then
    rm -rf "$staging"
    die "Failed to extract archive '$archive'."
  fi

  # ── Copy back into pod ────────────────────────────────────────────
  info "Copying restored data back into pod '$pod':/data ..."
  local max_retries=3
  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    if kubectl cp "${staging}/data/." "${NAMESPACE}/${pod}:/data" --retries=3 2>/tmp/pv_restore_err; then
      break
    fi
    warn "kubectl cp attempt ${attempt}/${max_retries} failed: $(cat /tmp/pv_restore_err)"
    if [[ "$attempt" -ge "$max_retries" ]]; then
      rm -rf "$staging"
      die "Network failure: restore kubectl cp failed after ${max_retries} attempts."
    fi
    sleep 5
  done

  rm -rf "$staging"
  success "Restore complete from archive: $archive"
  echo -e "  Restored to pod : ${BOLD}$pod${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: restore-latest
# ─────────────────────────────────────────────────────────────────────────────
cmd_restore_latest() {
  local latest
  latest=$(ls -t "${BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$latest" ]]; then
    die "No backups found in '${BACKUP_DIR}' to restore."
  fi
  info "Found latest backup: $latest"
  cmd_restore "$latest"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: monitor
# ─────────────────────────────────────────────────────────────────────────────
cmd_monitor() {
  local pod
  pod=$(get_running_pod)

  echo ""
  echo -e "${BOLD}── Storage Usage (df -h inside pod) ────────────────────────────────${RESET}"
  kubectl exec -n "$NAMESPACE" "$pod" -- df -h /data 2>/dev/null \
    || warn "Could not exec df in pod '$pod'"

  echo ""
  echo -e "${BOLD}── Pod Resource Usage (kubectl top pod) ────────────────────────────${RESET}"
  if kubectl top pod -n "$NAMESPACE" 2>/dev/null; then
    : # success
  else
    warn "kubectl top not available. Ensure metrics-server is installed:"
    warn "  minikube addons enable metrics-server"
  fi

  echo ""
  echo -e "${BOLD}── Node Resource Usage ─────────────────────────────────────────────${RESET}"
  kubectl top node 2>/dev/null || warn "kubectl top node not available."

  echo ""
  echo -e "${BOLD}── Backup Archive Inventory ────────────────────────────────────────${RESET}"
  if ls "${BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | head -20; then
    local count
    count=$(ls "${BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | wc -l)
    local total_size
    total_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
    echo ""
    echo -e "  Total backups : ${BOLD}$count${RESET}"
    echo -e "  Total size    : ${BOLD}$total_size${RESET}"
  else
    warn "No backup archives found in '$BACKUP_DIR'."
  fi
  echo ""

  check_storage_alert "$pod"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: dashboard
# ─────────────────────────────────────────────────────────────────────────────
cmd_dashboard() {
  echo -e "${BOLD}── Dashboard ───────────────────────────────────────────────────────${RESET}"
  
  local pv_name="pv-manager-pv"
  local capacity
  capacity=$(kubectl get pv "$pv_name" -o jsonpath='{.spec.capacity.storage}' 2>/dev/null || echo "1Gi")
  
  local pod
  pod=$(get_running_pod)
  
  local df_out
  df_out=$(kubectl exec -n "$NAMESPACE" "$pod" -- df -h /data 2>/dev/null | awk 'NR==2 {print $3, $4}')
  local used free
  used=$(echo "$df_out" | awk '{print $1}')
  free=$(echo "$df_out" | awk '{print $2}')
  
  local pod_status
  pod_status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  
  local last_backup="None"
  local latest
  latest=$(ls -t "${BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | head -1)
  if [[ -n "$latest" ]]; then
    # Parse timestamp from filename: backup_20260311T163012Z.tar.gz -> 16:30
    last_backup=$(basename "$latest" | sed -E 's/.*([0-9]{2})([0-9]{2})[0-9]{2}Z\.tar\.gz/\1:\2/' 2>/dev/null)
    if [[ "$last_backup" == "backup_"* ]]; then last_backup=$(basename "$latest"); fi
  fi

  check_storage_alert "$pod"

  echo "PV: $pv_name"
  echo "Capacity: ${capacity}"
  echo "Used: ${used:-Unknown}"
  echo "Free: ${free:-Unknown}"
  echo "Pod: $pod_status"
  echo "Last Backup: $last_backup"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: schedule [on|off]
# ─────────────────────────────────────────────────────────────────────────────
cmd_schedule() {
  local action="${1:-on}"

  case "$action" in
    on|enable|apply)
      info "Applying backup CronJob from $CRONJOB_MANIFEST ..."
      kubectl apply -f "$CRONJOB_MANIFEST"
      success "CronJob 'pv-manager-backup-cron' scheduled (every hour)."
      kubectl get cronjob pv-manager-backup-cron -n "$NAMESPACE"
      ;;
    off|disable|delete)
      info "Removing backup CronJob..."
      kubectl delete cronjob pv-manager-backup-cron -n "$NAMESPACE" --ignore-not-found=true
      success "CronJob removed."
      ;;
    *)
      die "Unknown schedule action '$action'. Use 'on' or 'off'."
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: help
# ─────────────────────────────────────────────────────────────────────────────
cmd_help() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║         PV Manager – Kubernetes Storage CLI          ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "${BOLD}USAGE:${RESET}"
  echo "  ./scripts/pv_manager.sh <command> [options]"
  echo ""
  echo -e "${BOLD}COMMANDS:${RESET}"
  printf "  %-26s %s\n" "list"                   "List all PVs (cluster) and PVCs (namespace)"
  printf "  %-26s %s\n" "status"                 "Show binding, pod, and CronJob status"
  printf "  %-26s %s\n" "backup"                 "Backup /data to a timestamped .tar.gz archive"
  printf "  %-26s %s\n" "restore <archive>"      "Restore /data from a backup archive"
  printf "  %-26s %s\n" "restore-latest"         "Restore from the most recent backup archive"
  printf "  %-26s %s\n" "monitor"                "Storage usage + kubectl top pod + backup inventory"
  printf "  %-26s %s\n" "dashboard"              "Show a quick, professional PV summary"
  printf "  %-26s %s\n" "schedule [on|off]"      "Apply or remove the hourly backup CronJob"
  printf "  %-26s %s\n" "help"                   "Show this help message"
  echo ""
  echo -e "${BOLD}ENVIRONMENT VARIABLES:${RESET}"
  printf "  %-26s %s\n" "PV_NAMESPACE"            "Kubernetes namespace (default: pv-manager)"
  printf "  %-26s %s\n" "PV_APP_LABEL"            "Pod selector label (default: app=pv-demo-app)"
  printf "  %-26s %s\n" "PV_BACKUP_DIR"           "Backup output directory (default: ./backups)"
  printf "  %-26s %s\n" "PV_CRONJOB_MANIFEST"     "CronJob YAML path (default: k8s/cronjob.yaml)"
  printf "  %-26s %s\n" "KUBECTL_TIMEOUT"         "kubectl timeout (default: 30s)"
  echo ""
  echo -e "${BOLD}EXIT CODES:${RESET}"
  printf "  %-6s %s\n" "0" "Success"
  printf "  %-6s %s\n" "1" "General error"
  printf "  %-6s %s\n" "2" "Precondition failure (PVC not bound, pod not running)"
  printf "  %-6s %s\n" "3" "Backup/restore failure"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN DISPATCHER
# ─────────────────────────────────────────────────────────────────────────────
main() {
  local command="${1:-help}"
  shift || true   # Shift away command; remaining args passed to sub-commands

  # For commands that need cluster access, run prereq checks
  case "$command" in
    list|status|backup|restore|restore-latest|monitor|dashboard|schedule)
      check_kubectl
      check_namespace
      ;;
  esac

  case "$command" in
    list)           cmd_list ;;
    status)         cmd_status ;;
    backup)         cmd_backup ;;
    restore)        cmd_restore "${1:-}" ;;
    restore-latest) cmd_restore_latest ;;
    monitor)        cmd_monitor ;;
    dashboard)      cmd_dashboard ;;
    schedule)       cmd_schedule "${1:-on}" ;;
    help|--help|-h) cmd_help ;;
    *)
      error "Unknown command: '$command'"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
