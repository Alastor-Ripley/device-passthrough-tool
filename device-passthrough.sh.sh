#!/bin/bash
set -o pipefail # Exit if any command in a pipeline fails

# --- Configuration ---
# DEFAULT_DISK_CONTROLLER is less relevant now we prompt explicitly with SCSI default
# DEFAULT_DISK_CONTROLLER="scsi" # Options: ide, sata, scsi, virtio

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
# Usage: find_next_device_index <vmid> <controller_prefix> (e.g., ide, sata, scsi, virtio, hostpci, usb)
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

    # Adjust grep pattern for hostpci which uses '--hostpciX' or '-hostpciX'
    local grep_pattern
    if [[ "$controller_prefix" == "hostpci" ]]; then
        # Match --hostpci<num> or -hostpci<num> at the start of a line or after whitespace
        grep_pattern="[[:space:]]*-{1,2}${controller_prefix}[0-9]+"
    else
        # Original pattern for disk/usb controllers (e.g., scsi0:, usb1:)
        grep_pattern="^${controller_prefix}[0-9]+"
    fi


    # Grep for lines matching the pattern, extract the digits,
    # sort numerically in reverse order, take the first one (highest number)
    last_idx=$(echo "$config" | grep -Eo "$grep_pattern" | grep -Eo '[0-9]+' | sort -nr | head -n 1)


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
    echo " Author: Casear (Original), Enhanced by AI & User"
    echo " GitHub: https://github.com/CasearF/device-passthrough-tool (Original)"
    echo " WARNING: Passthrough modifies VM configurations. Use with caution!"
    echo "-----------------------------------------------------"
    echo ""
    echo "Please select a function by entering the corresponding number:"
    echo "  1 - Passthrough Storage Device (Disk)"
    echo "  2 - Passthrough PCIe Device (NVIDIA Filtered)"
    echo "  3 - Passthrough USB Device"
    echo "  0 - Exit"
    echo ""
}

# Function to show and handle disk passthrough (REVISED CONTROLLER OPTIONS)
function show_disk() {
    echo "--- Storage Device Passthrough ---"
    if ! command_exists lsblk || ! command_exists readlink || ! command_exists basename || ! command_exists sort || ! command_exists stat; then
        error_exit "Required command not found (lsblk, readlink, basename, sort, stat)."
        return 1
    fi

    local -A disk_ids_map # Associative array to map display number to disk ID
    local count=1
    local selected_index selected_disk_id selected_vm_id controller_choice controller_type device_index cmd_result qm_command

    echo "Detecting available whole disk devices (via /dev/disk/by-id)..."
    # Find block devices of type 'disk' and get their corresponding /dev/disk/by-id links
    declare -A seen_targets # Track physical devices we've already added using inode
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

        # Check if we already added this physical device via another ID using inode
        local target_inode
        target_inode=$(stat -c %i "$target_dev")
        if [[ -n "${seen_targets[$target_inode]}" ]]; then continue; fi

        # Store the mapping and mark target as seen
        disk_ids_map[$count]="$(basename "$id_link")"
        seen_targets[$target_inode]=1 # Mark inode as seen
        echo "  $count - $(basename "$id_link") (points to $target_dev)"
        ((count++))
    done

    # Cleanup associative array just in case
    unset seen_targets

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
    list_vms # Show available VMs
    read -rp "Enter the target VM ID: " selected_vm_id
    if ! validate_vm_id "$selected_vm_id"; then return 1; fi

    # Ask for controller type (Revised Options)
    echo "Select Attachment Type (Controller):"
    echo "  1 - IDE (Legacy, Slowest, Max 4)"
    echo "  2 - SATA (Common, Max 6)"
    echo "  3 - SCSI (Recommended for VirtIO SCSI Controller in VM, Max 14)"
    echo "  4 - VirtIO Block (Paravirtualized, High Performance, Max 16)"
    read -rp "Enter choice (1-4, default 3 - SCSI): " controller_choice
    case "$controller_choice" in
        1) controller_type="ide" ;;
        2) controller_type="sata" ;;
        4) controller_type="virtio" ;; # qm uses 'virtio' for VirtIO Block
        3|*) controller_type="scsi" ;; # Default
    esac
    echo "Using attachment type: $controller_type"
    if [[ "$controller_type" == "scsi" ]]; then
        echo "Note: For best performance with SCSI attachment, ensure the VM has a 'VirtIO SCSI' controller added in its Hardware settings."
    fi
     if [[ "$controller_type" == "virtio" ]]; then
        echo "Note: VirtIO Block is high performance, often best for virtual disks but usable for passthrough."
    fi

    # Find next available device index
    device_index=$(find_next_device_index "$selected_vm_id" "$controller_type")
    if [[ $? -ne 0 ]] || [[ -z "$device_index" ]]; then
        error_exit "Could not determine next available device index for $controller_type."
        return 1
    fi
    echo "Using next available device index: $device_index"

    # Construct the qm command
    # Basic command construction - options like cache, iothread are added via GUI or qm set options separately if needed.
    qm_command="qm set $selected_vm_id -${controller_type}${device_index} /dev/disk/by-id/${selected_disk_id}"

    echo "-----------------------------------------------------"
    echo "The following command will be executed:"
    echo "  $qm_command"
    echo "-----------------------------------------------------"

    if ask_confirmation "Execute this command? (y/N): "; then
        echo "Executing command..."
        cmd_result=$(eval "$qm_command" 2>&1) # Use eval to handle potential options with commas if added later
        if [[ $? -eq 0 ]]; then
            echo "Success!"
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            echo "Note: You may need to restart the VM for changes to take full effect."
            if [[ "$controller_type" == "scsi" ]]; then
                 echo "Reminder: Ensure the VM has an appropriate SCSI controller (like VirtIO SCSI) added in Hardware."
            fi
        else
            error_exit "Command failed with status $?."
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            return 1
        fi
    else
        echo "Operation cancelled."
    fi
}


# Function to show and handle PCIe passthrough (FILTERED FOR NVIDIA)
# Function to show and handle PCIe passthrough (FILTERED FOR NVIDIA - CORRECTED GROUP LOOKUP)
function show_pcie() {
    echo "--- PCIe Device Passthrough (NVIDIA Only Filter) ---"
    echo "WARNING: PCIe passthrough is complex and requires proper IOMMU setup (BIOS/Kernel)!"
    echo "WARNING: You generally pass through ALL devices in an IOMMU group together!"

    if ! command_exists lspci || ! command_exists realpath; then # realpath no longer strictly needed here, but keep check for now
        error_exit "Required command not found (lspci, realpath)."
        return 1
    fi

    local iommu_group_path="/sys/kernel/iommu_groups"
    if [ ! -d "$iommu_group_path" ] || [ -z "$(ls -A $iommu_group_path)" ]; then
         error_exit "IOMMU groups not found or empty in $iommu_group_path. Is IOMMU enabled (check BIOS/kernel command line)?"
         return 1
    fi

    echo "Scanning for NVIDIA PCIe devices and their IOMMU groups..."
    # Map display index number to "BusID:GroupNum" string
    local -A pcie_devices_map
    local count=1
    local nvidia_found=false # Flag to track if any NVIDIA devices were found

    declare -a display_list

    shopt -s nullglob # Prevent loop from running if no matches
    for group_dir in "$iommu_group_path"/*/; do
        # Ensure group_dir ends with a number (basic check for valid group path)
        if [[ ! "$(basename "$group_dir")" =~ ^[0-9]+$ ]]; then continue; fi

        local group_num=$(basename "$group_dir")
        local group_has_nvidia=false
        local group_output_buffer=""

        for device_link in "$group_dir"/devices/*; do
            local busid=$(basename "$device_link")
            # Check if basename failed (e.g., malformed link)
            if [[ -z "$busid" || "$busid" == "*" ]]; then continue; fi

            local device_info
            device_info=$(lspci -s "$busid" -nn) # Get full line first
            if echo "$device_info" | grep -qi 'nvidia'; then
                 if ! $group_has_nvidia; then
                     group_output_buffer+="--- IOMMU Group $group_num ---\n"
                     group_has_nvidia=true
                 fi
                 nvidia_found=true

                 local cleaned_device_info=$(echo "$device_info" | sed 's/^[0-9a-f.:]* //')
                 local display_line="[$group_num] $busid $cleaned_device_info"
                 group_output_buffer+="  $count - $display_line\n"
                 # *** CHANGE: Store both BusID and GroupNum ***
                 pcie_devices_map[$count]="$busid:$group_num"
                 ((count++))
            fi
        done

         if $group_has_nvidia; then
            display_list+=("$group_output_buffer")
        fi
    done
    shopt -u nullglob

    if ! $nvidia_found; then
        echo "-----------------------------------------------------"
        echo "No NVIDIA PCIe devices found within active IOMMU groups."
        # ... (rest of not found message) ...
        return 1
    fi

    echo "-----------------------------------------------------"
    echo "Available NVIDIA PCIe devices for passthrough:"
    for item in "${display_list[@]}"; do
        printf "%b" "$item"
    done
    echo "-----------------------------------------------------"

    local selected_index selected_busid selected_map_entry correct_group_num
    read -rp "Enter the number corresponding to the NVIDIA device you want to pass through: " selected_index
    if [[ ! "$selected_index" =~ ^[0-9]+$ ]] || [[ -z "${pcie_devices_map[$selected_index]}" ]]; then
         error_exit "Invalid selection '$selected_index'. Please enter a number from the list above."
         return 1
    fi

    # *** CHANGE: Retrieve both BusID and GroupNum from the map ***
    selected_map_entry="${pcie_devices_map[$selected_index]}"
    selected_busid="${selected_map_entry%%:*}"    # Get part before colon
    correct_group_num="${selected_map_entry##*:}" # Get part after colon

    # Validate that we got a numeric group number
    if [[ -z "$correct_group_num" || ! "$correct_group_num" =~ ^[0-9]+$ ]]; then
        error_exit "Failed to determine the correct IOMMU group number for selection $selected_index. Map entry: '$selected_map_entry'"
        return 1
    fi

    local selected_device_info=$(lspci -s "$selected_busid" -nn | sed 's/^[0-9a-f.:]* //')
    echo "You selected: #$selected_index - $selected_busid ($selected_device_info)"


    # --- Find IOMMU Group and Confirm Group Passthrough ---
    # *** CHANGE: Use the retrieved correct_group_num directly ***
    echo "-----------------------------------------------------"
    echo "Selected device $selected_busid is in IOMMU group $correct_group_num." # Use correct group number
    echo "IMPORTANT: All devices within the *same IOMMU group* might need to be passed through together,"
    echo "or handled by the vfio-pci driver on the host. Review the full group:"

    local group_dev_links=("$iommu_group_path/$correct_group_num"/devices/*) # Use correct group number path
    local contains_other_devices=false
    if [[ ${#group_dev_links[@]} -eq 0 || ! -e "${group_dev_links[0]}" ]]; then
         echo "Warning: Could not list devices for group $correct_group_num. Path used: $iommu_group_path/$correct_group_num/devices/*"
         # Optionally fallback or just proceed with warning if needed, but this indicates an issue.
         # For now, just show the warning. The confirmation below will still use the correct group number.
    else
        for dev_link in "${group_dev_links[@]}"; do
            local current_busid=$(basename "$dev_link")
            if [[ -z "$current_busid" || "$current_busid" == "*" ]]; then
                echo "  - Error processing device link: $dev_link"
                continue
            fi
            echo "  - $current_busid : $(lspci -s "$current_busid" -nn | sed 's/^[0-9a-f.:]* //')"
            if [[ "$current_busid" != "$selected_busid" ]]; then
                contains_other_devices=true
            fi
        done
    fi
    if $contains_other_devices; then
      echo "Note: This group contains other devices besides the one you selected."
    fi

    # *** CHANGE: Use correct_group_num in the prompt ***
    if ! ask_confirmation "Proceed with passing through device $selected_busid (and potentially affecting others in group $correct_group_num)? (y/N): "; then
        echo "Operation cancelled."
        return 1
    fi
    echo "-----------------------------------------------------"

    # --- Get Target VM ID ---
    local selected_vm_id
    list_vms # Show available VMs
    read -rp "Enter the target VM ID to pass this device to: " selected_vm_id
    if ! validate_vm_id "$selected_vm_id"; then return 1; fi

    # --- Find Next Available PCI Slot in VM ---
    local device_index
    device_index=$(find_next_device_index "$selected_vm_id" "hostpci")
     if [[ $? -ne 0 ]] || [[ -z "$device_index" ]]; then
        error_exit "Could not determine next available hostpci index for VM $selected_vm_id."
        return 1
    fi
    echo "Assigning to VM PCI slot index: hostpci$device_index"

    # --- Configure Passthrough Options ---
    local pcie_opt="" rombar_opt="" primary_gpu_opt=""
    if ask_confirmation "Use PCIe specification (pcie=1)? (Recommended for most modern GPUs) (Y/n): " ; then
       pcie_opt=",pcie=1"
       if ask_confirmation "Is this the PRIMARY display adapter for the VM? (Sets primary_gpu=1/x-vga=1) (y/N): "; then
           local current_vga
           current_vga=$(qm config "$selected_vm_id" | grep -o '^vga: .*')
           if [[ -n "$current_vga" ]]; then
              echo "Warning: VM $selected_vm_id already has a display adapter configured ($current_vga)."
              echo "Setting this device as primary GPU (x-vga=1) might conflict or replace it."
              if ! ask_confirmation "Continue setting this as the primary GPU (x-vga=1)? (y/N): "; then
                 echo "Skipping primary GPU setting."
              else
                 primary_gpu_opt=",x-vga=1"
                 echo "Setting as primary GPU (x-vga=1). You might need to remove/change the existing '$current_vga' setting manually."
              fi
           else
              primary_gpu_opt=",x-vga=1"
              echo "Setting as primary GPU (x-vga=1)."
           fi
       fi
    fi

    if ask_confirmation "Disable ROM BAR (rombar=0)? (Often needed for NVIDIA GPUs) (Y/n): "; then
       rombar_opt=",rombar=0"
    fi

    # --- Construct and Confirm Command ---
    local qm_command cmd_result options=""
    if [[ -n "$pcie_opt" ]]; then options+="$pcie_opt"; fi
    if [[ -n "$rombar_opt" ]]; then options+="$rombar_opt"; fi
    if [[ -n "$primary_gpu_opt" ]]; then options+="$primary_gpu_opt"; fi

    qm_command="qm set $selected_vm_id --hostpci${device_index} ${selected_busid}${options}"

    echo "-----------------------------------------------------"
    echo "The following command will be executed:"
    echo "  $qm_command"
    echo "-----------------------------------------------------"

    # --- Execute Command ---
    if ask_confirmation "Execute this command? (y/N): "; then
        echo "Executing command..."
        cmd_result=$(eval "$qm_command" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "Success!"
            if [[ -n "$cmd_result" ]]; then echo "Output: $cmd_result"; fi
            echo "--- Important Notes ---"
            # ... (rest of success notes) ...
        else
            error_exit "Command failed with status $?. Check VM state (should be stopped) and host configuration."
            if [[ -n "$cmd_result" ]]; then echo "Output from failed command: $cmd_result"; fi
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
        # Match lines like "Bus 001 Device 002: ID 1d6b:0002 Linux Foundation 2.0 root hub"
        if [[ "$line" =~ Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+):[[:space:]]+ID[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})[[:space:]]+(.*) ]]; then
            local bus="${BASH_REMATCH[1]}"
            local dev="${BASH_REMATCH[2]}"
            local id="${BASH_REMATCH[3]}"
            local desc="${BASH_REMATCH[4]}"
            # Skip root hubs as they generally cannot be passed through directly
            if [[ "$desc" =~ root\ hub ]]; then continue; fi
            echo "  $count - ID $id | Bus $bus Dev $dev | $desc"
            usb_devices[$count]="$id"
            ((count++))
        fi
    done < <(lsusb)


    if [[ $count -eq 1 ]]; then
        echo "No suitable USB devices found (excluding root hubs)."
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
    list_vms # Show available VMs
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

    echo "-----------------------------------------------------"
    echo "The following command will be executed:"
    echo "  $qm_command"
    echo "-----------------------------------------------------"

    if ask_confirmation "Execute this command? (y/N): "; then
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
        # Clear screen can be disruptive, using spacing instead
        # clear
        echo ""
        echo "====================================================="
        show_help # Display the menu options
        read -rp "Please enter your choice (0-3): " choice

        # Validate if the input is a number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            error_exit "Invalid input '$choice'. Please enter a number."
            # Pause briefly to allow user to see error
            read -rp "Press Enter to continue..."
            continue # Loop again
        fi

        # Process the user's choice
        case $choice in
            1)
                show_disk
                ;;
            2)
                show_pcie # This now calls the NVIDIA-filtered version
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
             echo "-----------------------------------------------------"
            read -rp "Press Enter to return to the menu..."
        fi
    done
}

# --- Script Entry Point ---
show_menu
