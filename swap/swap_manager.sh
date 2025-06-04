#!/bin/bash

# 虚拟内存管理脚本
# 作者: AI Assistant
# 版本: 1.0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/etc/memory_manager.conf"
BACKUP_DIR="/etc/memory_manager_backup"

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行"
        exit 1
    fi
}

# 获取物理内存大小(MB)
get_physical_memory() {
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $((mem_kb / 1024))
}

# 获取当前swap大小(MB)
get_current_swap() {
    local swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    echo $((swap_kb / 1024))
}

# 创建备份目录
create_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log "创建备份目录: $BACKUP_DIR"
    fi
}

# 备份配置文件
backup_config() {
    local file="$1"
    local backup_name="$2"
    
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/${backup_name}.bak"
        log "备份文件: $file -> $BACKUP_DIR/${backup_name}.bak"
    fi
}

# 恢复配置文件
restore_config() {
    local file="$1"
    local backup_name="$2"
    
    if [[ -f "$BACKUP_DIR/${backup_name}.bak" ]]; then
        cp "$BACKUP_DIR/${backup_name}.bak" "$file"
        log "恢复文件: $BACKUP_DIR/${backup_name}.bak -> $file"
    fi
}

# 添加swap
add_swap() {
    local physical_mem=$(get_physical_memory)
    local default_size=$((physical_mem * 2))
    
    echo -e "${BLUE}当前物理内存: ${physical_mem}MB${NC}"
    echo -e "${BLUE}建议swap大小: ${default_size}MB${NC}"
    
    read -p "请输入swap大小(MB) [默认: $default_size]: " swap_size
    swap_size=${swap_size:-$default_size}
    
    # 验证输入
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        error "无效的数字格式"
        return 1
    fi
    
    local swap_file="/swapfile"
    
    # 检查是否已存在swap文件
    if [[ -f "$swap_file" ]]; then
        warning "Swap文件已存在，将先删除现有swap"
        swapoff "$swap_file" 2>/dev/null
        rm -f "$swap_file"
    fi
    
    log "创建${swap_size}MB的swap文件..."
    
    # 创建swap文件
    dd if=/dev/zero of="$swap_file" bs=1M count="$swap_size" status=progress
    
    if [[ $? -ne 0 ]]; then
        error "创建swap文件失败"
        return 1
    fi
    
    # 设置权限
    chmod 600 "$swap_file"
    
    # 格式化为swap
    mkswap "$swap_file"
    
    # 启用swap
    swapon "$swap_file"
    
    # 添加到fstab以实现重启后自动挂载
    backup_config "/etc/fstab" "fstab"
    
    # 移除旧的swap条目
    sed -i '/\/swapfile/d' /etc/fstab
    
    # 添加新的swap条目
    echo "$swap_file none swap sw 0 0" >> /etc/fstab
    
    # 记录配置
    echo "SWAP_FILE=$swap_file" > "$CONFIG_FILE"
    echo "SWAP_SIZE=$swap_size" >> "$CONFIG_FILE"
    
    log "Swap创建成功！"
    log "当前swap使用情况:"
    free -h
}

# 删除所有swap
remove_all_swap() {
    log "删除所有swap..."
    
    # 关闭所有swap
    swapoff -a
    
    # 从fstab中移除swap条目
    if [[ -f "/etc/fstab" ]]; then
        backup_config "/etc/fstab" "fstab"
        sed -i '/swap/d' /etc/fstab
    fi
    
    # 删除swap文件
    if [[ -f "/swapfile" ]]; then
        rm -f "/swapfile"
        log "删除swap文件: /swapfile"
    fi
    
    # 删除其他可能的swap文件
    for swap_file in /swap /var/swap /tmp/swap; do
        if [[ -f "$swap_file" ]]; then
            rm -f "$swap_file"
            log "删除swap文件: $swap_file"
        fi
    done
    
    log "所有swap已删除"
    free -h
}

# 设置swappiness值
set_swappiness() {
    local current_swappiness=$(cat /proc/sys/vm/swappiness)
    echo -e "${BLUE}当前swappiness值: $current_swappiness${NC}"
    echo -e "${BLUE}建议值: 60-100 (更积极使用swap)${NC}"
    
    read -p "请输入新的swappiness值 [0-100]: " new_swappiness
    
    # 验证输入
    if ! [[ "$new_swappiness" =~ ^[0-9]+$ ]] || [[ $new_swappiness -lt 0 ]] || [[ $new_swappiness -gt 100 ]]; then
        error "swappiness值必须在0-100之间"
        return 1
    fi
    
    # 立即生效
    echo "$new_swappiness" > /proc/sys/vm/swappiness
    
    # 永久生效
    backup_config "/etc/sysctl.conf" "sysctl"
    
    # 移除旧的swappiness设置
    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    
    # 添加新的设置
    echo "vm.swappiness=$new_swappiness" >> /etc/sysctl.conf
    
    log "Swappiness已设置为: $new_swappiness"
}

# 积极使用swap - 极端优化
aggressive_swap_mode() {
    log "启用积极swap模式..."

    create_backup_dir
    backup_config "/etc/sysctl.conf" "sysctl"
    backup_config "/etc/modules" "modules"

    # 设置极端的内核参数
    cat >> /etc/sysctl.conf << EOF

# Memory Manager - 积极swap模式
vm.swappiness=100
vm.vfs_cache_pressure=200
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.dirty_expire_centisecs=1000
vm.dirty_writeback_centisecs=100
vm.overcommit_memory=1
vm.overcommit_ratio=200
vm.min_free_kbytes=8192
vm.zone_reclaim_mode=1
EOF

    # 立即应用设置
    sysctl -p

    # 安装并配置ZRAM
    install_zram

    # 安装并配置ZSWAP
    install_zswap

    # 设置内存压缩
    setup_memory_compression

    # 创建启动脚本确保重启后生效
    create_startup_script

    log "积极swap模式已启用！"
    log "系统将优先使用swap和压缩内存"
}

# 安装和配置ZRAM
install_zram() {
    log "配置ZRAM..."

    # 检查是否支持ZRAM
    if ! modprobe zram 2>/dev/null; then
        warning "系统不支持ZRAM，跳过ZRAM配置"
        return 1
    fi

    # 添加zram模块到启动加载
    if ! grep -q "zram" /etc/modules; then
        echo "zram" >> /etc/modules
    fi

    # 创建ZRAM配置脚本
    cat > /usr/local/bin/setup-zram.sh << 'EOF'
#!/bin/bash
# ZRAM设置脚本

# 获取CPU核心数
CORES=$(nproc)
# 获取总内存(KB)
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
# 设置ZRAM大小为物理内存的50%
ZRAM_SIZE=$((TOTAL_MEM * 512))

# 卸载现有ZRAM设备
for i in $(seq 0 $((CORES-1))); do
    if [[ -b /dev/zram$i ]]; then
        swapoff /dev/zram$i 2>/dev/null
        echo 1 > /sys/block/zram$i/reset 2>/dev/null
    fi
done

# 设置ZRAM设备数量
echo $CORES > /sys/class/zram-control/hot_add 2>/dev/null || true

# 配置每个ZRAM设备
for i in $(seq 0 $((CORES-1))); do
    if [[ -b /dev/zram$i ]]; then
        # 设置压缩算法
        echo lz4 > /sys/block/zram$i/comp_algorithm 2>/dev/null || echo lzo > /sys/block/zram$i/comp_algorithm
        # 设置大小
        echo $ZRAM_SIZE > /sys/block/zram$i/disksize
        # 格式化为swap
        mkswap /dev/zram$i
        # 启用swap，设置高优先级
        swapon -p 10 /dev/zram$i
    fi
done

echo "ZRAM已配置完成"
EOF

    chmod +x /usr/local/bin/setup-zram.sh

    # 立即执行ZRAM设置
    /usr/local/bin/setup-zram.sh

    log "ZRAM配置完成"
}

# 安装和配置ZSWAP
install_zswap() {
    log "配置ZSWAP..."

    # 检查内核是否支持ZSWAP
    if [[ ! -d /sys/module/zswap ]]; then
        warning "内核不支持ZSWAP，尝试加载模块"
        modprobe zswap 2>/dev/null || {
            warning "无法加载ZSWAP模块，跳过ZSWAP配置"
            return 1
        }
    fi

    # 启用ZSWAP
    echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    # 设置ZSWAP参数
    echo 50 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
    echo lz4 > /sys/module/zswap/parameters/compressor 2>/dev/null || echo lzo > /sys/module/zswap/parameters/compressor 2>/dev/null || true
    echo z3fold > /sys/module/zswap/parameters/zpool 2>/dev/null || echo zbud > /sys/module/zswap/parameters/zpool 2>/dev/null || true

    # 添加到内核启动参数
    backup_config "/etc/default/grub" "grub"

    if grep -q "GRUB_CMDLINE_LINUX=" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="zswap.enabled=1 zswap.max_pool_percent=50 /' /etc/default/grub
        update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    fi

    log "ZSWAP配置完成"
}

# 设置内存压缩
setup_memory_compression() {
    log "配置内存压缩..."

    # 启用内存去重
    echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
    echo 100 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
    echo 1000 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true

    # 启用透明大页压缩
    echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo always > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    log "内存压缩配置完成"
}

# 创建启动脚本
create_startup_script() {
    log "创建启动脚本..."

    # 创建systemd服务
    cat > /etc/systemd/system/memory-manager.service << 'EOF'
[Unit]
Description=Memory Manager Service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/memory-manager-startup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # 创建启动脚本
    cat > /usr/local/bin/memory-manager-startup.sh << 'EOF'
#!/bin/bash
# Memory Manager 启动脚本

# 设置ZRAM
if [[ -x /usr/local/bin/setup-zram.sh ]]; then
    /usr/local/bin/setup-zram.sh
fi

# 启用内存去重
echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
echo 100 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true

# 启用透明大页
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo always > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# 启用ZSWAP
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true

echo "Memory Manager 启动脚本执行完成"
EOF

    chmod +x /usr/local/bin/memory-manager-startup.sh

    # 启用服务
    systemctl daemon-reload
    systemctl enable memory-manager.service

    log "启动脚本创建完成"
}

# 卸载脚本
uninstall_script() {
    echo -e "${YELLOW}警告: 此操作将卸载所有由脚本安装的组件并恢复原始配置${NC}"
    read -p "确定要继续吗? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "取消卸载操作"
        return 0
    fi

    log "开始卸载..."

    # 停止并禁用服务
    systemctl stop memory-manager.service 2>/dev/null || true
    systemctl disable memory-manager.service 2>/dev/null || true
    rm -f /etc/systemd/system/memory-manager.service
    systemctl daemon-reload

    # 删除启动脚本
    rm -f /usr/local/bin/memory-manager-startup.sh
    rm -f /usr/local/bin/setup-zram.sh

    # 关闭所有swap
    swapoff -a

    # 重置ZRAM设备
    for i in /dev/zram*; do
        if [[ -b "$i" ]]; then
            swapoff "$i" 2>/dev/null || true
            echo 1 > "/sys/block/$(basename $i)/reset" 2>/dev/null || true
        fi
    done

    # 禁用内存去重
    echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true

    # 恢复配置文件
    if [[ -d "$BACKUP_DIR" ]]; then
        restore_config "/etc/fstab" "fstab"
        restore_config "/etc/sysctl.conf" "sysctl"
        restore_config "/etc/modules" "modules"
        restore_config "/etc/default/grub" "grub"

        # 更新grub
        update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    fi

    # 删除swap文件
    rm -f /swapfile /swap /var/swap /tmp/swap

    # 应用原始sysctl设置
    sysctl -p 2>/dev/null || true

    # 删除配置文件和备份
    rm -f "$CONFIG_FILE"
    rm -rf "$BACKUP_DIR"

    log "卸载完成！"
    log "建议重启系统以完全恢复原始状态"
}

# 显示系统状态
show_status() {
    echo -e "${BLUE}=== 系统内存状态 ===${NC}"
    free -h
    echo

    echo -e "${BLUE}=== Swap使用情况 ===${NC}"
    swapon --show 2>/dev/null || echo "无活动swap"
    echo

    echo -e "${BLUE}=== 当前swappiness值 ===${NC}"
    echo "swappiness: $(cat /proc/sys/vm/swappiness)"
    echo

    echo -e "${BLUE}=== ZRAM状态 ===${NC}"
    if [[ -d /sys/class/zram-control ]]; then
        for zram in /dev/zram*; do
            if [[ -b "$zram" ]]; then
                local zram_name=$(basename "$zram")
                echo "$zram_name: $(cat /sys/block/$zram_name/disksize 2>/dev/null || echo '未配置') bytes"
            fi
        done
    else
        echo "ZRAM未启用"
    fi
    echo

    echo -e "${BLUE}=== ZSWAP状态 ===${NC}"
    if [[ -d /sys/module/zswap ]]; then
        echo "启用状态: $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo '未知')"
        echo "最大池百分比: $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo '未知')%"
    else
        echo "ZSWAP未启用"
    fi
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}    虚拟内存管理脚本 v1.0${NC}"
    echo -e "${GREEN}================================${NC}"
    echo

    # 显示当前状态摘要
    local physical_mem=$(get_physical_memory)
    local current_swap=$(get_current_swap)
    local swappiness=$(cat /proc/sys/vm/swappiness)

    echo -e "${BLUE}当前状态:${NC}"
    echo -e "  物理内存: ${physical_mem}MB"
    echo -e "  Swap大小: ${current_swap}MB"
    echo -e "  Swappiness: $swappiness"
    echo

    echo -e "${YELLOW}请选择操作:${NC}"
    echo "  1. 添加Swap"
    echo "  2. 删除所有Swap"
    echo "  3. 设置Swappiness值"
    echo "  4. 积极使用Swap模式 (推荐)"
    echo "  5. 查看详细状态"
    echo "  9. 卸载脚本"
    echo "  0. 退出"
    echo
}

# 主函数
main() {
    check_root

    while true; do
        show_menu
        read -p "请输入选项 [0-9]: " choice

        case $choice in
            1)
                echo
                add_swap
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                remove_all_swap
                echo
                read -p "按回车键继续..."
                ;;
            3)
                echo
                set_swappiness
                echo
                read -p "按回车键继续..."
                ;;
            4)
                echo
                echo -e "${YELLOW}警告: 积极Swap模式将进行极端优化，可能影响系统性能${NC}"
                echo -e "${YELLOW}但会最大化利用虚拟内存，适合内存紧张的VPS${NC}"
                read -p "确定要启用吗? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    aggressive_swap_mode
                else
                    log "取消积极Swap模式"
                fi
                echo
                read -p "按回车键继续..."
                ;;
            5)
                echo
                show_status
                echo
                read -p "按回车键继续..."
                ;;
            9)
                echo
                uninstall_script
                echo
                read -p "按回车键继续..."
                ;;
            0)
                log "退出脚本"
                exit 0
                ;;
            *)
                error "无效选项，请重新选择"
                sleep 2
                ;;
        esac
    done
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
