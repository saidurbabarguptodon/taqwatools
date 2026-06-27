#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Colors for a clean UI
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run this script with sudo or as root.${NC}"
    exit 1
fi

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

    # Print the Header Dashboard
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${GREEN}                           VPS/VM Setup                               ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${YELLOW}SYSTEM CONFIGURATION & METRICS:${NC}"
    echo -e "  OS:   $os_version"
    echo -e "  CPU:  $cpu_model (Load: $cpu_load)"
    echo -e "  RAM:  $ram_info"
    echo -e "  Disk: $disk_info"
    echo -e "${BLUE}======================================================================${NC}"
}

# Function to automatically inject OpenSSH Server custom configurations
configure_openssh_server() {
    echo -e "${BLUE}Applying SSH Login & SFTP Settings...${NC}"
    
    # Back up the original config just in case
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

    # Strip out existing instances of these settings to avoid duplicates/errors
    sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^PermitRootLogin/d' /etc/ssh/sshd_config
    sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^KbdInteractiveAuthentication/d' /etc/ssh/sshd_config
    sed -i '/^UsePAM/d' /etc/ssh/sshd_config
    sed -i '/^Subsystem[[:space:]]sftp/d' /etc/ssh/sshd_config

    # Append your exact custom configuration block
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

    # Restart SSH service to apply the updates live
    echo -e "${BLUE}Restarting SSH daemon...${NC}"
    systemctl restart ssh || service ssh restart
    echo -e "${GREEN}✓ Custom configurations applied and SSH service restarted.${NC}"
}

# Function to safely handle Neofetch removal and OS-dependent Fastfetch installation
install_fastfetch() {
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
        apt-get install -y fastfetch
    else
        echo -e "${YELLOW}Fastfetch not found in native repos. Downloading official GitHub release...${NC}"
        
        local arch
        arch=$(dpkg --print-architecture)
        
        if [ "$arch" != "amd64" ] && [ "$arch" != "arm64" ]; then
            echo -e "${RED}Error: Unsupported architecture ($arch). Fastfetch GitHub releases support amd64 and arm64.${NC}"
            return 1
        fi

        local url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${arch}.deb"
        
        echo -e "${BLUE}Downloading latest ${arch} package from GitHub...${NC}"
        cd /tmp
        wget -q --show-progress "$url" -O fastfetch.deb
        
        echo -e "${BLUE}Installing package...${NC}"
        apt-get install -y ./fastfetch.deb
        
        rm fastfetch.deb
        cd - &> /dev/null
    fi
    echo -e "${GREEN}✓ Fastfetch setup complete.${NC}"
}

# Sub-Menu for Option 2 (OpenSSH)
openssh_menu() {
    while true; do
        draw_banner
        echo -e "${YELLOW}>> OpenSSH Installation Options:${NC}"
        echo -e "1) Install Server"
        echo -e "2) Install Client"
        echo -e "3) Install Both"
        echo -e "4) Back to Main Menu"
        echo -ne "\nPlease select an option [1-4]: "
        read -r ssh_choice

        case $ssh_choice in
            1)
                clear
                echo -e "${BLUE}running apt update${NC}"
                apt-get update -y
                echo -e "${BLUE}running apt install openssh-server${NC}"
                apt-get install -y openssh-server
                echo -e "${GREEN}✓ OpenSSH Server installed successfully.${NC}"
                configure_openssh_server
                read -n 1 -s -r -p "Press any key to return..."
                ;;
            2)
                clear
                echo -e "${BLUE}running apt update${NC}"
                apt-get update -y
                echo -e "${BLUE}running apt install openssh-client${NC}"
                apt-get install -y openssh-client
                echo -e "${GREEN}✓ OpenSSH Client installed successfully.${NC}"
                read -n 1 -s -r -p "Press any key to return..."
                ;;
            3)
                clear
                echo -e "${BLUE}running apt update${NC}"
                apt-get update -y
                echo -e "${BLUE}running apt install openssh-server openssh-client${NC}"
                apt-get install -y openssh-server openssh-client
                echo -e "${GREEN}✓ OpenSSH Server and Client installed successfully.${NC}"
                configure_openssh_server
                read -n 1 -s -r -p "Press any key to return..."
                ;;
            4)
                break 
                ;;
            *)
                echo -e "${RED}Invalid selection. Please choose 1-4.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Main Application Menu Loop
while true; do
    draw_banner
    echo -e "1) Install Dropbear"
    echo -e "2) Install OpenSSH"
    echo -e "3) Install Fastfetch"
    echo -e "4) Exit Tool"
    echo -ne "\nPlease select an option [1-4]: "
    read -r main_choice

    case $main_choice in
        1)
            # Clears terminal, displays specific user output strings, installs dropbear
            clear
            echo -e "${BLUE}running apt update${NC}"
            apt-get update -y
            
            echo -e "${BLUE}running apt install dropbear${NC}"
            apt-get install -y dropbear
            
            echo -e "${GREEN}✓ Dropbear SSH installed successfully.${NC}"
            read -n 1 -s -r -p "Press any key to return..."
            ;;
        2)
            openssh_menu
            ;;
        3)
            clear
            install_fastfetch
            read -n 1 -s -r -p "Press any key to return..."
            ;;
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
