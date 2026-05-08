#!/bin/bash
# =============================================================================
#   Xray 一键管理脚本 Pro 版
#   功能：多协议支持 / 多用户管理 / 流量统计 / 备份恢复 /
#         防火墙管理 / 自动更新 / 系统监控 / BBR加速
# =============================================================================

# ──────────────────────────── 颜色 & 样式 ────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[0;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m';    DIM='\033[2m';       NC='\033[0m'

# ──────────────────────────── 全局常量 ───────────────────────────────────────
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly CLIENT_FILE="/root/xray-client.txt"
readonly BACKUP_DIR="/root/xray-backup"
readonly SCRIPT_VERSION="2.1.0"
readonly STATS_FILE="/root/xray-stats.json"
# 流量限制模块常量
readonly QUOTA_DB="/root/xray-quota.json"          # 各用户配额 & 累计用量持久化
readonly SUSPENDED_TAG="suspended-blackhole"        # 暂停用户路由标签
readonly QUOTA_CRON_TAG="# xray-quota-watchdog"    # cron 标识

# ──────────────────────────── 全局变量 ───────────────────────────────────────
PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
FINGERPRINT="chrome"; DEST=""; DEST_PORT=443
UUID=""; PORT=443; SERVER_IP=""; DOMAIN=""
REMARK="xray"; PROTOCOL_CHOICE=1
VMESS_PORT_FINAL=""; VLESS_LINK=""; VMESS_LINK=""
TROJAN_LINK=""; SS_LINK=""; HY2_LINK=""
PM=""; SYSTEM=""

# ──────────────────────────── 日志函数 ───────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${CYAN}[✓]${NC} $1"; }
step()    { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; }
tip()     { echo -e "${DIM}  → $1${NC}"; }

# 带进度的操作
run_with_progress() {
    local msg="$1"; shift
    echo -ne "${GREEN}[INFO]${NC} ${msg}..."
    if "$@" > /tmp/xray_op.log 2>&1; then
        echo -e " ${GREEN}完成${NC}"
        return 0
    else
        echo -e " ${RED}失败${NC}"
        warn "详情: $(cat /tmp/xray_op.log | tail -3)"
        return 1
    fi
}

# ──────────────────────────── 系统检测 ───────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
}

detect_system() {
    if [[ -f /etc/debian_version ]]; then
        PM="apt"; SYSTEM="debian"
        # 检测具体发行版
        if [[ -f /etc/os-release ]]; then
            source /etc/os-release
            OS_NAME="$NAME $VERSION_ID"
        else
            OS_NAME="Debian/Ubuntu"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        PM="yum"; SYSTEM="redhat"
        OS_NAME=$(cat /etc/redhat-release)
        # CentOS 8+ 用 dnf
        command -v dnf &>/dev/null && PM="dnf"
    else
        error "不支持的系统，仅支持 Debian/Ubuntu/RHEL/CentOS 系列"
    fi
}

# 检测 CPU 架构
detect_arch() {
    case $(uname -m) in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        armv7l)  echo "arm32-v7a" ;;
        *)       error "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

# ──────────────────────────── 依赖管理 ───────────────────────────────────────
check_pkg() {
    case $SYSTEM in
        debian) dpkg -l "$1" 2>/dev/null | grep -q "^ii" ;;
        redhat) rpm -q "$1" &>/dev/null ;;
    esac
}

install_dependencies() {
    step "检查系统依赖"
    local pkgs=(curl wget jq openssl certbot qrencode net-tools unzip dnsutils iptables cron)
    local missing=()

    for pkg in "${pkgs[@]}"; do
        check_pkg "$pkg" || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "所有依赖已安装"; return 0
    fi

    info "安装缺失依赖: ${missing[*]}"
    run_with_progress "更新软件源" $PM update -y
    run_with_progress "安装依赖包" $PM install -y "${missing[@]}"

    # RHEL 系额外处理 certbot
    if [[ $SYSTEM == "redhat" ]] && ! command -v certbot &>/dev/null; then
        run_with_progress "安装 certbot (EPEL)" bash -c \
            "$PM install -y epel-release && $PM install -y certbot"
    fi
}

# ──────────────────────────── Xray 安装/更新 ─────────────────────────────────
get_xray_latest_version() {
    curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null
}

install_xray() {
    local FORCE=${1:-false}

    if command -v xray &>/dev/null && [[ "$FORCE" != "true" ]]; then
        info "Xray 已安装: $(xray version 2>/dev/null | head -1)"
        return 0
    fi

    step "安装 Xray"
    local install_ok=false

    # 方式1：官方一键脚本
    if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ install -u root 2>/dev/null; then
        install_ok=true
    else
        warn "官方脚本安装失败，尝试手动下载..."
        local ARCH; ARCH=$(detect_arch)
        local VER; VER=$(get_xray_latest_version)
        [[ -z "$VER" ]] && error "无法获取最新版本号，请检查网络"

        local URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${ARCH}.zip"
        if wget -q --show-progress "$URL" -O /tmp/xray.zip; then
            mkdir -p /usr/local/xray
            unzip -o /tmp/xray.zip -d /usr/local/xray > /dev/null 2>&1
            install -m 755 /usr/local/xray/xray "$XRAY_BIN"
            cp /usr/local/xray/geoip.dat /usr/local/share/xray/ 2>/dev/null || true
            cp /usr/local/xray/geosite.dat /usr/local/share/xray/ 2>/dev/null || true
            rm -rf /tmp/xray.zip /usr/local/xray
            install_ok=true
        fi
    fi

    $install_ok || error "Xray 安装失败，请检查网络或手动安装"

    mkdir -p "$XRAY_LOG_DIR" /usr/local/etc/xray /usr/local/share/xray
    chmod 755 "$XRAY_LOG_DIR"
    success "Xray 安装完成: $(xray version 2>/dev/null | head -1)"
}

update_xray() {
    step "更新 Xray 核心"
    local CURRENT_VER; CURRENT_VER=$(xray version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)
    local LATEST_VER; LATEST_VER=$(get_xray_latest_version)

    if [[ -z "$LATEST_VER" ]]; then
        warn "无法获取最新版本信息，请检查网络"; return 1
    fi

    info "当前版本: ${CURRENT_VER:-未知}  →  最新版本: $LATEST_VER"

    if [[ "$CURRENT_VER" == "$LATEST_VER" ]]; then
        success "已是最新版本，无需更新"; return 0
    fi

    read -p "确认更新? [Y/n]: " confirm
    confirm=${confirm:-Y}
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    # 备份当前配置
    backup_config "pre-update"

    install_xray true
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray && success "更新完成，服务已重启" \
        || warn "服务重启失败，请检查日志"
}

# ──────────────────────────── Systemd 服务 ───────────────────────────────────
create_systemd_service() {
    # 官方脚本已创建则跳过
    [[ -f /etc/systemd/system/xray.service ]] && { systemctl daemon-reload; return 0; }

    cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    info "Systemd 服务文件已创建"
}

# 统一启动/重启入口（首次 & 重启均适用）
restart_and_show() {
    step "验证并启动服务"
    xray run -test -config "$XRAY_CONFIG" > /dev/null 2>&1 \
        || error "配置文件验证失败，请执行 'xray run -test -config $XRAY_CONFIG' 查看详情"

    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray \
        || error "Xray 服务启动失败，请执行 'journalctl -u xray -n 50' 查看错误"

    gen_qrcode
    gen_client_config
    save_config
    success "部署完成！节点已生效"
}

# ──────────────────────────── 系统状态检测 ───────────────────────────────────
check_xray_deployed() {
    [[ -f "$XRAY_CONFIG" ]] && command -v xray &>/dev/null
}

# ──────────────────────────── 防火墙管理 ─────────────────────────────────────
detect_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

open_port() {
    local port=$1 proto=${2:-tcp}
    local fw; fw=$(detect_firewall)

    case $fw in
        ufw)
            ufw allow "${port}/${proto}" > /dev/null 2>&1
            info "UFW 已放行端口 ${port}/${proto}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/${proto}" > /dev/null 2>&1
            firewall-cmd --reload > /dev/null 2>&1
            info "Firewalld 已放行端口 ${port}/${proto}"
            ;;
        iptables)
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
            # 持久化
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            info "iptables 已放行端口 ${port}/${proto}"
            ;;
        none)
            tip "未检测到防火墙，跳过端口开放"
            ;;
    esac
}

close_port() {
    local port=$1 proto=${2:-tcp}
    local fw; fw=$(detect_firewall)

    case $fw in
        ufw) ufw delete allow "${port}/${proto}" > /dev/null 2>&1 ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/${proto}" > /dev/null 2>&1
            firewall-cmd --reload > /dev/null 2>&1
            ;;
        iptables)
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ;;
    esac
}

manage_firewall() {
    step "防火墙管理"
    local fw; fw=$(detect_firewall)
    echo -e "${YELLOW}当前防火墙:${NC} ${fw}"
    echo ""
    echo -e "  ${GREEN}1${NC}. 查看当前规则"
    echo -e "  ${GREEN}2${NC}. 手动放行端口"
    echo -e "  ${GREEN}3${NC}. 手动关闭端口"
    echo -e "  ${GREEN}4${NC}. 自动放行所有 Xray 端口"
    echo -e "  ${GREEN}5${NC}. 返回"
    read -p "请选择: " fw_choice

    case $fw_choice in
        1)
            case $fw in
                ufw) ufw status numbered ;;
                firewalld) firewall-cmd --list-all ;;
                iptables) iptables -L INPUT -n --line-numbers ;;
                *) warn "未检测到防火墙" ;;
            esac
            ;;
        2)
            read -p "请输入端口号: " p
            read -p "协议 [tcp/udp, 默认tcp]: " proto; proto=${proto:-tcp}
            open_port "$p" "$proto"
            ;;
        3)
            read -p "请输入要关闭的端口号: " p
            read -p "协议 [tcp/udp, 默认tcp]: " proto; proto=${proto:-tcp}
            close_port "$p" "$proto"
            ;;
        4)
            if [[ -f "$XRAY_CONFIG" ]]; then
                local ports; ports=$(grep -o '"port": [0-9]*' "$XRAY_CONFIG" | grep -o '[0-9]*')
                for p in $ports; do
                    open_port "$p" tcp
                    open_port "$p" udp
                done
                success "已放行所有 Xray 监听端口"
            else
                warn "未找到 Xray 配置文件"
            fi
            ;;
        5) return ;;
    esac
}

# ──────────────────────────── 备份与恢复 ─────────────────────────────────────
backup_config() {
    local tag=${1:-manual}
    mkdir -p "$BACKUP_DIR"
    local bak_name="xray-backup-$(date +%Y%m%d-%H%M%S)-${tag}"
    local bak_path="$BACKUP_DIR/${bak_name}.tar.gz"

    local files=()
    [[ -f "$XRAY_CONFIG" ]]  && files+=("$XRAY_CONFIG")
    [[ -f "$CLIENT_FILE" ]]  && files+=("$CLIENT_FILE")
    [[ -f "$STATS_FILE" ]]   && files+=("$STATS_FILE")

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "没有找到可备份的文件"; return 1
    fi

    tar -czf "$bak_path" "${files[@]}" 2>/dev/null
    success "备份完成: $bak_path"

    # 只保留最近 10 份备份
    ls -t "$BACKUP_DIR"/xray-backup-*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    info "备份目录保留最近 10 份，旧备份已自动清理"
}

restore_config() {
    step "恢复配置"
    local baks=()
    while IFS= read -r f; do baks+=("$f"); done < <(ls -t "$BACKUP_DIR"/xray-backup-*.tar.gz 2>/dev/null)

    if [[ ${#baks[@]} -eq 0 ]]; then
        warn "备份目录 $BACKUP_DIR 中没有找到备份文件"; return 1
    fi

    echo -e "\n${BLUE}可用备份列表:${NC}"
    for i in "${!baks[@]}"; do
        echo -e "  ${GREEN}$((i+1))${NC}. $(basename "${baks[$i]}")"
    done
    echo -e "  ${GREEN}0${NC}. 取消"

    read -p "请选择备份编号: " idx
    [[ "$idx" == "0" || -z "$idx" ]] && return

    local chosen="${baks[$((idx-1))]}"
    [[ -z "$chosen" ]] && { warn "无效选择"; return 1; }

    warn "恢复将覆盖当前配置，确认继续?"
    read -p "[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    # 先备份当前配置
    backup_config "pre-restore"

    tar -xzf "$chosen" -C / 2>/dev/null
    success "配置已恢复自: $(basename "$chosen")"

    xray run -test -config "$XRAY_CONFIG" > /dev/null 2>&1 && {
        systemctl restart xray && sleep 2
        systemctl is-active --quiet xray && success "服务已重启" || warn "服务重启失败"
    } || warn "恢复的配置验证失败，服务未重启"
}

manage_backup() {
    echo ""
    echo -e "${PURPLE}═══════════════════════════════${NC}"
    echo -e "${PURPLE}       备份与恢复管理${NC}"
    echo -e "${PURPLE}═══════════════════════════════${NC}"
    echo -e "  ${GREEN}1${NC}. 立即备份当前配置"
    echo -e "  ${GREEN}2${NC}. 恢复历史备份"
    echo -e "  ${GREEN}3${NC}. 查看备份列表"
    echo -e "  ${GREEN}4${NC}. 删除所有备份"
    echo -e "  ${GREEN}5${NC}. 返回"
    read -p "请选择: " choice

    case $choice in
        1) backup_config "manual" ;;
        2) restore_config ;;
        3)
            echo ""
            if ls "$BACKUP_DIR"/xray-backup-*.tar.gz &>/dev/null; then
                ls -lh "$BACKUP_DIR"/xray-backup-*.tar.gz
            else
                warn "暂无备份文件"
            fi
            ;;
        4)
            read -p "确认删除所有备份? [y/N]: " confirm
            [[ "$confirm" == "y" || "$confirm" == "Y" ]] && {
                rm -f "$BACKUP_DIR"/xray-backup-*.tar.gz
                success "所有备份已删除"
            }
            ;;
        5) return ;;
    esac
}

# ──────────────────────────── BBR 加速 ───────────────────────────────────────
check_bbr_status() {
    [[ "$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')" == "bbr" ]]
}

enable_bbr() {
    step "开启 BBR 加速"
    local kver; kver=$(uname -r | cut -d'-' -f1)
    if ! awk "BEGIN{exit !($kver>=4.9)}"; then
        warn "内核版本 $kver 低于 4.9，不支持 BBR"; return 1
    fi

    check_bbr_status && { success "BBR 已处于开启状态"; return 0; }

    # 去重写入
    grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf 2>/dev/null || {
        cat >> /etc/sysctl.conf << 'EOF'

# BBR 加速配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    }
    sysctl -p > /dev/null 2>&1
    sleep 1
    check_bbr_status && success "BBR 加速开启成功" || warn "BBR 开启失败，请检查内核配置"
}

disable_bbr() {
    step "关闭 BBR 加速"
    sed -i '/# BBR 加速配置/d;/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' \
        /etc/sysctl.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    sysctl -p > /dev/null 2>&1
    success "BBR 已关闭，已切换为 cubic"
}

view_bbr_status() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════${NC}"
    echo -e "${BLUE}         BBR 加速状态${NC}"
    echo -e "${BLUE}═══════════════════════════════${NC}"
    echo -e "${YELLOW}内核版本:${NC}  $(uname -r)"
    echo -e "${YELLOW}拥塞算法:${NC}  $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
    echo -e "${YELLOW}队列算法:${NC}  $(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')"
    echo -e "${BLUE}═══════════════════════════════${NC}"
    check_bbr_status && success "BBR 加速已开启" || warn "BBR 加速未开启"
}


# ──────────────────────────── 密钥生成 ───────────────────────────────────────
generate_reality_keys_once() {
    PRIVATE_KEY=""; PUBLIC_KEY=""
    local XRAY_CMD; XRAY_CMD=$(command -v xray || echo "$XRAY_BIN")

    [[ ! -x "$XRAY_CMD" ]] && { warn "未找到 xray 命令"; _manual_input_keys; return; }

    mapfile -t KEYS < <("$XRAY_CMD" x25519 2>&1)
    local rc=$?

    if [[ $rc -eq 0 && ${#KEYS[@]} -ge 2 ]]; then
        PRIVATE_KEY=$(echo "${KEYS[0]}" | awk -F': ' '{print $2}' | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "${KEYS[1]}"  | awk -F': ' '{print $2}' | tr -d '[:space:]')
    fi

    if [[ ${#PRIVATE_KEY} -eq 43 && ${#PUBLIC_KEY} -eq 43 ]]; then
        success "Reality 密钥对生成成功"
        tip "PrivateKey: $PRIVATE_KEY"
        tip "PublicKey:  $PUBLIC_KEY"
        return 0
    fi

    warn "自动生成失败，进入手动输入模式"
    _manual_input_keys
}

_manual_input_keys() {
    echo -e "\n${YELLOW}手动输入密钥说明:${NC}"
    echo "  执行 'xray x25519' 获取密钥，只粘贴冒号后面的内容"
    echo -e "  第1行: ${GREEN}PrivateKey${NC}  第2行: ${GREEN}PublicKey${NC}\n"

    while true; do
        read -p "请粘贴 PrivateKey (私钥): " PRIVATE_KEY
        read -p "请粘贴 PublicKey  (公钥): " PUBLIC_KEY
        PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$PUBLIC_KEY"   | tr -d '[:space:]')
        if [[ ${#PRIVATE_KEY} -ge 40 && ${#PUBLIC_KEY} -ge 40 ]]; then
            success "密钥格式验证通过"; break
        fi
        warn "密钥长度异常（应≥40字符），请重新输入"
        read -p "强制使用? [y/N]: " f; [[ "$f" == "y" ]] && break
    done
}

# ──────────────────────────── SSL 证书 ───────────────────────────────────────
get_cert() {
    [[ "$PROTOCOL_CHOICE" == "1" ]] && { tip "VLESS+Reality 无需证书"; return 0; }
    [[ -z "$DOMAIN" ]] && error "申请证书需要提供域名"

    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        warn "证书已存在，跳过申请"; return 0
    fi

    step "申请 SSL 证书"
    local DOMAIN_IP; DOMAIN_IP=$(dig +short "$DOMAIN" | tail -1)
    local SRV_IP; SRV_IP=$(curl -s4 ip.sb)

    if [[ "$DOMAIN_IP" != "$SRV_IP" ]]; then
        warn "域名 $DOMAIN 解析 IP ($DOMAIN_IP) ≠ 服务器 IP ($SRV_IP)"
        read -p "是否继续申请? [y/N]: " c
        [[ "$c" != "y" ]] && error "请先将域名解析到服务器 IP: $SRV_IP"
    fi

    systemctl stop nginx apache2 caddy 2>/dev/null || true
    certbot certonly --standalone -d "$DOMAIN" \
        --non-interactive --agree-tos \
        --email "admin@$DOMAIN" --key-type ecdsa \
        || error "SSL 证书申请失败，请检查域名解析和端口 80 是否可访问"
    success "SSL 证书申请成功"
}

setup_cert_renewal() {
    [[ "$PROTOCOL_CHOICE" == "1" ]] && return 0
    (crontab -l 2>/dev/null | grep -v "certbot renew"
     echo "0 3 1,15 * * certbot renew --quiet --deploy-hook 'systemctl restart xray'"
    ) | crontab -
    info "SSL 证书自动续期已配置（每月1日和15日凌晨3点）"
}

# ──────────────────────────── 协议选择 ───────────────────────────────────────
select_protocol() {
    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}              请选择代理协议${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}1${NC}. VLESS + Reality + Vision     ${DIM}(推荐，无需域名)${NC}"
    echo -e "  ${GREEN}2${NC}. VMess + TLS + WebSocket      ${DIM}(需要域名)${NC}"
    echo -e "  ${GREEN}3${NC}. Trojan + TLS                 ${DIM}(需要域名)${NC}"
    echo -e "  ${GREEN}4${NC}. Shadowsocks 2022             ${DIM}(无需域名，轻量)${NC}"
    echo -e "  ${GREEN}5${NC}. VLESS+Reality + VMess (双栈) ${DIM}(需要域名)${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    read -p "请选择 [默认 1]: " PROTOCOL_CHOICE
    PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}
    [[ ! "$PROTOCOL_CHOICE" =~ ^[1-5]$ ]] && { warn "无效选择，使用默认值 1"; PROTOCOL_CHOICE=1; }
}

# Reality 回落配置
get_reality_input() {
    generate_reality_keys_once
    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "Reality 密钥生成失败"

    SHORT_ID=$(openssl rand -hex 8)
    DEST="www.microsoft.com"
    DEST_PORT=443
    FINGERPRINT="chrome"
    tip "Short ID:   $SHORT_ID"
    tip "回落目标:   ${DEST}:${DEST_PORT}"
    tip "TLS 指纹:   $FINGERPRINT"
}

# ──────────────────────────── 配置文件生成 ────────────────────────────────────
gen_reality_server_config() {
    info "生成 VLESS + Reality 服务端配置..."
    [[ -z "$UUID$PORT$PRIVATE_KEY$SHORT_ID$DEST" ]] && error "配置参数不完整"
    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "dns": {
    "servers": ["https://1.1.1.1/dns-query", "https://223.5.5.5/dns-query", "8.8.8.8"],
    "queryStrategy": "UseIP"
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "user-default@${REMARK}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:${DEST_PORT}",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": { "sockopt": { "tcpFastOpen": true, "tcpKeepAliveIdle": 30 } }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
    success "VLESS+Reality 配置生成完成"
}

gen_vmess_server_config() {
    info "生成 VMess + TLS + WebSocket 服务端配置..."
    [[ -z "$UUID$PORT$DOMAIN" ]] && error "配置参数不完整"
    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "vmess-ws-tls-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "${UUID}", "alterId": 0, "email": "user-default@${REMARK}" }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess", "headers": { "Host": "${DOMAIN}" } },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ],
          "alpn": ["h2", "http/1.1"],
          "minVersion": "1.2"
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "streamSettings": { "sockopt": { "tcpFastOpen": true } } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
    success "VMess+TLS+WS 配置生成完成"
}

gen_trojan_server_config() {
    info "生成 Trojan + TLS 服务端配置..."
    [[ -z "$UUID$PORT$DOMAIN" ]] && error "配置参数不完整"
    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "trojan-tls-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [
          { "password": "${UUID}", "email": "user-default@${REMARK}" }
        ],
        "fallbacks": [{ "dest": 80 }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ],
          "alpn": ["h2", "http/1.1"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
    success "Trojan+TLS 配置生成完成"
}

gen_ss_server_config() {
    info "生成 Shadowsocks 2022 服务端配置..."
    local SS_KEY; SS_KEY=$(openssl rand -base64 32)
    UUID="$SS_KEY"
    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "tag": "ss-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-256-gcm",
        "password": "${SS_KEY}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
    success "Shadowsocks 2022 配置生成完成"
    info "密码(即Key): $SS_KEY"
}

gen_dual_server_config() {
    info "生成双协议 (VLESS+Reality / VMess+TLS) 配置..."
    [[ -z "$UUID$PORT$PRIVATE_KEY$SHORT_ID$DEST$DOMAIN" ]] && error "配置参数不完整"
    mkdir -p /usr/local/etc/xray
    local VMESS_PORT=$((PORT + 1))
    VMESS_PORT_FINAL=$VMESS_PORT

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "user-default@${REMARK}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${DEST}:${DEST_PORT}",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws-tls-in",
      "listen": "::",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${UUID}", "alterId": 0, "email": "user-default-vmess@${REMARK}" }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess", "headers": { "Host": "${DOMAIN}" } },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "streamSettings": { "sockopt": { "tcpFastOpen": true } } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
    success "双协议配置生成完成"
}


# ──────────────────────────── 多用户管理 ─────────────────────────────────────
list_users() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到配置文件"; return 1; }
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${BLUE}              当前用户列表${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"

    local protocol
    if grep -q "realitySettings" "$XRAY_CONFIG"; then
        protocol="vless"
        echo -e "${YELLOW}协议: VLESS + Reality${NC}\n"
        jq -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[] |
            "  用户: \(.email // "未命名")\n  UUID: \(.id)\n  Flow: \(.flow // "无")\n"' \
            "$XRAY_CONFIG" 2>/dev/null
    elif grep -q '"protocol": "vmess"' "$XRAY_CONFIG"; then
        protocol="vmess"
        echo -e "${YELLOW}协议: VMess + TLS${NC}\n"
        jq -r '.inbounds[] | select(.protocol=="vmess") | .settings.clients[] |
            "  用户: \(.email // "未命名")\n  UUID: \(.id)\n"' \
            "$XRAY_CONFIG" 2>/dev/null
    elif grep -q '"protocol": "trojan"' "$XRAY_CONFIG"; then
        protocol="trojan"
        echo -e "${YELLOW}协议: Trojan + TLS${NC}\n"
        jq -r '.inbounds[] | select(.protocol=="trojan") | .settings.clients[] |
            "  用户: \(.email // "未命名")\n  密码: \(.password)\n"' \
            "$XRAY_CONFIG" 2>/dev/null
    elif grep -q '"protocol": "shadowsocks"' "$XRAY_CONFIG"; then
        echo -e "${YELLOW}协议: Shadowsocks 2022${NC}\n"
        jq -r '.inbounds[] | select(.protocol=="shadowsocks") |
            "  方法: \(.settings.method)\n  密码: \(.settings.password)\n"' \
            "$XRAY_CONFIG" 2>/dev/null
    fi
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
}

add_user() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到配置文件"; return 1; }

    read -p "请输入新用户备注名称: " new_email
    [[ -z "$new_email" ]] && { warn "用户名不能为空"; return 1; }

    local new_uuid; new_uuid=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "生成 UUID: $new_uuid"

    # 判断协议类型
    if grep -q "realitySettings" "$XRAY_CONFIG"; then
        # VLESS Reality
        local new_client="{\"id\": \"$new_uuid\", \"flow\": \"xtls-rprx-vision\", \"email\": \"${new_email}@xray\"}"
        jq --argjson c "$new_client" \
            '(.inbounds[] | select(.protocol=="vless") | .settings.clients) += [$c]' \
            "$XRAY_CONFIG" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$XRAY_CONFIG"

    elif grep -q '"protocol": "vmess"' "$XRAY_CONFIG"; then
        local new_client="{\"id\": \"$new_uuid\", \"alterId\": 0, \"email\": \"${new_email}@xray\"}"
        jq --argjson c "$new_client" \
            '(.inbounds[] | select(.protocol=="vmess") | .settings.clients) += [$c]' \
            "$XRAY_CONFIG" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$XRAY_CONFIG"

    elif grep -q '"protocol": "trojan"' "$XRAY_CONFIG"; then
        local new_pwd; new_pwd=$(openssl rand -hex 16)
        local new_client="{\"password\": \"$new_pwd\", \"email\": \"${new_email}@xray\"}"
        jq --argjson c "$new_client" \
            '(.inbounds[] | select(.protocol=="trojan") | .settings.clients) += [$c]' \
            "$XRAY_CONFIG" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$XRAY_CONFIG"
        info "Trojan 密码: $new_pwd"

    else
        warn "当前协议不支持多用户管理（Shadowsocks 2022 仅单密码）"
        return 1
    fi

    xray run -test -config "$XRAY_CONFIG" > /dev/null 2>&1 || {
        warn "配置验证失败，已回滚"; git checkout "$XRAY_CONFIG" 2>/dev/null; return 1
    }
    systemctl reload xray 2>/dev/null || systemctl restart xray
    success "用户 ${new_email} 已添加，UUID: $new_uuid"
}

delete_user() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到配置文件"; return 1; }
    list_users

    read -p "请输入要删除的用户 email (精确匹配): " del_email
    [[ -z "$del_email" ]] && return

    local count; count=$(jq '[.. | objects | select(has("email")) | select(.email | contains("'"$del_email"'"))] | length' "$XRAY_CONFIG" 2>/dev/null)
    [[ "$count" -eq 0 ]] && { warn "未找到用户: $del_email"; return 1; }

    # 不允许删除最后一个用户
    local total; total=$(jq '[.inbounds[].settings.clients // [] | .[]] | length' "$XRAY_CONFIG" 2>/dev/null)
    [[ "$total" -le 1 ]] && { warn "至少保留一个用户，无法删除"; return 1; }

    read -p "确认删除用户 $del_email ? [y/N]: " confirm
    [[ "$confirm" != "y" ]] && return

    jq 'del(.. | objects | select(has("email")) | select(.email | contains("'"$del_email"'")))' \
        "$XRAY_CONFIG" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$XRAY_CONFIG"

    systemctl reload xray 2>/dev/null || systemctl restart xray
    success "用户 $del_email 已删除"
}

manage_users() {
    echo ""
    echo -e "${PURPLE}═══════════════════════════════${NC}"
    echo -e "${PURPLE}         多用户管理${NC}"
    echo -e "${PURPLE}═══════════════════════════════${NC}"
    echo -e "  ${GREEN}1${NC}. 查看所有用户"
    echo -e "  ${GREEN}2${NC}. 添加用户"
    echo -e "  ${GREEN}3${NC}. 删除用户"
    echo -e "  ${GREEN}4${NC}. 返回"
    read -p "请选择: " choice

    case $choice in
        1) list_users ;;
        2) add_user ;;
        3) delete_user ;;
        4) return ;;
        *) warn "无效选项" ;;
    esac
}

# ──────────────────────────── 流量统计 ───────────────────────────────────────
format_bytes() {
    local bytes=$1
    if   [[ $bytes -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824" | bc)"
    elif [[ $bytes -ge 1048576    ]]; then printf "%.2f MB" "$(echo "scale=2; $bytes/1048576"    | bc)"
    elif [[ $bytes -ge 1024       ]]; then printf "%.2f KB" "$(echo "scale=2; $bytes/1024"       | bc)"
    else printf "%d B" "$bytes"
    fi
}

view_traffic() {
    step "流量统计"

    # 检查 API 端口
    if ! ss -tuln | grep -q ":10085 "; then
        warn "Xray API 未启用（仅 VLESS/VMess/Trojan 支持流量统计）"
        return 1
    fi

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              Xray 流量统计 (累计)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    # 查询入站流量
    local uplink downlink
    local inbound_tags; inbound_tags=$(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null | grep -v "api")

    for tag in $inbound_tags; do
        uplink=$(xray api statsquery --server=127.0.0.1:10085 \
            -pattern "inbound>>>${tag}>>>traffic>>>uplink" 2>/dev/null \
            | grep -oP '(?<=value: )\d+' | head -1 || echo "0")
        downlink=$(xray api statsquery --server=127.0.0.1:10085 \
            -pattern "inbound>>>${tag}>>>traffic>>>downlink" 2>/dev/null \
            | grep -oP '(?<=value: )\d+' | head -1 || echo "0")
        echo -e "${YELLOW}[$tag]${NC}"
        echo -e "  上传: $(format_bytes ${uplink:-0})   下载: $(format_bytes ${downlink:-0})"
    done

    echo ""
    echo -e "${YELLOW}各用户流量:${NC}"
    # 查询用户流量
    xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" 2>/dev/null | \
        grep -E "(name|value)" | paste - - | \
        awk '{gsub(/name: "|"/, "", $2); gsub(/value: /, "", $4);
              printf "  %-40s  %s\n", $2, $4}' | head -30 || \
        echo "  暂无用户流量数据"

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    tip "流量数据为 Xray 启动后累计值，重启服务后清零"
}

# ──────────────────────────── 系统监控 ───────────────────────────────────────
view_system_status() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                  系统状态监控${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    # Xray 服务状态
    if systemctl is-active --quiet xray; then
        echo -e "  ${YELLOW}Xray 状态:${NC}    ${GREEN}● 运行中${NC}"
    else
        echo -e "  ${YELLOW}Xray 状态:${NC}    ${RED}● 已停止${NC}"
    fi

    # 版本
    echo -e "  ${YELLOW}Xray 版本:${NC}    $(xray version 2>/dev/null | grep -oP 'Xray \S+' | head -1 || echo '未知')"

    # 运行时长
    local uptime_str; uptime_str=$(systemctl show xray --property=ActiveEnterTimestamp \
        | cut -d= -f2 | xargs -I{} date -d {} +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "未知")
    echo -e "  ${YELLOW}启动时间:${NC}    $uptime_str"

    echo ""
    # CPU 负载
    echo -e "  ${YELLOW}CPU 负载:${NC}     $(uptime | awk -F'load average:' '{print $2}' | xargs)"
    # 内存
    local mem_info; mem_info=$(free -h | awk 'NR==2{printf "已用 %s / 总计 %s (%.1f%%)", $3, $2, $3/$2*100}')
    echo -e "  ${YELLOW}内存使用:${NC}     $mem_info"
    # 磁盘
    local disk_info; disk_info=$(df -h / | awk 'NR==2{printf "已用 %s / 总计 %s (%s)", $3, $2, $5}')
    echo -e "  ${YELLOW}磁盘使用:${NC}     $disk_info"
    # 网络连接数
    local conn_count; conn_count=$(ss -tn state established | wc -l)
    echo -e "  ${YELLOW}TCP 连接数:${NC}   $((conn_count - 1))"

    echo ""
    # BBR 状态
    check_bbr_status && \
        echo -e "  ${YELLOW}BBR 加速:${NC}     ${GREEN}已开启${NC}" || \
        echo -e "  ${YELLOW}BBR 加速:${NC}     ${RED}未开启${NC}"

    # 监听端口
    echo -e "  ${YELLOW}监听端口:${NC}     $(ss -tuln | grep xray | awk '{print $5}' | grep -oP ':\K\d+' | tr '\n' ' ')"

    # 证书状态（如有域名）
    if [[ -n "$DOMAIN" && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        local expiry; expiry=$(openssl x509 -enddate -noout \
            -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>/dev/null \
            | cut -d= -f2)
        echo -e "  ${YELLOW}证书到期:${NC}     $expiry"
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

# ──────────────────────────── 链接生成 ───────────────────────────────────────
gen_vless_reality_link() {
    [[ -z "$UUID$SERVER_IP$PORT$DEST$PUBLIC_KEY$SHORT_ID" ]] && { warn "VLESS 链接参数不完整"; VLESS_LINK=""; return 1; }
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&xver=0#${REMARK}"
}

gen_vmess_link() {
    local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
    [[ -z "$UUID$DOMAIN$PORT_USE" ]] && { warn "VMess 链接参数不完整"; VMESS_LINK=""; return 1; }
    local j="{\"v\":\"2\",\"ps\":\"${REMARK}-VMess\",\"add\":\"${DOMAIN}\",\"port\":\"${PORT_USE}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess\",\"tls\":\"tls\"}"
    VMESS_LINK="vmess://$(echo -n "$j" | base64 -w 0)"
}

gen_trojan_link() {
    [[ -z "$UUID$DOMAIN$PORT" ]] && { warn "Trojan 链接参数不完整"; TROJAN_LINK=""; return 1; }
    TROJAN_LINK="trojan://${UUID}@${DOMAIN}:${PORT}?security=tls&sni=${DOMAIN}&type=tcp#${REMARK}-Trojan"
}

gen_ss_link() {
    [[ -z "$UUID$SERVER_IP$PORT" ]] && { warn "SS 链接参数不完整"; SS_LINK=""; return 1; }
    local METHOD="2022-blake3-aes-256-gcm"
    local encoded; encoded=$(echo -n "${METHOD}:${UUID}" | base64 -w 0)
    SS_LINK="ss://${encoded}@${SERVER_IP}:${PORT}#${REMARK}-SS2022"
}

# 输出二维码与节点信息
gen_qrcode() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                 客户端节点信息${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    case $PROTOCOL_CHOICE in
        1)
            gen_vless_reality_link || { warn "VLESS 链接生成失败"; return 1; }
            echo -e "\n${GREEN}【VLESS + Reality + Vision】${NC}"
            echo -e "${YELLOW}节点链接:${NC}\n${GREEN}${VLESS_LINK}${NC}\n"
            echo -e "${YELLOW}节点二维码:${NC}"
            qrencode -t ANSIUTF8 "$VLESS_LINK"
            ;;
        2)
            gen_vmess_link || { warn "VMess 链接生成失败"; return 1; }
            echo -e "\n${GREEN}【VMess + TLS + WebSocket】${NC}"
            echo -e "${YELLOW}节点链接:${NC}\n${GREEN}${VMESS_LINK}${NC}\n"
            qrencode -t ANSIUTF8 "$VMESS_LINK"
            ;;
        3)
            gen_trojan_link || { warn "Trojan 链接生成失败"; return 1; }
            echo -e "\n${GREEN}【Trojan + TLS】${NC}"
            echo -e "${YELLOW}节点链接:${NC}\n${GREEN}${TROJAN_LINK}${NC}\n"
            qrencode -t ANSIUTF8 "$TROJAN_LINK"
            ;;
        4)
            gen_ss_link || { warn "SS 链接生成失败"; return 1; }
            echo -e "\n${GREEN}【Shadowsocks 2022】${NC}"
            echo -e "${YELLOW}密码(Key):${NC} $UUID"
            echo -e "${YELLOW}方法:${NC}      2022-blake3-aes-256-gcm"
            echo -e "${YELLOW}节点链接:${NC}\n${GREEN}${SS_LINK}${NC}\n"
            qrencode -t ANSIUTF8 "$SS_LINK"
            ;;
        5)
            gen_vless_reality_link
            gen_vmess_link
            [[ -n "$VLESS_LINK" ]] && {
                echo -e "\n${GREEN}【VLESS + Reality】(端口 ${PORT})${NC}"
                echo -e "${YELLOW}节点链接:${NC}\n${VLESS_LINK}\n"
                qrencode -t ANSIUTF8 "$VLESS_LINK"
            }
            [[ -n "$VMESS_LINK" ]] && {
                echo -e "\n${GREEN}【VMess + TLS】(端口 ${VMESS_PORT_FINAL})${NC}"
                echo -e "${YELLOW}节点链接:${NC}\n${VMESS_LINK}\n"
                qrencode -t ANSIUTF8 "$VMESS_LINK"
            }
            ;;
    esac
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}


# ──────────────────────────── 客户端 JSON 配置输出 ────────────────────────────
gen_client_config() {
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}               客户端 JSON 配置参考${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════${NC}"

    case $PROTOCOL_CHOICE in
        1|5)
            [[ -z "$SERVER_IP$PORT$UUID$PUBLIC_KEY$SHORT_ID$DEST" ]] && { warn "参数不完整"; return; }
            echo -e "${GREEN}【VLESS + Reality 客户端配置】${NC}"
            cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http",  "port": 10809, "protocol": "http" }
  ],
  "outbounds": [{
    "tag": "proxy",
    "protocol": "vless",
    "settings": {
      "vnext": [{ "address": "${SERVER_IP}", "port": ${PORT}, "users": [
        { "id": "${UUID}", "flow": "xtls-rprx-vision", "encryption": "none" }
      ]}]
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "fingerprint": "${FINGERPRINT}",
        "serverName": "${DEST}",
        "publicKey": "${PUBLIC_KEY}",
        "shortId": "${SHORT_ID}"
      }
    }
  }, { "tag": "direct", "protocol": "freedom" }]
}
EOF
            ;;
        2)
            [[ -z "$DOMAIN$PORT$UUID" ]] && { warn "参数不完整"; return; }
            echo -e "${GREEN}【VMess + TLS 客户端配置】${NC}"
            cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http",  "port": 10809, "protocol": "http" }
  ],
  "outbounds": [{
    "tag": "proxy",
    "protocol": "vmess",
    "settings": {
      "vnext": [{ "address": "${DOMAIN}", "port": ${PORT}, "users": [
        { "id": "${UUID}", "alterId": 0, "security": "auto" }
      ]}]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "/vmess", "headers": { "Host": "${DOMAIN}" } },
      "security": "tls",
      "tlsSettings": { "serverName": "${DOMAIN}", "fingerprint": "chrome" }
    }
  }, { "tag": "direct", "protocol": "freedom" }]
}
EOF
            ;;
        3)
            [[ -z "$DOMAIN$PORT$UUID" ]] && { warn "参数不完整"; return; }
            echo -e "${GREEN}【Trojan + TLS 客户端配置】${NC}"
            cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [{
    "tag": "proxy",
    "protocol": "trojan",
    "settings": {
      "servers": [{ "address": "${DOMAIN}", "port": ${PORT}, "password": "${UUID}" }]
    },
    "streamSettings": {
      "network": "tcp", "security": "tls",
      "tlsSettings": { "serverName": "${DOMAIN}" }
    }
  }, { "tag": "direct", "protocol": "freedom" }]
}
EOF
            ;;
        4)
            echo -e "${GREEN}【Shadowsocks 2022 连接信息】${NC}"
            echo -e "  服务器: $SERVER_IP"
            echo -e "  端口:   $PORT"
            echo -e "  方法:   2022-blake3-aes-256-gcm"
            echo -e "  密码:   $UUID"
            ;;
    esac
    echo -e "${PURPLE}═══════════════════════════════════════════════════${NC}"
}

# ──────────────────────────── 配置文件保存 ───────────────────────────────────
save_config() {
    cat > "$CLIENT_FILE" << EOF
==========================================
      Xray 节点配置信息 v${SCRIPT_VERSION}
==========================================
生成时间: $(date "+%Y-%m-%d %H:%M:%S")
服务器IP: ${SERVER_IP}
域名:     ${DOMAIN:-无需域名}
UUID:     ${UUID}
协议选择: ${PROTOCOL_CHOICE}
==========================================
EOF

    case $PROTOCOL_CHOICE in
        1|5)
            cat >> "$CLIENT_FILE" << EOF

【VLESS + Reality + Vision】
监听端口:   ${PORT}
回落目标:   ${DEST}:${DEST_PORT}
服务端Key:  ${PRIVATE_KEY}
客户端Key:  ${PUBLIC_KEY}
Short ID:   ${SHORT_ID}
TLS 指纹:   ${FINGERPRINT}

节点链接:
${VLESS_LINK:-生成失败}

EOF
            ;;&
        5)
            cat >> "$CLIENT_FILE" << EOF
【VMess + TLS + WebSocket】
监听端口:   ${VMESS_PORT_FINAL}
WS 路径:    /vmess

节点链接:
${VMESS_LINK:-生成失败}

EOF
            ;;
        2)
            cat >> "$CLIENT_FILE" << EOF

【VMess + TLS + WebSocket】
监听端口:   ${PORT}
WS 路径:    /vmess

节点链接:
${VMESS_LINK:-生成失败}

EOF
            ;;
        3)
            cat >> "$CLIENT_FILE" << EOF

【Trojan + TLS】
监听端口:   ${PORT}

节点链接:
${TROJAN_LINK:-生成失败}

EOF
            ;;
        4)
            cat >> "$CLIENT_FILE" << EOF

【Shadowsocks 2022】
监听端口:   ${PORT}
方法:       2022-blake3-aes-256-gcm
密码(Key):  ${UUID}

节点链接:
${SS_LINK:-生成失败}

EOF
            ;;
    esac

    local tcp_algo; tcp_algo=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    cat >> "$CLIENT_FILE" << EOF
【系统状态】
TCP 算法:   ${tcp_algo}
==========================================
EOF
    info "配置已保存至: $CLIENT_FILE"
}

# ──────────────────────────── 查看配置 ───────────────────────────────────────
view_config() {
    if [[ ! -f "$CLIENT_FILE" ]]; then
        warn "未找到配置文件，请先完成安装"; return 1
    fi

    cat "$CLIENT_FILE"
    echo ""
    read -p "是否显示节点二维码? [y/N]: " show_qr
    if [[ "$show_qr" == "y" || "$show_qr" == "Y" ]]; then
        # 提取各类链接并显示二维码
        local vless_link vmess_link trojan_link ss_link
        vless_link=$(grep  "^vless://"  "$CLIENT_FILE" | head -1)
        vmess_link=$(grep  "^vmess://"  "$CLIENT_FILE" | head -1)
        trojan_link=$(grep "^trojan://" "$CLIENT_FILE" | head -1)
        ss_link=$(grep     "^ss://"     "$CLIENT_FILE" | head -1)

        [[ -n "$vless_link"  ]] && { echo -e "\n${GREEN}VLESS 二维码:${NC}";  qrencode -t ANSIUTF8 "$vless_link";  }
        [[ -n "$vmess_link"  ]] && { echo -e "\n${GREEN}VMess 二维码:${NC}";  qrencode -t ANSIUTF8 "$vmess_link";  }
        [[ -n "$trojan_link" ]] && { echo -e "\n${GREEN}Trojan 二维码:${NC}"; qrencode -t ANSIUTF8 "$trojan_link"; }
        [[ -n "$ss_link"     ]] && { echo -e "\n${GREEN}SS 二维码:${NC}";     qrencode -t ANSIUTF8 "$ss_link";     }
    fi
}

# ──────────────────────────── 日志查看 ───────────────────────────────────────
view_logs() {
    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════${NC}"
    echo -e "${PURPLE}  ${GREEN}1${NC}. 实时日志 (journalctl, Ctrl+C 退出)"
    echo -e "${PURPLE}  ${GREEN}2${NC}. 最近 50 条日志"
    echo -e "${PURPLE}  ${GREEN}3${NC}. 访问日志 (access.log)"
    echo -e "${PURPLE}  ${GREEN}4${NC}. 错误日志 (error.log)"
    echo -e "${PURPLE}  ${GREEN}5${NC}. 清空日志文件"
    echo -e "${PURPLE}═══════════════════════════════════════${NC}"
    read -p "请选择: " log_choice

    case $log_choice in
        1) journalctl -u xray -f ;;
        2) journalctl -u xray --no-pager -n 50 ;;
        3) [[ -f "$XRAY_LOG_DIR/access.log" ]] && tail -n 50 "$XRAY_LOG_DIR/access.log" || warn "访问日志不存在" ;;
        4) [[ -f "$XRAY_LOG_DIR/error.log"  ]] && tail -n 50 "$XRAY_LOG_DIR/error.log"  || warn "错误日志不存在" ;;
        5)
            read -p "确认清空日志? [y/N]: " c
            [[ "$c" == "y" ]] && {
                > "$XRAY_LOG_DIR/access.log" 2>/dev/null
                > "$XRAY_LOG_DIR/error.log"  2>/dev/null
                success "日志已清空"
            }
            ;;
    esac
}

# ──────────────────────────── 查看当前部署信息 ───────────────────────────────
view_current_deploy() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到 Xray 配置文件"; return 1; }
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                  当前部署信息${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    local CONFIG; CONFIG=$(cat "$XRAY_CONFIG")
    local PORTS; PORTS=$(echo "$CONFIG" | grep -o '"port": [0-9]*' | grep -o '[0-9]*' | tr '\n' ' ')
    echo -e "${YELLOW}监听端口:${NC}  $PORTS"

    if echo "$CONFIG" | grep -q "realitySettings"; then
        echo -e "${YELLOW}核心协议:${NC}  VLESS + Reality + Vision"
    elif echo "$CONFIG" | grep -q '"protocol": "trojan"'; then
        echo -e "${YELLOW}核心协议:${NC}  Trojan + TLS"
    elif echo "$CONFIG" | grep -q '"protocol": "vmess"'; then
        echo -e "${YELLOW}核心协议:${NC}  VMess + TLS + WebSocket"
    elif echo "$CONFIG" | grep -q '"protocol": "shadowsocks"'; then
        echo -e "${YELLOW}核心协议:${NC}  Shadowsocks 2022"
    else
        echo -e "${YELLOW}核心协议:${NC}  混合/其他协议"
    fi

    local user_count; user_count=$(jq '[.inbounds[].settings.clients // [] | .[]] | length' "$XRAY_CONFIG" 2>/dev/null)
    echo -e "${YELLOW}用户数量:${NC}  ${user_count:-0}"

    systemctl is-active --quiet xray \
        && echo -e "${YELLOW}服务状态:${NC}  ${GREEN}● 运行中${NC}" \
        || echo -e "${YELLOW}服务状态:${NC}  ${RED}● 已停止${NC}"

    echo -e "${YELLOW}Xray 版本:${NC} $(xray version 2>/dev/null | grep -oP 'Xray \S+' | head -1 || echo '未知')"
    [[ -f "$CLIENT_FILE" ]] && echo -e "${YELLOW}配置时间:${NC}  $(grep '生成时间' "$CLIENT_FILE" | cut -d: -f2-)"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

# ──────────────────────────── 卸载 ───────────────────────────────────────────
uninstall() {
    echo ""
    warn "即将完全卸载 Xray，包括配置文件和日志"
    read -p "确认卸载? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    # 卸载前备份
    backup_config "pre-uninstall"

    info "停止并禁用 Xray 服务..."
    systemctl disable --now xray 2>/dev/null

    info "清理文件..."
    rm -f /etc/systemd/system/xray.service
    rm -rf "$XRAY_BIN" /usr/local/etc/xray "$XRAY_LOG_DIR" /usr/local/share/xray
    rm -f "$CLIENT_FILE" "$STATS_FILE"
    systemctl daemon-reload

    read -p "是否同时删除 SSL 证书? [y/N]: " del_cert
    if [[ "$del_cert" == "y" ]]; then
        local domain_list; domain_list=$(ls /etc/letsencrypt/live/ 2>/dev/null)
        if [[ -n "$domain_list" ]]; then
            echo "证书目录列表:"
            echo "$domain_list"
            read -p "输入要删除证书的域名 (留空跳过): " del_domain
            [[ -n "$del_domain" ]] && {
                rm -rf "/etc/letsencrypt/live/$del_domain" \
                       "/etc/letsencrypt/archive/$del_domain" \
                       "/etc/letsencrypt/renewal/$del_domain.conf"
                success "证书已删除"
            }
        fi
    fi

    # 清除防火墙中 Xray 相关规则（只清 iptables，ufw/firewalld 规则可能混入其他用途端口不自动删）
    info "如有需要，请手动清理防火墙规则"
    success "Xray 已完全卸载，配置备份位于: $BACKUP_DIR"
}

# ──────────────────────────── 重新部署 ───────────────────────────────────────
redeploy_xray() {
    warn "重新部署将覆盖当前所有配置"
    view_current_deploy
    backup_config "pre-redeploy"

    echo ""
    echo -e "${PURPLE}════════════════════════════${NC}"
    echo -e "${PURPLE}       重新部署选项${NC}"
    echo -e "${PURPLE}════════════════════════════${NC}"
    echo -e "  ${GREEN}1${NC}. 保留当前 UUID，更新其他配置"
    echo -e "  ${GREEN}2${NC}. 全部重新生成（包括 UUID）"
    echo -e "  ${GREEN}3${NC}. 仅更新 Reality 密钥"
    echo -e "  ${GREEN}4${NC}. 仅更换监听端口"
    echo -e "  ${GREEN}5${NC}. 返回"
    echo -e "${PURPLE}════════════════════════════${NC}"
    read -p "请选择 [默认 1]: " c; c=${c:-1}

    case $c in
        1)
            if [[ -f "$CLIENT_FILE" ]]; then
                UUID=$(grep "^UUID:" "$CLIENT_FILE" | awk '{print $2}')
            fi
            UUID=${UUID:-$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
            _redeploy_common
            ;;
        2) UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid); _redeploy_common ;;
        3) _redeploy_update_keys ;;
        4) _redeploy_change_port ;;
        5) return ;;
        *) warn "无效选择" ;;
    esac
}

_redeploy_common() {
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器公网 IP: $SERVER_IP"
    select_protocol

    read -p "请输入监听端口 [默认 443]: " PORT;  PORT=${PORT:-443}
    read -p "请输入节点备注名称 [默认 xray]: " REMARK; REMARK=${REMARK:-xray}

    if [[ "$PROTOCOL_CHOICE" =~ ^(2|3|5)$ ]]; then
        read -p "请输入域名: " DOMAIN; [[ -z "$DOMAIN" ]] && error "此协议必须提供域名"
    else
        DOMAIN=""
    fi

    [[ "$PROTOCOL_CHOICE" =~ ^(1|5)$ ]] && get_reality_input
    get_cert

    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config   ;;
        3) gen_trojan_server_config  ;;
        4) gen_ss_server_config      ;;
        5) gen_dual_server_config    ;;
    esac

    open_port "$PORT" tcp
    [[ -n "$VMESS_PORT_FINAL" ]] && open_port "$VMESS_PORT_FINAL" tcp
    restart_and_show
    setup_cert_renewal
}

_redeploy_update_keys() {
    grep -q "realitySettings" "$XRAY_CONFIG" 2>/dev/null || error "当前配置非 Reality 协议"
    [[ -f "$CLIENT_FILE" ]] && {
        UUID=$(grep "^UUID:" "$CLIENT_FILE" | awk '{print $2}')
        PORT=$(grep "监听端口:" "$CLIENT_FILE" | head -1 | awk '{print $2}')
        DEST=$(grep "回落目标:" "$CLIENT_FILE" | awk -F: '{print $2}' | sed 's/:.*//' | tr -d ' ')
    }
    UUID=${UUID:-$(xray uuid)}; PORT=${PORT:-443}
    DEST=${DEST:-"www.microsoft.com"}; DEST_PORT=443; FINGERPRINT="chrome"
    PROTOCOL_CHOICE=1; REMARK="xray"
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)

    generate_reality_keys_once
    SHORT_ID=$(openssl rand -hex 8)
    gen_reality_server_config
    restart_and_show
}

_redeploy_change_port() {
    local OLD_PORT; OLD_PORT=$(grep -o '"port": [0-9]*' "$XRAY_CONFIG" | head -1 | grep -o '[0-9]*')
    info "当前监听端口: $OLD_PORT"
    read -p "请输入新端口: " NEW_PORT
    [[ -z "$NEW_PORT" ]] && { warn "端口不能为空"; return; }

    ss -tuln | grep -q ":${NEW_PORT} " && {
        warn "端口 $NEW_PORT 已被占用"
        read -p "强制继续? [y/N]: " fc; [[ "$fc" != "y" ]] && return
    }

    sed -i "0,/\"port\": ${OLD_PORT}/s/\"port\": ${OLD_PORT}/\"port\": ${NEW_PORT}/" "$XRAY_CONFIG"
    close_port "$OLD_PORT" tcp
    open_port "$NEW_PORT" tcp
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray && success "端口已更新为 $NEW_PORT" || warn "重启失败，请检查日志"
}



# ══════════════════════════════════════════════════════════════════════════════
#  VLESS 中转 / Socks5 模块  v3
#
#  支持的拓扑：
#    ① 端口映射模式：每个 Socks5 对应一个独立 VLESS 入站端口
#       客户端连 :10001 → socks5-A，连 :10002 → socks5-B，以此类推
#
#    ② 用户映射模式：单端口 VLESS 入站，不同 UUID → 不同 Socks5 出口
#       用户A 的流量 → socks5-A，用户B → socks5-B
#
#    ③ 本机 Socks5 代理：直接开放 Socks5 端口，支持多账号
#
#  所有 VLESS 用户均带 email，可对接流量限额模块
# ══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────── 公共：入站安全配置 ───────────────────────────────
# 收集 Reality / TLS / 无加密 参数
# 结果写入全局变量 _IN_SEC / _IN_STREAM / _IN_PUBKEY / _IN_SHORTID /
#                  _IN_PRIVKEY / _IN_DEST / _IN_DOMAIN
_collect_inbound_security() {
    _IN_SEC="" _IN_STREAM="" _IN_PUBKEY="" _IN_SHORTID=""
    _IN_PRIVKEY="" _IN_DEST="www.microsoft.com" _IN_DOMAIN=""

    echo -e "\n${YELLOW}入站安全方式:${NC}"
    echo -e "  ${GREEN}1${NC}. Reality（推荐，无需域名）"
    echo -e "  ${GREEN}2${NC}. TLS（需要证书域名）"
    echo -e "  ${GREEN}3${NC}. 无加密（仅内网/受信任环境）"
    read -p "请选择 [默认 1]: " _IN_SEC; _IN_SEC=${_IN_SEC:-1}

    case $_IN_SEC in
        1)
            generate_reality_keys_once
            _IN_PRIVKEY=$PRIVATE_KEY
            _IN_PUBKEY=$PUBLIC_KEY
            _IN_SHORTID=$(openssl rand -hex 8)
            _IN_STREAM=$(python3 -c "
import json
print(json.dumps({
    'network': 'tcp',
    'security': 'reality',
    'realitySettings': {
        'show': False,
        'dest': '${_IN_DEST}:443',
        'serverNames': ['${_IN_DEST}'],
        'privateKey': '${_IN_PRIVKEY}',
        'shortIds': ['${_IN_SHORTID}', '']
    }
}))
")
            ;;
        2)
            read -p "请输入证书域名: " _IN_DOMAIN
            [[ -z "$_IN_DOMAIN" ]] && { warn "TLS 模式需要域名"; return 1; }
            DOMAIN=$_IN_DOMAIN; get_cert
            _IN_STREAM=$(python3 -c "
import json
print(json.dumps({
    'network': 'tcp',
    'security': 'tls',
    'tlsSettings': {
        'certificates': [{
            'certificateFile': '/etc/letsencrypt/live/${_IN_DOMAIN}/fullchain.pem',
            'keyFile': '/etc/letsencrypt/live/${_IN_DOMAIN}/privkey.pem'
        }]
    }
}))
")
            ;;
        3)
            _IN_STREAM='{"network":"tcp"}'
            ;;
        *)
            warn "无效选择，使用默认 Reality"; _IN_SEC=1
            _collect_inbound_security; return
            ;;
    esac
}

# ─────────────────────────── 公共：生成并验证 config ─────────────────────────
# 用 python3 把配置字典序列化为 JSON 写到 XRAY_CONFIG，然后 xray -test 验证
# 用法：_write_and_verify_config <python3_config_expr>
#   python3_config_expr 是一段 Python 表达式，值为 dict
_write_and_verify_config() {
    local py_expr="$1"
    python3 - << PYEOF
import json, sys
config = ${py_expr}
with open("${XRAY_CONFIG}", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print("[python3] config.json 写入成功")
PYEOF
    local rc=$?
    [[ $rc -ne 0 ]] && { error "python3 生成配置失败"; return 1; }

    info "验证配置文件..."
    local test_out; test_out=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}配置内容:${NC}"
        cat "$XRAY_CONFIG"
        error "xray 配置验证失败:\n${test_out}"
    fi
    success "配置验证通过"
}

# ─────────────────────────── 公共：启动服务 ──────────────────────────────────
_start_relay_service() {
    local ports=("$@")
    create_systemd_service
    for p in "${ports[@]}"; do
        open_port "$p" tcp
        open_port "$p" udp
    done
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray \
        && success "Xray 服务启动成功" \
        || error "服务启动失败，请执行 journalctl -u xray -n 50 查看日志"
}

# ─────────────────────────── ① 端口映射模式 ──────────────────────────────────
#
#  每条 Socks5 绑定一个独立的 VLESS 入站端口
#  客户端只需改端口即可切换落地 IP，配置简单
#  拓扑：
#    client → 本机:PORT_1(VLESS+Reality) → socks5-ip1:port1
#    client → 本机:PORT_2(VLESS+Reality) → socks5-ip2:port2
#    ...

gen_relay_port_mapping() {
    step "端口映射模式：每个端口对应一个 Socks5 出口"
    echo -e "${DIM}每个 Socks5 绑定独立 VLESS 端口，切换端口即切换落地 IP${NC}\n"

    # ── 入站安全（所有端口共用同一套 Reality/TLS 配置）────────────────────────
    _collect_inbound_security || return 1

    # ── 收集 Socks5 → 端口 映射关系 ─────────────────────────────────────────
    local -a MAPPING_LIST=()   # 格式: "vless_port|s5_addr|s5_port|s5_user|s5_pass|email"
    local entry_count=0
    local base_port=10001

    echo -e "\n${YELLOW}依次添加 Socks5 映射（直接回车结束）:${NC}"
    echo -e "${DIM}每条映射 = 一个 VLESS 入站端口 + 一个 Socks5 出口${NC}\n"

    while true; do
        entry_count=$((entry_count + 1))
        echo -e "  ${GREEN}▶ 映射 #${entry_count}${NC}"

        read -p "  Socks5 地址（留空结束）: " s5_addr
        [[ -z "$s5_addr" ]] && { entry_count=$((entry_count - 1)); break; }

        read -p "  Socks5 端口 [默认 1080]: " s5_port
        s5_port=${s5_port:-1080}

        read -p "  Socks5 用户名（无认证留空）: " s5_user
        local s5_pass=""
        [[ -n "$s5_user" ]] && read -p "  Socks5 密码: " s5_pass

        read -p "  VLESS 入站端口 [默认 $((base_port + entry_count - 1))]: " vless_port
        vless_port=${vless_port:-$((base_port + entry_count - 1))}

        read -p "  用户备注名 [默认 user${entry_count}]: " uname
        uname=${uname:-user${entry_count}}
        local email="${uname}@relay"

        MAPPING_LIST+=("${vless_port}|${s5_addr}|${s5_port}|${s5_user}|${s5_pass}|${email}")
        success "  映射 #${entry_count}: VLESS:${vless_port} → ${s5_addr}:${s5_port}  用户: ${email}"
        echo ""
    done

    [[ $entry_count -eq 0 ]] && { warn "至少需要添加一条映射"; return 1; }

    # ── 用 python3 生成完整 config ────────────────────────────────────────────
    mkdir -p /usr/local/etc/xray

    # 把 MAPPING_LIST 拼成 python 赋值语句
    local py_mappings="mappings = [\n"
    for item in "${MAPPING_LIST[@]}"; do
        IFS='|' read -r vp sa sp su spw em <<< "$item"
        py_mappings+="    {'vless_port':${vp},'s5_addr':'${sa}','s5_port':${sp},'s5_user':'${su}','s5_pass':'${spw}','email':'${em}'},\n"
    done
    py_mappings+="]\n"

    python3 - << PYEOF
import json

stream_settings = ${_IN_STREAM}

$(printf "%b" "$py_mappings")

inbounds = [
    {"tag":"api-in","listen":"127.0.0.1","port":10085,
     "protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}
]
outbounds = []
rules = [
    {"type":"field","inboundTag":["api-in"],"outboundTag":"api"},
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"}
]

for m in mappings:
    vp   = m['vless_port']
    tag_in  = f"vless-in-{vp}"
    tag_out = f"socks5-out-{vp}"
    email   = m['email']

    # VLESS 入站
    inbounds.append({
        "tag": tag_in,
        "listen": "::",
        "port": vp,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": __import__('uuid').uuid4().__str__(),
                         "flow": "xtls-rprx-vision",
                         "email": email}],
            "decryption": "none"
        },
        "streamSettings": stream_settings,
        "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
    })

    # Socks5 出站
    server = {"address": m['s5_addr'], "port": m['s5_port'], "udp": True}
    if m['s5_user']:
        server["user"] = m['s5_user']
        server["pass"] = m['s5_pass']
    outbounds.append({
        "tag": tag_out,
        "protocol": "socks",
        "settings": {"servers": [server]}
    })

    # 路由规则：该入站 → 对应出站
    rules.append({
        "type": "field",
        "inboundTag": [tag_in],
        "outboundTag": tag_out
    })

outbounds += [
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}
]

config = {
    "log": {"loglevel":"warning",
            "access":"${XRAY_LOG_DIR}/access.log",
            "error":"${XRAY_LOG_DIR}/error.log"},
    "stats": {},
    "api": {"tag":"api","services":["StatsService"]},
    "policy": {
        "levels": {"0":{"statsUserUplink":True,"statsUserDownlink":True}},
        "system": {"statsInboundUplink":True,"statsInboundDownlink":True}
    },
    "inbounds":  inbounds,
    "outbounds": outbounds,
    "routing": {"domainStrategy":"IPIfNonMatch","rules": rules}
}

# 把实际生成的 UUID 写回临时文件供 bash 读取
uuid_map = {}
for ib in config['inbounds']:
    if ib['protocol'] == 'vless':
        uid  = ib['settings']['clients'][0]['id']
        port = ib['port']
        email= ib['settings']['clients'][0]['email']
        uuid_map[str(port)] = {'uuid': uid, 'email': email}

with open('${XRAY_CONFIG}', 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

import os, json as _j
with open('/tmp/_xray_uuid_map.json','w') as f:
    _j.dump(uuid_map, f)

print("[python3] config.json 生成成功")
PYEOF

    [[ $? -ne 0 ]] && { error "python3 生成配置失败"; return 1; }

    info "验证配置..."
    local test_out; test_out=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}── xray 验证错误 ──${NC}"
        echo "$test_out"
        error "配置验证失败，请检查上方错误信息"
    fi

    # ── 启动服务 ──────────────────────────────────────────────────────────────
    local all_ports=()
    for item in "${MAPPING_LIST[@]}"; do
        all_ports+=("$(echo "$item" | cut -d'|' -f1)")
    done
    _start_relay_service "${all_ports[@]}"

    # ── 展示结果 ──────────────────────────────────────────────────────────────
    local PUB_IP; PUB_IP=$(curl -s4 --max-time 5 ip.sb || curl -s6 ip.sb)

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║               端口映射模式 — 节点信息                        ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  服务器 IP: ${CYAN}${PUB_IP}${NC}"
    [[ "$_IN_SEC" == "1" ]] && {
        echo -e "${BLUE}║${NC}  PublicKey:  ${CYAN}${_IN_PUBKEY}${NC}"
        echo -e "${BLUE}║${NC}  ShortId:    ${CYAN}${_IN_SHORTID}${NC}"
        echo -e "${BLUE}║${NC}  SNI:        ${CYAN}${_IN_DEST}${NC}"
    }
    [[ "$_IN_SEC" == "2" ]] && echo -e "${BLUE}║${NC}  域名: ${CYAN}${_IN_DOMAIN}${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC}  %-8s  %-36s  %-20s ${BLUE}║${NC}\n" "端口" "UUID" "落地 Socks5"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"

    # 从 python3 写出的 uuid_map 读取实际 UUID
    for item in "${MAPPING_LIST[@]}"; do
        IFS='|' read -r vp sa sp su spw em <<< "$item"
        local actual_uuid
        actual_uuid=$(python3 -c "
import json
m = json.load(open('/tmp/_xray_uuid_map.json'))
print(m.get('${vp}',{}).get('uuid','N/A'))
" 2>/dev/null)
        printf "${BLUE}║${NC}  %-8s  %-36s  %-20s ${BLUE}║${NC}\n" \
            ":${vp}" "${actual_uuid}" "${sa}:${sp}"
    done

    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    tip "每个端口 → 独立落地 IP；客户端切换端口即切换出口"
    tip "流量限额：进入「流量限额管理」按 email 设置配额"

    # 保存配置摘要
    {
        echo "=========================================="
        echo "    端口映射中转配置"
        echo "=========================================="
        echo "生成时间:  $(date "+%Y-%m-%d %H:%M:%S")"
        echo "服务器IP:  ${PUB_IP}"
        echo "安全方式:  $([ "$_IN_SEC" == "1" ] && echo "Reality" || [ "$_IN_SEC" == "2" ] && echo "TLS" || echo "无加密")"
        [[ "$_IN_SEC" == "1" ]] && echo "PublicKey: ${_IN_PUBKEY}" && echo "ShortId:   ${_IN_SHORTID}"
        echo "------------------------------------------"
        for item in "${MAPPING_LIST[@]}"; do
            IFS='|' read -r vp sa sp su spw em <<< "$item"
            local uuid
            uuid=$(python3 -c "import json; m=json.load(open('/tmp/_xray_uuid_map.json')); print(m.get('${vp}',{}).get('uuid','N/A'))" 2>/dev/null)
            echo "VLESS端口: ${vp}  UUID: ${uuid}"
            echo "→ Socks5:  ${sa}:${sp}  用户:${su:-无认证}"
            echo "  Email:   ${em}"
            echo ""
        done
        echo "=========================================="
    } > "$CLIENT_FILE"

    rm -f /tmp/_xray_uuid_map.json

    echo ""
    read -p "是否立即为各用户设置流量配额? [y/N]: " set_q
    [[ "$set_q" =~ ^[Yy]$ ]] && manage_quota
}

# ─────────────────────────── ② 用户映射模式 ──────────────────────────────────
#
#  单端口 VLESS 入站，不同 UUID → 路由到不同 Socks5 出口
#  拓扑：
#    client(UUID-A) → 本机:PORT(VLESS+Reality) → socks5-ip1:port1
#    client(UUID-B) → 本机:PORT(VLESS+Reality) → socks5-ip2:port2
#    ...

gen_relay_user_mapping() {
    step "用户映射模式：同一端口，不同用户走不同 Socks5 出口"
    echo -e "${DIM}单端口 VLESS 入站，按 UUID 分流到不同落地 IP${NC}\n"

    read -p "VLESS 入站端口 [默认 443]: " RELAY_PORT; RELAY_PORT=${RELAY_PORT:-443}

    _collect_inbound_security || return 1

    # ── 收集 用户 → Socks5 映射 ──────────────────────────────────────────────
    local -a USER_MAP=()  # 格式: "email|uuid|s5_addr|s5_port|s5_user|s5_pass"
    local entry_count=0

    echo -e "\n${YELLOW}依次添加用户→Socks5 映射（直接回车结束）:${NC}\n"

    while true; do
        entry_count=$((entry_count + 1))
        echo -e "  ${GREEN}▶ 用户 #${entry_count}${NC}"

        read -p "  用户备注名 [默认 user${entry_count}]: " uname
        uname=${uname:-user${entry_count}}
        local email="${uname}@relay"

        read -p "  UUID（留空自动生成）: " uuid
        [[ -z "$uuid" ]] && uuid=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

        read -p "  Socks5 地址（留空结束整个添加）: " s5_addr
        [[ -z "$s5_addr" ]] && { entry_count=$((entry_count - 1)); break; }

        read -p "  Socks5 端口 [默认 1080]: " s5_port; s5_port=${s5_port:-1080}

        read -p "  Socks5 用户名（无认证留空）: " s5_user
        local s5_pass=""
        [[ -n "$s5_user" ]] && read -p "  Socks5 密码: " s5_pass

        USER_MAP+=("${email}|${uuid}|${s5_addr}|${s5_port}|${s5_user}|${s5_pass}")
        success "  用户 ${email} (${uuid:0:8}…) → ${s5_addr}:${s5_port}"
        echo ""
    done

    [[ $entry_count -eq 0 ]] && { warn "至少需要添加一个用户"; return 1; }

    # ── python3 生成 config ───────────────────────────────────────────────────
    mkdir -p /usr/local/etc/xray

    local py_users="user_map = [\n"
    for item in "${USER_MAP[@]}"; do
        IFS='|' read -r em uuid sa sp su spw <<< "$item"
        py_users+="    {'email':'${em}','uuid':'${uuid}','s5_addr':'${sa}','s5_port':${sp},'s5_user':'${su}','s5_pass':'${spw}'},\n"
    done
    py_users+="]\n"

    python3 - << PYEOF
import json

stream_settings = ${_IN_STREAM}

$(printf "%b" "$py_users")

# 构建 VLESS clients 列表
clients = [{"id": u['uuid'], "flow": "xtls-rprx-vision", "email": u['email']}
           for u in user_map]

# 构建 Socks5 出站和路由规则
outbounds = []
rules = [
    {"type":"field","inboundTag":["api-in"],"outboundTag":"api"},
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"}
]

for u in user_map:
    tag_out = f"socks5-{u['email'].replace('@','_').replace('.','_')}"
    server = {"address": u['s5_addr'], "port": u['s5_port'], "udp": True}
    if u['s5_user']:
        server["user"] = u['s5_user']
        server["pass"] = u['s5_pass']
    outbounds.append({
        "tag": tag_out,
        "protocol": "socks",
        "settings": {"servers": [server]}
    })
    # 按 email/user 路由
    rules.append({
        "type": "field",
        "user": [u['email']],
        "outboundTag": tag_out
    })

outbounds += [
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}
]

config = {
    "log": {"loglevel":"warning",
            "access":"${XRAY_LOG_DIR}/access.log",
            "error":"${XRAY_LOG_DIR}/error.log"},
    "stats": {},
    "api": {"tag":"api","services":["StatsService"]},
    "policy": {
        "levels": {"0":{"statsUserUplink":True,"statsUserDownlink":True}},
        "system": {"statsInboundUplink":True,"statsInboundDownlink":True}
    },
    "inbounds": [
        {"tag":"api-in","listen":"127.0.0.1","port":10085,
         "protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}},
        {
            "tag": "relay-user-map-in",
            "listen": "::",
            "port": ${RELAY_PORT},
            "protocol": "vless",
            "settings": {"clients": clients, "decryption": "none"},
            "streamSettings": stream_settings,
            "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
        }
    ],
    "outbounds": outbounds,
    "routing": {"domainStrategy":"IPIfNonMatch","rules": rules}
}

with open("${XRAY_CONFIG}", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print("[python3] config.json 生成成功")
PYEOF

    [[ $? -ne 0 ]] && { error "python3 生成配置失败"; return 1; }

    info "验证配置..."
    local test_out; test_out=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}── xray 验证错误 ──${NC}"
        echo "$test_out"
        error "配置验证失败"
    fi

    _start_relay_service "$RELAY_PORT"

    # ── 展示结果 ──────────────────────────────────────────────────────────────
    local PUB_IP; PUB_IP=$(curl -s4 --max-time 5 ip.sb || curl -s6 ip.sb)

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║               用户映射模式 — 节点信息                        ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  服务器:  ${CYAN}${PUB_IP}:${RELAY_PORT}${NC}"
    [[ "$_IN_SEC" == "1" ]] && {
        echo -e "${BLUE}║${NC}  PublicKey: ${CYAN}${_IN_PUBKEY}${NC}"
        echo -e "${BLUE}║${NC}  ShortId:   ${CYAN}${_IN_SHORTID}${NC}"
        echo -e "${BLUE}║${NC}  SNI:       ${CYAN}${_IN_DEST}${NC}"
    }
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC}  %-20s  %-36s ${BLUE}║${NC}\n" "用户(Email)" "UUID"
    printf "${BLUE}║${NC}  %-20s  %-36s ${BLUE}║${NC}\n" "落地 Socks5" ""
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"

    for item in "${USER_MAP[@]}"; do
        IFS='|' read -r em uuid sa sp su spw <<< "$item"
        printf "${BLUE}║${NC}  ${CYAN}%-20s${NC}  %-36s ${BLUE}║${NC}\n" "$em" "$uuid"
        printf "${BLUE}║${NC}  → %-18s  %-36s ${BLUE}║${NC}\n" "${sa}:${sp}" "${su:+用户:$su}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    done
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    tip "每个用户拥有独立落地 IP，客户端只需换 UUID 即可切换出口"
    tip "流量限额：进入「流量限额管理」按 email 设置配额"

    # 保存摘要
    {
        echo "=========================================="
        echo "    用户映射中转配置"
        echo "=========================================="
        echo "生成时间:  $(date "+%Y-%m-%d %H:%M:%S")"
        echo "服务器:    ${PUB_IP}:${RELAY_PORT}"
        [[ "$_IN_SEC" == "1" ]] && echo "PublicKey: ${_IN_PUBKEY}" && echo "ShortId:   ${_IN_SHORTID}"
        echo "------------------------------------------"
        for item in "${USER_MAP[@]}"; do
            IFS='|' read -r em uuid sa sp su spw <<< "$item"
            echo "用户:    ${em}"
            echo "UUID:    ${uuid}"
            echo "→ Socks5: ${sa}:${sp}  ${su:+用户:$su}"
            echo ""
        done
        echo "=========================================="
    } > "$CLIENT_FILE"

    echo ""
    read -p "是否立即为各用户设置流量配额? [y/N]: " set_q
    [[ "$set_q" =~ ^[Yy]$ ]] && manage_quota
}

# ─────────────────────────── ③ 本机 Socks5 代理 ──────────────────────────────

gen_socks5_config() {
    step "本机 Socks5 代理（直接对外开放 Socks5 端口）"
    echo -e "${DIM}本机作为 Socks5 服务器，支持多用户账号，可叠加到现有配置${NC}\n"

    local MERGE=false
    if [[ -f "$XRAY_CONFIG" ]]; then
        read -p "检测到现有 Xray 配置，叠加添加 Socks5 入站? [Y/n]: " mg
        mg=${mg:-Y}; [[ "$mg" =~ ^[Yy]$ ]] && MERGE=true
    fi

    read -p "Socks5 监听端口 [默认 1080]: " S5_PORT;  S5_PORT=${S5_PORT:-1080}
    read -p "监听地址 [默认 0.0.0.0]: "       S5_LISTEN; S5_LISTEN=${S5_LISTEN:-"0.0.0.0"}

    local S5_AUTH=false S5_ACCOUNTS_JSON="" u_count=0
    read -p "启用账号密码认证（支持多用户）? [y/N]: " auth_yn
    if [[ "$auth_yn" =~ ^[Yy]$ ]]; then
        S5_AUTH=true
        echo -e "${YELLOW}添加用户（直接回车结束）:${NC}"
        while true; do
            u_count=$((u_count + 1))
            read -p "  用户名 #${u_count}（留空结束）: " S5_USER
            [[ -z "$S5_USER" ]] && { u_count=$((u_count - 1)); break; }
            read -p "  密码: " S5_PASS
            [[ -z "$S5_PASS" ]] && { warn "密码不能为空，跳过"; u_count=$((u_count-1)); continue; }
            [[ -n "$S5_ACCOUNTS_JSON" ]] && S5_ACCOUNTS_JSON+=","
            S5_ACCOUNTS_JSON+="{\"user\":\"${S5_USER}\",\"pass\":\"${S5_PASS}\"}"
            success "  用户 ${S5_USER} 已添加"
        done
        [[ $u_count -eq 0 ]] && { warn "未添加用户，改为无认证"; S5_AUTH=false; }
    fi

    local UDP=true
    read -p "启用 UDP? [Y/n]: " udp_yn; udp_yn=${udp_yn:-Y}
    [[ "$udp_yn" =~ ^[Nn]$ ]] && UDP=false

    local AUTH_BLOCK
    $S5_AUTH \
        && AUTH_BLOCK="\"auth\":\"password\",\"accounts\":[${S5_ACCOUNTS_JSON}]," \
        || AUTH_BLOCK='"auth":"noauth",'

    local S5_INBOUND
    S5_INBOUND=$(python3 -c "
import json
ib = {
    'tag': 'socks5-in',
    'listen': '${S5_LISTEN}',
    'port': ${S5_PORT},
    'protocol': 'socks',
    'settings': json.loads('{${AUTH_BLOCK}\"udp\":${UDP}}')
}
print(json.dumps(ib, indent=2))
")

    if $MERGE; then
        python3 - << PYEOF
import json
cfg = json.load(open('${XRAY_CONFIG}'))
cfg['inbounds'] = [ib for ib in cfg['inbounds'] if ib.get('tag') != 'socks5-in']
cfg['inbounds'].append(${S5_INBOUND})
with open('${XRAY_CONFIG}','w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("Socks5 入站已合并")
PYEOF
    else
        python3 - << PYEOF
import json
config = {
    "log": {"loglevel":"warning",
            "access":"${XRAY_LOG_DIR}/access.log",
            "error":"${XRAY_LOG_DIR}/error.log"},
    "inbounds":  [${S5_INBOUND}],
    "outbounds": [{"tag":"direct","protocol":"freedom"},
                  {"tag":"block","protocol":"blackhole"}],
    "routing": {"rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"block"}]}
}
with open('${XRAY_CONFIG}','w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print("Socks5 配置生成成功")
PYEOF
    fi

    [[ $? -ne 0 ]] && { error "python3 生成配置失败"; return 1; }

    info "验证配置..."
    local test_out; test_out=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$test_out"; error "配置验证失败"
    fi

    open_port "$S5_PORT" tcp
    $UDP && open_port "$S5_PORT" udp
    _start_relay_service "$S5_PORT"

    local PUB_IP; PUB_IP=$(curl -s4 --max-time 5 ip.sb || curl -s6 ip.sb)
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}               Socks5 代理节点信息${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}地址:${NC}    ${PUB_IP}"
    echo -e "${YELLOW}端口:${NC}    ${S5_PORT}"
    echo -e "${YELLOW}认证:${NC}    $($S5_AUTH && echo "账号密码（${u_count} 个用户）" || echo "无需认证")"
    echo -e "${YELLOW}UDP:${NC}     ${UDP}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

# ─────────────────────────── 状态查看 ────────────────────────────────────────

_view_relay_status() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到 Xray 配置文件"; return; }
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}             当前入站 & 出站配置${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    python3 - << PYEOF
import json
cfg = json.load(open('${XRAY_CONFIG}'))

print("  入站列表:")
for ib in cfg.get('inbounds', []):
    if ib.get('tag') == 'api-in': continue
    proto = ib.get('protocol','?')
    port  = ib.get('port','?')
    clients = ib.get('settings',{}).get('clients',[])
    n = len(clients)
    emails = ', '.join(c.get('email','?') for c in clients[:3])
    suffix = f'  用户({n}): {emails}{"..." if n>3 else ""}' if clients else ''
    print(f"    [{ib.get('tag')}]  {proto}  端口:{port}{suffix}")

print()
print("  Socks5 出站列表:")
for ob in cfg.get('outbounds', []):
    if ob.get('protocol') != 'socks': continue
    srv = ob.get('settings',{}).get('servers',[{}])[0]
    auth = f"  用户:{srv['user']}" if 'user' in srv else '  无认证'
    print(f"    [{ob.get('tag')}]  {srv.get('address')}:{srv.get('port')}{auth}")

print()
print("  路由规则（用户/入站 → 出站）:")
for r in cfg.get('routing',{}).get('rules',[]):
    src = r.get('user') or r.get('inboundTag') or []
    dst = r.get('outboundTag') or r.get('balancerTag','')
    if dst in ('block','direct','api'): continue
    print(f"    {src} → {dst}")
PYEOF

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    systemctl is-active --quiet xray \
        && echo -e "  服务状态: ${GREEN}● 运行中${NC}" \
        || echo -e "  服务状态: ${RED}● 已停止${NC}"
}

# ─────────────────────────── 动态增删映射 ────────────────────────────────────

# 向现有配置追加一条新映射（端口映射模式专用）
relay_add_port_mapping() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到配置文件"; return 1; }
    python3 -c "
import json
cfg = json.load(open('${XRAY_CONFIG}'))
# 检查是否为端口映射模式（有 socks5-out-* 出站）
tags = [o['tag'] for o in cfg.get('outbounds',[])]
has_port_map = any(t.startswith('socks5-out-') for t in tags)
print('port_map' if has_port_map else 'other')
" 2>/dev/null | grep -q "port_map" || { warn "当前不是端口映射模式配置"; return 1; }

    echo ""
    read -p "新 VLESS 入站端口: " vp; [[ -z "$vp" ]] && return
    read -p "Socks5 地址: " sa;       [[ -z "$sa" ]] && return
    read -p "Socks5 端口 [默认 1080]: " sp; sp=${sp:-1080}
    read -p "Socks5 用户名（留空无认证）: " su
    local spw=""
    [[ -n "$su" ]] && read -p "Socks5 密码: " spw
    read -p "用户备注名 [默认 user_new]: " uname; uname=${uname:-user_new}
    local email="${uname}@relay"

    # 读取现有入站的 streamSettings
    python3 - << PYEOF
import json, uuid as _uuid
cfg  = json.load(open('${XRAY_CONFIG}'))

# 复用已有 VLESS 入站的 streamSettings
existing_ss = None
for ib in cfg['inbounds']:
    if ib.get('protocol') == 'vless' and 'streamSettings' in ib:
        existing_ss = ib['streamSettings']
        break

tag_in  = f"vless-in-${vp}"
tag_out = f"socks5-out-${vp}"

# 新入站
new_ib = {
    "tag": tag_in, "listen": "::", "port": ${vp},
    "protocol": "vless",
    "settings": {"clients": [{"id": str(_uuid.uuid4()), "flow": "xtls-rprx-vision", "email": "${email}"}], "decryption": "none"},
    "streamSettings": existing_ss or {"network":"tcp"},
    "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}

# 新出站
server = {"address":"${sa}","port":${sp},"udp":True}
$([ -n "$su" ] && echo 'server["user"]="${su}"; server["pass"]="${spw}"')
new_ob = {"tag": tag_out, "protocol": "socks", "settings": {"servers": [server]}}

# 新路由规则
new_rule = {"type":"field","inboundTag":[tag_in],"outboundTag":tag_out}

cfg['inbounds'].append(new_ib)
# 插在 direct 之前
idx = next((i for i,o in enumerate(cfg['outbounds']) if o['tag']=='direct'), len(cfg['outbounds']))
cfg['outbounds'].insert(idx, new_ob)
# 插在 block/private 规则之前
cfg['routing']['rules'].insert(-1, new_rule)

with open('${XRAY_CONFIG}','w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f"已添加: VLESS:{vp} → {sa}:{sp}  用户:{email}")
PYEOF

    local test_out; test_out=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$test_out"; error "配置验证失败，已回滚"; return 1
    fi
    open_port "$vp" tcp
    systemctl reload xray 2>/dev/null || systemctl restart xray
    success "新映射已生效"
}

# 删除一条映射（端口映射 & 用户映射通用）
relay_remove_mapping() {
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到配置文件"; return 1; }
    _view_relay_status
    echo ""
    read -p "请输入要删除的用户 email: " del_email
    [[ -z "$del_email" ]] && return

    python3 - << PYEOF
import json
cfg = json.load(open('${XRAY_CONFIG}'))

# 找到关联的 outbound tag（通过路由规则）
target_tag = None
rules_new  = []
for r in cfg['routing']['rules']:
    users = r.get('user', [])
    intags= r.get('inboundTag', [])
    if '${del_email}' in users:
        target_tag = r.get('outboundTag')
    else:
        # 端口映射：找该 email 所在 inbound 的 tag
        for ib in cfg['inbounds']:
            clients = ib.get('settings',{}).get('clients',[])
            if any(c.get('email') == '${del_email}' for c in clients):
                if ib['tag'] in intags:
                    target_tag = r.get('outboundTag')
                    break
        if target_tag is None:
            rules_new.append(r)
        else:
            pass  # 跳过此规则（删除）
    if target_tag and r not in rules_new and r.get('outboundTag') != target_tag:
        rules_new.append(r)

if target_tag is None:
    print("未找到用户 ${del_email} 的映射关系")
    exit(1)

# 删除对应 inbound
cfg['inbounds'] = [
    ib for ib in cfg['inbounds']
    if not any(c.get('email')=='${del_email}'
               for c in ib.get('settings',{}).get('clients',[]))
]

# 删除对应 outbound
cfg['outbounds'] = [o for o in cfg['outbounds'] if o['tag'] != target_tag]

# 删除路由规则
cfg['routing']['rules'] = [
    r for r in cfg['routing']['rules']
    if not ('${del_email}' in r.get('user',[]) or r.get('outboundTag') == target_tag)
]

with open('${XRAY_CONFIG}','w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f"已删除用户 ${del_email} 的映射（出站: {target_tag}）")
PYEOF

    [[ $? -ne 0 ]] && { warn "删除失败"; return 1; }
    xray run -test -config "$XRAY_CONFIG" > /dev/null 2>&1 || { error "配置验证失败"; return 1; }
    systemctl reload xray 2>/dev/null || systemctl restart xray
    success "映射已删除并生效"
}

# ─────────────────────────── 管理菜单 ────────────────────────────────────────

manage_relay_socks5() {
    while true; do
        echo ""
        echo -e "${PURPLE}═══════════════════════════════════════════════════${NC}"
        echo -e "${PURPLE}           VLESS 中转 / Socks5 管理${NC}"
        echo -e "${PURPLE}═══════════════════════════════════════════════════${NC}"
        echo -e "  ${BOLD}新建中转${NC}"
        echo -e "  ${GREEN}1${NC}. 端口映射模式  ${DIM}（每端口→独立Socks5，切端口换IP）${NC}"
        echo -e "  ${GREEN}2${NC}. 用户映射模式  ${DIM}（同端口，换UUID换落地IP）${NC}"
        echo -e "  ${GREEN}3${NC}. 本机 Socks5 代理"
        echo -e "  ${BOLD}管理现有配置${NC}"
        echo -e "  ${GREEN}4${NC}. 查看当前入站/出站状态"
        echo -e "  ${GREEN}5${NC}. 追加端口映射条目"
        echo -e "  ${GREEN}6${NC}. 删除映射条目"
        echo -e "  ${GREEN}7${NC}. 流量配额管理"
        echo -e "  ${GREEN}0${NC}. 返回主菜单"
        echo -e "${PURPLE}═══════════════════════════════════════════════════${NC}"
        read -p "请选择: " rc

        case $rc in
            1) gen_relay_port_mapping ;;
            2) gen_relay_user_mapping ;;
            3) gen_socks5_config ;;
            4) _view_relay_status ;;
            5) relay_add_port_mapping ;;
            6) relay_remove_mapping ;;
            7) manage_quota ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        echo ""
        read -rp "按 Enter 继续..."
    done
}

# ──────────────────────────── 全新安装主流程 ─────────────────────────────────
install_new() {
    # 重置全局变量
    PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""; FINGERPRINT="chrome"
    DEST=""; DEST_PORT=443; UUID=""; PORT=443; SERVER_IP=""; DOMAIN=""
    REMARK="xray"; PROTOCOL_CHOICE=1; VMESS_PORT_FINAL=""
    VLESS_LINK=""; VMESS_LINK=""; TROJAN_LINK=""; SS_LINK=""; HY2_LINK=""

    install_dependencies
    install_xray

    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}              选择安装类型${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}1${NC}. 标准代理节点（VLESS/VMess/Trojan/SS）"
    echo -e "  ${GREEN}2${NC}. 端口映射中转 ${DIM}（每端口→独立Socks5）${NC}"
    echo -e "  ${GREEN}3${NC}. 用户映射中转 ${DIM}（同端口，换UUID换落地）${NC}"
    echo -e "  ${GREEN}4${NC}. 本机 Socks5 代理"
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    read -p "请选择 [默认 1]: " INSTALL_TYPE; INSTALL_TYPE=${INSTALL_TYPE:-1}

    case $INSTALL_TYPE in
        2) gen_relay_port_mapping;  enable_bbr; return ;;
        3) gen_relay_user_mapping;  enable_bbr; return ;;
        4) gen_socks5_config;       enable_bbr; return ;;
    esac

    # ── 标准代理节点流程 ──
    select_protocol

    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器公网 IP: $SERVER_IP"

    read -p "请输入监听端口 [默认 443]: " PORT; PORT=${PORT:-443}
    read -p "请输入节点备注名称 [默认 xray]: " REMARK; REMARK=${REMARK:-xray}

    # Shadowsocks 跳过 UUID，密码在 gen 函数里生成
    if [[ "$PROTOCOL_CHOICE" != "4" ]]; then
        UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        info "已生成 UUID: $UUID"
    fi

    if [[ "$PROTOCOL_CHOICE" =~ ^(2|3|5)$ ]]; then
        read -p "请输入域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && error "此协议必须提供域名"
    else
        DOMAIN=""
    fi

    [[ "$PROTOCOL_CHOICE" =~ ^(1|5)$ ]] && get_reality_input
    get_cert

    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config   ;;
        3) gen_trojan_server_config  ;;
        4) gen_ss_server_config      ;;
        5) gen_dual_server_config    ;;
    esac

    create_systemd_service
    open_port "$PORT" tcp
    open_port "$PORT" udp
    [[ -n "$VMESS_PORT_FINAL" ]] && { open_port "$VMESS_PORT_FINAL" tcp; open_port "$VMESS_PORT_FINAL" udp; }
    restart_and_show
    setup_cert_renewal

    read -p "是否开启 BBR 加速? [Y/n]: " bbr_choice; bbr_choice=${bbr_choice:-Y}
    [[ "$bbr_choice" =~ ^[Yy]$ ]] && enable_bbr

    success "✓ Xray 安装完成！节点可正常使用"
}

# ══════════════════════════════════════════════════════════════════════════════
#  流量限额管理模块
#  策略：不重置 / 超额暂停 / 纯本地文件存储
#
#  QUOTA_DB 结构：
#    {
#      "user@remark": {
#        "quota_bytes":  10737418240,   # 配额上限（字节），0=不限
#        "used_bytes":   3221225472,    # 累计已用（字节）
#        "suspended":    false,         # 是否已被暂停
#        "set_time":     "2024-06-01 12:00:00"  # 配额设置时间
#      }
#    }
#
#  流量来源：解析 Xray access.log（无需 API，重启不清零）
#            每次查看/检查时实时解析日志增量，累加写入 QUOTA_DB
#            日志轮转时自动感知（通过记录已解析的字节偏移量）
#
#  超额流程：cron 每 5 分钟调用 watchdog → 解析日志增量 → 累加 used_bytes
#            → 超额则向 routing.rules 头部注入 user→blackhole 规则 → reload
#            → 手动重置后删除规则恢复访问
# ══════════════════════════════════════════════════════════════════════════════


# ─────────────────────────── DB 读写工具 ─────────────────────────────────────

_quota_db_init() {
    [[ -f "$QUOTA_DB" ]] || echo '{}' > "$QUOTA_DB"
}

# _qget <email> <field> [default]
_qget() {
    local email="$1" field="$2" default="${3:-}"
    local val
    val=$(jq -r --arg e "$email" --arg f "$field" \
        'if .[$e] and (.[$e][$f] != null) then .[$e][$f] | tostring else "" end' \
        "$QUOTA_DB" 2>/dev/null)
    echo "${val:-$default}"
}

# _qset <email> <field> <value>   数字不加引号
_qset() {
    local email="$1" field="$2" value="$3"
    local tmp; tmp=$(mktemp)
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        jq --arg e "$email" --arg f "$field" --argjson v "$value" \
            'if .[$e] then .[$e][$f]=$v else .[$e]={($f):$v} end' \
            "$QUOTA_DB" > "$tmp"
    else
        jq --arg e "$email" --arg f "$field" --arg v "$value" \
            'if .[$e] then .[$e][$f]=$v else .[$e]={($f):$v} end' \
            "$QUOTA_DB" > "$tmp"
    fi
    mv "$tmp" "$QUOTA_DB"
}

_quota_list_emails() {
    jq -r 'keys[]' "$QUOTA_DB" 2>/dev/null
}

# ─────────────────────────── 单位换算 ────────────────────────────────────────

human_to_bytes() {
    local input="${1^^}"
    if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)(GB|MB|KB|B)?$ ]]; then
        local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]:-B}"
        case $unit in
            GB) awk "BEGIN{printf \"%.0f\", $num * 1073741824}" ;;
            MB) awk "BEGIN{printf \"%.0f\", $num * 1048576}"    ;;
            KB) awk "BEGIN{printf \"%.0f\", $num * 1024}"       ;;
            B)  awk "BEGIN{printf \"%.0f\", $num}"              ;;
        esac
    else
        echo "0"; return 1
    fi
}

bytes_to_human() {
    local b=${1:-0}
    if   awk "BEGIN{exit !($b >= 1073741824)}"; then
        awk "BEGIN{printf \"%.2f GB\", $b/1073741824}"
    elif awk "BEGIN{exit !($b >= 1048576)}"; then
        awk "BEGIN{printf \"%.2f MB\", $b/1048576}"
    elif awk "BEGIN{exit !($b >= 1024)}"; then
        awk "BEGIN{printf \"%.2f KB\", $b/1024}"
    else
        echo "${b} B"
    fi
}

# ─────────────────────────── 日志解析流量统计 ─────────────────────────────────
#
# 原理：Xray access.log 每行格式：
#   时间 [tag] addr -> dest  email  上行/下行
# 实际字段因版本而异，但"字节数"体现在 accepted 行里的流量记录。
#
# 由于 access.log 格式不含明确流量字节，改用更可靠方案：
# 直接调用 xray api statsquery（如 API 可用）拉取增量；
# API 不可用时回退到解析 access.log 的连接次数（粗估）。
#
# 核心：用"日志文件大小偏移量"做增量标记，只解析新增内容，避免重复计算。
# QUOTA_DB 额外字段：
#   log_offset  : 上次解析时 access.log 的字节大小（用于增量定位）
#   log_inode   : 上次解析时的 inode（检测日志轮转）

# 拉取单用户的 API 流量增量（字节），失败返回 -1
_api_user_bytes_delta() {
    local email="$1"
    # 检查 API 是否可用
    ss -tuln 2>/dev/null | grep -q ":10085 " || { echo -1; return; }
    command -v xray &>/dev/null          || { echo -1; return; }

    local up dn
    up=$(xray api statsquery --server=127.0.0.1:10085 \
        -pattern "user>>>${email}>>>traffic>>>uplink" 2>/dev/null \
        | grep -oP '(?<=value: )\d+' | head -1)
    dn=$(xray api statsquery --server=127.0.0.1:10085 \
        -pattern "user>>>${email}>>>traffic>>>downlink" 2>/dev/null \
        | grep -oP '(?<=value: )\d+' | head -1)
    up=${up:-0}; dn=${dn:-0}

    # API 返回的是 Xray 启动后累计值
    # 用 api_baseline 做差值，得到本次增量
    local baseline; baseline=$(_qget "$email" api_baseline 0)
    local total; total=$(awk "BEGIN{print $up + $dn}")

    if [[ "$total" -ge "$baseline" ]]; then
        awk "BEGIN{print $total - $baseline}"
    else
        # Xray 重启后 API 归零，把当前值全部算作增量
        echo "$total"
    fi

    # 更新 baseline（写入 QUOTA_DB 由调用方完成）
    echo "$total" > /tmp/_xray_api_total_"${email//[@.]/_}"
}

# 解析 access.log 增量，统计指定 email 的新增连接数（字节粗估）
# 每条连接按 50KB 估算（保守值，主要用于 API 不可用时的兜底）
_log_user_delta() {
    local email="$1"
    local logfile="${XRAY_LOG_DIR}/access.log"
    [[ -f "$logfile" ]] || { echo 0; return; }

    local cur_size; cur_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    local cur_inode; cur_inode=$(stat -c%i "$logfile" 2>/dev/null || echo 0)
    local last_offset; last_offset=$(_qget "$email" log_offset 0)
    local last_inode; last_inode=$(_qget "$email" log_inode 0)

    # 日志轮转检测（inode 变化）
    if [[ "$cur_inode" != "$last_inode" ]]; then
        last_offset=0
    fi

    # 无新内容
    if [[ "$cur_size" -le "$last_offset" ]]; then
        echo 0; return
    fi

    # 读取增量部分，统计含该 email 的 accepted 行数
    local new_conns
    new_conns=$(dd if="$logfile" bs=1 skip="$last_offset" \
        count=$((cur_size - last_offset)) 2>/dev/null \
        | grep -c "accepted.*${email}" 2>/dev/null || echo 0)

    # 更新偏移量和 inode（写入由调用方完成）
    echo "${cur_size}:${cur_inode}" > /tmp/_xray_log_offset_"${email//[@.]/_}"

    # 粗估：每连接 50 KB
    awk "BEGIN{print $new_conns * 51200}"
}

# ─────────────────────────── 暂停 / 恢复 ────────────────────────────────────

_suspend_user() {
    local email="$1"
    [[ ! -f "$XRAY_CONFIG" ]] && return 1

    # 确保 suspended-blackhole outbound 存在
    local has_bh
    has_bh=$(jq --arg t "$SUSPENDED_TAG" \
        '[.outbounds[] | select(.tag==$t)] | length' "$XRAY_CONFIG" 2>/dev/null)
    if [[ "${has_bh:-0}" -eq 0 ]]; then
        jq --arg t "$SUSPENDED_TAG" \
            '.outbounds += [{"tag":$t,"protocol":"blackhole"}]' \
            "$XRAY_CONFIG" > /tmp/_xq.json && mv /tmp/_xq.json "$XRAY_CONFIG"
    fi

    # 若规则已存在则跳过
    local already
    already=$(jq --arg e "$email" \
        '[.routing.rules[] | select(.user? and (any(.[]; .==($e))))] | length' \
        "$XRAY_CONFIG" 2>/dev/null)
    [[ "${already:-0}" -gt 0 ]] && return 0

    # 在路由规则最前面插入封禁规则（最高优先级）
    jq --arg e "$email" --arg t "$SUSPENDED_TAG" \
        '.routing.rules = [{"type":"field","user":[$e],"outboundTag":$t}] + .routing.rules' \
        "$XRAY_CONFIG" > /tmp/_xq.json && mv /tmp/_xq.json "$XRAY_CONFIG"

    systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
    _qset "$email" suspended true
    warn "⚠ 用户 ${email} 已超出流量配额，已暂停访问"
}

_resume_user() {
    local email="$1"
    [[ ! -f "$XRAY_CONFIG" ]] && return 1

    # 删除该 email 的封禁路由规则
    jq --arg e "$email" \
        'del(.routing.rules[] | select(.user? and (any(.[]; .==($e)))))' \
        "$XRAY_CONFIG" > /tmp/_xq.json && mv /tmp/_xq.json "$XRAY_CONFIG"

    systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
    _qset "$email" suspended false
    success "用户 ${email} 访问已恢复"
}

# ─────────────────────────── 守护进程 Watchdog ───────────────────────────────
#
# 执行流程：
#   1. 遍历 QUOTA_DB 中所有用户
#   2. 优先尝试 Xray API 获取流量增量
#   3. API 不可用时回退到日志解析粗估
#   4. 增量累加到 used_bytes 并持久化
#   5. 若 used_bytes >= quota_bytes 且未暂停 → 暂停用户
#   6. 已暂停用户跳过流量累加（避免数据重复）

quota_watchdog() {
    _quota_db_init
    local emails; emails=$(_quota_list_emails)
    [[ -z "$emails" ]] && return 0

    local logfile="${XRAY_LOG_DIR}/access.log"

    while IFS= read -r email; do
        [[ -z "$email" ]] && continue

        local quota_bytes; quota_bytes=$(_qget "$email" quota_bytes 0)
        [[ "$quota_bytes" -eq 0 ]] && continue   # 无配额限制，跳过

        local suspended; suspended=$(_qget "$email" suspended false)

        # 已暂停用户不再累加流量（防止数据虚高）
        if [[ "$suspended" == "true" ]]; then
            continue
        fi

        # ── 获取流量增量 ──────────────────────────────────────────────────────
        local delta=0
        local api_delta; api_delta=$(_api_user_bytes_delta "$email")

        if [[ "$api_delta" -ge 0 ]]; then
            # API 成功：使用精确增量
            delta=$api_delta
            # 更新 api_baseline
            local total_file="/tmp/_xray_api_total_${email//[@.]/_}"
            if [[ -f "$total_file" ]]; then
                local new_baseline; new_baseline=$(cat "$total_file")
                _qset "$email" api_baseline "${new_baseline:-0}"
                rm -f "$total_file"
            fi
        else
            # API 不可用：回退日志解析
            delta=$(_log_user_delta "$email")
            # 更新日志偏移量
            local offset_file="/tmp/_xray_log_offset_${email//[@.]/_}"
            if [[ -f "$offset_file" ]]; then
                local offset_data; offset_data=$(cat "$offset_file")
                _qset "$email" log_offset  "$(echo "$offset_data" | cut -d: -f1)"
                _qset "$email" log_inode   "$(echo "$offset_data" | cut -d: -f2)"
                rm -f "$offset_file"
            fi
        fi

        # ── 累加到持久化 DB ───────────────────────────────────────────────────
        if [[ "$delta" -gt 0 ]]; then
            local used_bytes; used_bytes=$(_qget "$email" used_bytes 0)
            local new_used=$(( used_bytes + delta ))
            _qset "$email" used_bytes "$new_used"
            used_bytes=$new_used
        else
            local used_bytes; used_bytes=$(_qget "$email" used_bytes 0)
        fi

        # ── 超额检测 ─────────────────────────────────────────────────────────
        if [[ "$used_bytes" -ge "$quota_bytes" ]]; then
            _suspend_user "$email"
        fi

    done <<< "$emails"
}

# ─────────────────────────── Cron 安装 / 卸载 ────────────────────────────────

_install_quota_cron() {
    local script_path; script_path=$(realpath "$0")
    local cron_line="*/5 * * * * bash ${script_path} --watchdog >> ${XRAY_LOG_DIR}/quota-watchdog.log 2>&1 ${QUOTA_CRON_TAG}"
    (crontab -l 2>/dev/null | grep -v "$QUOTA_CRON_TAG"
     echo "$cron_line"
    ) | crontab -
    success "流量守护进程已配置（每 5 分钟检查一次）"
    tip "日志: ${XRAY_LOG_DIR}/quota-watchdog.log"
}

_uninstall_quota_cron() {
    (crontab -l 2>/dev/null | grep -v "$QUOTA_CRON_TAG") | crontab -
    info "流量守护进程 Cron 已移除"
}

_quota_cron_status() {
    crontab -l 2>/dev/null | grep -c "$QUOTA_CRON_TAG" || true
}

# ─────────────────────────── 配额设置 ────────────────────────────────────────

quota_set() {
    _quota_db_init
    [[ ! -f "$XRAY_CONFIG" ]] && { warn "未找到 Xray 配置文件，请先完成安装"; return 1; }

    echo ""
    step "为用户设置流量配额"
    list_users
    echo ""
    read -p "请输入目标用户的 email: " target_email
    [[ -z "$target_email" ]] && { warn "email 不能为空"; return 1; }

    # 验证用户存在于配置中（支持 vless/vmess/trojan）
    local exists
    exists=$(jq --arg e "$target_email" \
        '[ .. | objects | select(.email? == $e or .id? == $e) ] | length' \
        "$XRAY_CONFIG" 2>/dev/null)
    [[ "${exists:-0}" -eq 0 ]] && {
        warn "配置文件中未找到用户 ${target_email}，请先通过「多用户管理」添加用户"
        return 1
    }

    # 显示当前配额（如果有）
    local cur_quota; cur_quota=$(_qget "$target_email" quota_bytes 0)
    if [[ "$cur_quota" -gt 0 ]]; then
        info "当前配额: $(bytes_to_human $cur_quota)（重新输入可修改）"
    fi

    echo -e "\n${YELLOW}支持格式：50GB / 500MB / 102400KB${NC}"
    read -p "请输入流量配额上限: " quota_input
    [[ -z "$quota_input" ]] && { warn "配额不能为空"; return 1; }

    local quota_bytes; quota_bytes=$(human_to_bytes "$quota_input")
    [[ "${quota_bytes:-0}" -le 0 ]] && {
        warn "无法识别的格式: ${quota_input}，请使用如 50GB / 500MB"
        return 1
    }

    # 写入 DB（新用户初始化，老用户只更新 quota_bytes）
    local set_time; set_time=$(date "+%Y-%m-%d %H:%M:%S")
    if [[ "$cur_quota" -gt 0 ]]; then
        # 已有配额：仅更新配额值，保留已用量
        _qset "$target_email" quota_bytes "$quota_bytes"
        _qset "$target_email" set_time    "$set_time"
    else
        # 首次设置：初始化全部字段
        local tmp; tmp=$(mktemp)
        jq --arg e "$target_email" \
           --argjson qb "$quota_bytes" \
           --arg st "$set_time" \
           '.[$e] = {
               "quota_bytes":  $qb,
               "used_bytes":   0,
               "suspended":    false,
               "set_time":     $st,
               "api_baseline": 0,
               "log_offset":   0,
               "log_inode":    0
           }' "$QUOTA_DB" > "$tmp" && mv "$tmp" "$QUOTA_DB"
    fi

    # 自动安装 cron（如未安装）
    local cron_count; cron_count=$(_quota_cron_status)
    [[ "${cron_count:-0}" -eq 0 ]] && _install_quota_cron

    success "用户 ${target_email} 流量配额已设置: $(bytes_to_human $quota_bytes)"
    tip "配额用完后用户将被自动暂停，需手动执行「重置流量」恢复"
}

# ─────────────────────────── 取消限制 ────────────────────────────────────────

quota_remove() {
    _quota_db_init
    local emails; emails=$(_quota_list_emails)
    [[ -z "$emails" ]] && { warn "当前无用户设置了流量限制"; return; }

    echo ""
    echo -e "${BLUE}已设配额的用户:${NC}"
    while IFS= read -r e; do
        local qb; qb=$(_qget "$e" quota_bytes 0)
        local susp; susp=$(_qget "$e" suspended false)
        local susp_str; [[ "$susp" == "true" ]] && susp_str="${RED}[已暂停]${NC}" || susp_str="${GREEN}[正常]${NC}"
        echo -e "  ${CYAN}${e}${NC}  配额: $(bytes_to_human $qb)  ${susp_str}"
    done <<< "$emails"
    echo ""

    read -p "请输入要取消限制的用户 email（留空取消操作）: " target_email
    [[ -z "$target_email" ]] && return

    local ex; ex=$(jq --arg e "$target_email" 'has($e)' "$QUOTA_DB" 2>/dev/null)
    [[ "$ex" != "true" ]] && { warn "用户 ${target_email} 未设置流量限制"; return; }

    # 若已暂停，先恢复
    local susp; susp=$(_qget "$target_email" suspended false)
    [[ "$susp" == "true" ]] && _resume_user "$target_email"

    # 从 DB 删除
    local tmp; tmp=$(mktemp)
    jq --arg e "$target_email" 'del(.[$e])' "$QUOTA_DB" > "$tmp" && mv "$tmp" "$QUOTA_DB"

    # 若 DB 已空，卸载 cron
    local remain; remain=$(jq 'keys | length' "$QUOTA_DB" 2>/dev/null)
    [[ "${remain:-0}" -eq 0 ]] && _uninstall_quota_cron

    success "用户 ${target_email} 流量限制已取消，访问已恢复"
}

# ─────────────────────────── 手动重置流量 ────────────────────────────────────

quota_reset_user() {
    _quota_db_init
    local emails; emails=$(_quota_list_emails)
    [[ -z "$emails" ]] && { warn "当前无用户设置了流量限制"; return; }

    echo ""
    echo -e "${BLUE}已设配额的用户（已用 / 配额）:${NC}"
    while IFS= read -r e; do
        local used; used=$(_qget "$e" used_bytes 0)
        local qb;   qb=$(_qget "$e" quota_bytes 0)
        local susp; susp=$(_qget "$e" suspended false)
        local susp_str; [[ "$susp" == "true" ]] && susp_str=" ${RED}[已暂停]${NC}" || susp_str=""
        printf "  ${CYAN}%-35s${NC} %s / %s%b\n" \
            "$e" "$(bytes_to_human $used)" "$(bytes_to_human $qb)" "$susp_str"
    done <<< "$emails"
    echo ""

    read -p "请输入要重置的用户 email（留空则重置所有）: " target_email

    _do_reset_one() {
        local e="$1"
        _qset "$e" used_bytes   0
        _qset "$e" api_baseline 0
        _qset "$e" log_offset   0
        _qset "$e" log_inode    0
        # 若已暂停，恢复访问
        local susp; susp=$(_qget "$e" suspended false)
        [[ "$susp" == "true" ]] && _resume_user "$e" || true
        success "用户 ${e} 流量已重置为 0"
    }

    if [[ -z "$target_email" ]]; then
        read -p "确认重置所有用户的流量计数? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
        while IFS= read -r e; do
            _do_reset_one "$e"
        done <<< "$emails"
    else
        local ex; ex=$(jq --arg e "$target_email" 'has($e)' "$QUOTA_DB" 2>/dev/null)
        [[ "$ex" != "true" ]] && { warn "用户 ${target_email} 未在配额 DB 中"; return; }
        _do_reset_one "$target_email"
    fi
}

# ─────────────────────────── 手动暂停 / 恢复 ─────────────────────────────────

quota_toggle_suspend() {
    _quota_db_init
    local emails; emails=$(_quota_list_emails)
    [[ -z "$emails" ]] && { warn "当前无用户设置了流量限制"; return; }

    echo ""
    echo -e "${BLUE}用户状态列表:${NC}"
    while IFS= read -r e; do
        local susp; susp=$(_qget "$e" suspended false)
        local used; used=$(_qget "$e" used_bytes 0)
        local qb;   qb=$(_qget "$e" quota_bytes 0)
        if [[ "$susp" == "true" ]]; then
            echo -e "  ${CYAN}${e}${NC}  ${RED}● 已暂停${NC}  已用: $(bytes_to_human $used) / $(bytes_to_human $qb)"
        else
            echo -e "  ${CYAN}${e}${NC}  ${GREEN}● 正常${NC}    已用: $(bytes_to_human $used) / $(bytes_to_human $qb)"
        fi
    done <<< "$emails"
    echo ""

    read -p "请输入用户 email（留空取消）: " target_email
    [[ -z "$target_email" ]] && return

    local ex; ex=$(jq --arg e "$target_email" 'has($e)' "$QUOTA_DB" 2>/dev/null)
    [[ "$ex" != "true" ]] && { warn "用户 ${target_email} 未在配额 DB 中"; return; }

    local susp; susp=$(_qget "$target_email" suspended false)
    if [[ "$susp" == "true" ]]; then
        read -p "确认恢复用户 ${target_email} 的访问？（不会重置流量计数）[y/N]: " c
        [[ "$c" != "y" && "$c" != "Y" ]] && return
        _resume_user "$target_email"
    else
        read -p "确认手动暂停用户 ${target_email}？[y/N]: " c
        [[ "$c" != "y" && "$c" != "Y" ]] && return
        _suspend_user "$target_email"
    fi
}

# ─────────────────────────── 配额总览 ────────────────────────────────────────

quota_view() {
    _quota_db_init
    local emails; emails=$(_quota_list_emails)

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                      用户流量配额总览                            ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"

    if [[ -z "$emails" ]]; then
        echo -e "${BLUE}║${NC}  暂无配置流量限制的用户                                        ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  请使用选项 2「设置配额」为用户添加流量限制                    ${BLUE}║${NC}"
    else
        while IFS= read -r email; do
            [[ -z "$email" ]] && continue

            local used_bytes;  used_bytes=$(_qget  "$email" used_bytes  0)
            local quota_bytes; quota_bytes=$(_qget "$email" quota_bytes 0)
            local suspended;   suspended=$(_qget   "$email" suspended   false)
            local set_time;    set_time=$(_qget    "$email" set_time    "未知")

            local used_h;  used_h=$(bytes_to_human  "$used_bytes")
            local quota_h; quota_h=$(bytes_to_human "$quota_bytes")

            # 百分比 & 进度条（20格）
            local pct=0 filled=0
            if [[ "$quota_bytes" -gt 0 ]]; then
                pct=$(awk "BEGIN{v=$used_bytes/$quota_bytes*100; printf \"%.1f\", (v>100?100:v)}")
                filled=$(awk "BEGIN{printf \"%.0f\", $pct/5}")
                [[ "$filled" -gt 20 ]] && filled=20
            fi
            local empty=$(( 20 - filled ))

            # 进度条颜色：<80% 绿，80-99% 黄，100% 红
            local bar_color
            awk "BEGIN{exit !($pct >= 100)}" && bar_color="$RED" \
            || { awk "BEGIN{exit !($pct >= 80)}" && bar_color="$YELLOW" || bar_color="$GREEN"; }

            local bar
            bar="${bar_color}$(printf '█%.0s' $(seq 1 $filled 2>/dev/null))${NC}"
            bar+="$(printf '░%.0s' $(seq 1 $empty 2>/dev/null))"

            # 状态标记
            local status_str
            [[ "$suspended" == "true" ]] \
                && status_str="${RED}● 已暂停${NC}" \
                || status_str="${GREEN}● 正常${NC}"

            echo -e "${BLUE}║${NC}  用户: ${CYAN}${email}${NC}"
            echo -e "${BLUE}║${NC}  进度: [${bar}] ${pct}%   ${used_h} / ${quota_h}"
            echo -e "${BLUE}║${NC}  状态: ${status_str}    配额设置时间: ${set_time}"
            echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
        done <<< "$emails"
    fi

    # 守护进程状态
    local cron_count; cron_count=$(_quota_cron_status)
    local daemon_str
    [[ "${cron_count:-0}" -gt 0 ]] \
        && daemon_str="${GREEN}运行中（每 5 分钟）${NC}" \
        || daemon_str="${RED}未运行${NC} ${DIM}→ 选项 7 安装${NC}"

    echo -e "${BLUE}║${NC}  守护进程: ${daemon_str}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${DIM}  重置策略: 不自动重置，配额用完后暂停，手动重置（选项 4）后恢复${NC}"
}

# ─────────────────────────── 管理菜单入口 ────────────────────────────────────

manage_quota() {
    while true; do
        echo ""
        echo -e "${PURPLE}═══════════════════════════════════════════${NC}"
        echo -e "${PURPLE}           用户流量限额管理${NC}"
        echo -e "${PURPLE}═══════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}1${NC}. 查看配额总览（含进度条）"
        echo -e "  ${GREEN}2${NC}. 为用户设置 / 修改流量配额"
        echo -e "  ${GREEN}3${NC}. 取消用户流量限制"
        echo -e "  ${GREEN}4${NC}. 手动重置用户流量（同时恢复访问）"
        echo -e "  ${GREEN}5${NC}. 手动暂停 / 恢复用户"
        echo -e "  ${GREEN}6${NC}. 立即执行一次流量检查"
        echo -e "  ${GREEN}7${NC}. 安装 / 重置守护进程 Cron"
        echo -e "  ${GREEN}8${NC}. 卸载守护进程 Cron"
        echo -e "  ${GREEN}0${NC}. 返回主菜单"
        echo -e "${PURPLE}═══════════════════════════════════════════${NC}"
        read -p "请选择: " qc

        case $qc in
            1) quota_view ;;
            2) quota_set ;;
            3) quota_remove ;;
            4) quota_reset_user ;;
            5) quota_toggle_suspend ;;
            6)
                info "正在执行流量检查..."
                quota_watchdog
                success "检查完成"
                quota_view
                ;;
            7) _install_quota_cron ;;
            8) _uninstall_quota_cron ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        echo ""
        read -rp "按 Enter 继续..."
    done
}


# ──────────────────────────── 主菜单 ─────────────────────────────────────────
show_menu() {
    clear
    local SRV_IP; SRV_IP=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || echo "获取中...")
    local XRAY_VER; XRAY_VER=$(xray version 2>/dev/null | grep -oP 'Xray \S+' | head -1 || echo "未安装")

    echo -e "${PURPLE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║         Xray 一键管理脚本 Pro  v${SCRIPT_VERSION}          ║${NC}"
    echo -e "${PURPLE}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${PURPLE}║${NC}  IP: ${CYAN}${SRV_IP}${NC}   版本: ${CYAN}${XRAY_VER}${NC}"

    if check_xray_deployed; then
        local STATUS_STR
        systemctl is-active --quiet xray \
            && STATUS_STR="${GREEN}● 运行中${NC}" \
            || STATUS_STR="${RED}● 已停止${NC}"
        echo -e "${PURPLE}║${NC}  状态: ${STATUS_STR}   BBR: $(check_bbr_status && echo "${GREEN}已开启${NC}" || echo "${RED}未开启${NC}")"
        echo -e "${PURPLE}╠══════════════════════════════════════════════════╣${NC}"
        echo -e "${PURPLE}║${NC}  ${BOLD}节点管理${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}1${NC}. 重新部署       ${GREEN}2${NC}. 当前节点信息"
        echo -e "${PURPLE}║${NC}   ${GREEN}3${NC}. 查看节点配置   ${GREEN}4${NC}. 多用户管理"
        echo -e "${PURPLE}║${NC}   ${GREEN}5${NC}. 流量统计       ${GREEN}6${NC}. 流量限额管理"
        echo -e "${PURPLE}║${NC}  ${BOLD}中转 & 代理${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}7${NC}. VLESS中转/Socks5管理"
        echo -e "${PURPLE}║${NC}  ${BOLD}系统管理${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}8${NC}. 查看日志       ${GREEN}9${NC}. 重启服务"
        echo -e "${PURPLE}║${NC}   ${GREEN}10${NC}. 系统状态      ${GREEN}11${NC}. 更新 Xray"
        echo -e "${PURPLE}║${NC}  ${BOLD}工具${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}12${NC}. 防火墙管理    ${GREEN}13${NC}. 备份/恢复"
        echo -e "${PURPLE}║${NC}   ${GREEN}14${NC}. BBR 加速管理  ${GREEN}15${NC}. 卸载 Xray"
        echo -e "${PURPLE}║${NC}   ${GREEN}0${NC}.  退出脚本"
    else
        echo -e "${PURPLE}║${NC}  状态: ${RED}● 未安装${NC}"
        echo -e "${PURPLE}╠══════════════════════════════════════════════════╣${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}1${NC}. 安装 Xray"
        echo -e "${PURPLE}║${NC}   ${GREEN}2${NC}. 系统状态       ${GREEN}3${NC}. BBR 加速管理"
        echo -e "${PURPLE}║${NC}   ${GREEN}4${NC}. 防火墙管理     ${GREEN}5${NC}. 备份/恢复"
        echo -e "${PURPLE}║${NC}   ${GREEN}0${NC}. 退出脚本"
    fi
    echo -e "${PURPLE}╚══════════════════════════════════════════════════╝${NC}"
    echo -ne "请输入选项: "
}

# ──────────────────────────── 主循环 ─────────────────────────────────────────
main() {
    check_root
    detect_system

    while true; do
        show_menu
        read -r choice
        choice=${choice:-1}

        if check_xray_deployed; then
            case $choice in
                1)  redeploy_xray ;;
                2)  view_current_deploy ;;
                3)  view_config ;;
                4)  manage_users ;;
                5)  view_traffic ;;
                6)  manage_quota ;;
                7)  manage_relay_socks5 ;;
                8)  view_logs ;;
                9)
                    systemctl restart xray && sleep 2
                    systemctl is-active --quiet xray \
                        && success "服务重启成功" || warn "服务重启失败，请查看日志"
                    ;;
                10) view_system_status ;;
                11) update_xray ;;
                12) manage_firewall ;;
                13) manage_backup ;;
                14)
                    echo -e "\n  ${GREEN}1${NC}. 开启 BBR  ${GREEN}2${NC}. 关闭 BBR  ${GREEN}3${NC}. 查看状态"
                    read -p "请选择: " bc
                    case $bc in 1) enable_bbr;; 2) disable_bbr;; 3) view_bbr_status;; esac
                    ;;
                15) uninstall ;;
                0)  echo -e "${GREEN}再见！${NC}"; exit 0 ;;
                *)  warn "无效选项，请重新输入" ;;
            esac
        else
            case $choice in
                1)  install_new ;;
                2)  view_system_status ;;
                3)
                    echo -e "\n  ${GREEN}1${NC}. 开启 BBR  ${GREEN}2${NC}. 关闭 BBR  ${GREEN}3${NC}. 查看状态"
                    read -p "请选择: " bc
                    case $bc in 1) enable_bbr;; 2) disable_bbr;; 3) view_bbr_status;; esac
                    ;;
                4)  manage_firewall ;;
                5)  manage_backup ;;
                0)  echo -e "${GREEN}再见！${NC}"; exit 0 ;;
                *)  warn "无效选项，请重新输入" ;;
            esac
        fi

        echo ""
        read -rp "按 Enter 返回主菜单..."
    done
}

# ──────────────────────────── 入口 ───────────────────────────────────────────
# 支持 cron 以 --watchdog 参数直接调用流量检查，不进入交互菜单
if [[ "${1:-}" == "--watchdog" ]]; then
    detect_system
    quota_watchdog
    exit 0
fi

main
