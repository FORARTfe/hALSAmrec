#!/bin/sh

################################################################################
# LuCI VU Meter Module Installer
# 
# Comprehensive installation script for the LuCI VU Meter display module.
# Supports both package-based and manual installation on OpenWRT/LEDE systems.
#
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
INSTALL_MODE="manual"
DEV_MODE=0
CREATE_CONFIG=1
OPKG_INSTALL=0
ACTION="install"
VERBOSE=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENWRT_ROOT="${OPENWRT_ROOT:-/}"
LUCI_LIB_PATH="${OPENWRT_ROOT}usr/lib/lua/luci"
LUCI_VIEW_PATH="${OPENWRT_ROOT}usr/share/luci"
LUCI_STATIC_PATH="${OPENWRT_ROOT}www/luci-static/resources"
UCI_CONFIG_PATH="${OPENWRT_ROOT}etc/config"

# Module info
MODULE_NAME="vumeter"
MODULE_VERSION="1.0"
MODULE_AUTHOR="Marco Ravich"
ORIGINAL_AUTHOR="tomnomnom"

################################################################################
# Utility Functions
################################################################################

print_header() {
  printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
  printf '%b\n' "${BLUE}  LuCI VU Meter Module Installer v${MODULE_VERSION}${NC}"
  printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_info() {
  printf '%b\n' "${BLUE}ℹ${NC}  $1"
}

print_success() {
  printf '%b\n' "${GREEN}✓${NC}  $1"
}

print_warning() {
  printf '%b\n' "${YELLOW}⚠${NC}  $1"
}

print_error() {
  printf '%b\n' "${RED}✗${NC}  $1"
}

print_step() {
  printf '%b\n' "${YELLOW}→${NC}  $1"
}

# Check if running as root
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
  fi
}

# Check if we're on an OpenWRT system
check_openwrt() {
  if [ ! -f /etc/openwrt_release ]; then
    if [ "$OPENWRT_ROOT" = "/" ]; then
      print_warning "This doesn't appear to be an OpenWRT system"
      printf "Continue anyway? (y/n) "
      read -r REPLY
      echo
      case "$REPLY" in
        [Yy]* ) ;;
        * ) exit 1 ;;
      esac
    fi
  else
    print_success "OpenWRT system detected"
  fi
}

# Create directory if it doesn't exist
ensure_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    print_step "Creating directory: $dir"
    mkdir -p "$dir"
  fi
}

# Install file (copy or symlink)
install_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-644}"
  
  if [ ! -f "$src" ]; then
    print_error "Source file not found: $src"
    return 1
  fi
  
  ensure_dir "$(dirname "$dst")"
  
  if [ "$DEV_MODE" -eq 1 ]; then
    print_step "Linking $dst -> $src"
    ln -sf "$src" "$dst"
  else
    print_step "Installing $dst"
    cp "$src" "$dst"
    chmod "$mode" "$dst"
  fi
  
  return 0
}

# Helper for checking and printing installed files
check_and_print_file() {
  local file="$1"
  local desc="$2"
  if [ -f "$file" ] || [ -L "$file" ]; then
    if [ -L "$file" ]; then
      print_success "$desc (symlink) -> $file"
    else
      print_success "$desc -> $file"
    fi
  fi
}

# List installed files
list_installed_files() {
  printf '%b\n' "${BLUE}Installed files:${NC}"
  
  check_and_print_file "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua" "Controller"
  check_and_print_file "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua" "CBI Model"
  check_and_print_file "${LUCI_VIEW_PATH}/view/${MODULE_NAME}/display.htm" "View Template"
  check_and_print_file "${LUCI_STATIC_PATH}/${MODULE_NAME}.js" "JavaScript Library"
  check_and_print_file "${UCI_CONFIG_PATH}/${MODULE_NAME}" "UCI Config"
}

################################################################################
# Installation Functions
################################################################################

install_manual() {
  print_header
  print_info "Starting manual installation..."
  echo ""
  
  # Install controller
  print_step "Installing controller module"
  ensure_dir "${LUCI_LIB_PATH}/controller"
  install_file "${SCRIPT_DIR}/luci/controller/${MODULE_NAME}.lua" \
    "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua" "755"
  
  # Install CBI model
  print_step "Installing CBI configuration model"
  ensure_dir "${LUCI_LIB_PATH}/model/cbi"
  install_file "${SCRIPT_DIR}/luci/model/cbi/${MODULE_NAME}.lua" \
    "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua" "644"
  
  # Install view template
  print_step "Installing view template"
  ensure_dir "${LUCI_VIEW_PATH}/view/${MODULE_NAME}"
  install_file "${SCRIPT_DIR}/luci/view/${MODULE_NAME}/display.htm" \
    "${LUCI_VIEW_PATH}/view/${MODULE_NAME}/display.htm" "644"
  
  # Install JavaScript library
  print_step "Installing JavaScript library"
  ensure_dir "${LUCI_STATIC_PATH}"
  install_file "${SCRIPT_DIR}/htdocs/luci-static/resources/${MODULE_NAME}.js" \
    "${LUCI_STATIC_PATH}/${MODULE_NAME}.js" "644"
  
  # Install/merge configuration
  if [ "$CREATE_CONFIG" -eq 1 ]; then
    print_step "Installing UCI configuration"
    if [ -f "${UCI_CONFIG_PATH}/${MODULE_NAME}" ]; then
      print_warning "UCI config already exists, backing up to ${MODULE_NAME}.bak"
      cp "${UCI_CONFIG_PATH}/${MODULE_NAME}" "${UCI_CONFIG_PATH}/${MODULE_NAME}.bak"
    fi
    ensure_dir "${UCI_CONFIG_PATH}"
    install_file "${SCRIPT_DIR}/root/etc/config/${MODULE_NAME}" \
      "${UCI_CONFIG_PATH}/${MODULE_NAME}" "644"
  fi
  
  echo ""
  print_success "Manual installation completed!"
}

install_package() {
  print_header
  print_info "Installing via opkg package manager..."
  echo ""
  
  print_step "Updating package lists"
  opkg update || print_warning "Failed to update package lists"
  
  print_step "Installing luci-app-vumeter (if available)"
  if ! opkg install luci-app-vumeter; then
    print_warning "luci-app-vumeter package not found"
    print_info "Falling back to manual installation..."
    install_manual
    return
  fi
  
  echo ""
  print_success "Package installation completed!"
}

################################################################################
# Uninstall Functions
################################################################################

uninstall_module() {
  print_header
  print_info "Starting uninstallation..."
  echo ""
  
  local files_removed=0
  
  # Remove controller
  if [ -f "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua" ]; then
    print_step "Removing controller: ${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua"
    rm -f "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua"
    files_removed=$((files_removed + 1))
  fi
  
  # Remove CBI model
  if [ -f "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua" ]; then
    print_step "Removing CBI model: ${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua"
    rm -f "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua"
    files_removed=$((files_removed + 1))
  fi
  
  # Remove view template
  if [ -d "${LUCI_VIEW_PATH}/view/${MODULE_NAME}" ]; then
    print_step "Removing view directory: ${LUCI_VIEW_PATH}/view/${MODULE_NAME}"
    rm -rf "${LUCI_VIEW_PATH}/view/${MODULE_NAME}"
    files_removed=$((files_removed + 1))
  fi
  
  # Remove JavaScript
  if [ -f "${LUCI_STATIC_PATH}/${MODULE_NAME}.js" ]; then
    print_step "Removing JavaScript: ${LUCI_STATIC_PATH}/${MODULE_NAME}.js"
    rm -f "${LUCI_STATIC_PATH}/${MODULE_NAME}.js"
    files_removed=$((files_removed + 1))
  fi
  
  # Ask about config
  printf "Remove UCI configuration? (y/n) "
  read -r REPLY
  echo
  case "$REPLY" in
    [Yy]*)
      if [ -f "${UCI_CONFIG_PATH}/${MODULE_NAME}" ]; then
        print_step "Removing UCI config: ${UCI_CONFIG_PATH}/${MODULE_NAME}"
        rm -f "${UCI_CONFIG_PATH}/${MODULE_NAME}"
        files_removed=$((files_removed + 1))
      fi
      ;;
  esac
  
  echo ""
  if [ "$files_removed" -gt 0 ]; then
    print_success "Uninstallation completed! Removed $files_removed files/directories"
  else
    print_warning "No files were found to remove"
  fi
}

################################################################################
# Check Functions
################################################################################

check_installation() {
  print_header
  print_info "Checking installation status..."
  echo ""
  
  local installed=0
  local missing=0
  
  for file in \
    "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua" \
    "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua" \
    "${LUCI_VIEW_PATH}/view/${MODULE_NAME}/display.htm" \
    "${LUCI_STATIC_PATH}/${MODULE_NAME}.js" \
    "${UCI_CONFIG_PATH}/${MODULE_NAME}"
  do
    if [ -f "$file" ] || [ -L "$file" ]; then
      print_success "Found: $file"
      installed=$((installed + 1))
    else
      print_warning "Missing: $file"
      missing=$((missing + 1))
    fi
  done
  
  echo ""
  echo "Status: $installed installed, $missing missing"
  
  if [ "$missing" -eq 0 ]; then
    echo ""
    list_installed_files
    echo ""
    print_success "Module is fully installed!"
    return 0
  else
    print_warning "Module installation is incomplete"
    return 1
  fi
}

################################################################################
# Help and Usage
################################################################################

show_help() {
  cat << EOF
LuCI VU Meter Module Installer

USAGE:
  ./install.sh [OPTIONS]

ACTIONS:
  -i, --install               Install the module (default)
  -u, --uninstall             Remove the module
  -c, --check                 Check installation status
  -h, --help                  Show this help message

OPTIONS:
  --manual                    Manual installation (default)
  --opkg                      Use opkg package manager
  --dev, --development        Development mode (use symlinks)
  --no-config                 Skip UCI configuration creation
  -v, --verbose               Verbose output
  -r, --root PATH             Specify OpenWRT root path (default: /)
EOF
}

################################################################################
# Verification Functions
################################################################################

verify_installation() {
  print_step "Verifying installation..."
  
  local errors=0
  
  # Check file existence
  if [ ! -f "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua" ]; then
    print_error "Controller not found"
    errors=$((errors + 1))
  fi
  
  if [ ! -f "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua" ]; then
    print_error "CBI model not found"
    errors=$((errors + 1))
  fi
  
  if [ ! -f "${LUCI_VIEW_PATH}/view/${MODULE_NAME}/display.htm" ]; then
    print_error "View template not found"
    errors=$((errors + 1))
  fi
  
  if [ ! -f "${LUCI_STATIC_PATH}/${MODULE_NAME}.js" ]; then
    print_error "JavaScript library not found"
    errors=$((errors + 1))
  fi
  
  # Check Lua syntax
  if command -v lua >/dev/null 2>&1; then
    print_step "Checking Lua syntax..."
    
    if lua -c "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua" 2>/dev/null; then
      print_success "Controller Lua syntax OK"
    else
      print_warning "Controller Lua syntax check failed"
    fi
    
    if lua -c "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua" 2>/dev/null; then
      print_success "CBI model Lua syntax OK"
    else
      print_warning "CBI model Lua syntax check failed"
    fi
  fi
  
  return $errors
}

################################################################################
# Post-Installation Steps
################################################################################

post_install_steps() {
  echo ""
  printf '%b\n' "${BLUE}Post-Installation Steps:${NC}"
  echo ""
  
  print_info "1. Access the web interface at:"
  echo "   http://<router-ip>/cgi-bin/luci"
  echo ""
  print_info "2. Navigate to: System > VU Meter > Display"
  echo ""
  print_info "3. Configure settings at: System > VU Meter"
  echo ""
  
  if [ -f /etc/init.d/uhttpd ]; then
    print_info "4. If changes don't appear, restart LuCI:"
    echo "   /etc/init.d/uhttpd restart"
    echo ""
  fi
}

################################################################################
# Main Script
################################################################################

main() {
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -i|--install)
        ACTION="install"
        shift
        ;;
      -u|--uninstall)
        ACTION="uninstall"
        shift
        ;;
      -c|--check)
        ACTION="check"
        shift
        ;;
      --manual)
        INSTALL_MODE="manual"
        shift
        ;;
      --opkg)
        INSTALL_MODE="opkg"
        OPKG_INSTALL=1
        shift
        ;;
      --dev|--development)
        DEV_MODE=1
        shift
        ;;
      --no-config)
        CREATE_CONFIG=0
        shift
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -r|--root)
        OPENWRT_ROOT="$2"
        LUCI_LIB_PATH="${OPENWRT_ROOT}usr/lib/lua/luci"
        LUCI_VIEW_PATH="${OPENWRT_ROOT}usr/share/luci"
        LUCI_STATIC_PATH="${OPENWRT_ROOT}www/luci-static/resources"
        UCI_CONFIG_PATH="${OPENWRT_ROOT}etc/config"
        shift 2
        ;;
      *)
        print_error "Unknown option: $1"
        echo ""
        show_help
        exit 1
        ;;
    esac
  done
  
  # Verify prerequisites
  check_root
  check_openwrt
  
  # Perform action
  case "$ACTION" in
    install)
      if [ "$OPKG_INSTALL" -eq 1 ]; then
        install_package
      else
        install_manual
      fi
      verify_installation
      post_install_steps
      ;;
    uninstall)
      uninstall_module
      ;;
    check)
      check_installation
      ;;
    *)
      print_error "Unknown action: $ACTION"
      exit 1
      ;;
  esac
}

# Run main function
main "$@"