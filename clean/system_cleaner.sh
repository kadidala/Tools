#!/bin/bash

# 系统清理脚本
# 作者: AI Assistant
# 版本: 1.0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/etc/system_cleaner.conf"
CRON_FILE="/etc/cron.d/system-cleaner"
LOG_FILE="/var/log/system_cleaner.log"

# 日志函数
log() {
    local message="$1"
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message" >> "$LOG_FILE"
}

warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $message" >> "$LOG_FILE"
}

info() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $message" >> "$LOG_FILE"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行"
        exit 1
    fi
}

# 获取磁盘使用情况
get_disk_usage() {
    df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}'
}

# 获取可清理空间大小
calculate_cleanable_space() {
    local total_size=0
    
    # 计算各种垃圾文件大小
    local apt_cache=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
    local yum_cache=$(du -sb /var/cache/yum/ 2>/dev/null | awk '{print $1}' || echo 0)
    local dnf_cache=$(du -sb /var/cache/dnf/ 2>/dev/null | awk '{print $1}' || echo 0)
    local logs=$(find /var/log -name "*.log" -type f -exec du -sb {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    local tmp_files=$(du -sb /tmp/ 2>/dev/null | awk '{print $1}' || echo 0)
    local old_kernels=$(dpkg -l | grep -E "linux-(image|headers)" | grep -v $(uname -r) | wc -l 2>/dev/null || echo 0)
    
    total_size=$((apt_cache + yum_cache + dnf_cache + logs + tmp_files + old_kernels * 100000000))
    
    # 转换为MB
    echo $((total_size / 1024 / 1024))
}

# 清理APT缓存
clean_apt_cache() {
    if command -v apt-get &> /dev/null; then
        log "清理APT缓存..."
        local before=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
        
        apt-get clean >/dev/null 2>&1
        apt-get autoclean >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        
        local after=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
        local saved=$((before - after))
        
        if [[ $saved -gt 0 ]]; then
            info "APT缓存清理完成，释放空间: $(($saved / 1024 / 1024))MB"
        fi
    fi
}

# 清理YUM/DNF缓存
clean_yum_dnf_cache() {
    if command -v yum &> /dev/null; then
        log "清理YUM缓存..."
        local before=$(du -sb /var/cache/yum/ 2>/dev/null | awk '{print $1}' || echo 0)
        
        yum clean all >/dev/null 2>&1
        
        local after=$(du -sb /var/cache/yum/ 2>/dev/null | awk '{print $1}' || echo 0)
        local saved=$((before - after))
        
        if [[ $saved -gt 0 ]]; then
            info "YUM缓存清理完成，释放空间: $(($saved / 1024 / 1024))MB"
        fi
    fi
    
    if command -v dnf &> /dev/null; then
        log "清理DNF缓存..."
        local before=$(du -sb /var/cache/dnf/ 2>/dev/null | awk '{print $1}' || echo 0)
        
        dnf clean all >/dev/null 2>&1
        
        local after=$(du -sb /var/cache/dnf/ 2>/dev/null | awk '{print $1}' || echo 0)
        local saved=$((before - after))
        
        if [[ $saved -gt 0 ]]; then
            info "DNF缓存清理完成，释放空间: $(($saved / 1024 / 1024))MB"
        fi
    fi
}

# 清理系统日志
clean_system_logs() {
    log "清理系统日志..."
    local total_saved=0
    
    # 清理journal日志，保留最近7天
    if command -v journalctl &> /dev/null; then
        local before=$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMGT]B' | head -1 || echo "0B")
        journalctl --vacuum-time=7d >/dev/null 2>&1
        journalctl --vacuum-size=100M >/dev/null 2>&1
        local after=$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMGT]B' | head -1 || echo "0B")
        info "Journal日志清理完成"
    fi
    
    # 清理旧的日志文件
    find /var/log -name "*.log.*" -type f -mtime +7 -delete 2>/dev/null
    find /var/log -name "*.gz" -type f -mtime +7 -delete 2>/dev/null
    find /var/log -name "*.old" -type f -mtime +7 -delete 2>/dev/null
    
    # 清理大型日志文件（保留最后1000行）
    for log_file in /var/log/syslog /var/log/messages /var/log/auth.log /var/log/kern.log; do
        if [[ -f "$log_file" && $(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0) -gt 10485760 ]]; then
            tail -n 1000 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
            info "清理大型日志文件: $log_file"
        fi
    done
    
    info "系统日志清理完成"
}

# 清理临时文件
clean_temp_files() {
    log "清理临时文件..."
    local total_saved=0
    
    # 清理/tmp目录（保留最近1天的文件）
    local before=$(du -sb /tmp/ 2>/dev/null | awk '{print $1}' || echo 0)
    find /tmp -type f -atime +1 -delete 2>/dev/null
    find /tmp -type d -empty -delete 2>/dev/null
    local after=$(du -sb /tmp/ 2>/dev/null | awk '{print $1}' || echo 0)
    local saved=$((before - after))
    
    if [[ $saved -gt 0 ]]; then
        info "/tmp目录清理完成，释放空间: $(($saved / 1024 / 1024))MB"
    fi
    
    # 清理/var/tmp目录
    find /var/tmp -type f -atime +7 -delete 2>/dev/null
    find /var/tmp -type d -empty -delete 2>/dev/null
    
    # 清理用户临时文件
    find /home/*/tmp -type f -atime +3 -delete 2>/dev/null
    find /root/tmp -type f -atime +3 -delete 2>/dev/null
    
    info "临时文件清理完成"
}

# 清理缓存文件
clean_cache_files() {
    log "清理缓存文件..."
    
    # 清理用户缓存
    find /home/*/.cache -type f -atime +7 -delete 2>/dev/null
    find /root/.cache -type f -atime +7 -delete 2>/dev/null
    
    # 清理浏览器缓存
    find /home/*/.mozilla/firefox/*/Cache -type f -delete 2>/dev/null
    find /home/*/.config/google-chrome/Default/Cache -type f -delete 2>/dev/null
    
    # 清理系统缓存
    if [[ -d /var/cache/fontconfig ]]; then
        rm -rf /var/cache/fontconfig/* 2>/dev/null
    fi
    
    # 清理Python缓存
    find /usr -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null
    find /home -name "*.pyc" -type f -delete 2>/dev/null
    
    info "缓存文件清理完成"
}

# 清理旧内核
clean_old_kernels() {
    log "清理旧内核..."

    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian系统
        local current_kernel=$(uname -r)
        local old_kernels=$(dpkg -l | grep -E "linux-(image|headers)" | grep -v "$current_kernel" | awk '{print $2}')

        if [[ -n "$old_kernels" ]]; then
            echo "$old_kernels" | while read kernel; do
                if [[ -n "$kernel" ]]; then
                    apt-get remove --purge -y "$kernel" >/dev/null 2>&1
                    info "删除旧内核: $kernel"
                fi
            done
            apt-get autoremove -y >/dev/null 2>&1
        else
            info "没有发现旧内核"
        fi
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL系统
        package-cleanup --oldkernels --count=1 -y >/dev/null 2>&1 || true
        info "CentOS旧内核清理完成"
    elif command -v dnf &> /dev/null; then
        # Fedora系统
        dnf remove $(dnf repoquery --installonly --latest-limit=-1 -q) -y >/dev/null 2>&1 || true
        info "Fedora旧内核清理完成"
    fi
}

# 清理孤立包
clean_orphaned_packages() {
    log "清理孤立包..."

    if command -v apt-get &> /dev/null; then
        # 清理孤立的包
        apt-get autoremove -y >/dev/null 2>&1
        apt-get autoclean >/dev/null 2>&1

        # 清理配置文件残留
        dpkg -l | grep "^rc" | awk '{print $2}' | xargs dpkg --purge >/dev/null 2>&1 || true

        info "APT孤立包清理完成"
    elif command -v yum &> /dev/null; then
        # 清理YUM孤立包
        package-cleanup --quiet --leaves --exclude-bin >/dev/null 2>&1 || true
        info "YUM孤立包清理完成"
    elif command -v dnf &> /dev/null; then
        # 清理DNF孤立包
        dnf autoremove -y >/dev/null 2>&1
        info "DNF孤立包清理完成"
    fi
}

# 清理大文件和重复文件
clean_large_duplicate_files() {
    log "查找并清理大文件..."

    # 查找大于100MB的文件（排除重要目录）
    local large_files=$(find /var/log /tmp /var/tmp /home -type f -size +100M 2>/dev/null | grep -v -E "(\.iso|\.img|\.vmdk|\.vdi)" | head -10)

    if [[ -n "$large_files" ]]; then
        echo "$large_files" | while read file; do
            if [[ -f "$file" ]]; then
                local size=$(du -sh "$file" | awk '{print $1}')
                warning "发现大文件: $file ($size)"
                # 不自动删除大文件，只记录
            fi
        done
    fi

    # 清理重复的日志文件
    find /var/log -name "*.log.*" -type f | sort | uniq -d | while read file; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            info "删除重复日志文件: $file"
        fi
    done
}

# 清理Docker相关（如果存在）
clean_docker() {
    if command -v docker &> /dev/null; then
        log "清理Docker资源..."

        # 清理停止的容器
        docker container prune -f >/dev/null 2>&1 || true

        # 清理未使用的镜像
        docker image prune -f >/dev/null 2>&1 || true

        # 清理未使用的网络
        docker network prune -f >/dev/null 2>&1 || true

        # 清理未使用的卷
        docker volume prune -f >/dev/null 2>&1 || true

        info "Docker资源清理完成"
    fi
}

# 主清理函数
clean_system() {
    log "开始系统清理..."

    local before_usage=$(df / | awk 'NR==2 {print $3}')
    local cleanable_space=$(calculate_cleanable_space)

    echo -e "${CYAN}预计可清理空间: ${cleanable_space}MB${NC}"
    echo

    # 执行各种清理操作
    clean_apt_cache
    clean_yum_dnf_cache
    clean_system_logs
    clean_temp_files
    clean_cache_files
    clean_old_kernels
    clean_orphaned_packages
    clean_large_duplicate_files
    clean_docker

    # 清理内存缓存
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    local after_usage=$(df / | awk 'NR==2 {print $3}')
    local freed_space=$(((before_usage - after_usage) / 1024))

    echo
    log "系统清理完成！"
    if [[ $freed_space -gt 0 ]]; then
        echo -e "${GREEN}释放磁盘空间: ${freed_space}MB${NC}"
    else
        echo -e "${YELLOW}本次清理释放空间较少${NC}"
    fi

    echo -e "${BLUE}当前磁盘使用情况: $(get_disk_usage)${NC}"
}

# 设置定时任务
setup_cron_job() {
    log "设置定时清理任务..."

    echo -e "${YELLOW}请选择清理周期:${NC}"
    echo "  1. 每小时执行一次"
    echo "  2. 每天执行一次 (推荐)"
    echo "  3. 每周执行一次"
    echo "  4. 每月执行一次"
    echo "  5. 自定义时间"
    echo

    read -p "请输入选项 [1-5]: " cron_choice

    local cron_schedule=""
    local description=""

    case $cron_choice in
        1)
            cron_schedule="0 * * * *"
            description="每小时"
            ;;
        2)
            cron_schedule="0 2 * * *"
            description="每天凌晨2点"
            ;;
        3)
            cron_schedule="0 2 * * 0"
            description="每周日凌晨2点"
            ;;
        4)
            cron_schedule="0 2 1 * *"
            description="每月1号凌晨2点"
            ;;
        5)
            echo "请输入cron表达式 (格式: 分 时 日 月 周):"
            read -p "例如 '0 2 * * *' 表示每天凌晨2点: " custom_cron
            if [[ -n "$custom_cron" ]]; then
                cron_schedule="$custom_cron"
                description="自定义时间"
            else
                error "无效的cron表达式"
                return 1
            fi
            ;;
        *)
            error "无效选项"
            return 1
            ;;
    esac

    # 创建cron任务文件
    cat > "$CRON_FILE" << EOF
# System Cleaner Cron Job
# 自动清理系统垃圾文件
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

$cron_schedule root $0 --auto-clean >/dev/null 2>&1
EOF

    # 记录配置
    echo "CRON_SCHEDULE=$cron_schedule" > "$CONFIG_FILE"
    echo "DESCRIPTION=$description" >> "$CONFIG_FILE"
    echo "CREATED=$(date)" >> "$CONFIG_FILE"

    log "定时任务设置成功！"
    echo -e "${GREEN}清理周期: $description${NC}"
    echo -e "${GREEN}Cron表达式: $cron_schedule${NC}"
    echo -e "${BLUE}任务将在后台自动执行，日志保存在: $LOG_FILE${NC}"
}

# 查看定时任务状态
show_cron_status() {
    echo -e "${BLUE}=== 定时任务状态 ===${NC}"

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo -e "状态: ${GREEN}已启用${NC}"
        echo -e "清理周期: $DESCRIPTION"
        echo -e "Cron表达式: $CRON_SCHEDULE"
        echo -e "创建时间: $CREATED"
        echo

        # 显示下次执行时间
        if command -v crontab &> /dev/null; then
            echo -e "${BLUE}最近的清理日志:${NC}"
            tail -n 5 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
        fi
    else
        echo -e "状态: ${YELLOW}未设置${NC}"
    fi
    echo
}

# 卸载脚本和定时任务
uninstall_script() {
    echo -e "${YELLOW}警告: 此操作将删除所有定时任务和配置文件${NC}"
    read -p "确定要卸载吗? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "取消卸载操作"
        return 0
    fi

    log "开始卸载系统清理脚本..."

    # 删除cron任务
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        log "删除定时任务文件: $CRON_FILE"
    fi

    # 删除配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        log "删除配置文件: $CONFIG_FILE"
    fi

    # 保留日志文件，但添加卸载记录
    log "系统清理脚本已卸载"
    log "日志文件保留在: $LOG_FILE"

    echo
    log "卸载完成！"
    echo -e "${GREEN}所有定时任务和配置已删除${NC}"
    echo -e "${BLUE}日志文件已保留: $LOG_FILE${NC}"
    echo -e "${YELLOW}脚本文件需要手动删除${NC}"
}

# 显示系统状态
show_system_status() {
    echo -e "${BLUE}=== 系统磁盘状态 ===${NC}"
    df -h / | head -2
    echo

    echo -e "${BLUE}=== 内存使用情况 ===${NC}"
    free -h
    echo

    echo -e "${BLUE}=== 可清理空间预估 ===${NC}"
    local cleanable=$(calculate_cleanable_space)
    echo -e "预计可清理: ${CYAN}${cleanable}MB${NC}"
    echo

    # 显示大文件
    echo -e "${BLUE}=== 大文件检查 (>50MB) ===${NC}"
    local large_files=$(find /var/log /tmp /var/tmp -type f -size +50M 2>/dev/null | head -5)
    if [[ -n "$large_files" ]]; then
        echo "$large_files" | while read file; do
            if [[ -f "$file" ]]; then
                local size=$(du -sh "$file" | awk '{print $1}')
                echo "  $file ($size)"
            fi
        done
    else
        echo "  未发现大文件"
    fi
    echo

    show_cron_status
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}    系统清理脚本 v1.0${NC}"
    echo -e "${GREEN}================================${NC}"
    echo

    # 显示当前磁盘使用情况
    local disk_usage=$(get_disk_usage)
    local cleanable=$(calculate_cleanable_space)

    echo -e "${BLUE}当前状态:${NC}"
    echo -e "  磁盘使用: $disk_usage"
    echo -e "  可清理空间: ${cleanable}MB"

    # 显示定时任务状态
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null
        echo -e "  定时清理: ${GREEN}已启用${NC} ($DESCRIPTION)"
    else
        echo -e "  定时清理: ${YELLOW}未设置${NC}"
    fi
    echo

    echo -e "${YELLOW}请选择操作:${NC}"
    echo "  1. 清理垃圾文件"
    echo "  2. 设置定时任务"
    echo "  3. 查看系统状态"
    echo "  9. 卸载脚本"
    echo "  0. 退出"
    echo
}

# 处理命令行参数
handle_arguments() {
    case "$1" in
        --auto-clean)
            # 自动清理模式（用于cron任务）
            clean_system
            exit 0
            ;;
        --status)
            show_system_status
            exit 0
            ;;
        --help|-h)
            echo "系统清理脚本 v1.0"
            echo "用法: $0 [选项]"
            echo
            echo "选项:"
            echo "  --auto-clean    执行自动清理（用于定时任务）"
            echo "  --status        显示系统状态"
            echo "  --help, -h      显示此帮助信息"
            echo
            exit 0
            ;;
    esac
}

# 主函数
main() {
    # 处理命令行参数
    if [[ $# -gt 0 ]]; then
        handle_arguments "$1"
    fi

    check_root

    # 创建日志文件
    touch "$LOG_FILE"

    while true; do
        show_menu
        read -p "请输入选项 [0-9]: " choice

        case $choice in
            1)
                echo
                echo -e "${CYAN}开始清理系统垃圾文件...${NC}"
                echo
                clean_system
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                setup_cron_job
                echo
                read -p "按回车键继续..."
                ;;
            3)
                echo
                show_system_status
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
                log "退出系统清理脚本"
                echo -e "${GREEN}感谢使用系统清理脚本！${NC}"
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
