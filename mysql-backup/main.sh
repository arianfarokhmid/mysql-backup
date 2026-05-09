#!/bin/bash
# ====================================================
# MySQL Backup Script - Main Entry Point
# ====================================================

# Get script directory for sourcing lib files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration
source "$SCRIPT_DIR/config/config.sh"

# Source library files
source "$SCRIPT_DIR/lib/permissions.sh"
source "$SCRIPT_DIR/lib/os.sh"
source "$SCRIPT_DIR/lib/prerequisites.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/incremental.sh"
source "$SCRIPT_DIR/lib/s3.sh"
source "$SCRIPT_DIR/lib/mysql.sh"

# Parse --auto-install flag before acquiring lock
AUTO_INSTALL=0
for arg in "$@"; do
    if [[ "$arg" == "--auto-install" ]]; then
        AUTO_INSTALL=1
        break
    fi
done


if [[ "$1" != "--help" ]]; then
    acquire_lock
fi

# --------------------------
# Help Function
# --------------------------
show_help() {
cat <<EOF
Usage: $0 [OPTIONS]

Backup Options:
  --full                     Run full backup
  --incremental              Run incremental backup
  --priority                 Specify a table priority

General Options:
  --help                     Show this help message
  --verbose                  Enable verbose output

Examples:
  $0 --full
  $0 --priority 1/2
  $0 --incremental
  sudo $0 --full --auto-install
EOF
}

# --------------------------
# Default variables
# --------------------------
MODE=""
TABLE_LABEL=""
VERBOSE=0

# --------------------------
# Argument Parser
# --------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
        show_help
        exit 0
        ;;
    --full)
        MODE="full"
        fullbackup_name="$2"
        shift
        ;;
    --incremental)
        MODE="incremental"
        ;;
    --priority)
        if [[ "$2" != "1" && "$2" != "2" ]]; then
            echo "Error: --priority must be 1 or 2"
            exit 1
        fi

        if [[ -n "$3" && "$3" != --* ]]; then
            echo "Error: --priority accepts only one value"
            exit 1
        fi

        MODE="$2"
        shift
        ;;
    --verbose)
        VERBOSE=1
        ;;
    --auto-install)
        ;;
    *)
        echo "Error: Unknown option '$1'"
        echo "Use --help for usage."
        exit 1
        ;;
  esac
  shift
done

# --------------------------
# Execute Logic
# --------------------------
if [[ "$VERBOSE" -eq 1 ]]; then
    echo "Mode = $MODE"
    echo "Table Label = $TABLE_LABEL"
fi

case "$MODE" in
  full)
      #check_prerequisites
      full_backup 
      ;;
  incremental)
      #check_prerequisites
      incremental
      ;;
  1)
      check_prerequisites
      level1_tables
      ;;
  2)
      check_prerequisites
      level2_tables
      ;;
  "")
      log "ERROR" "You must specify --full or --incremental or --priority.Use --help for more"
      exit 1
      ;;
esac