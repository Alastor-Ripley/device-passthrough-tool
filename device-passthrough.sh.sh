#!/bin/bash

# Function to display help information and the main menu
function show_help() {
    echo "Author: Casear"
    echo "GitHub: https://github.com/CasearF/device-passthrough-tool"
    echo "This is a simple script written by the author. Please use it with caution."
    echo ""
    echo ""
    echo "Please select a function by entering the corresponding number:"
    echo "  1 - View storage devices"
    echo "  2 - View PCIe devices"
    echo "  3 - View USB devices"
    echo "  0 - Exit"
}

# Function to show and handle disk passthrough
function show_disk() {
    echo "The following hard disk devices are available:"
    # List block devices by ID, filter for symbolic links (^lrwxrwx), 
    # keep only ata and nvme devices, print the target filename ($9),
    # and exclude partitions (-v 'part')
    result=$(ls -l /dev/disk/by-id/ | grep '^lrwxrwxrwx' | grep -E 'ata-|nvme-' | awk '{print $9}' | grep -v 'part')

    if [ -z "$result" ]; then
        echo "No hard disk devices found."
        return
    fi

    # Set Internal Field Separator to newline to handle disk names correctly
    IFS=$'\n'
    # Create an array of disk names
    disk_array=($result)
    i=1

    # Loop through the array and display numbered options
    for disk in "${disk_array[@]}"; do
        echo "$i - $disk"
        ((i++))
    done

    # Prompt user to select a disk number
    read -p "Please enter the number of the hard disk to select: " selected_number

    # Validate the user input
    if [[ "$selected_number" =~ ^[0-9]+$ ]] && [ "$selected_number" -gt 0 ] && [ "$selected_number" -le "${#disk_array[@]}" ]; then
        # Get the selected disk name from the array (adjusting for 0-based index)
        selected_disk="${disk_array[$selected_number-1]}"
        echo "You have selected the hard disk device: $selected_disk"
        # Prompt user for the target VM ID
        read -p "Please enter the VM ID to pass through to: " selected_vm_id
        # Echo the command that will be run (for user visibility)
        echo "qm set $selected_vm_id -sata2 /dev/disk/by-id/$selected_disk"
        # Execute the Proxmox VE command to attach the disk to the VM as sata2
        result2=$(qm set $selected_vm_id -sata2 /dev/disk/by-id/$selected_disk)
        # Display the output/result of the command
        echo $result2
    else
        # Handle invalid input
        echo "Invalid selection. Please choose a valid number again."
    fi
}

# Main menu loop function
function show_menu() {
    while true; do
        echo ""
        show_help # Display the menu options
        # Prompt user for their choice
        read -p "Please enter your choice (0-3): " choice

        # Validate if the input is a number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo "Invalid input. Please enter a number."
            continue # Loop again if input is not a number
        fi

        # Process the user's choice
        case $choice in
        1)
            show_disk # Call the disk passthrough function
            ;;
        2)
            echo "Under development..." # Placeholder for PCIe devices
            ;;
        3)
            echo "Under development..." # Placeholder for USB devices
            ;;
        0)
            echo "Exiting script. Goodbye!"
            exit 0 # Exit the script successfully
            ;;
        *)
            # Handle invalid numeric choices
            echo "Invalid choice. Please enter a number between 0 and 3."
            ;;
        esac
    done
}

# Start the main menu
show_menu
