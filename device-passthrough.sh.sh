#!/bin/bash

function show_help() {
    echo "作者: Casear"
    echo "GitHub: https://github.com/CasearF/device-passthrough-tool"
    echo "这是一个自写的简单脚本，请谨慎使用。"
    echo ""
    echo ""
    echo "请选择一个功能，输入对应的数字:"
    echo "  1 - 查看储存设备"
    echo "  2 - 查看pcie设备"
    echo "  3 - 查看usb设备"
    echo "  0 - 退出"
}

function show_disk() {
    echo "以下是可用的硬盘设备："
    result=$(ls -l /dev/disk/by-id/ | grep '^lrwxrwxrwx' | grep -E 'ata-|nvme-' | awk '{print $9}' | grep -v 'part')

    if [ -z "$result" ]; then
        echo "没有找到硬盘设备。"
        return
    fi

    IFS=$'\n'
    disk_array=($result)
    i=1

    for disk in "${disk_array[@]}"; do
        echo "$i - $disk"
        ((i++))
    done

    read -p "请输入要选择的硬盘编号: " selected_number

    if [[ "$selected_number" =~ ^[0-9]+$ ]] && [ "$selected_number" -gt 0 ] && [ "$selected_number" -le "${#disk_array[@]}" ]; then
        selected_disk="${disk_array[$selected_number-1]}"
        echo "你选择的硬盘设备是: $selected_disk"
        read -p "请输入要直通的虚拟机编号: " selected_vm_id
        echo "qm set $selected_vm_id -sata2 /dev/disk/by-id/$selected_disk"
        result2=$(qm set $selected_vm_id -sata2 /dev/disk/by-id/$selected_disk)
        echo $result2
    else
        echo "无效的选择，请重新选择一个有效的编号。"
    fi
}

function show_menu() {
    while true; do
        echo ""
        show_help
        read -p "请输入你的选择 (0-3): " choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo "输入无效，请输入一个数字。"
            continue
        fi

        case $choice in
        1)
            show_disk
            ;;
        2)
            echo "正在开发中..."
            ;;
        3)
            echo "正在开发中..."
            ;;
        0)
            echo "退出脚本。再见！"
            exit 0
            ;;
        *)
            echo "无效的选择，请输入一个数字，范围是 0 到 3。"
            ;;
        esac
    done
}

show_menu
