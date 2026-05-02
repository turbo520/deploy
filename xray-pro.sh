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
readonly SCRIPT_VERSION="2.0.0"
readonly STATS_FILE="/root/xray-stats.json"

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


# ──────────────────────────── VLESS 中转 / Socks5 ────────────────────────────

# 生成 VLESS 中转配置（本机作为入口，转发到多台下游服务器，支持负载均衡）
gen_vless_relay_config() {
    step "配置 VLESS 中转（多下游服务器）"
    echo -e "${DIM}本机作为中转节点，接受客户端 VLESS 连接后，按策略转发到多台下游 Xray 服务器${NC}\n"

    # 本地入站
    read -p "中转节点监听端口 [默认 443]: " RELAY_IN_PORT
    RELAY_IN_PORT=${RELAY_IN_PORT:-443}
    local RELAY_UUID; RELAY_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "中转入站 UUID: $RELAY_UUID"

    # 入站安全方式
    echo -e "\n${YELLOW}入站安全方式:${NC}"
    echo -e "  ${GREEN}1${NC}. Reality（推荐，无需域名）"
    echo -e "  ${GREEN}2${NC}. TLS（需要证书域名）"
    echo -e "  ${GREEN}3${NC}. 无加密（内网/受信任环境）"
    read -p "请选择 [默认 1]: " relay_sec; relay_sec=${relay_sec:-1}

    local RELAY_PRIVATE_KEY="" RELAY_PUBLIC_KEY="" RELAY_SHORT_ID=""
    local RELAY_DEST="www.microsoft.com" RELAY_DOMAIN=""

    if [[ "$relay_sec" == "1" ]]; then
        generate_reality_keys_once
        RELAY_PRIVATE_KEY=$PRIVATE_KEY; RELAY_PUBLIC_KEY=$PUBLIC_KEY
        RELAY_SHORT_ID=$(openssl rand -hex 8)
    elif [[ "$relay_sec" == "2" ]]; then
        read -p "请输入证书域名: " RELAY_DOMAIN
        [[ -z "$RELAY_DOMAIN" ]] && error "TLS 模式需要域名"
        DOMAIN=$RELAY_DOMAIN; get_cert
    fi

    # 收集下游服务器列表
    local OUTBOUNDS_JSON="" BALANCER_TAGS=()
    local server_count=0

    echo -e "\n${YELLOW}添加下游服务器（输入空地址结束）:${NC}"
    while true; do
        server_count=$((server_count + 1))
        echo -e "\n  ${GREEN}下游服务器 #${server_count}${NC}"
        read -p "  服务器地址 (留空结束): " DS_ADDR
        [[ -z "$DS_ADDR" ]] && { server_count=$((server_count - 1)); break; }

        read -p "  服务器端口 [默认 443]: " DS_PORT; DS_PORT=${DS_PORT:-443}
        read -p "  UUID: " DS_UUID
        [[ -z "$DS_UUID" ]] && { warn "UUID 不能为空，跳过此服务器"; server_count=$((server_count - 1)); continue; }

        echo -e "  ${YELLOW}下游安全方式:${NC}"
        echo -e "    ${GREEN}1${NC}. Reality   ${GREEN}2${NC}. TLS   ${GREEN}3${NC}. 无"
        read -p "  请选择 [默认 1]: " ds_sec; ds_sec=${ds_sec:-1}

        local ds_flow="" ds_stream=""
        case $ds_sec in
            1)
                read -p "  下游 PublicKey: " DS_PBK
                read -p "  下游 ShortId: "   DS_SID
                read -p "  下游 SNI [默认 www.microsoft.com]: " DS_SNI
                DS_SNI=${DS_SNI:-"www.microsoft.com"}
                ds_flow='"flow": "xtls-rprx-vision",'
                ds_stream=$(cat << STREAM
        "streamSettings": {
          "network": "tcp", "security": "reality",
          "realitySettings": {
            "fingerprint": "chrome",
            "serverName": "${DS_SNI}",
            "publicKey": "${DS_PBK}",
            "shortId": "${DS_SID}"
          }
        }
STREAM
)
                ;;
            2)
                read -p "  下游 SNI/域名: " DS_SNI
                ds_stream=$(cat << STREAM
        "streamSettings": {
          "network": "tcp", "security": "tls",
          "tlsSettings": { "serverName": "${DS_SNI}" }
        }
STREAM
)
                ;;
            3)
                ds_stream='"streamSettings": { "network": "tcp" }'
                ;;
        esac

        local tag="downstream-${server_count}"
        BALANCER_TAGS+=("\"$tag\"")

        local ob_entry
        ob_entry=$(cat << OB
    {
      "tag": "${tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${DS_ADDR}",
          "port": ${DS_PORT},
          "users": [{ "id": "${DS_UUID}", ${ds_flow} "encryption": "none" }]
        }]
      },
${ds_stream}
    }
OB
)
        OUTBOUNDS_JSON="${OUTBOUNDS_JSON}${ob_entry},"
        success "下游服务器 #${server_count} 已添加: ${DS_ADDR}:${DS_PORT}"
    done

    [[ $server_count -eq 0 ]] && { warn "至少需要添加一台下游服务器"; return 1; }

    # 负载均衡策略
    echo -e "\n${YELLOW}负载均衡策略:${NC}"
    echo -e "  ${GREEN}1${NC}. 随机（每次随机选一台）"
    echo -e "  ${GREEN}2${NC}. 轮询（依次使用）"
    read -p "请选择 [默认 1]: " lb_type; lb_type=${lb_type:-1}
    local lb_strategy="random"
    [[ "$lb_type" == "2" ]] && lb_strategy="roundRobin"

    # 拼接入站 streamSettings
    local IN_STREAM=""
    case $relay_sec in
        1)
            IN_STREAM=$(cat << SS
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "${RELAY_DEST}:443",
          "serverNames": ["${RELAY_DEST}"],
          "privateKey": "${RELAY_PRIVATE_KEY}",
          "shortIds": ["${RELAY_SHORT_ID}", ""]
        }
      }
SS
)
            ;;
        2)
            IN_STREAM=$(cat << SS
      "streamSettings": {
        "network": "tcp", "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "/etc/letsencrypt/live/${RELAY_DOMAIN}/fullchain.pem",
            "keyFile": "/etc/letsencrypt/live/${RELAY_DOMAIN}/privkey.pem"
          }]
        }
      }
SS
)
            ;;
        3) IN_STREAM='"streamSettings": { "network": "tcp" }' ;;
    esac

    local BALANCER_TAGS_STR; BALANCER_TAGS_STR=$(IFS=,; echo "${BALANCER_TAGS[*]}")

    mkdir -p /usr/local/etc/xray
    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [{
    "tag": "relay-in",
    "listen": "::",
    "port": ${RELAY_IN_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${RELAY_UUID}", "flow": "xtls-rprx-vision", "email": "relay-user@xray" }],
      "decryption": "none"
    },
${IN_STREAM},
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
${OUTBOUNDS_JSON}
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "balancers": [{
    "tag": "relay-balancer",
    "selector": [${BALANCER_TAGS_STR}],
    "strategy": { "type": "${lb_strategy}" }
  }],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["relay-in"], "balancerTag": "relay-balancer" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

    xray run -test -config "$XRAY_CONFIG" > /dev/null 2>&1 \
        || error "配置验证失败，请检查下游参数"

    open_port "$RELAY_IN_PORT" tcp
    create_systemd_service
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray && success "中转节点启动成功" || error "启动失败，请查看日志"

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              VLESS 中转节点信息${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}本机入站地址:${NC} $(curl -s4 ip.sb || curl -s6 ip.sb):${RELAY_IN_PORT}"
    echo -e "${YELLOW}入站 UUID:${NC}    $RELAY_UUID"
    [[ "$relay_sec" == "1" ]] && {
        echo -e "${YELLOW}PublicKey:${NC}    $RELAY_PUBLIC_KEY"
        echo -e "${YELLOW}ShortId:${NC}      $RELAY_SHORT_ID"
        echo -e "${YELLOW}SNI:${NC}          $RELAY_DEST"
    }
    echo -e "${YELLOW}下游服务器数:${NC} $server_count"
    echo -e "${YELLOW}负载均衡:${NC}     $lb_strategy"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    # 保存中转配置摘要
    cat > "$CLIENT_FILE" << EOF
==========================================
      Xray VLESS 中转节点配置
==========================================
生成时间:   $(date "+%Y-%m-%d %H:%M:%S")
监听端口:   ${RELAY_IN_PORT}
入站 UUID:  ${RELAY_UUID}
PublicKey:  ${RELAY_PUBLIC_KEY:-N/A}
ShortId:    ${RELAY_SHORT_ID:-N/A}
SNI:        ${RELAY_DEST}
下游数量:   ${server_count}
负载策略:   ${lb_strategy}
==========================================
EOF
    info "中转配置摘要已保存至 $CLIENT_FILE"
}

# 生成 Socks5 入站配置（本机开放 Socks5，可叠加在现有配置上）
gen_socks5_config() {
    step "配置 Socks5 代理入站"
    echo -e "${DIM}在本机开放 Socks5 代理，适合内网使用或与其他服务叠加${NC}\n"

    # 如果已有配置，询问是否叠加
    local MERGE=false
    if [[ -f "$XRAY_CONFIG" ]]; then
        read -p "检测到现有 Xray 配置，是否叠加添加 Socks5 入站? [Y/n]: " mg
        mg=${mg:-Y}
        [[ "$mg" == "y" || "$mg" == "Y" ]] && MERGE=true
    fi

    read -p "Socks5 监听端口 [默认 1080]: " S5_PORT; S5_PORT=${S5_PORT:-1080}
    read -p "监听地址 [默认 0.0.0.0，填 127.0.0.1 限本机]: " S5_LISTEN
    S5_LISTEN=${S5_LISTEN:-"0.0.0.0"}

    local S5_AUTH=false S5_USER="" S5_PASS=""
    read -p "是否启用账号密码认证? [y/N]: " auth_yn
    if [[ "$auth_yn" == "y" || "$auth_yn" == "Y" ]]; then
        S5_AUTH=true
        read -p "用户名: " S5_USER
        read -p "密码: "   S5_PASS
        [[ -z "$S5_USER" || -z "$S5_PASS" ]] && { warn "用户名/密码不能为空"; return 1; }
    fi

    local UDP_SUPPORT=true
    read -p "启用 UDP 支持? [Y/n]: " udp_yn; udp_yn=${udp_yn:-Y}
    [[ "$udp_yn" != "y" && "$udp_yn" != "Y" ]] && UDP_SUPPORT=false

    # 构造 Socks5 入站 JSON 片段
    local AUTH_BLOCK=""
    if $S5_AUTH; then
        AUTH_BLOCK='"auth": "password", "accounts": [{"user": "'"$S5_USER"'", "pass": "'"$S5_PASS"'"}],'
    else
        AUTH_BLOCK='"auth": "noauth",'
    fi

    local S5_INBOUND
    S5_INBOUND=$(cat << EOF
    {
      "tag": "socks5-in",
      "listen": "${S5_LISTEN}",
      "port": ${S5_PORT},
      "protocol": "socks",
      "settings": {
        ${AUTH_BLOCK}
        "udp": ${UDP_SUPPORT}
      }
    }
EOF
)

    if $MERGE; then
        # 向现有配置追加入站
        jq --argjson nb "$S5_INBOUND" '.inbounds += [$nb]' \
            "$XRAY_CONFIG" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$XRAY_CONFIG"
        info "Socks5 入站已合并到现有配置"
    else
        # 全新配置（带 freedom 出站）
        mkdir -p /usr/local/etc/xray
        cat > "$XRAY_CONFIG" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [${S5_INBOUND}],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }]
  }
}
EOF
    fi

    xray run -test -config "$XRAY_CONFIG" > /dev/null 2>&1 \
        || error "配置验证失败"

    open_port "$S5_PORT" tcp
    $UDP_SUPPORT && open_port "$S5_PORT" udp

    create_systemd_service
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray && success "Socks5 代理启动成功" || error "启动失败，请查看日志"

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              Socks5 代理节点信息${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    local PUB_IP; PUB_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    echo -e "${YELLOW}地址:${NC}    $PUB_IP"
    echo -e "${YELLOW}端口:${NC}    $S5_PORT"
    if $S5_AUTH; then
        echo -e "${YELLOW}用户名:${NC}  $S5_USER"
        echo -e "${YELLOW}密码:${NC}    $S5_PASS"
    else
        echo -e "${YELLOW}认证:${NC}    无需认证"
    fi
    echo -e "${YELLOW}UDP:${NC}     $UDP_SUPPORT"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    # 保存 Socks5 配置
    cat >> "$CLIENT_FILE" << EOF

==========================================
       Socks5 代理配置
==========================================
生成时间: $(date "+%Y-%m-%d %H:%M:%S")
地址:     ${PUB_IP}
端口:     ${S5_PORT}
用户名:   ${S5_USER:-无}
密码:     ${S5_PASS:-无}
UDP:      ${UDP_SUPPORT}
==========================================
EOF
}

# 中转/Socks5 管理菜单
manage_relay_socks5() {
    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════${NC}"
    echo -e "${PURPLE}     VLESS 中转 / Socks5 管理${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════${NC}"
    echo -e "  ${GREEN}1${NC}. 配置 VLESS 中转（多下游服务器）"
    echo -e "  ${GREEN}2${NC}. 添加 Socks5 代理入站"
    echo -e "  ${GREEN}3${NC}. 返回主菜单"
    echo -e "${PURPLE}═══════════════════════════════════════${NC}"
    read -p "请选择: " rc

    case $rc in
        1) gen_vless_relay_config ;;
        2) gen_socks5_config ;;
        3) return ;;
        *) warn "无效选项" ;;
    esac
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
    echo -e "  ${GREEN}2${NC}. VLESS 中转节点（转发多台下游服务器）"
    echo -e "  ${GREEN}3${NC}. Socks5 代理"
    echo -e "${PURPLE}═══════════════════════════════════════════════${NC}"
    read -p "请选择 [默认 1]: " INSTALL_TYPE; INSTALL_TYPE=${INSTALL_TYPE:-1}

    case $INSTALL_TYPE in
        2) gen_vless_relay_config; enable_bbr; return ;;
        3) gen_socks5_config; enable_bbr; return ;;
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
        echo -e "${PURPLE}║${NC}   ${GREEN}5${NC}. 流量统计"
        echo -e "${PURPLE}║${NC}  ${BOLD}中转 & 代理${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}6${NC}. VLESS中转/Socks5管理"
        echo -e "${PURPLE}║${NC}  ${BOLD}系统管理${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}7${NC}. 查看日志       ${GREEN}8${NC}. 重启服务"
        echo -e "${PURPLE}║${NC}   ${GREEN}9${NC}. 系统状态       ${GREEN}10${NC}. 更新 Xray"
        echo -e "${PURPLE}║${NC}  ${BOLD}工具${NC}"
        echo -e "${PURPLE}║${NC}   ${GREEN}11${NC}. 防火墙管理    ${GREEN}12${NC}. 备份/恢复"
        echo -e "${PURPLE}║${NC}   ${GREEN}13${NC}. BBR 加速管理  ${GREEN}14${NC}. 卸载 Xray"
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
                6)  manage_relay_socks5 ;;
                7)  view_logs ;;
                8)
                    systemctl restart xray && sleep 2
                    systemctl is-active --quiet xray \
                        && success "服务重启成功" || warn "服务重启失败，请查看日志"
                    ;;
                9)  view_system_status ;;
                10) update_xray ;;
                11) manage_firewall ;;
                12) manage_backup ;;
                13)
                    echo -e "\n  ${GREEN}1${NC}. 开启 BBR  ${GREEN}2${NC}. 关闭 BBR  ${GREEN}3${NC}. 查看状态"
                    read -p "请选择: " bc
                    case $bc in 1) enable_bbr;; 2) disable_bbr;; 3) view_bbr_status;; esac
                    ;;
                14) uninstall ;;
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
main
