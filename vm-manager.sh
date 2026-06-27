#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Colors for a clean UI
GREEN='\033;0;32m'
BLUE='\033;0;34m'
YELLOW='\033;1;33m'
RED='\033;0;31m'
NC='\033[0m' # No Color

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run this script with sudo or as root.${NC}"
    exit 1
fi

# Helper function to check if an APT package is installed
is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# Helper function to check if a command binary exists
is_cmd_installed() {
    command -v "$1" &> /dev/null
}

# Function to draw the interface header with dynamic system info
draw_banner() {
    clear
    
    # 1. Fetch OS and Version
    local os_version
    os_version=$(awk -F= '/^PRETTY_NAME/ {gsub(/"/, "", $2); print $2}' /etc/os-release)
    
    # 2. Fetch RAM Info (Used and Free)
    local ram_info
    ram_info=$(free -h | awk '/^Mem:/ {print "Used: " $3 " / Free: " $4 " (Total: " $2 ")"}')
    
    # 3. Fetch Disk Info for Root Partition
    local disk_info
    disk_info=$(df -h / | awk 'NR==2 {print "Used: " $3 " / Free: " $4 " (" $5 " Used)"}')
    
    # 4. Fetch CPU Model and Current Load
    local cpu_model
    cpu_model=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^[ \t]*//')
    if [ -z "$cpu_model" ]; then
        cpu_model=$(uname -m)
    fi
    local cpu_load
    cpu_load=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//')

    # 5. Fetch System Virtualization Type
    local sys_type="Bare-metal"
    if command -v systemd-detect-virt &> /dev/null; then
        sys_type=$(systemd-detect-virt 2>/dev/null || echo "Bare-metal")
    elif [ -d /proc/vz ]; then
        sys_type="OpenVZ"
    elif [ -f /.dockerenv ]; then
        sys_type="Docker"
    fi
    # Capitalize first letter for visual clean output
    sys_type=$(echo "$sys_type" | awk '{print toupper(substr($0,1,1))substr($0,2)}')

    # 6. Detect Systemctl Operational Support Status
    local systemctl_support="No"
    if [ -d /run/systemd/system ] && command -v systemctl &> /dev/null; then
        systemctl_support="Yes"
    fi

    # Print the Header Dashboard
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${GREEN}                           VPS/VM Setup                               ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${YELLOW}SYSTEM CONFIGURATION & METRICS:${NC}"
    echo -e "  OS:                $os_version"
    echo -e "  System Type:       $sys_type"
    echo -e "  Systemctl Support: $systemctl_support"
    echo -e "  CPU:               $cpu_model (Load: $cpu_load)"
    echo -e "  RAM:               $ram_info"
    echo -e "  Disk:              $disk_info"
    echo -e "${BLUE}======================================================================${NC}"
}

# Smart Service Manager - Systemctl fallback directly to Background Built-in Binary
start_service_smart() {
    local service_name=$1
    echo -e "${BLUE}Managing $service_name startup...${NC}"

    if [ -d /run/systemd/system ]; then
        echo -e "${GREEN}Systemd environment verified. Starting $service_name...${NC}"
        systemctl unmask "$service_name" 2>/dev/null || true
        systemctl daemon-reload
        systemctl restart "$service_name"
        echo -e "${GREEN}✓ $service_name managed successfully via systemctl.${NC}"
    else
        echo -e "${YELLOW}Systemd absent. Forcing built-in binary execution into background...${NC}"
        if [ "$service_name" = "ssh" ]; then
            mkdir -p /var/run/sshd
            $(command -v sshd) >/dev/null 2>&1 &
        elif [ "$service_name" = "dropbear" ]; then
            $(command -v dropbear) -R >/dev/null 2>&1 &
        fi
        echo -e "${GREEN}✓ Direct built-in $service_name binary running in background (bg).${NC}"
    fi
}

# Strict Status Checker - Checks ONLY systemctl or the running built-in binary process
check_status_smart() {
    local service_name=$1
    local proc_name=$service_name
    if [ "$service_name" = "ssh" ]; then proc_name="sshd"; fi

    echo -ne "${YELLOW}Service Status for [$service_name]: ${NC}"
    
    # 1. Try systemctl engine
    if [ -d /run/systemd/system ]; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo -e "${GREEN}RUNNING (via systemctl)${NC}"
            return 0
        fi
    fi

    # 2. Try raw built-in binary process engine
    if pgrep -x "$proc_name" >/dev/null; then
        echo -e "${GREEN}RUNNING (via built-in binary)${NC}"
        return 0
    fi

    echo -e "${RED}STOPPED${NC}"
}

# Function to automatically inject OpenSSH Server custom configurations
configure_openssh_server() {
    echo -e "${BLUE}Applying SSH Login & SFTP Settings...${NC}"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

    sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^PermitRootLogin/d' /etc/ssh/sshd_config
    sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^KbdInteractiveAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^UsePAM/d' /etc/ssh/sshd_config
    sed -i '/^Subsystem[[:space:]]sftp/d' /etc/ssh/sshd_config

    cat << 'EOF' >> /etc/ssh/sshd_config

# SSH LOGIN SETTINGS
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes

# SFTP SETTINGS
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    start_service_smart "ssh"
}

# Function to safely handle Neofetch removal and OS-dependent Fastfetch installation
install_fastfetch_logic() {
    if command -v neofetch &> /dev/null; then
        echo -e "${YELLOW}Found legacy neofetch installed. Purging...${NC}"
        apt-get purge -y neofetch
        apt-get autoremove -y
        echo -e "${GREEN}✓ Legacy neofetch successfully removed.${NC}"
    fi

    echo -e "${BLUE}running apt update${NC}"
    apt-get update -y

    if apt-cache show fastfetch &> /dev/null; then
        echo -e "${GREEN}Fastfetch found in native OS repositories. Installing via apt...${NC}"
        apt-get install -y --reinstall fastfetch
    else
        echo -e "${YELLOW}Fastfetch not found in native repos. Downloading official GitHub release...${NC}"
        local arch
        arch=$(dpkg --print-architecture)
        if [ "$arch" != "amd64" ] && [ "$arch" != "arm64" ]; then
            echo -e "${RED}Error: Unsupported architecture ($arch).${NC}"
            return 1
        fi
        local url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${arch}.deb"
        cd /tmp
        wget -q --show-progress "$url" -O fastfetch.deb
        apt-get install -y --reinstall ./fastfetch.deb
        rm fastfetch.deb
        cd - &> /dev/null
    fi
    echo -e "${GREEN}✓ Fastfetch setup complete.${NC}"
}

# Sub-Menu: Dropbear Management
dropbear_menu() {
    while true; do
        draw_banner
        if is_pkg_installed "dropbear"; then
            echo -e "${YELLOW}>> Dropbear Manager (Installed):${NC}"
            echo -e "1) Reinstall"
            echo -e "2) Remove"
            echo -e "3) Status (running/stop)"
            echo -e "4) Back to Main Menu"
            echo -ne "\nPlease select an option [1-4]: "
            read -r choice
            case $choice in
                1)
                    clear
                    echo -e "${BLUE}running apt update${NC}"
                    apt-get update -y
                    echo -e "${BLUE}running apt install dropbear${NC}"
                    apt-get install -y --reinstall dropbear
                    echo -e "${GREEN}✓ Dropbear reinstalled successfully.${NC}"
                    start_service_smart "dropbear"
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                2)
                    clear
                    echo -e "${RED}Removing Dropbear...${NC}"
                    apt-get purge -y dropbear
                    apt-get autoremove -y
                    echo -e "${GREEN}✓ Dropbear successfully removed.${NC}"
                    read -n 1 -s -r -p "Press any key to return..."
                    break
                    ;;
                3)
                    echo -e "\n"
                    check_status_smart "dropbear"
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                4) break ;;
                *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}>> Dropbear Manager (Not Installed):${NC}"
            echo -e "1) Install"
            echo -e "2) Back to Main Menu"
            echo -ne "\nPlease select an option [1-2]: "
            read -r choice
            case $choice in
                1)
                    clear
                    echo -e "${BLUE}running apt update${NC}"
                    apt-get update -y
                    echo -e "${BLUE}running apt install dropbear${NC}"
                    apt-get install -y dropbear
                    echo -e "${GREEN}✓ Dropbear SSH installed successfully.${NC}"
                    start_service_smart "dropbear"
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                2) break ;;
                *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
            esac
        fi
    done
}

# Sub-Menu: OpenSSH Management
openssh_menu() {
    while true; do
        draw_banner
        if is_pkg_installed "openssh-server"; then
            echo -e "${YELLOW}>> OpenSSH Manager (Installed):${NC}"
            echo -e "1) Reinstall"
            echo -e "2) Remove"
            echo -e "3) Status (running/stop)"
            echo -e "4) Back to Main Menu"
            echo -ne "\nPlease select an option [1-4]: "
            read -r choice
            case $choice in
                1)
                    clear
                    echo -e "${BLUE}running apt update${NC}"
                    apt-get update -y
                    echo -e "${BLUE}running apt install openssh-server openssh-client${NC}"
                    apt-get install -y --reinstall openssh-server openssh-client
                    echo -e "${GREEN}✓ OpenSSH Suite reinstalled successfully.${NC}"
                    configure_openssh_server
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                2)
                    clear
                    echo -e "${RED}Removing OpenSSH Server and Client...${NC}"
                    apt-get purge -y openssh-server openssh-client
                    apt-get autoremove -y
                    echo -e "${GREEN}✓ OpenSSH Suite successfully removed.${NC}"
                    read -n 1 -s -r -p "Press any key to return..."
                    break
                    ;;
                3)
                    echo -e "\n"
                    check_status_smart "ssh"
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                4) break ;;
                *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}>> OpenSSH Manager (Not Installed):${NC}"
            echo -e "1) Install"
            echo -e "2) Back to Main Menu"
            echo -ne "\nPlease select an option [1-2]: "
            read -r choice
            case $choice in
                1)
                    clear
                    echo -e "${BLUE}running apt update${NC}"
                    apt-get update -y
                    echo -e "${BLUE}running apt install openssh-server openssh-client${NC}"
                    apt-get install -y openssh-server openssh-client
                    echo -e "${GREEN}✓ OpenSSH Suite installed successfully.${NC}"
                    configure_openssh_server
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                2) break ;;
                *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
            esac
        fi
    done
}

# Sub-Menu: Fastfetch Management
fastfetch_menu() {
    while true; do
        draw_banner
        if is_cmd_installed "fastfetch"; then
            echo -e "${YELLOW}>> Fastfetch Manager (Installed):${NC}"
            echo -e "1) Reinstall"
            echo -e "2) Remove"
            echo -e "3) Back to Main Menu"
            echo -ne "\nPlease select an option [1-3]: "
            read -r choice
            case $choice in
                1)
                    clear
                    install_fastfetch_logic
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                2)
                    clear
                    echo -e "${RED}Removing Fastfetch...${NC}"
                    apt-get purge -y fastfetch || true
                    if [ -f /usr/local/bin/fastfetch ]; then rm -f /usr/local/bin/fastfetch; fi
                    echo -e "${GREEN}✓ Fastfetch successfully removed.${NC}"
                    read -n 1 -s -r -p "Press any key to return..."
                    break
                    ;;
                3) break ;;
                *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}>> Fastfetch Manager (Not Installed):${NC}"
            echo -e "1) Install"
            echo -e "2) Back to Main Menu"
            echo -ne "\nPlease select an option [1-2]: "
            read -r choice
            case $choice in
                1)
                    clear
                    install_fastfetch_logic
                    read -n 1 -s -r -p "Press any key to return..."
                    ;;
                2) break ;;
                *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
            esac
        fi
    done
}

# Main Application Menu Loop
while true; do
    draw_banner
    echo -e "1) Dropbear"
    echo -e "2) OpenSSH"
    echo -e "3) Fastfetch"
    echo -e "4) Exit Tool"
    echo -ne "\nPlease select an option [1-4]: "
    read -r main_choice

    case $main_choice in
        1) dropbear_menu ;;
        2) openssh_menu ;;
        3) fastfetch_menu ;;
        4)
            echo -e "\n${GREEN}Exiting VPS/VM Setup. Goodbye!${NC}\n"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid selection. Please choose 1-4.${NC}"
            sleep 1
            ;;
    esac
done
