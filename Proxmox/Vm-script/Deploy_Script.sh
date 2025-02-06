#!/bin/bash

# Check script syntax
bash -n "$0" || exit 1

# Default values
DEFAULT_VM_ID="5000"
DEFAULT_MEMORY="2048"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE="local-lvm"
DEFAULT_MACHINE="q35"
DEFAULT_SCSI="virtio-scsi-pci"
DEFAULT_CORES="2"
DEFAULT_SOCKETS="1"
DEFAULT_USERNAME="ubuntu"
DEFAULT_PASSWORD="ubuntu"

# Function to select file using dialog
select_file() {
    local start_dir=${1:-"/"}
    local selection
    
    while true; do
        selection=$(dialog --title "Select Cloud Image" \
            --fselect "$start_dir" \
            20 70 \
            2>&1 >/dev/tty)
        
        if [ $? -ne 0 ]; then
            return 1
        fi
        
        if [ -f "$selection" ]; then
            echo "$selection"
            return 0
        else
            dialog --msgbox "Please select a valid file" 5 40
        fi
    done
}

# Function to list templates
list_templates() {
    local templates=$(qm list | grep "template" | awk '{print $1" "$2" "$3}')
    if [ -z "$templates" ]; then
        dialog --msgbox "No templates found" 5 40
        return 1
    fi
    echo "$templates"
}

# Function to list VMs
list_vms() {
    local vms=$(qm list | grep -v "template" | awk '{print $1" "$2" "$3}')
    if [ -z "$vms" ]; then
        dialog --msgbox "No VMs found" 5 40
        return 1
    fi
    echo "$vms"
}

# Function to list storages
list_storages() {
    local storages=$(pvesm status -content images | tail -n +2 | awk '{print $1}')
    if [ -z "$storages" ]; then
        dialog --msgbox "No storages found" 5 40
        return 1
    fi
    echo "$storages"
}

# Function to delete template
delete_template() {
    local templates=$(list_templates)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Create menu items from templates
    local menu_items=()
    while read -r vmid name status; do
        menu_items+=("$vmid" "$name ($status)")
    done <<< "$templates"
    
    # Show template selection dialog
    local template_id=$(dialog --menu "Select template to delete:" 20 60 10 "${menu_items[@]}" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Confirm deletion
    dialog --yesno "Are you sure you want to delete template $template_id?" 7 60
    if [ $? -eq 0 ]; then
        qm destroy "$template_id" && dialog --msgbox "Template deleted successfully" 5 40
    fi
}

# Function to get disk size in bytes
get_disk_size() {
    local vm_id=$1
    local disk=${2:-"scsi0"}
    
    # Get disk size using qm config and parse it
    local config_output=$(qm config "$vm_id" 2>/dev/null)
    local disk_line=$(echo "$config_output" | grep "^${disk}:")
    if [ -z "$disk_line" ]; then
        echo "Error: Disk $disk not found in VM $vm_id config" >&2
        return 1
    fi
    
    local size=$(echo "$disk_line" | sed -E 's/.*size=([0-9]+).*/\1/')
    if [ -z "$size" ]; then
        echo "Error: Could not parse disk size from config" >&2
        return 1
    fi
    echo "$size"
}

# Function to get all disks for a VM
get_vm_disks() {
    local vm_id=$1
    local config_output=$(qm config "$vm_id" 2>/dev/null)
    
    # Get all disk entries (scsi, virtio, ide, sata)
    echo "$config_output" | grep -E "^(scsi|virtio|ide|sata)[0-9]+:" | cut -d: -f1
}

# Function to select disk for migration
select_disk_for_migration() {
    local vm_id=$1
    local temp_file=$(mktemp)
    
    # Get all disks
    local disks=($(get_vm_disks "$vm_id"))
    
    if [ ${#disks[@]} -eq 0 ]; then
        dialog --msgbox "No disks found for VM $vm_id" 5 40
        rm -f "$temp_file"
        return 1
    fi
    
    # If only one disk, return it directly
    if [ ${#disks[@]} -eq 1 ]; then
        echo "${disks[0]}"
        return 0
    fi
    
    # Create options for dialog
    local options=()
    local i=1
    for disk in "${disks[@]}"; do
        local disk_info=$(qm config "$vm_id" | grep "^${disk}:")
        options+=("$disk" "$disk_info")
    done
    
    # Show disk selection dialog
    dialog --title "Select Disk for Migration" \
           --menu "Choose disk to migrate:" 15 70 8 \
           "${options[@]}" 2>"$temp_file"
    
    local result=$?
    local selected_disk=""
    
    if [ $result -eq 0 ]; then
        selected_disk=$(cat "$temp_file")
        rm -f "$temp_file"
        echo "$selected_disk"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Function to get storage free space in bytes
get_storage_free_space() {
    local storage=$1
    
    # Get storage info using pvesm and parse it
    local storage_info=$(pvesm status 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get storage status" >&2
        return 1
    fi
    
    local free=$(echo "$storage_info" | grep "^$storage" | awk '{print $4}' | sed 's/G//')
    if [ -z "$free" ]; then
        echo "Error: Could not find free space for storage $storage" >&2
        return 1
    fi
    
    # Convert GB to bytes (1GB = 1024*1024*1024 bytes)
    echo $((free * 1024 * 1024 * 1024))
}

# Function to check if storage type is compatible
check_storage_compatibility() {
    local source_storage=$1
    local target_storage=$2
    
    # Get storage info
    local storage_info=$(pvesm status 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get storage status" >&2
        return 1
    fi
    
    # Get storage types
    local source_type=$(echo "$storage_info" | grep "^$source_storage" | awk '{print $2}')
    local target_type=$(echo "$storage_info" | grep "^$target_storage" | awk '{print $2}')
    
    if [ -z "$source_type" ] || [ -z "$target_type" ]; then
        echo "Error: Could not determine storage types" >&2
        return 1
    fi
    
    # Check if target storage supports VM disks
    local target_features=$(pvesm status -content images 2>/dev/null | grep "^$target_storage" | awk '{print $3}')
    if [ $? -ne 0 ] || [[ ! $target_features =~ "images" ]]; then
        echo "Error: Target storage does not support VM disks" >&2
        return 1
    fi
    
    return 0
}

# Function to validate storage move
validate_storage_move() {
    local vm_id=$1
    local target_storage=$2
    local disk=${3:-"scsi0"}
    local temp_file=$(mktemp)
    local error_file=$(mktemp)
    
    {
        echo "Validating storage move..."
        echo "VM ID: $vm_id"
        echo "Target Storage: $target_storage"
        echo "Disk: $disk"
        echo
        
        # Check if VM/template exists
        if ! qm status "$vm_id" >/dev/null 2>&1; then
            echo "Error: VM/Template $vm_id does not exist"
            return 1
        fi
        echo "✓ VM/Template exists"
        
        # Get current storage
        local current_storage=$(qm config "$vm_id" 2>/dev/null | grep "^${disk}:" | sed -E 's/.*:([^,]+).*/\1/')
        if [ -z "$current_storage" ]; then
            echo "Error: Could not determine current storage for disk $disk"
            return 1
        fi
        echo "✓ Current storage: $current_storage"
        
        # Check if target storage exists
        if ! pvesm status 2>/dev/null | grep -q "^$target_storage"; then
            echo "Error: Target storage $target_storage does not exist"
            return 1
        fi
        echo "✓ Target storage exists"
        
        # Check storage compatibility
        if ! check_storage_compatibility "$current_storage" "$target_storage" 2>$error_file; then
            echo "Error: Storage compatibility check failed"
            cat $error_file
            return 1
        fi
        echo "✓ Storage types are compatible"
        
        # Get disk size and free space
        local disk_size=$(get_disk_size "$vm_id" "$disk" 2>$error_file)
        if [ $? -ne 0 ]; then
            echo "Error getting disk size:"
            cat $error_file
            return 1
        fi
        echo "✓ Disk size: $((disk_size/1024/1024/1024))G"
        
        local free_space=$(get_storage_free_space "$target_storage" 2>$error_file)
        if [ $? -ne 0 ]; then
            echo "Error getting free space:"
            cat $error_file
            return 1
        fi
        echo "✓ Free space: $((free_space/1024/1024/1024))G"
        
        # Check if enough free space (with 10% margin)
        local required_space=$((disk_size * 110 / 100))
        if [ $free_space -lt $required_space ]; then
            echo "Error: Not enough free space on target storage"
            echo "Required (with 10% margin): $((required_space/1024/1024/1024))G"
            echo "Available: $((free_space/1024/1024/1024))G"
            return 1
        fi
        echo "✓ Sufficient free space available"
        
        # Check if VM is running
        if qm status "$vm_id" 2>/dev/null | grep -q "running"; then
            echo "Warning: VM is running. It will need to be stopped before migration."
        fi
        
    } >$temp_file
    
    # Show the validation results
    dialog --title "Storage Move Validation" --textbox "$temp_file" 25 70
    local validation_status=$?
    
    # Clean up
    rm -f "$temp_file" "$error_file"
    
    return $validation_status
}

# Function to move storage
move_storage() {
    local vm_id=$1
    local target_storage=$2
    local disk=$3
    local error_file=$(mktemp)
    
    # Validate storage move first
    if ! validate_storage_move "$vm_id" "$target_storage" "$disk"; then
        return 1
    fi
    
    # Check if VM is running
    local vm_was_running=false
    if qm status "$vm_id" 2>/dev/null | grep -q "running"; then
        dialog --yesno "VM is running. Stop it to proceed with storage migration?" 7 60
        if [ $? -eq 0 ]; then
            vm_was_running=true
            qm stop "$vm_id" 2>$error_file
            if [ $? -ne 0 ]; then
                dialog --msgbox "Failed to stop VM:\n$(cat $error_file)" 10 60
                rm -f "$error_file"
                return 1
            fi
            # Wait for VM to stop
            local timeout=30
            while qm status "$vm_id" 2>/dev/null | grep -q "running"; do
                sleep 1
                ((timeout--))
                if [ $timeout -le 0 ]; then
                    dialog --msgbox "Timeout waiting for VM to stop" 5 40
                    rm -f "$error_file"
                    return 1
                fi
            done
        else
            rm -f "$error_file"
            return 1
        fi
    fi
    
    # Show progress dialog
    {
        echo "0"; echo "XXX"; echo "Preparing to move storage..."; echo "XXX"
        
        # Move the storage with detailed error output
        qm move-disk "$vm_id" "$disk" "$target_storage" --delete 2>"$error_file" | \
        while IFS= read -r line; do
            if [[ $line =~ transferred[[:space:]]+([0-9.]+)[[:space:]]+(.*)[[:space:]]+of[[:space:]]+([0-9.]+)[[:space:]]+(.*)[[:space:]]+\(([0-9.]+)%\) ]]; then
                local percent="${BASH_REMATCH[5]}"
                echo "$percent"
                echo "XXX"
                echo "Transferring: $line"
                echo "XXX"
            fi
        done
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "100"; echo "XXX"; echo "Storage migration complete!"; echo "XXX"
            sleep 1
        else
            local error_msg=$(cat "$error_file")
            if [ -z "$error_msg" ]; then
                error_msg="Unknown error occurred during storage migration"
            fi
            dialog --title "Storage Migration Error" --msgbox "Failed to move storage:\n$error_msg" 10 60
            echo "100"; echo "XXX"; echo "Error: $error_msg"; echo "XXX"
            sleep 2
        fi
    } | dialog --gauge "Moving storage..." 8 70 0
    
    local status=${PIPESTATUS[0]}
    rm -f "$error_file"
    return $status
}

# Function to move VM storage
move_vm_storage() {
    # Get VM list with one qm list call
    local vm_list=$(qm list | tail -n +2)
    
    if [ -z "$vm_list" ]; then
        dialog --msgbox "No VMs found." 6 40
        return 1
    fi
    
    # Create menu items for VMs
    local menu_items=()
    while read -r vmid name status mem disk; do
        menu_items+=("$vmid" "$name ($status, Disk: $disk)")
    done <<< "$vm_list"
    
    # Select VM to move
    local vm_id
    vm_id=$(dialog --stdout --title "Select VM to Move" \
        --menu "Choose VM:" 15 60 5 "${menu_items[@]}")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get VM config directly - more efficient
    local config_file="/etc/pve/qemu-server/${vm_id}.conf"
    if [ ! -f "$config_file" ]; then
        dialog --msgbox "VM configuration not found." 6 40
        return 1
    fi
    
    # Get storage list once
    local storage_list=$(pvesm status -content images | tail -n +2)
    if [ -z "$storage_list" ]; then
        dialog --msgbox "No storage targets available." 6 40
        return 1
    fi
    
    # Create menu items for storages
    local storage_menu=()
    while read -r storage type content avail; do
        # Skip empty lines
        [ -z "$storage" ] && continue
        storage_menu+=("$storage" "Type: $type, Available: $avail")
    done <<< "$storage_list"
    
    if [ ${#storage_menu[@]} -eq 0 ]; then
        dialog --msgbox "No storage targets available." 6 50
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
            echo "Stopping VM $vm_id for migration"
            qm stop "$vm_id"
            was_running=true
            sleep 2
        else
            dialog --msgbox "Migration cancelled." 6 40
            return 1
        fi
    fi
    
    # Show progress
    dialog --infobox "Moving VM... This may take a while." 4 50
    
    # Get all disks for the VM
    local disks=($(grep -E '^(scsi|virtio|ide|sata)[0-9]+:' "$config_file" | cut -d: -f1))
    
    local success=true
    for disk in "${disks[@]}"; do
        echo "Moving disk $disk to $target_storage"
        if ! qm move_disk "$vm_id" "$disk" "$target_storage" --delete=1; then
            echo "Failed to move disk $disk to $target_storage"
            success=false
            break
        fi
    done
    
    # Restart VM if it was running before
    if [ "$was_running" = true ] && [ "$success" = true ]; then
        echo "Restarting VM $vm_id"
        qm start "$vm_id"
    fi
    
    if [ "$success" = true ]; then
        dialog --msgbox "Successfully moved VM to $target_storage" 6 50
        echo "Successfully moved VM $vm_id to $target_storage"
    else
        dialog --msgbox "Failed to move VM. Check the logs for details." 6 50
        echo "Failed to move VM $vm_id to $target_storage"
        # Try to restart VM if it was running
        if [ "$was_running" = true ]; then
            qm start "$vm_id"
        fi
        return 1
    fi
    
    return 0
}

# Function to get VM's current storage
get_vm_storage() {
    local vmid=$1
    local config_file="/etc/pve/qemu-server/${vmid}.conf"
    
    # Get the first disk's storage from the VM config
    if [ -f "$config_file" ]; then
        local storage=$(grep -E '^(scsi|virtio|ide|sata)[0-9]+:' "$config_file" | head -n1 | cut -d',' -f1 | cut -d':' -f2 | cut -d'/' -f1)
        echo "$storage"
    fi
}

# Function to move template storage
move_template_storage() {
    local template_id
    local target_storage
    
    # Get list of templates and create menu items
    local template_menu_items=()
    while IFS= read -r line; do
        # Skip empty lines and header
        [[ -z "$line" || "$line" =~ ^[[:space:]]*VMID ]] && continue
        
        # Parse template ID and name
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([^[:space:]]+) ]]; then
            local id="${BASH_REMATCH[1]}"
            local name="${BASH_REMATCH[2]}"
            template_menu_items+=("$id" "$name")
        fi
    done < <(qm list | grep -i "template")
    
    if [ ${#template_menu_items[@]} -eq 0 ]; then
        dialog --msgbox "No templates found" 5 40
        return 1
    fi
    
    # Create temporary files
    local temp_template=$(mktemp)
    local temp_storage=$(mktemp)
    
    # Show template selection dialog
    dialog --title "Select Template" \
           --menu "Choose template to migrate:" 20 60 10 \
           "${template_menu_items[@]}" 2>"$temp_template"
    
    if [ $? -ne 0 ]; then
        rm -f "$temp_template" "$temp_storage"
        return 1
    fi
    
    template_id=$(cat "$temp_template")
    
    # Select disk to migrate
    local disk=$(select_disk_for_migration "$template_id")
    if [ $? -ne 0 ]; then
        rm -f "$temp_template" "$temp_storage"
        return 1
    fi
    
    # Get available storages and create menu items
    local storage_menu_items=()
    while IFS= read -r line; do
        # Skip empty lines and header
        [[ -z "$line" || "$line" =~ ^[[:space:]]*Name ]] && continue
        
        # Parse storage info (assuming format: NAME TYPE CONTENT)
        read -r storage type content size <<< "$line"
        if [[ -n "$storage" && -n "$type" ]]; then
            storage_menu_items+=("$storage" "$type ($size available)")
        fi
    done < <(pvesm status)
    
    if [ ${#storage_menu_items[@]} -eq 0 ]; then
        dialog --msgbox "No compatible storages found" 5 40
        rm -f "$temp_template" "$temp_storage"
        return 1
    fi
    
    # Show storage selection dialog
    dialog --title "Select Target Storage" \
           --menu "Choose target storage:" 20 60 10 \
           "${storage_menu_items[@]}" 2>"$temp_storage"
    
    if [ $? -ne 0 ]; then
        rm -f "$temp_template" "$temp_storage"
        return 1
    fi
    
    target_storage=$(cat "$temp_storage")
    
    # Clean up temp files
    rm -f "$temp_template" "$temp_storage"
    
    # Check if VM is running
    if qm status "$template_id" 2>/dev/null | grep -q "running"; then
        dialog --title "VM Running" \
               --yesno "VM $template_id is running. For safety:\n\n1. VM will be stopped\n2. Storage will be migrated\n3. VM will be restarted\n\nProceed?" 12 60
        
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Move the storage
    move_storage "$template_id" "$target_storage" "$disk"
    return $?
}

# Function to get available storages
get_storage_list() {
    local storage_menu_items=()
    local first_line=true
    
    while IFS= read -r line; do
        # Skip the header line
        if [ "$first_line" = true ]; then
            first_line=false
            continue
        fi
        
        # Parse storage info using awk to handle variable spacing
        read -r name type status total used available percent <<< "$line"
        
        # Skip disabled storages
        if [ "$status" = "disabled" ]; then
            continue
        fi
        
        # Add to menu items if storage is active
        if [ "$status" = "active" ]; then
            # Convert bytes to GB for display
            local available_gb=$((available / 1024 / 1024))
            storage_menu_items+=("$name" "$type ($available_gb GB free)")
        fi
    done < <(pvesm status)
    
    echo "${storage_menu_items[@]}"
}

# Function to move storage
move_storage() {
    local vm_id=$1
    local target_storage=$2
    local disk=$3
    local error_file=$(mktemp)
    
    # Show progress dialog
    {
        echo "0"; echo "XXX"; echo "Starting storage migration..."; echo "XXX"
        
        # Move the storage with detailed error output
        qm move-disk "$vm_id" "$disk" "$target_storage" --delete 2>"$error_file" | \
        while IFS= read -r line; do
            if [[ $line =~ transferred[[:space:]]+([0-9.]+)[[:space:]]+(.*)[[:space:]]+of[[:space:]]+([0-9.]+)[[:space:]]+(.*)[[:space:]]+\(([0-9.]+)%\) ]]; then
                local percent="${BASH_REMATCH[5]}"
                echo "$percent"
                echo "XXX"
                echo "Transferring: $line"
                echo "XXX"
            fi
        done
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "100"; echo "XXX"; echo "Storage migration complete!"; echo "XXX"
            sleep 1
        else
            local error_msg=$(cat "$error_file")
            if [ -z "$error_msg" ]; then
                error_msg="Unknown error occurred during storage migration"
            fi
            dialog --title "Storage Migration Error" --msgbox "Failed to move storage:\n$error_msg" 10 60
            echo "100"; echo "XXX"; echo "Error: $error_msg"; echo "XXX"
            sleep 2
        fi
    } | dialog --gauge "Moving storage..." 8 70 0
    
    local status=${PIPESTATUS[0]}
    rm -f "$error_file"
    return $status
}

# Function to move VM storage
move_vm_storage() {
    # Get VM list
    local vm_list=$(list_vms)
    
    if [ -z "$vm_list" ]; then
        dialog --msgbox "No VMs found." 6 40
        return 1
    fi
    
    # Create menu items for VMs
    local menu_items=()
    while read -r vmid name status; do
        local current_storage=$(get_vm_storage "$vmid")
        if [ -z "$current_storage" ]; then
            current_storage="unknown"
        fi
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
    local current_storage=$(get_vm_storage "$vm_id")
    
    if [ -z "$current_storage" ]; then
        dialog --msgbox "Could not determine current storage for VM $vm_id" 6 60
        return 1
    fi
    
    # Get available storages
    local available_storages=$(pvesm status | tail -n +2 | awk '{print $1}')
    if [ -z "$available_storages" ]; then
        dialog --msgbox "No storage locations found. Please check Proxmox configuration." 8 50
        return 1
    fi

    # Create storage options for dialog
    local storage_options=()
    while IFS= read -r storage_name; do
        storage_options+=("$storage_name" "Storage location")
    done <<< "$available_storages"

    # Let user select storage
    local storage
    storage=$(dialog --backtitle "Proxmox Template Creator" \
        --title "Storage Selection" \
        --menu "Select storage location:" 15 50 8 \
        "${storage_options[@]}" \
        2>&1 1>&3)

    if [ $? -ne 0 ]; then
        return 1
    fi

    # Verify storage exists and is active
    storage_check=$(pvesm status | grep "^$storage")
    if [ -z "$storage_check" ]; then
        dialog --title "Error" --msgbox "Storage '$storage' does not exist" 6 50
        return 1
    fi

    # Check if storage is active
    storage_status=$(echo "$storage_check" | awk '{print $3}')
    if [ "$storage_status" != "active" ]; then
        dialog --title "Error" --msgbox "Storage '$storage' is not active (status: $storage_status)" 6 60
        return 1
    fi

    # Check if VM is running
    local vm_status=$(qm status "$vm_id" 2>/dev/null | awk '{print $2}')
    local was_running=false
    
    if [ "$vm_status" = "running" ]; then
        dialog --yesno "VM is currently running. Would you like to temporarily stop it for migration?" 8 60
        if [ $? -eq 0 ]; then
            echo "Stopping VM $vm_id for migration"
            qm stop "$vm_id"
            was_running=true
            sleep 2
        else
            dialog --msgbox "Migration cancelled." 6 40
            return 1
        fi
    fi
    
    # Confirm move
    if ! dialog --yesno "Move VM $vm_id from $current_storage to $storage?" 6 60; then
        if [ "$was_running" = true ]; then
            qm start "$vm_id"
        fi
        return 1
    fi
    
    # Show progress
    dialog --infobox "Moving VM... This may take a while." 4 50
    
    # Move the VM disks
    echo "Moving VM $vm_id from $current_storage to $storage"
    
    # Get all disks for the VM
    local config_file="/etc/pve/qemu-server/${vm_id}.conf"
    local disks=($(grep -E '^(scsi|virtio|ide|sata)[0-9]+:' "$config_file" | cut -d: -f1))
    
    local success=true
    for disk in "${disks[@]}"; do
        echo "Moving disk $disk to $storage"
        if ! qm move_disk "$vm_id" "$disk" "$storage" --delete=1; then
            echo "Failed to move disk $disk to $storage"
            success=false
            break
        fi
    done
    
    # Restart VM if it was running before
    if [ "$was_running" = true ] && [ "$success" = true ]; then
        echo "Restarting VM $vm_id"
        qm start "$vm_id"
    fi
    
    if [ "$success" = true ]; then
        dialog --msgbox "Successfully moved VM to $storage" 6 50
        echo "Successfully moved VM $vm_id to $storage"
    else
        dialog --msgbox "Failed to move VM. Check the logs for details." 6 50
        echo "Failed to move VM $vm_id to $storage"
        # Try to restart VM if it was running
        if [ "$was_running" = true ]; then
            qm start "$vm_id"
        fi
        return 1
    fi
    
    return 0
}

# Function to create template
create_template() {
    local vm_id="$1"
    local vm_name="$2"
    local memory="$3"
    local bridge="$4"
    local storage="$5"
    local machine="$6"
    local cores="$7"
    local sockets="$8"
    local username="$9"
    local password="${10}"
    local image_path="${11}"

    # Create temporary file for progress
    local temp_file=$(mktemp)
    
    # Display progress dialog
    (
        echo "0"; echo "XXX"; echo "Creating VM..."; echo "XXX"
        
        # Create VM
        qm create "$vm_id" \
            --memory "$memory" \
            --net0 "virtio,bridge=$bridge" \
            --scsihw virtio-scsi-pci \
            --name "$vm_name" \
            --machine "$machine" \
            --cores "$cores" \
            --sockets "$sockets" \
            --cpu cputype=host \
            2>>$temp_file
        
        if [ $? -ne 0 ]; then
            echo "Failed to create VM. Check the logs for details."
            exit 1
        fi
        
        echo "20"; echo "XXX"; echo "Importing disk..."; echo "XXX"
        sleep 1
        
        # Import the disk
        qm importdisk "$vm_id" "$image_path" "$storage" 2>>$temp_file
        
        if [ $? -ne 0 ]; then
            echo "Failed to import disk. Check the logs for details."
            exit 1
        fi
        
        echo "40"; echo "XXX"; echo "Configuring disk..."; echo "XXX"
        sleep 1
        
        # Attach the imported disk
        qm set "$vm_id" --scsi0 "$storage:vm-$vm_id-disk-0" 2>>$temp_file
        
        # Verify disk attachment
        if ! qm config "$vm_id" | grep -q "scsi0"; then
            echo "Failed to attach disk. Check the logs for details."
            exit 1
        fi
        
        echo "60"; echo "XXX"; echo "Configuring cloud-init..."; echo "XXX"
        
        # Add cloud-init drive
        qm set "$vm_id" --ide2 "$storage:cloudinit" 2>>$temp_file
        
        # Verify cloud-init drive
        if ! qm config "$vm_id" | grep -q "ide2"; then
            echo "Failed to attach cloud-init drive. Check the logs for details."
            exit 1
        fi
        
        # Configure cloud-init
        qm set "$vm_id" --ipconfig0 "ip=dhcp" 2>>$temp_file
        qm set "$vm_id" --ciuser "$DEFAULT_USERNAME" 2>>$temp_file
        qm set "$vm_id" --cipassword "$DEFAULT_PASSWORD" 2>>$temp_file
        
        echo "70"; echo "XXX"; echo "Setting boot order..."; echo "XXX"
        
        # Set boot order
        qm set "$vm_id" --boot c --bootdisk scsi0 2>>$temp_file
        
        # Verify boot order
        if ! qm config "$vm_id" | grep -q "boot: c"; then
            echo "Failed to set boot order. Check the logs for details."
            exit 1
        fi
        
        echo "80"; echo "XXX"; echo "Enabling QEMU agent..."; echo "XXX"
        
        # Enable QEMU guest agent
        qm set "$vm_id" --agent enabled=1 2>>$temp_file
        
        echo "90"; echo "XXX"; echo "Converting to template..."; echo "XXX"
        sleep 1
        
        # Convert to template
        qm template "$vm_id" 2>>$temp_file
        
        if [ $? -ne 0 ]; then
            echo "Failed to convert to template. Check the logs for details."
            exit 1
        fi
        
        echo "100"; echo "XXX"; echo "Template created successfully!"; echo "XXX"
        sleep 1
    ) | dialog --title "Creating Template" --gauge "Please wait..." 8 50

    # Check if any errors occurred
    if [ -s "$temp_file" ]; then
        dialog --title "Error" --msgbox "$(cat "$temp_file")" 15 60
        rm "$temp_file"
        return 1
    fi

    rm "$temp_file"
    dialog --msgbox "Template created successfully!\n\nTo use this template:\nqm clone $vm_id NEW_ID\nqm set NEW_ID --ipconfig0 ip=dhcp\nqm start NEW_ID" 10 60
    return 0
}

# Main menu
while true; do
    exec 3>&1
    selection=$(dialog \
        --backtitle "Proxmox Template Creator" \
        --title "Main Menu" \
        --clear \
        --cancel-label "Exit" \
        --menu "Please select an option:" 15 50 6 \
        "1" "Create template from cloud image" \
        "2" "Delete template" \
        "3" "Move template storage" \
        "4" "Move VM storage" \
        2>&1 1>&3)
    exit_status=$?
    exec 3>&-
    
    case $exit_status in
        1)
            clear
            echo "Program terminated."
            exit
            ;;
        255)
            clear
            echo "Program terminated."
            exit
            ;;
    esac
    
    case $selection in
        1)  # Create template from cloud image
            image_path=$(select_file "/var/lib/vz/template/iso")
            if [ $? -ne 0 ]; then
                continue
            fi
            
            # Get available storages first
            exec 3>&1
            available_storages=$(pvesm status | tail -n +2 | awk '{print $1}')
            if [ -z "$available_storages" ]; then
                dialog --msgbox "No storage locations found. Please check Proxmox configuration." 8 50
                exec 3>&-
                continue
            fi

            # Create storage options for dialog
            storage_options=()
            while IFS= read -r storage_name; do
                # Get storage status and type
                storage_info=$(pvesm status | grep "^$storage_name" | awk '{print $2, $3}')
                storage_options+=("$storage_name" "$storage_info")
            done <<< "$available_storages"

            # Let user select storage
            storage=$(dialog --backtitle "Proxmox Template Creator" \
                --title "Storage Selection" \
                --menu "Select storage location:" 15 60 8 \
                "${storage_options[@]}" \
                2>&1 1>&3)
            storage_status=$?
            
            if [ $storage_status -ne 0 ]; then
                exec 3>&-
                continue
            fi

            # Verify storage exists and is active
            storage_check=$(pvesm status | grep "^$storage")
            if [ -z "$storage_check" ]; then
                dialog --title "Error" --msgbox "Storage '$storage' does not exist" 6 50
                exec 3>&-
                continue
            fi

            # Check if storage is active
            storage_status=$(echo "$storage_check" | awk '{print $3}')
            if [ "$storage_status" != "active" ]; then
                dialog --title "Error" --msgbox "Storage '$storage' is not active (status: $storage_status)" 6 60
                exec 3>&-
                continue
            fi

            # Get VM configuration using forms
            values=$(dialog --ok-label "Submit" \
                --backtitle "Proxmox Template Creator" \
                --title "VM Configuration" \
                --form "VM Settings" \
                25 70 0 \
                "VM ID:"        1 1 "$DEFAULT_VM_ID"     1 25 10 0 \
                "VM Name:"      2 1 "template-vm"        2 25 30 0 \
                "Memory (MB):"  3 1 "$DEFAULT_MEMORY"    3 25 10 0 \
                "Bridge:"       4 1 "$DEFAULT_BRIDGE"    4 25 20 0 \
                "Machine:"      5 1 "$DEFAULT_MACHINE"   5 25 20 0 \
                "Cores:"        6 1 "$DEFAULT_CORES"     6 25 5  0 \
                "Sockets:"      7 1 "$DEFAULT_SOCKETS"   7 25 5  0 \
                "Username:"     8 1 "$DEFAULT_USERNAME"  8 25 20 0 \
                "Password:"     9 1 "$DEFAULT_PASSWORD"  9 25 20 0 \
                2>&1 1>&3)
            form_status=$?
            exec 3>&-

            if [ $form_status -ne 0 ]; then
                continue
            fi
            
            # Parse form values and ensure they are numeric where needed
            vm_id=$(echo "$values" | sed -n 1p | tr -cd '0-9')
            vm_name=$(echo "$values" | sed -n 2p)
            memory=$(echo "$values" | sed -n 3p | tr -cd '0-9')
            bridge=$(echo "$values" | sed -n 4p)
            machine=$(echo "$values" | sed -n 5p)
            cores=$(echo "$values" | sed -n 6p | tr -cd '0-9')
            sockets=$(echo "$values" | sed -n 7p | tr -cd '0-9')
            username=$(echo "$values" | sed -n 8p)
            password=$(echo "$values" | sed -n 9p)

            # Set defaults if values are empty
            vm_id=${vm_id:-$DEFAULT_VM_ID}
            memory=${memory:-$DEFAULT_MEMORY}
            cores=${cores:-$DEFAULT_CORES}
            sockets=${sockets:-$DEFAULT_SOCKETS}

            # Verify all values are present and valid
            if [ -z "$vm_id" ] || [ -z "$vm_name" ] || [ -z "$memory" ] || [ -z "$bridge" ] || \
               [ -z "$machine" ] || [ -z "$cores" ] || [ -z "$sockets" ] || \
               [ -z "$username" ] || [ -z "$password" ] || [ -z "$storage" ]; then
                dialog --title "Error" --msgbox "All fields are required" 6 50
                continue
            fi

            # Validate numeric values
            if ! [[ "$vm_id" =~ ^[0-9]+$ ]]; then
                dialog --title "Error" --msgbox "VM ID must be a number" 6 50
                continue
            fi

            if ! [[ "$memory" =~ ^[0-9]+$ ]]; then
                dialog --title "Error" --msgbox "Memory must be a number" 6 50
                continue
            fi

            if ! [[ "$cores" =~ ^[0-9]+$ ]]; then
                dialog --title "Error" --msgbox "Cores must be a number" 6 50
                continue
            fi

            if ! [[ "$sockets" =~ ^[0-9]+$ ]]; then
                dialog --title "Error" --msgbox "Sockets must be a number" 6 50
                continue
            fi

            # Ensure numeric values are within reasonable ranges
            if [ "$vm_id" -lt 100 ] || [ "$vm_id" -gt 999999 ]; then
                dialog --title "Error" --msgbox "VM ID must be between 100 and 999999" 6 50
                continue
            fi

            if [ "$memory" -lt 512 ] || [ "$memory" -gt 262144 ]; then
                dialog --title "Error" --msgbox "Memory must be between 512MB and 256GB" 6 50
                continue
            fi

            if [ "$cores" -lt 1 ] || [ "$cores" -gt 128 ]; then
                dialog --title "Error" --msgbox "Cores must be between 1 and 128" 6 50
                continue
            fi

            if [ "$sockets" -lt 1 ] || [ "$sockets" -gt 4 ]; then
                dialog --title "Error" --msgbox "Sockets must be between 1 and 4" 6 50
                continue
            fi

            # Create template
            if ! create_template "$vm_id" "$vm_name" "$memory" "$bridge" "$storage" \
                               "$machine" "$cores" "$sockets" "$username" "$password" "$image_path"; then
                continue
            fi
            ;;
        2)  # Delete template
            delete_template
            ;;
        3)  # Move template storage
            move_template_storage
            ;;
        4)  # Move VM storage
            move_vm_storage
            ;;
    esac
done
