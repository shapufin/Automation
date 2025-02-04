#!/bin/bash

# Default values
DEFAULT_MEMORY=4096
DEFAULT_CORES=4

# Setup logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/vm_creation_$(date +%Y%m%d_%H%M%S).log"

# Logging functions
log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${1}"
}

log_error() {
    printf "[ERROR] %s\n" "${1}" >&2
}

# Function to verify VM ID is available
verify_vm_id() {
    local vmid=$1
    
    # Check if ID is a positive number
    if ! [[ "$vmid" =~ ^[1-9][0-9]*$ ]]; then
        return 1
    fi
    
    # Check if VM ID is already in use
    if qm status "$vmid" &>/dev/null; then
        return 1
    fi
    
    return 0
}

# Function to verify package exists
verify_package() {
    local pkg=$1
    local disk_path=$2
    
    # Check if package exists in repositories
    if ! apt-cache show "$pkg" &>/dev/null; then
        return 1
    fi
    
    # If disk_path is provided, check if package is already installed
    if [ ! -z "$disk_path" ]; then
        if virt-customize -a "$disk_path" --run-command "dpkg -l $pkg" &>/dev/null; then
            log "Package $pkg is already installed"
            return 1
        fi
    fi
    
    return 0
}

# Function to list templates
list_templates() {
    # First check if there are any VMs
    if ! qm list >/dev/null 2>&1; then
        dialog --msgbox "Error: Unable to get VM list." 6 40
        return
    fi

    # Get templates, including the header
    local temp_list=$(mktemp)
    
    # Add header
    echo "VMID    NAME                STATUS     MEM(MB)    BOOTDISK(GB)" > "$temp_list"
    echo "----    ----                ------     -------    ------------" >> "$temp_list"
    
    # Get template list - check both template status and config file
    qm list | tail -n +2 | while read -r vmid name status mem disk pid; do
        # Check if it's a template by looking at the config file
        if grep -q "^template: 1" "/etc/pve/qemu-server/$vmid.conf" 2>/dev/null; then
            printf "%-7s %-19s %-10s %-10s %-10s\n" "$vmid" "$name" "$status" "$mem" "$disk" >> "$temp_list"
        fi
    done

    # Check if any templates were found (file has more than 2 lines - header lines)
    if [ $(wc -l < "$temp_list") -le 2 ]; then
        dialog --msgbox "No templates found." 6 40
        rm -f "$temp_list"
        return
    fi

    # Show templates in a scrollable list
    dialog --title "Available Templates" \
           --textbox "$temp_list" 20 70

    rm -f "$temp_list"
}

# Function to delete template
delete_template() {
    # First check if there are any VMs
    if ! qm list >/dev/null 2>&1; then
        dialog --msgbox "Error: Unable to get VM list." 6 40
        return 1
    fi

    # Create temporary files for template list and menu
    local temp_list=$(mktemp)
    local menu_list=$(mktemp)

    # Get template list by checking config files
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        # Check if it's a template
        if grep -q "^template: 1" "/etc/pve/qemu-server/$vmid.conf" 2>/dev/null; then
            echo "$vmid $name" >> "$temp_list"
        fi
    done < <(qm list | tail -n +2)

    # Check if any templates were found
    if [ ! -s "$temp_list" ]; then
        dialog --msgbox "No templates found." 6 40
        rm -f "$temp_list" "$menu_list"
        return 1
    fi

    # Create menu list
    while read -r vmid name; do
        echo "$vmid \"$name\"" >> "$menu_list"
    done < "$temp_list"

    # Show menu and get selected template
    local selected_id=$(dialog --stdout \
        --title "Delete Template" \
        --menu "Select template to delete:" 15 50 10 $(cat "$menu_list"))

    # Clean up temp files
    rm -f "$temp_list" "$menu_list"

    # If user cancelled, return
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Confirm deletion
    if dialog --title "Confirm Deletion" \
        --yesno "Are you sure you want to delete template $selected_id?" 6 50; then
        
        log "Deleting template: $selected_id"
        
        # Stop the VM if it's running
        if qm status "$selected_id" | grep -q "running"; then
            log "Stopping template VM: $selected_id"
            qm stop "$selected_id" >/dev/null 2>&1
            sleep 2
        fi

        # Delete the VM and all its disks
        if ! qm destroy "$selected_id" --purge >/dev/null 2>&1; then
            dialog --msgbox "Failed to delete template $selected_id" 6 40
            return 1
        fi

        dialog --msgbox "Template $selected_id deleted successfully." 6 40
        return 0
    fi

    return 0
}

# Function to get available storages
get_storages() {
    # Get list of storages that support disk images (type 'dir', 'lvmthin', or 'zfspool')
    local storage_list=""
    while IFS= read -r line; do
        local storage=$(echo "$line" | awk '{print $1}')
        local content=$(echo "$line" | awk '{print $2}')
        local type=$(pvesm status -storage "$storage" | grep "^type" | awk '{print $2}')
        
        # Only include storages that support disk images and templates
        if [[ "$type" == "lvmthin" ]] || [[ "$type" == "dir" ]] || [[ "$type" == "zfspool" ]]; then
            if [[ -n "$storage_list" ]]; then
                storage_list="$storage_list $storage"
            else
                storage_list="$storage"
            fi
        fi
    done < <(pvesm status | tail -n +2)
    echo "$storage_list"
}

# Function to select storage
select_storage() {
    local storages=($(get_storages))
    
    if [ ${#storages[@]} -eq 0 ]; then
        dialog --msgbox "No suitable storage found." 6 40
        return 1
    fi
    
    # Create menu items
    local menu_items=()
    for storage in "${storages[@]}"; do
        # Get storage info
        local info=$(pvesm status -storage "$storage")
        local type=$(echo "$info" | grep "^type" | awk '{print $2}')
        local avail=$(echo "$info" | grep "^avail" | awk '{print $2}')
        menu_items+=("$storage" "Type: $type, Available: $avail")
    done
    
    # Show storage selection menu
    local selected_storage=$(dialog --stdout --title "Select Storage" \
        --menu "Choose storage for the template:" 15 60 5 "${menu_items[@]}")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get storage type
    local storage_type=$(pvesm status -storage "$selected_storage" | grep "^type" | awk '{print $2}')
    
    # Return both storage name and type
    echo "$selected_storage:$storage_type"
}

# Function to get disk path based on storage type
get_disk_path() {
    local template_id="$1"
    local storage_name="$2"
    local storage_type="$3"
    local disk_name="$4"

    case "$storage_type" in
        "lvmthin")
            echo "/dev/pve/$disk_name"
            ;;
        "zfspool")
            echo "/dev/zvol/$storage_name/$disk_name"
            ;;
        "dir")
            echo "/var/lib/vz/images/$template_id/$disk_name"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to create new template
create_template() {
    local temp_file=$(mktemp)
    
    # Step 1: Get template ID
    while true; do
        local template_id=$(dialog --stdout --title "Create Template" \
            --inputbox "Enter template ID (positive number):" 8 40)
        
        if [ $? -ne 0 ]; then
            rm -f "$temp_file"
            return 1
        fi
        
        if verify_vm_id "$template_id"; then
            break
        else
            dialog --msgbox "Invalid template ID or ID already in use.\nPlease enter a different number." 8 60
        fi
    done
    
    # Step 2: Get template name
    local template_name=$(dialog --stdout --title "Create Template" \
        --inputbox "Enter template name:" 8 40)
    
    if [ $? -ne 0 ]; then
        rm -f "$temp_file"
        return 1
    fi

    # Step 3: Get user credentials
    local username=$(dialog --stdout --title "User Configuration" \
        --inputbox "Enter default username:" 8 40)
    
    if [ $? -ne 0 ] || [ -z "$username" ]; then
        dialog --msgbox "Username is required." 6 40
        rm -f "$temp_file"
        return 1
    fi

    local password=$(dialog --stdout --title "User Configuration" \
        --passwordbox "Enter default password:" 8 40)
    
    if [ $? -ne 0 ] || [ -z "$password" ]; then
        dialog --msgbox "Password is required." 6 40
        rm -f "$temp_file"
        return 1
    fi

    # Step 4: Get storage name
    local storage_name=$(dialog --stdout --title "Storage Selection" \
        --inputbox "Enter storage name (e.g., data-zfs, local-lvm):" 8 50)
    
    if [ $? -ne 0 ] || [ -z "$storage_name" ]; then
        dialog --msgbox "No storage specified. Creation cancelled." 6 60
        rm -f "$temp_file"
        return 1
    fi

    # Verify if storage exists
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        dialog --msgbox "Storage '$storage_name' not found. Please check the storage name." 6 60
        rm -f "$temp_file"
        return 1
    fi

    log "Using storage: $storage_name"

    # Step 5: Select the image file
    while true; do
        local image_path=$(dialog --stdout --title "Select Image File" \
            --fselect /var/lib/vz/template/iso/ 20 70)
        
        if [ $? -ne 0 ]; then
            log "Image selection cancelled"
            rm -f "$temp_file"
            return 1
        fi
        
        image_path=$(echo "$image_path" | sed 's/^://')
        
        if [ ! -f "$image_path" ]; then
            if [ -d "$image_path" ]; then
                continue
            fi
            dialog --msgbox "Please select a valid image file." 6 40
            continue
        fi
        
        if ! file "$image_path" | grep -qiE "boot sector|ISO 9660|QEMU|disk image"; then
            dialog --msgbox "Selected file does not appear to be a valid disk image." 6 60
            continue
        fi
        
        break
    done
    
    log "Selected image file: $image_path"

    # Step 6: Option to install packages
    if dialog --title "Package Installation" \
        --yesno "Would you like to install additional packages?" 6 50; then
        
        local packages=$(dialog --stdout --title "Package Installation" \
            --inputbox "Enter package names (space-separated):" 8 50)
        
        if [ $? -eq 0 ] && [ ! -z "$packages" ]; then
            dialog --infobox "Installing packages... This may take a while." 5 50
            
            log "Installing packages: $packages on image: $image_path"
            
            # Install packages directly on the source image with automatic updates
            if ! virt-customize -a "$image_path" --install "$packages" --run-command "apt-get update -y && apt-get upgrade -y" < /dev/null; then
                dialog --msgbox "Warning: Failed to install packages. Check the log for details." 6 50
                log "Failed to install packages: $packages"
                if ! dialog --title "Continue?" \
                    --yesno "Package installation failed. Continue with template creation?" 6 60; then
                    rm -f "$temp_file"
                    return 1
                fi
            else
                dialog --msgbox "Packages installed successfully." 6 40
                log "Successfully installed packages: $packages"
            fi
        fi
    fi
    
    # Step 7: Create the VM
    log "Creating VM with ID: $template_id"
    if ! qm create "$template_id" \
        --name "$template_name" \
        --memory "$DEFAULT_MEMORY" \
        --cores "$DEFAULT_CORES" \
        --net0 virtio,bridge=vmbr0 \
        --ipconfig0 ip=dhcp \
        --ostype l26 \
        --machine q35 \
        --scsihw virtio-scsi-single; then
        dialog --msgbox "Failed to create VM." 6 40
        rm -f "$temp_file"
        return 1
    fi
    
    # Step 8: Import the disk
    log "Importing disk from: $image_path to storage: $storage_name"
    if ! qm importdisk "$template_id" "$image_path" "$storage_name" 2>/dev/null; then
        qm destroy "$template_id" >/dev/null 2>&1
        dialog --msgbox "Failed to import disk." 6 40
        rm -f "$temp_file"
        return 1
    fi
    
    # Wait for disk import to complete
    sleep 2
    
    # Step 9: Configure VM settings
    log "Configuring VM settings"
    if ! qm set "$template_id" \
        --scsi0 "$storage_name:vm-$template_id-disk-0" \
        --ide2 "$storage_name:cloudinit" \
        --boot c \
        --bootdisk scsi0 \
        --serial0 socket \
        --vga serial0 \
        --agent 1 \
        --ciuser "$username" \
        --cipassword "$password"; then
        qm destroy "$template_id" >/dev/null 2>&1
        dialog --msgbox "Failed to configure VM." 6 40
        rm -f "$temp_file"
        return 1
    fi
    
    # Step 10: Ask if user wants to convert to template
    if dialog --title "Convert to Template" \
        --yesno "Would you like to convert this VM to a template?" 6 50; then
        log "Converting to template"
        if ! qm template "$template_id"; then
            dialog --msgbox "Failed to convert to template, but VM was created successfully." 6 60
        else
            dialog --msgbox "Successfully converted to template with ID: $template_id" 6 50
        fi
    else
        dialog --msgbox "VM created successfully with ID: $template_id" 6 50
    fi
    
    rm -f "$temp_file"
    return 0
}

# Function to get available bridges
get_network_bridges() {
    # Use -br flag to directly list bridges, faster than grep
    local bridges=$(ip -br link show type bridge | awk '{print $1}')
    if [ -z "$bridges" ]; then
        echo "vmbr0" # Fallback to default if no bridges found
        return
    fi
    echo "$bridges"
}

# Function to find next available IP on a subnet
get_next_free_ip() {
    local -r bridge=$1
    local subnet
    local gateway
    local start_ip
    
    # Get bridge IP and convert to subnet - using -br for faster output
    local bridge_ip
    bridge_ip=$(ip -br addr show "$bridge" | awk '{print $3}' | cut -d'/' -f1)
    
    if [ -z "$bridge_ip" ]; then
        case "$bridge" in
            vmbr0) 
                subnet="192.168.1"
                gateway="192.168.1.1"
                ;;
            vmbr1) 
                subnet="192.168.2"
                gateway="192.168.2.1"
                ;;
            *) 
                subnet="192.168.1"
                gateway="192.168.1.1"
                ;;
        esac
        start_ip=100
    else
        subnet=$(echo "$bridge_ip" | cut -d'.' -f1-3)
        gateway="$subnet.1"
        start_ip=2
    fi

    # Use parallel ping for faster IP checking (max 10 at a time)
    local -a pids=()
    local -a ips=()
    local batch_size=10
    local current_batch=0
    
    for i in $(seq "$start_ip" 254); do
        local ip="${subnet}.$i"
        
        # Skip if IP is already used in configs
        if is_ip_used_in_configs "$ip"; then
            continue
        fi
        
        # Add to current batch
        ping -c 1 -W 1 "$ip" >/dev/null 2>&1 &
        pids+=($!)
        ips+=("$ip")
        ((current_batch++))
        
        # Check batch results
        if [ $current_batch -eq $batch_size ]; then
            for j in "${!pids[@]}"; do
                if ! wait "${pids[$j]}" 2>/dev/null; then
                    echo "${ips[$j]}|$gateway"
                    return 0
                fi
            done
            pids=()
            ips=()
            current_batch=0
        fi
    done
    
    # Check remaining IPs
    for j in "${!pids[@]}"; do
        if ! wait "${pids[$j]}" 2>/dev/null; then
            echo "${ips[$j]}|$gateway"
            return 0
        fi
    done
    
    echo "${subnet}.100|$gateway"
    return 0
}

# Function to get Proxmox host's SSH public key
get_proxmox_ssh_key() {
    local ssh_key=""
    
    # First try root's SSH key
    if [ -f "/root/.ssh/id_rsa.pub" ]; then
        ssh_key=$(cat "/root/.ssh/id_rsa.pub")
    elif [ -f "/root/.ssh/id_ed25519.pub" ]; then
        ssh_key=$(cat "/root/.ssh/id_ed25519.pub")
    fi
    
    # If root has no key, generate one
    if [ -z "$ssh_key" ]; then
        dialog --infobox "Generating SSH key for Proxmox host..." 4 50
        ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
        ssh_key=$(cat "/root/.ssh/id_ed25519.pub")
    fi
    
    echo "$ssh_key"
}

# Function to check if IP is used in any VM config
is_ip_used_in_configs() {
    local ip=$1
    update_vm_config_cache
    
    for config in "${VM_CONFIG_CACHE[@]}"; do
        if echo "$config" | grep -q "ip=${ip}/"; then
            return 0
        fi
    done
    return 1
}

# Function to clone from template
clone_from_template() {
    # Get template list using cache
    local temp_list=$(mktemp)
    local menu_list=$(mktemp)
    
    get_template_list > "$temp_list"

    # Check if any templates were found
    if [ ! -s "$temp_list" ]; then
        dialog --msgbox "No templates found." 6 40
        rm -f "$temp_list" "$menu_list"
        return 1
    fi

    # Create menu list
    while read -r vmid name; do
        echo "$vmid \"$name\"" >> "$menu_list"
    done < "$temp_list"

    # Show menu and get selected template
    local template_id=$(dialog --stdout \
        --title "Clone Template" \
        --menu "Select template to clone:" 15 50 10 $(cat "$menu_list"))

    # Clean up temp files
    rm -f "$temp_list" "$menu_list"

    if [ -z "$template_id" ]; then
        return 1
    fi

    # Get new VM ID
    local new_vmid
    new_vmid=$(dialog --stdout \
        --title "Clone Template" \
        --inputbox "Enter new VM ID:" 8 40)

    if [ -z "$new_vmid" ]; then
        return 1
    fi

    # Verify VM ID is available
    if ! verify_vm_id "$new_vmid"; then
        dialog --msgbox "VM ID $new_vmid is not available." 6 40
        return 1
    fi

    # Get new VM name
    local new_name
    new_name=$(dialog --stdout \
        --title "Clone Template" \
        --inputbox "Enter new VM name:" 8 40)

    if [ -z "$new_name" ]; then
        return 1
    fi

    # Ask if user wants to resize the disk
    if dialog --yesno "Would you like to resize the disk?" 6 40; then
        local new_size
        new_size=$(dialog --stdout \
            --title "Resize Disk" \
            --inputbox "Enter new size (e.g., 32G):" 8 40)
        
        if [ -n "$new_size" ]; then
            # Clone the VM with full clone option
            log "Cloning template $template_id to VM $new_vmid (full clone)"
            if ! qm clone "$template_id" "$new_vmid" --name "$new_name" --full; then
                dialog --msgbox "Failed to clone template." 6 40
                return 1
            fi
            
            # Resize the disk
            log "Resizing disk to $new_size"
            if ! qm resize "$new_vmid" scsi0 "$new_size"; then
                dialog --msgbox "Failed to resize disk. The VM was created but disk size remains unchanged." 8 60
                return 1
            fi
        fi
    else
        # Just clone without resizing, but still make it a full clone
        log "Cloning template $template_id to VM $new_vmid (full clone)"
        if ! qm clone "$template_id" "$new_vmid" --name "$new_name" --full; then
            dialog --msgbox "Failed to clone template." 6 40
            return 1
        fi
    fi

    dialog --msgbox "Successfully cloned template to VM $new_vmid" 6 50
    return 0
}

# Function to examine image packages
examine_image() {
    # Select the image file
    local image_path=$(dialog --stdout --title "Select Image to Examine" \
        --fselect /var/lib/vz/template/iso/ 20 70)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    image_path=$(echo "$image_path" | sed 's/^://')
    
    if [ ! -f "$image_path" ]; then
        dialog --msgbox "Please select a valid image file." 6 40
        return 1
    fi
    
    if ! file "$image_path" | grep -qiE "boot sector|ISO 9660|QEMU|disk image"; then
        dialog --msgbox "Selected file does not appear to be a valid disk image." 6 60
        return 1
    fi

    # Show progress
    dialog --infobox "Examining image packages... This may take a while." 5 50
    
    # Create temporary files
    local temp_xml=$(mktemp)
    local temp_packages=$(mktemp)
    local filtered_packages=$(mktemp)
    
    # Use virt-inspector to get package information
    if ! virt-inspector -a "$image_path" > "$temp_xml" 2>/dev/null; then
        dialog --msgbox "Failed to examine image." 6 40
        rm -f "$temp_xml" "$temp_packages" "$filtered_packages"
        return 1
    fi

    # Extract package information from XML
    if command -v xmlstarlet >/dev/null 2>&1; then
        xmlstarlet sel -t -m "//application" -v "concat(name, ' ', version)" -n "$temp_xml" | sort > "$temp_packages"
    else
        grep -A1 "<application>" "$temp_xml" | grep -E "(<name>|<version>)" | \
        sed -e 's/<name>//' -e 's/<\/name>//' -e 's/<version>//' -e 's/<\/version>//' | \
        paste -d' ' - - | sort > "$temp_packages"
    fi

    # Count packages
    local package_count=$(wc -l < "$temp_packages")
    
    if [ $package_count -eq 0 ]; then
        dialog --msgbox "No packages found or failed to parse package information." 6 60
        rm -f "$temp_xml" "$temp_packages" "$filtered_packages"
        return 1
    fi

    # Package viewing loop
    while true; do
        local view_choice=$(dialog --stdout --title "Package List Options" \
            --menu "Found $package_count packages. Choose an option:" 15 60 4 \
            1 "View all packages" \
            2 "Search for package" \
            3 "View common packages only" \
            4 "Back to main menu")
        
        case $? in
            0)
                case $view_choice in
                    1)  # View all packages
                        dialog --title "All Packages" \
                            --backtitle "Found $package_count packages" \
                            --textbox "$temp_packages" 20 70
                        ;;
                    2)  # Search for package
                        local search_term=$(dialog --stdout --title "Search Packages" \
                            --inputbox "Enter search term (case-insensitive):" 8 50)
                        if [ $? -eq 0 ] && [ ! -z "$search_term" ]; then
                            grep -i "$search_term" "$temp_packages" > "$filtered_packages"
                            local found_count=$(wc -l < "$filtered_packages")
                            if [ $found_count -gt 0 ]; then
                                dialog --title "Search Results" \
                                    --backtitle "Found $found_count matching packages" \
                                    --textbox "$filtered_packages" 20 70
                            else
                                dialog --msgbox "No packages found matching: $search_term" 6 50
                            fi
                        fi
                        ;;
                    3)  # View common packages
                        {
                            echo "=== System Packages ==="
                            grep -iE "^(base-|systemd|kernel|grub|bash)" "$temp_packages"
                            echo -e "\n=== Network Packages ==="
                            grep -iE "^(nginx|apache2|ssh|net-tools|curl|wget)" "$temp_packages"
                            echo -e "\n=== Development Packages ==="
                            grep -iE "^(python|gcc|make|git|perl|php)" "$temp_packages"
                        } > "$filtered_packages"
                        dialog --title "Common Packages" \
                            --textbox "$filtered_packages" 20 70
                        ;;
                    4)  # Exit
                        break
                        ;;
                esac
                ;;
            *)
                break
                ;;
        esac
    done
    
    rm -f "$temp_xml" "$temp_packages" "$filtered_packages"
    return 0
}

# Function to check dependencies
check_dependencies() {
    local -r REQUIRED_COMMANDS=("qm" "dialog" "ip" "grep" "awk" "virt-inspector")
    local -r REQUIRED_LIBRARIES=("libguestfs-tools" "cloud-init")
    local missing_commands=()
    local missing_libraries=()
    local failed_libraries=()

    # Check for required commands
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done

    # Check for required libraries
    for lib in "${REQUIRED_LIBRARIES[@]}"; do
        if ! dpkg -s "$lib" >/dev/null 2>&1; then
            missing_libraries+=("$lib")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        return 1
    fi

    if [ ${#missing_libraries[@]} -ne 0 ]; then
        log "Installing missing libraries: ${missing_libraries[*]}"
        apt-get update
        for lib in "${missing_libraries[@]}"; do
            log "Installing library: $lib"
            if [ "$lib" == "cloud-init" ]; then
                log "WARNING: Installing cloud-init may remove unused Proxmox packages."
                if ! apt-get install -y "$lib"; then
                    log_error "Failed to install library: $lib"
                    failed_libraries+=("$lib")
                fi
            else
                if ! apt-get install -y --no-remove "$lib"; then
                    log_error "Failed to install library: $lib"
                    failed_libraries+=("$lib")
                fi
            fi
        done
    fi

    if [ ${#failed_libraries[@]} -ne 0 ]; then
        log_error "Failed to install libraries: ${failed_libraries[*]}"
        return 1
    fi
    return 0
}

# Cache VM configurations for faster IP checking
declare -A VM_CONFIG_CACHE
declare VM_CONFIG_CACHE_TIME=0
readonly VM_CONFIG_CACHE_TIMEOUT=30

# Function to update VM config cache
update_vm_config_cache() {
    local current_time
    current_time=$(date +%s)
    
    if [ $((current_time - VM_CONFIG_CACHE_TIME)) -lt $VM_CONFIG_CACHE_TIMEOUT ] && [ ${#VM_CONFIG_CACHE[@]} -gt 0 ]; then
        return 0
    fi

    VM_CONFIG_CACHE=()
    while IFS= read -r -d '' config_file; do
        local vmid
        vmid=$(basename "$config_file" .conf)
        VM_CONFIG_CACHE[$vmid]=$(cat "$config_file")
    done < <(find /etc/pve/qemu-server/ -type f -name "*.conf" -print0)
    
    VM_CONFIG_CACHE_TIME=$current_time
}

# Function to get template list with caching
get_template_list() {
    local current_time
    current_time=$(date +%s)
    
    # Return cached result if valid
    if [ $((current_time - template_cache_time)) -lt $CACHE_TIMEOUT ] && [ ${#template_cache[@]} -gt 0 ]; then
        for id in "${!template_cache[@]}"; do
            echo "$id ${template_cache[$id]}"
        done
        return 0
    fi
    
    # Clear old cache
    template_cache=()
    
    # Update cache with new data
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        if grep -q "^template: 1" "/etc/pve/qemu-server/$vmid.conf" 2>/dev/null; then
            template_cache[$vmid]=$name
            echo "$vmid $name"
        fi
    done < <(qm list | tail -n +2)
    
    template_cache_time=$current_time
}

# Function to get current storage of a template
get_template_storage() {
    local vmid=$1
    local config_file="/etc/pve/qemu-server/${vmid}.conf"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # Get the storage from scsi0 line
    grep "^scsi0:" "$config_file" | cut -d',' -f1 | cut -d':' -f2
    return 0
}

# Function to move template to different storage
move_template_storage() {
    # Get template list
    local template_list=$(get_template_list)
    
    if [ -z "$template_list" ]; then
        dialog --msgbox "No templates found." 6 40
        return 1
    fi
    
    # Create menu items for templates
    local menu_items=()
    while read -r vmid name; do
        local current_storage=$(get_template_storage "$vmid")
        menu_items+=("$vmid" "$name (Current: $current_storage)")
    done <<< "$template_list"
    
    # Select template to move
    local template_id
    template_id=$(dialog --stdout --title "Select Template to Move" \
        --menu "Choose template:" 15 60 5 "${menu_items[@]}")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get current storage
    local current_storage
    current_storage=$(get_template_storage "$template_id")
    
    if [ -z "$current_storage" ]; then
        dialog --msgbox "Could not determine current storage for template $template_id" 6 60
        return 1
    fi
    
    # Get available storages
    local storage_info=$(pvesm status)
    if [ -z "$storage_info" ]; then
        dialog --msgbox "Could not get storage information." 6 40
        return 1
    fi
    
    # Create menu items for storages
    local storage_menu=()
    while read -r line; do
        # Skip header line
        if [[ "$line" =~ ^"Storage" ]]; then
            continue
        fi
        
        local storage=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local avail=$(echo "$line" | awk '{print $4}')
        
        # Skip current storage and empty lines
        if [ -n "$storage" ] && [ "$storage" != "$current_storage" ]; then
            storage_menu+=("$storage" "Type: $type, Available: $avail")
        fi
    done <<< "$storage_info"
    
    if [ ${#storage_menu[@]} -eq 0 ]; then
        dialog --msgbox "No other storage targets available." 6 50
        return 1
    fi
    
    # Select target storage
    local target_storage
    target_storage=$(dialog --stdout --title "Select Target Storage" \
        --menu "Choose storage to move template to:" 15 60 5 "${storage_menu[@]}")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Confirm move
    if ! dialog --yesno "Move template $template_id from $current_storage to $target_storage?" 6 60; then
        return 1
    fi
    
    # Show progress
    dialog --infobox "Moving template... This may take a while." 4 50
    
    # Stop the VM if it's running
    local vm_status=$(qm status "$template_id" 2>/dev/null | awk '{print $2}')
    if [ "$vm_status" = "running" ]; then
        log "Stopping VM $template_id before migration"
        qm stop "$template_id"
        sleep 2
    fi
    
    # Move the template disk
    log "Moving template $template_id from $current_storage to $target_storage"
    
    # First, get all disks for the VM
    local config_file="/etc/pve/qemu-server/${template_id}.conf"
    local disks=($(grep -E '^(scsi|virtio|ide|sata)[0-9]+:' "$config_file" | cut -d: -f1))
    
    local success=true
    for disk in "${disks[@]}"; do
        log "Moving disk $disk to $target_storage"
        if ! qm move_disk "$template_id" "$disk" "$target_storage" --delete=1; then
            log_error "Failed to move disk $disk to $target_storage"
            success=false
            break
        fi
    done
    
    if [ "$success" = true ]; then
        dialog --msgbox "Successfully moved template to $target_storage" 6 50
        log "Successfully moved template $template_id to $target_storage"
    else
        dialog --msgbox "Failed to move template. Check the logs for details." 6 50
        log_error "Failed to move template $template_id to $target_storage"
        return 1
    fi
    
    return 0
}

# Function to get VM list (non-templates)
get_vm_list() {
    local temp_file=$(mktemp)
    qm list | grep -v "TEMPLATE" | tail -n +2 | while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        echo "$vmid $name $status"
    done
    rm -f "$temp_file"
}

# Function to move VM storage
move_vm_storage() {
    # Get VM list
    local vm_list=$(get_vm_list)
    
    if [ -z "$vm_list" ]; then
        dialog --msgbox "No VMs found." 6 40
        return 1
    fi
    
    # Create menu items for VMs
    local menu_items=()
    while read -r vmid name status; do
        local current_storage=$(get_template_storage "$vmid")
        menu_items+=("$vmid" "$name (Status: $status, Storage: $current_storage)")
    done <<< "$vm_list"
    
    # Select VM to move
    local vm_id
    vm_id=$(dialog --stdout --title "Select VM to Move" \
        --menu "Choose VM:" 15 60 5 "${menu_items[@]}")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get current storage
    local current_storage
    current_storage=$(get_template_storage "$vm_id")
    
    if [ -z "$current_storage" ]; then
        dialog --msgbox "Could not determine current storage for VM $vm_id" 6 60
        return 1
    fi
    
    # Get available storages
    local storage_info=$(pvesm status)
    if [ -z "$storage_info" ]; then
        dialog --msgbox "Could not get storage information." 6 40
        return 1
    fi
    
    # Create menu items for storages
    local storage_menu=()
    while read -r line; do
        # Skip header line
        if [[ "$line" =~ ^"Storage" ]]; then
            continue
        fi
        
        local storage=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local avail=$(echo "$line" | awk '{print $4}')
        
        # Skip current storage and empty lines
        if [ -n "$storage" ] && [ "$storage" != "$current_storage" ]; then
            storage_menu+=("$storage" "Type: $type, Available: $avail")
        fi
    done <<< "$storage_info"
    
    if [ ${#storage_menu[@]} -eq 0 ]; then
        dialog --msgbox "No other storage targets available." 6 50
        return 1
    fi
    
    # Select target storage
    local target_storage
    target_storage=$(dialog --stdout --title "Select Target Storage" \
        --menu "Choose storage to move VM to:" 15 60 5 "${storage_menu[@]}")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Check if VM is running
    local vm_status=$(qm status "$vm_id" 2>/dev/null | awk '{print $2}')
    local was_running=false
    
    if [ "$vm_status" = "running" ]; then
        dialog --yesno "VM is currently running. Would you like to temporarily stop it for migration?" 8 60
        if [ $? -eq 0 ]; then
            log "Stopping VM $vm_id for migration"
            qm stop "$vm_id"
            was_running=true
            sleep 2
        else
            dialog --msgbox "Migration cancelled." 6 40
            return 1
        fi
    fi
    
    # Confirm move
    if ! dialog --yesno "Move VM $vm_id from $current_storage to $target_storage?" 6 60; then
        if [ "$was_running" = true ]; then
            qm start "$vm_id"
        fi
        return 1
    fi
    
    # Show progress
    dialog --infobox "Moving VM... This may take a while." 4 50
    
    # Move the VM disks
    log "Moving VM $vm_id from $current_storage to $target_storage"
    
    # Get all disks for the VM
    local config_file="/etc/pve/qemu-server/${vm_id}.conf"
    local disks=($(grep -E '^(scsi|virtio|ide|sata)[0-9]+:' "$config_file" | cut -d: -f1))
    
    local success=true
    for disk in "${disks[@]}"; do
        log "Moving disk $disk to $target_storage"
        if ! qm move_disk "$vm_id" "$disk" "$target_storage" --delete=1; then
            log_error "Failed to move disk $disk to $target_storage"
            success=false
            break
        fi
    done
    
    # Restart VM if it was running before
    if [ "$was_running" = true ] && [ "$success" = true ]; then
        log "Restarting VM $vm_id"
        qm start "$vm_id"
    fi
    
    if [ "$success" = true ]; then
        dialog --msgbox "Successfully moved VM to $target_storage" 6 50
        log "Successfully moved VM $vm_id to $target_storage"
    else
        dialog --msgbox "Failed to move VM. Check the logs for details." 6 50
        log_error "Failed to move VM $vm_id to $target_storage"
        # Try to restart VM if it was running
        if [ "$was_running" = true ]; then
            qm start "$vm_id"
        fi
        return 1
    fi
    
    return 0
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi

# Check dependencies
if ! check_dependencies; then
    exit 1
fi

# Check if required packages are installed
if ! command -v dialog &> /dev/null || ! command -v virt-customize &> /dev/null; then
    log "Required packages not installed. Installing..."
    apt-get update && apt-get install -y dialog libguestfs-tools
fi

# Main menu loop
while true; do
    choice=$(dialog --stdout --title "Proxmox Template Manager" \
        --menu "Choose an operation:" 15 50 8 \
        1 "Create new template" \
        2 "List templates" \
        3 "Delete template" \
        4 "Clone from template" \
        5 "Examine image packages" \
        6 "Move template storage" \
        7 "Move VM storage" \
        8 "Exit")
    
    case $? in
        0)
            case $choice in
                1) create_template ;;
                2) list_templates ;;
                3) delete_template ;;
                4) clone_from_template ;;
                5) examine_image ;;
                6) move_template_storage ;;
                7) move_vm_storage ;;
                8) exit 0 ;;
            esac
            ;;
        1)
            exit 0
            ;;
        255)
            exit 0
            ;;
    esac
done