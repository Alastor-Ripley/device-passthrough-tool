#!/bin/bash
set -o pipefail # Exit if any command in a pipeline fails

# --- Configuration ---
DEFAULT_DISK_CONTROLLER="virtio-scsi-pci" # Options: sata, scsi, virtio-scsi-pci

# --- Helper Functions ---

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display error messages and exit (optional)
error_exit() {
    echo "ERROR: $1" >&2
    # Optionally exit if the second argument is non-zero
    if [[ -n "$2" && "$2" -ne 0 ]]; then
        exit "$2"
    fi
}

# Function to list VMs
list_vms() {
    echo "Available Proxmox VMs:"
    if ! command_exists qm; then
         error_exit "'qm' command not found. Is Proxmox VE installed and in PATH?"
         return 1
    fi
    # List VMs, skip header row, print ID and Name
    qm list | awk 'NR>1 {printf "  VM %s - %s\n", $1, $2}'
    return 0
}

# Function to validate VM ID
# Returns 0 if valid, 1 if invalid or non-existent
validate_vm_id() {
    local vmid="$1"
    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid VM ID '$vmid'. Please enter a number."
        return 1
    fi

    if ! command_exists qm; then
         error_exit "'qm' command not found."
         return 1
    fi

    # Check if VM config exists
    qm config "$vmid" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error_exit "VM ID '$vmid' does not exist."
        list_vms # Show available VMs
        return 1
    fi
    return 0 # VM ID is valid
}

# Function to find the next available device index for a given controller type
# Usage: find_next_device_index <vmid> <controller_prefix> (e.g., sata, scsi, hostpci, usb)
# Returns the next index (integer) or echoes error and returns 1
find_next_device_index() {
    local vmid="$1"
    local controller_prefix="$2"
    local config max_idx last_idx

    if ! command_exists qm; then
         error_exit "'qm' command not found."
         return 1
    fi

    config=$(qm config "$vmid" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        error_exit "Could not retrieve config for VM $vmid."
        return 1
    fi

    # Grep for lines starting with the prefix followed by digits, extract the digits,
    # sort numerically in reverse order, take the first one (highest number)
    last_idx=$(echo "$config" | grep -o "^${controller_prefix}[0-9]\+" | grep -o '[0-9]\+' | sort -nr | head -n 1)

    if [[ -z "$last_idx" ]]; then
        max_idx=-1 # No existing devices of this type found
    else
        max_idx=$last_idx
    fi

    echo $((max_idx + 1)) # Output the next available index
    return 0
}

# Function to ask for confirmation
# Usage: ask_confirmation ["Prompt Message"]
# Returns 0 if confirmed (yes), 1 if not (no/empty/anything else)
ask_confirmation() {
    local prompt_msg=${1:-"Proceed? (y/N): "}
    local response
    read -rp "$prompt_msg" response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


# --- Main Feature Functions ---

# Function to display help information and the main menu
function show_help() {
    echo "-----------------------------------------------------"
    echo " Proxmox VE Device Passthrough Helper"
    echo " Author: Casear (Original), Enhanced by AI"
    echo " GitHub: https://github.com/CasearF/device-passthrough-tool"
    echo " WARNING: Passthrough modifies VM configurations. Use with caution!"
    echo "-----------------------------------------------------"
    echo ""
    echo "Please select a function by entering the corresponding number:"
    echo "  1 - Passthrough Storage Device (Disk)"
    echo "  2 - Passthrough PCIe Device"
    echo "  3 - Passthrough USB Device"
    echo "  0 - Exit"
    echo ""
}

# Function to show and handle disk passthrough
function show_disk() {
    echo "--- Storage Device Passthrough ---"
    if ! command_exists lsblk || ! command_exists readlink || ! command_exists basename || ! command_exists sort; then
        error_exit "Required command not found (lsblk, readlink, basename, sort)."
        return 1
    fi

    local -a disk_ids_map # Associative array to map display number to disk ID
    local count=1
    local selected_index selected_disk_id selected_vm_id controller_choice controller_type device_index cmd_result qm_command

    echo "Detecting available whole disk devices (via /dev/disk/by-id)..."
    # Find block devices of type 'disk' and get their corresponding /dev/disk/by-id links
    declare -A seen_targets # Track physical devices we've already added
    local unique_ids=()
    for id_link in /dev/disk/by-id/*; do
        if [[ ! -L "$id_link" ]]; then continue; fi # Skip if not a symlink

        local target_dev
        target_dev=$(readlink -f "$id_link") || continue # Skip if readlink fails
        if [[ ! -b "$target_dev" ]]; then continue; fi # Skip if target not a block device

        # Check if it's a whole disk using lsblk
        local dev_type
        dev_type=$(lsblk -ndo TYPE "$target_dev")
        if [[ "$dev_type" != "disk" ]]; then continue; fi # Skip if not type 'disk'

        # Check if we already added this physical device via another ID
        if [[ -n "${seen_targets[$target_dev]}" ]]; then continue; fi

        # Store the mapping and mark target as seen
        disk_ids_map[$count]="$(basename "$id_link")"
        seen_targets[$target_dev]=1
        echo "  $count - $(basename "$id_link") (points to $target_dev)"
        ((count++))
    done

    if [[ $count -eq 1 ]]; then
        echo "No suitable whole disk devices found in /dev/disk/by-id."
        return 1
    fi

    # Prompt user to select a disk number
    read -rp "Please enter the number of the disk to passthrough: " selected_index
    if [[ ! "$selected_index" =~ ^[0-9]+$ ]] || [[ -z "${disk_ids_map[$selected_index]}" ]]; then
         error_exit "Invalid selection."
         return 1
    fi
    selected_disk_id="${disk_ids_map[$selected_index]}"
    echo "Selected disk ID: $selected_disk_id"

    # Prompt for VM ID and validate
    read -rp "Enter the target VM ID: " selected_vm_id
    if ! validate_vm_id "$selected_vm_id"; then return 1; fi

    # Ask for controller type
    echo "Select controller type:"
    echo "  1 - SATA"
    echo "  2 - SCSI (Legacy)"
    echo "  3 - VirtIO SCSI PCI (Recommended: $DEFAULT_DISK_CONTROLLER)"
    read -rp "Enter choice (1-3, default 3): " controller_choice
    case "$controller_choice" in
        1) controller_type="sata" ;;
        2) controller_type="scsi" ;;
        3|*) controller_type="$DEFAULT_DISK_CONTROLLER" ;; # Default
    esac
    echo "Using controller type: $controller_type"

    # Find next available device index
    device_index=$(find_next_device_index "$selected_vm_id" "$controller_type")
    if [[ $? -ne 0 ]] || [[ -z "$device_index" ]]; then
        error_exit "Could not determine next available device index for $controller_type."
        return 1
    fi
    echo "Using next available device index: $device_index"

    # Construct the qm command
    qm_command="qm set $selected_vm_id -${controller_type}${device_index} /dev/disk/by-id/${selected_disk_id}"
    # Add recommended options for VirtIO SCSI
    if [[ "$controller_type" == "virtio-scsi-pci" ]]; then
        qm_command+=",cache=writeback,iothread=1"
    fi

    echo "The following command will be executed:"
    echo "  $qm_command"

    if ask_confirmation; then
        echo "Executing command..."
        cmd_result=$(eval "$qm_command" 2>&1) # Use eval to handle potential options with commas correctly
        if [[ $? -eq 0 ]]; then
            echo "Success!"
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            echo "Note: You may need to restart the VM for changes to take effect."
        else
            error_exit "Command failed with status $?."
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            return 1
        fi
    else
        echo "Operation cancelled."
    fi
}

# Function to show and handle PCIe passthrough
function show_pcie() {
    echo "--- PCIe Device Passthrough ---"
    echo "WARNING: PCIe passthrough is complex and requires proper IOMMU setup (BIOS/Kernel)!"
    echo "WARNING: You pass through ALL devices in an IOMMU group together!"

    if ! command_exists lspci || ! command_exists realpath; then
        error_exit "Required command not found (lspci, realpath)."
        return 1
    fi

    local iommu_group_path="/sys/kernel/iommu_groups"
    if [ ! -d "$iommu_group_path" ] || [ -z "$(ls -A $iommu_group_path)" ]; then
         error_exit "IOMMU groups not found or empty in $iommu_group_path. Is IOMMU enabled (check BIOS/kernel command line)?"
         return 1
    fi

    echo "Listing PCIe devices and their IOMMU groups..."
    local -A pcie_devices # Map BusID to descriptive line
    local count=1
    local selected_busid selected_vm_id device_index group_num group_dev_links pcie_opt rombar_opt qm_command cmd_result

    # Loop through groups and devices
    shopt -s nullglob # Prevent loop from running if no matches
    for group_dir in "$iommu_group_path"/*/; do
        group_num=$(basename "$group_dir")
        echo "--- IOMMU Group $group_num ---"
        for device_link in "$group_dir"/devices/*; do
            busid=$(basename "$device_link")
            # Use lspci -s to get info for this specific device ID, -nn to get vendor/product IDs
            device_info=$(lspci -s "$busid" -nn | sed 's/^[0-9a-f:]* //') # Remove busid prefix
            display_line="[$group_num] $busid $device_info"
            echo "  $count - $display_line"
            pcie_devices[$count]="$busid" # Store BusID mapping
            ((count++))
        done
    done
    shopt -u nullglob # Restore default behavior

    if [[ $count -eq 1 ]]; then
        echo "No PCIe devices found in IOMMU groups."
        return 1
    fi

    read -rp "Enter the number of the PCIe device to passthrough: " selected_index
    if [[ ! "$selected_index" =~ ^[0-9]+$ ]] || [[ -z "${pcie_devices[$selected_index]}" ]]; then
         error_exit "Invalid selection."
         return 1
    fi
    selected_busid="${pcie_devices[$selected_index]}"

    # Find the group for the selected device again and list all devices in it
    group_num=$(basename "$(dirname "$(realpath "$iommu_group_path"/*/devices/"$selected_busid")")")
    echo "Selected device $selected_busid is in IOMMU group $group_num."
    echo "All devices in this group (will be passed through together):"
    group_dev_links=("$iommu_group_path/$group_num"/devices/*)
    for dev_link in "${group_dev_links[@]}"; do
        echo "  - $(basename "$dev_link") : $(lspci -s "$(basename "$dev_link")")"
    done
    if ! ask_confirmation "WARNING: Pass through ALL devices listed above from group $group_num? (y/N): "; then
        echo "Operation cancelled."
        return 1
    fi

    # Prompt for VM ID and validate
    read -rp "Enter the target VM ID: " selected_vm_id
    if ! validate_vm_id "$selected_vm_id"; then return 1; fi

    # Find next available hostpci index
    device_index=$(find_next_device_index "$selected_vm_id" "hostpci")
     if [[ $? -ne 0 ]] || [[ -z "$device_index" ]]; then
        error_exit "Could not determine next available hostpci index."
        return 1
    fi
    echo "Using next available hostpci index: $device_index"

    # Ask for common options
    pcie_opt=""
    if ask_confirmation "Use PCIe mode (pcie=1)? (Recommended) (Y/n): " ; then
       pcie_opt=",pcie=1"
    fi

    rombar_opt=""
    if ask_confirmation "Disable ROM BAR (rombar=0)? (Often needed) (Y/n): "; then
       rombar_opt=",rombar=0"
    fi
    # Add primary GPU option later? Needs more logic

    # Construct the command
    qm_command="qm set $selected_vm_id -hostpci${device_index} ${selected_busid}${pcie_opt}${rombar_opt}"

    echo "The following command will be executed:"
    echo "  $qm_command"

    if ask_confirmation; then
        echo "Executing command..."
        # Note: This might require the VM to be stopped. qm set will usually error if not.
        cmd_result=$(eval "$qm_command" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "Success!"
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            echo "Note: Ensure required kernel modules (vfio, vfio_pci, etc.) are loaded."
            echo "Note: You may need to blacklist the original driver for $selected_busid on the host."
            echo "Note: VM needs to be fully stopped and started (not rebooted) for PCIe passthrough."
        else
            error_exit "Command failed with status $?."
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            return 1
        fi
    else
        echo "Operation cancelled."
    fi
}


# Function to show and handle USB passthrough
function show_usb() {
    echo "--- USB Device Passthrough ---"
    if ! command_exists lsusb; then
        error_exit "Required command 'lsusb' not found."
        return 1
    fi

    echo "Listing USB devices..."
    local -A usb_devices # Map number to vendor:product ID
    local count=1
    local selected_index selected_usb_id selected_vm_id device_index qm_command cmd_result

    # Use lsusb, format output nicely
    while IFS= read -r line; do
        if [[ "$line" =~ Bus\ ([0-9]+)\ Device\ ([0-9]+):\ ID\ ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\ (.*) ]]; then
            local bus="${BASH_REMATCH[1]}"
            local dev="${BASH_REMATCH[2]}"
            local id="${BASH_REMATCH[3]}"
            local desc="${BASH_REMATCH[4]}"
            echo "  $count - ID $id | Bus $bus Dev $dev | $desc"
            usb_devices[$count]="$id"
            ((count++))
        fi
    done < <(lsusb)


    if [[ $count -eq 1 ]]; then
        echo "No USB devices found."
        return 1
    fi

    read -rp "Enter the number of the USB device to passthrough (by ID): " selected_index
    if [[ ! "$selected_index" =~ ^[0-9]+$ ]] || [[ -z "${usb_devices[$selected_index]}" ]]; then
         error_exit "Invalid selection."
         return 1
    fi
    selected_usb_id="${usb_devices[$selected_index]}"
    echo "Selected USB ID: $selected_usb_id"

    # Prompt for VM ID and validate
    read -rp "Enter the target VM ID: " selected_vm_id
    if ! validate_vm_id "$selected_vm_id"; then return 1; fi

    # Find next available usb index
    device_index=$(find_next_device_index "$selected_vm_id" "usb")
    if [[ $? -ne 0 ]] || [[ -z "$device_index" ]]; then
        error_exit "Could not determine next available usb index."
        return 1
    fi
    echo "Using next available usb index: $device_index"

    # Construct the command (passthrough by ID)
    qm_command="qm set $selected_vm_id -usb${device_index} host=${selected_usb_id}"

    echo "The following command will be executed:"
    echo "  $qm_command"

    if ask_confirmation; then
        echo "Executing command..."
        cmd_result=$(eval "$qm_command" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "Success!"
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            echo "Note: USB passthrough by ID is generally persistent across host reboots."
        else
            error_exit "Command failed with status $?."
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            return 1
        fi
    else
        echo "Operation cancelled."
    fi
}


# --- Main Menu Loop ---
function show_menu() {
    # Check essential commands needed for the menu itself
    if ! command_exists qm; then
        error_exit "'qm' command not found. This script requires Proxmox VE environment." 1
    fi

    while true; do
        echo "" # Add spacing
        show_help # Display the menu options
        read -rp "Please enter your choice (0-3): " choice

        # Validate if the input is a number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            error_exit "Invalid input '$choice'. Please enter a number."
            continue # Loop again
        fi

        # Process the user's choice
        case $choice in
            1)
                show_disk
                ;;
            2)
                show_pcie
                ;;
            3)
                show_usb
                ;;
            0)
                echo "Exiting script. Goodbye!"
                exit 0 # Exit the script successfully
                ;;
            *)
                # Handle invalid numeric choices
                error_exit "Invalid choice '$choice'. Please enter a number between 0 and 3."
                ;;
        esac
        # Pause briefly before showing menu again, unless exiting
        if [[ "$choice" != "0" ]]; then
            read -rp "Press Enter to return to the menu..."
        fi
    done
}

# --- Script Entry Point ---
show_menu
