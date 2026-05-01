#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量初始化
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
FINGERPRINT="chrome"
DEST=""
DEST_PORT=443
UUID=""
PORT=443
SERVER_IP=""
DOMAIN=""
REMARK="xray"
PROTOCOL_CHOICE=1
VMESS_PORT_FINAL=""
VLESS_LINK=""
VMESS_LINK=""

# 基础日志函数
info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
success() { echo -e "${CYAN}[SUCCESS] $1${NC}"; }

# 权限与系统检测
check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
}

detect_system() {
    if [[ -f /etc/debian_version ]]; then
        PM="apt"
        SYSTEM="debian"
    elif [[ -f /etc/redhat-release ]]; then
        PM="yum"
        SYSTEM="redhat"
    else
        error "不支持的系统，仅支持Debian/Ubuntu/RHEL/CentOS系列"
    fi
}

# 依赖检查与安装
check_dependency_installed() {
    local pkg=$1
    case $SYSTEM in
        debian)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && return 0
            ;;
        redhat)
            rpm -q "$pkg" &>/dev/null && return 0
            ;;
    esac
    return 1
}

install_dependencies() {
    info "检查系统依赖..."

    local packages_to_install=""
    local all_installed=true

    for pkg in curl wget jq openssl certbot qrencode net-tools unzip dnsutils; do
        if ! check_dependency_installed "$pkg"; then
            packages_to_install="$packages_to_install $pkg"
            all_installed=false
        fi
    done

    if $all_installed; then
        info "所有依赖已安装，跳过"
        return 0
    fi

    info "更新包管理器索引..."
    $PM update -y > /dev/null 2>&1

    info "安装缺失依赖: $packages_to_install"
    $PM install -y $packages_to_install > /dev/null 2>&1
}

# Xray核心安装
install_xray() {
    if command -v xray &> /dev/null; then
        info "Xray 已安装: $(xray version | head -1)"
        return
    fi

    info "开始安装 Xray 最新版..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || {
        warn "官方脚本安装失败，尝试手动安装..."

        local ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="64" ;;
            aarch64) ARCH="arm64-v8a" ;;
            armv7l) ARCH="arm32-v7a" ;;
            *) error "不支持的CPU架构: $ARCH" ;;
        esac

        local VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
        [[ -z "$VERSION" ]] && error "获取最新版本号失败"
        local URL="https://github.com/XTLS/Xray-core/releases/download/${VERSION}/Xray-linux-${ARCH}.zip"

        wget -q "$URL" -O /tmp/xray.zip || error "安装包下载失败"
        mkdir -p /usr/local/xray
        unzip -o /tmp/xray.zip -d /usr/local/xray > /dev/null 2>&1
        mv /usr/local/xray/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        rm -rf /tmp/xray.zip /usr/local/xray
    }

    mkdir -p /var/log/xray /usr/local/etc/xray
    chmod 644 /var/log/xray
    command -v xray &> /dev/null || error "Xray安装失败，请手动检查"
    success "Xray 安装完成"
}

# 部署状态检测
check_xray_deployed() {
    if [[ -f "/usr/local/etc/xray/config.json" ]] && command -v xray &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 查看当前部署信息
view_current_deploy() {
    if [[ ! -f "/usr/local/etc/xray/config.json" ]]; then
        warn "未找到Xray配置文件"
        return 1
    fi

    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               当前部署信息${NC}"
    echo -e "${BLUE}================================================${NC}"

    local CONFIG=$(cat /usr/local/etc/xray/config.json)
    local PORT=$(echo "$CONFIG" | grep -o '"port": [0-9]*' | head -1 | grep -o '[0-9]*')
    echo -e "${YELLOW}监听端口:${NC} ${PORT:-未知}"

    if echo "$CONFIG" | grep -q "realitySettings"; then
        echo -e "${YELLOW}核心协议:${NC} VLESS + Reality + Vision"
    elif echo "$CONFIG" | grep -q '"protocol": "vmess"'; then
        echo -e "${YELLOW}核心协议:${NC} VMess + TLS + WebSocket"
    else
        echo -e "${YELLOW}核心协议:${NC} 混合/其他协议"
    fi

    systemctl is-active --quiet xray && STATUS="${GREEN}运行中${NC}" || STATUS="${RED}已停止${NC}"
    echo -e "${YELLOW}服务状态:${NC} $STATUS"
    echo -e "${YELLOW}Xray 版本:${NC} $(xray version 2>/dev/null | head -1 || echo '未知')"

    [[ -f "/root/xray-client.txt" ]] && echo -e "${YELLOW}配置更新时间:${NC} $(grep "配置时间:" /root/xray-client.txt | cut -d: -f2-)"
    echo -e "${BLUE}================================================${NC}"
}

# 重新部署主逻辑
redeploy_xray() {
    echo ""
    warn "重新部署将覆盖当前所有配置，请提前备份"
    view_current_deploy

    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}           重新部署选项${NC}"
    echo -e "${PURPLE}============================================${NC}"
    echo -e "  ${GREEN}1${NC}. 保留当前 UUID，更新其他配置"
    echo -e "  ${GREEN}2${NC}. 全部重新生成 (包括 UUID)"
    echo -e "  ${GREEN}3${NC}. 只更新 Reality 密钥"
    echo -e "  ${GREEN}4${NC}. 只更换监听端口"
    echo -e "  ${GREEN}5${NC}. 返回主菜单"
    echo -e "${PURPLE}============================================${NC}"
    read -p "请选择 [默认 1]: " REDEPLOY_CHOICE
    REDEPLOY_CHOICE=${REDEPLOY_CHOICE:-1}

    case $REDEPLOY_CHOICE in
        1) redeploy_keep_uuid ;;
        2) redeploy_full ;;
        3) redeploy_update_keys ;;
        4) redeploy_change_port ;;
        5) return ;;
        *) warn "无效选择，请重新输入"; return ;;
    esac
}

# 保留UUID重新部署
redeploy_keep_uuid() {
    info "保留 UUID 重新部署..."
    if [[ -f "/root/xray-client.txt" ]]; then
        OLD_UUID=$(grep "UUID:" /root/xray-client.txt | head -1 | awk '{print $2}')
        info "读取到当前 UUID: $OLD_UUID"
    else
        warn "未找到历史配置，将生成新 UUID"
        OLD_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    fi
    UUID=$OLD_UUID
    redeploy_common
}

# 全量重新生成
redeploy_full() {
    info "全部配置重新生成..."
    UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "生成的新 UUID: $UUID"
    redeploy_common
}

# 仅更新Reality密钥
redeploy_update_keys() {
    [[ ! -f "/usr/local/etc/xray/config.json" ]] && error "未找到配置文件，无法更新密钥"
    grep -q "realitySettings" /usr/local/etc/xray/config.json || error "当前配置不是 Reality 协议，无法更新密钥"

    info "开始更新 Reality 密钥对..."
    if [[ -f "/root/xray-client.txt" ]]; then
        OLD_UUID=$(grep "UUID:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_PORT=$(grep "监听端口:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_DEST=$(grep "回落目标:" /root/xray-client.txt | awk -F: '{print $2}' | sed 's/:.*//' | tr -d ' ')
        OLD_FP=$(grep "TLS 指纹:" /root/xray-client.txt | awk '{print $3}')
    fi

    UUID=${OLD_UUID:-$(xray uuid)}
    PORT=${OLD_PORT:-443}
    DEST=${OLD_DEST:-"www.microsoft.com"}
    DEST_PORT=443
    FINGERPRINT=${OLD_FP:-"chrome"}

    # 自动生成密钥，失败则兜底手动
    generate_reality_keys_once
    SHORT_ID=$(openssl rand -hex 8)
    info "生成的 Short ID: $SHORT_ID"

    REMARK="xray"
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    gen_reality_server_config
    restart_and_show
}

# 仅更换端口
redeploy_change_port() {
    info "更换监听端口..."
    [[ ! -f "/usr/local/etc/xray/config.json" ]] && error "未找到配置文件"

    local OLD_PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/xray/config.json | head -1 | grep -o '[0-9]*')
    info "当前监听端口: $OLD_PORT"
    read -p "请输入新的监听端口: " NEW_PORT
    [[ -z "$NEW_PORT" ]] && error "端口不能为空"

    ss -tuln | grep -q ":${NEW_PORT} " && {
        warn "端口 $NEW_PORT 已被其他程序占用"
        read -p "是否强制继续? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    }

    sed -i "0,/\"port\": ${OLD_PORT}/s/\"port\": ${OLD_PORT}/\"port\": ${NEW_PORT}/" /usr/local/etc/xray/config.json
    [[ -f "/root/xray-client.txt" ]] && sed -i "s/监听端口: ${OLD_PORT}/监听端口: ${NEW_PORT}/" /root/xray-client.txt

    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray && success "端口更新完成，服务已重启" || warn "服务重启失败，请检查日志"
}

# 重新部署通用流程
redeploy_common() {
    select_protocol
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器公网IP: $SERVER_IP"

    read -p "请输入监听端口 [默认443]: " PORT
    PORT=${PORT:-443}
    read -p "请输入节点备注名称 [默认xray]: " REMARK
    REMARK=${REMARK:-"xray"}

    # VMess/双协议需要域名
    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        read -p "请输入你的域名 (VMess 协议必须): " DOMAIN
        [[ -z "$DOMAIN" ]] && error "VMess 协议必须提供域名"
    else
        DOMAIN=""
    fi

    # Reality协议需要配置回落目标
    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        get_reality_input
    fi

    # 申请SSL证书
    get_cert

    # 生成对应配置
    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config ;;
        3) gen_dual_server_config ;;
    esac

    restart_and_show
}

# ====================== 【修复1】统一的服务启动与展示函数 ======================
# restart_and_show 同时支持首次启动（enable+start）和重启（restart）两种场景
restart_and_show() {
    info "验证配置文件合法性..."
    xray run -test -config /usr/local/etc/xray/config.json > /dev/null 2>&1 || error "配置文件验证失败，请检查语法"

    info "启动/重启 Xray 服务..."
    # 先 enable 确保开机自启，再用 restart 统一处理首次启动和重启两种场景
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray || error "Xray 服务启动失败，请执行 journalctl -u xray 查看错误日志"

    gen_qrcode
    gen_client_config
    save_config
    success "部署完成！节点已生效"
}

# BBR加速相关
check_kernel_version() {
    local KERNEL_VERSION=$(uname -r | cut -d '-' -f 1)
    [[ $(echo "$KERNEL_VERSION 4.9" | awk '{if($1>=$2) print 1; else print 0}') -eq 1 ]] && return 0 || return 1
}

check_bbr_status() {
    [[ "$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')" == "bbr" ]] && return 0 || return 1
}

enable_bbr() {
    info "开始开启 BBR 加速..."
    check_kernel_version || { warn "内核版本低于4.9，无法开启BBR"; return 1; }
    check_bbr_status && { success "BBR 已经处于开启状态"; return 0; }

    cat >> /etc/sysctl.conf << EOF
# BBR 加速配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p > /dev/null 2>&1

    sleep 1
    check_bbr_status && success "BBR 加速开启成功" || warn "BBR 开启失败，请手动检查内核配置"
}

disable_bbr() {
    info "关闭 BBR 加速..."
    sed -i '/# BBR 加速配置/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    sysctl -p > /dev/null 2>&1
    success "BBR 已关闭，已切换为 cubic 算法"
}

view_bbr_status() {
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               BBR 加速状态${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo -e "${YELLOW}系统内核版本:${NC} $(uname -r)"
    echo -e "${YELLOW}TCP 拥塞算法:${NC} $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
    echo -e "${BLUE}================================================${NC}"
    check_bbr_status && success "BBR 加速已正常开启" || warn "BBR 加速未开启"
}

# 协议选择菜单
select_protocol() {
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}           请选择安装方式${NC}"
    echo -e "${PURPLE}============================================${NC}"
    echo -e "  ${GREEN}1${NC}. VLESS + Reality + Vision (推荐，无需域名)"
    echo -e "  ${GREEN}2${NC}. VMess + TLS + WebSocket (需要域名)"
    echo -e "  ${GREEN}3${NC}. 同时安装两种协议 (需要域名)"
    echo -e "${PURPLE}============================================${NC}"
    read -p "请选择 [默认 1]: " PROTOCOL_CHOICE
    PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}
}

# ====================== 【修复核心】全自动密钥生成函数 ======================
generate_reality_keys_once() {
    info "开始全自动生成 Reality 密钥对..."

    # 重置变量
    PRIVATE_KEY=""
    PUBLIC_KEY=""

    # 查找 xray 命令路径
    local XRAY_CMD=""
    if command -v xray &> /dev/null; then
        XRAY_CMD="xray"
    elif [[ -f /usr/local/bin/xray ]]; then
        XRAY_CMD="/usr/local/bin/xray"
    elif [[ -f /usr/bin/xray ]]; then
        XRAY_CMD="/usr/bin/xray"
    else
        warn "未找到 xray 命令，进入手动输入模式"
        _manual_input_keys
        return 0
    fi

    # 执行一次密钥生成，把输出按行存入数组
    mapfile -t KEYS_LINES < <($XRAY_CMD x25519 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 || ${#KEYS_LINES[@]} -lt 2 ]]; then
        warn "Xray 密钥生成命令执行失败，错误信息: ${KEYS_LINES[*]}"
        _manual_input_keys
        return 0
    fi

    # 固定行提取：第1行=私钥，第2行=公钥
    PRIVATE_KEY=$(echo "${KEYS_LINES[0]}" | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "${KEYS_LINES[1]}" | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | tr -d '[:space:]')

    # 密钥合法性校验
    if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#PRIVATE_KEY} -eq 43 && ${#PUBLIC_KEY} -eq 43 ]]; then
        success "密钥全自动生成成功！"
        info "服务端 PrivateKey: ${PRIVATE_KEY}"
        info "客户端 PublicKey:  ${PUBLIC_KEY}"
        return 0
    fi

    warn "自动生成的密钥校验不通过，进入手动输入模式"
    _manual_input_keys
}

# 手动输入密钥兜底函数
_manual_input_keys() {
    echo ""
    echo -e "${YELLOW}手动输入密钥操作指南：${NC}"
    echo "1. 新开终端窗口，执行命令: ${GREEN}xray x25519${NC}"
    echo "2. 复制对应的值，只粘贴冒号后面的密钥内容"
    echo ""
    echo -e "${YELLOW}xray 输出格式：${NC}"
    echo "  第1行 PrivateKey: xxxxx  <-- 粘贴到 PrivateKey 输入框"
    echo "  第2行 PublicKey:  yyyyy  <-- 粘贴到 PublicKey 输入框"
    echo ""
    echo -e "${RED}注意：不要复制第3行的 Hash32！${NC}"
    echo ""

    while true; do
        read -p "请粘贴 PrivateKey (私钥): " PRIVATE_KEY
        read -p "请粘贴 PublicKey (公钥): " PUBLIC_KEY

        PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')

        if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#PRIVATE_KEY} -ge 40 && ${#PUBLIC_KEY} -ge 40 ]]; then
            success "密钥输入验证通过"
            break
        else
            warn "密钥长度异常，请检查输入是否正确"
            read -p "是否确认使用? [y/N]: " confirm
            [[ "$confirm" == "y" || "$confirm" == "Y" ]] && break
        fi
    done
}

# Reality回落目标配置
get_reality_input() {
    generate_reality_keys_once

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "Reality 密钥生成失败，无法继续配置"
    fi

    SHORT_ID=$(openssl rand -hex 8)
    info "生成的 Short ID: $SHORT_ID"

    DEST="www.microsoft.com"
    DEST_PORT=443
    FINGERPRINT="chrome"
    info "回落目标: ${DEST}:${DEST_PORT}"
    info "TLS指纹: ${FINGERPRINT}"
}

# SSL证书申请
get_cert() {
    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        info "VLESS + Reality 协议无需申请SSL证书"
        return
    fi

    [[ -z "$DOMAIN" ]] && error "域名不能为空"

    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        warn "证书已存在，跳过申请"
        return
    fi

    info "开始申请SSL证书..."
    local DOMAIN_IP=$(dig +short "$DOMAIN" | tail -1)
    SERVER_IP=$(curl -s4 ip.sb)
    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        warn "域名解析IP与服务器IP不匹配"
        read -p "是否继续申请? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && error "请先将域名解析到服务器IP"
    fi

    systemctl stop nginx apache2 caddy 2>/dev/null
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN" --key-type ecdsa || {
        error "SSL证书申请失败"
    }
    success "SSL证书申请成功"
}

# ====================== 配置文件生成 ======================
gen_reality_server_config() {
    info "生成 VLESS + Reality 服务端配置..."

    if [[ -z "$UUID" || -z "$PORT" || -z "$PRIVATE_KEY" || -z "$SHORT_ID" || -z "$DEST" ]]; then
        error "配置参数不完整"
    fi

    mkdir -p /usr/local/etc/xray

    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https://223.5.5.5/dns-query",
      "https://1.1.1.1/dns-query",
      "8.8.8.8",
      "1.0.0.1"
    ],
    "queryStrategy": "UseIP"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "xver": 0,
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:${DEST_PORT}",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "TOS": 64,
          "tcpKeepAliveIdle": 30
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block",
        "enabled": true
      }
    ]
  }
}
EOF

    success "服务端配置生成完成"
    info "确认配置文件内 privateKey = ${PRIVATE_KEY}"
}

gen_vmess_server_config() {
    info "生成 VMess + TLS + WebSocket 服务端配置..."

    if [[ -z "$UUID" || -z "$PORT" || -z "$DOMAIN" ]]; then
        error "配置参数不完整"
    fi

    mkdir -p /usr/local/etc/xray

    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https://223.5.5.5/dns-query",
      "https://1.1.1.1/dns-query"
    ]
  },
  "inbounds": [
    {
      "tag": "vmess-ws-tls-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess",
          "headers": {
            "Host": "${DOMAIN}"
          }
        },
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
          "minVersion": "1.3"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    success "服务端配置生成完成"
}

gen_dual_server_config() {
    info "生成双协议配置..."

    if [[ -z "$UUID" || -z "$PORT" || -z "$PRIVATE_KEY" || -z "$SHORT_ID" || -z "$DEST" || -z "$DOMAIN" ]]; then
        error "配置参数不完整"
    fi

    mkdir -p /usr/local/etc/xray
    local VMESS_PORT=$((PORT + 1))
    VMESS_PORT_FINAL=$VMESS_PORT

    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https://223.5.5.5/dns-query",
      "https://1.1.1.1/dns-query"
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "xver": 0,
        "realitySettings": {
          "dest": "${DEST}:443",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "vmess-ws-tls-in",
      "listen": "::",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess",
          "headers": {
            "Host": "${DOMAIN}"
          }
        },
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
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    success "服务端配置生成完成"
}

# ====================== 【修复2】Systemd服务创建 ======================
# 官方安装脚本通常已创建服务文件，此函数仅在手动安装时补充创建
create_systemd_service() {
    # 如果服务文件已由官方脚本创建，则跳过以避免覆盖官方配置
    if [[ -f "/etc/systemd/system/xray.service" ]]; then
        info "Systemd 服务文件已存在，跳过创建"
        systemctl daemon-reload
        return 0
    fi

    info "创建 Xray Systemd 服务..."
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS
After=network.target nss-lookup.target

[Service]
User=root
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ====================== 链接生成 ======================
gen_vless_reality_link() {
    if [[ -z "$UUID" || -z "$SERVER_IP" || -z "$PORT" || -z "$DEST" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
        warn "VLESS 链接参数不完整"
        VLESS_LINK=""
        return 1
    fi

    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&xver=0#${REMARK}"
    info "确认链接内 pbk = ${PUBLIC_KEY}"
    return 0
}

gen_vmess_link() {
    local PORT_USE=${VMESS_PORT_FINAL:-$PORT}

    if [[ -z "$UUID" || -z "$DOMAIN" || -z "$PORT_USE" ]]; then
        warn "VMess 链接参数不完整"
        VMESS_LINK=""
        return 1
    fi

    local vmess_json="{\"v\":\"2\",\"ps\":\"${REMARK}-VMess\",\"add\":\"${DOMAIN}\",\"port\":\"${PORT_USE}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess\",\"tls\":\"tls\"}"
    VMESS_LINK="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
    return 0
}

# 二维码生成
gen_qrcode() {
    info "生成客户端节点信息..."
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               客户端节点配置${NC}"
    echo -e "${BLUE}================================================${NC}"

    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        gen_vless_reality_link || error "VLESS 链接生成失败"

        echo -e "${GREEN}【VLESS + Reality + Vision】${NC}"
        echo ""
        echo -e "${YELLOW}密钥配对确认:${NC}"
        echo -e "  config.json privateKey: ${PRIVATE_KEY}"
        echo -e "  链接 pbk: ${PUBLIC_KEY}"
        echo ""
        echo -e "${YELLOW}节点链接:${NC}"
        echo -e "${GREEN}${VLESS_LINK}${NC}"
        echo ""
        echo -e "${YELLOW}节点二维码:${NC}"
        qrencode -t ANSIUTF8 "$VLESS_LINK"

    elif [[ "$PROTOCOL_CHOICE" == "2" ]]; then
        gen_vmess_link || error "VMess 链接生成失败"

        echo -e "${GREEN}【VMess + TLS + WebSocket】${NC}"
        echo -e "${YELLOW}节点链接:${NC}"
        echo -e "${GREEN}${VMESS_LINK}${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$VMESS_LINK"

    else
        gen_vless_reality_link || warn "VLESS 链接生成失败"
        gen_vmess_link || warn "VMess 链接生成失败"

        echo -e "${GREEN}【VLESS + Reality】(端口 ${PORT})${NC}"
        if [[ -n "$VLESS_LINK" ]]; then
            echo ""
            echo -e "${YELLOW}密钥配对确认:${NC}"
            echo -e "  privateKey: ${PRIVATE_KEY}"
            echo -e "  pbk: ${PUBLIC_KEY}"
            echo ""
            echo -e "${VLESS_LINK}"
            qrencode -t ANSIUTF8 "$VLESS_LINK"
        fi

        echo ""
        echo -e "${BLUE}================================================${NC}"
        echo -e "${GREEN}【VMess + TLS】(端口 ${VMESS_PORT_FINAL})${NC}"
        if [[ -n "$VMESS_LINK" ]]; then
            echo -e "${VMESS_LINK}"
            qrencode -t ANSIUTF8 "$VMESS_LINK"
        fi
    fi
    echo -e "${BLUE}================================================${NC}"
}

# 客户端JSON配置
gen_client_config() {
    echo -e "\n${PURPLE}================================================${NC}"
    echo -e "${PURPLE}          客户端 JSON 配置${NC}"
    echo -e "${PURPLE}================================================${NC}"

    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        if [[ -z "$SERVER_IP" || -z "$PORT" || -z "$UUID" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" || -z "$DEST" ]]; then
            warn "VLESS 客户端配置参数不完整"
        else
            echo -e "${GREEN}【VLESS + Reality 客户端配置】${NC}"
            cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 10808,
      "listen": "::",
      "protocol": "socks",
      "settings": { "udp": true, "auth": "noauth" }
    },
    {
      "tag": "http-in",
      "port": 10809,
      "listen": "::",
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_IP}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID}",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "xver": 0,
        "realitySettings": {
          "fingerprint": "${FINGERPRINT}",
          "serverName": "${DEST}",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF
        fi
    fi

    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        [[ "$PROTOCOL_CHOICE" == "3" ]] && echo ""
        local PORT_USE=${VMESS_PORT_FINAL:-$PORT}

        if [[ -z "$DOMAIN" || -z "$PORT_USE" || -z "$UUID" ]]; then
            warn "VMess 客户端配置参数不完整"
        else
            echo -e "${GREEN}【VMess + TLS 客户端配置】${NC}"
            cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 10808,
      "listen": "::",
      "protocol": "socks",
      "settings": { "udp": true }
    },
    {
      "tag": "http-in",
      "port": 10809,
      "listen": "::",
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "${DOMAIN}",
            "port": ${PORT_USE},
            "users": [
              {
                "id": "${UUID}",
                "alterId": 0,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess",
          "headers": { "Host": "${DOMAIN}" }
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "fingerprint": "chrome"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF
        fi
    fi
    echo -e "${PURPLE}================================================${NC}"
}

# 配置文件保存
save_config() {
    local config_file="/root/xray-client.txt"

    cat > "$config_file" << EOF
==========================================
    Xray 节点配置信息
==========================================
服务器IP: ${SERVER_IP}
域名: ${DOMAIN:-无需域名}
UUID: ${UUID}
配置时间: $(date "+%Y-%m-%d %H:%M:%S")
==========================================

EOF

    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        cat >> "$config_file" << EOF
【VLESS + Reality + Vision】
监听端口: ${PORT}
回落目标: ${DEST}:${DEST_PORT}

密钥配对关系（必须一致）
服务端 privateKey: ${PRIVATE_KEY}
客户端 publicKey:  ${PUBLIC_KEY}

Short ID: ${SHORT_ID}
TLS 指纹: ${FINGERPRINT}

节点链接:
${VLESS_LINK:-生成失败}

EOF
    fi

    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
        cat >> "$config_file" << EOF
【VMess + TLS + WebSocket】
监听端口: ${PORT_USE}
WebSocket路径: /vmess

节点链接:
${VMESS_LINK:-生成失败}

EOF
    fi

    local TCP_ALGORITHM=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    cat >> "$config_file" << EOF
【系统状态】
TCP 拥塞算法: ${TCP_ALGORITHM}
==========================================
EOF

    info "配置已保存到: $config_file"
}

# 证书续期
setup_cert_renewal() {
    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        info "Reality协议无需证书续期"
        return
    fi

    info "设置证书自动续期..."
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * certbot renew --quiet && systemctl restart xray") | crontab -
    success "证书续期已设置"
}

# 卸载
uninstall() {
    echo ""
    warn "即将卸载 Xray"
    read -p "确认卸载? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    info "开始卸载..."
    systemctl disable --now xray 2>/dev/null
    rm -f /etc/systemd/system/xray.service
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /var/log/xray
    rm -f /root/xray-client.txt
    systemctl daemon-reload

    read -p "是否删除SSL证书? [y/N]: " del_cert
    [[ "$del_cert" == "y" ]] && rm -rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf

    success "Xray 已卸载"
}

# 辅助功能
view_config() {
    if [[ -f "/root/xray-client.txt" ]]; then
        cat /root/xray-client.txt
        echo ""
        read -p "是否显示二维码? [y/N]: " show_qr
        if [[ "$show_qr" == "y" || "$show_qr" == "Y" ]]; then
            if grep -q "VLESS" /root/xray-client.txt; then
                local vless_link=$(grep -A1 "节点链接:" /root/xray-client.txt | tail -1)
                echo -e "${GREEN}VLESS 二维码:${NC}"
                qrencode -t ANSIUTF8 "$vless_link"
            fi
            if grep -q "VMess" /root/xray-client.txt; then
                local vmess_link=$(grep -A1 "节点链接:" /root/xray-client.txt | tail -1)
                echo -e "${GREEN}VMess 二维码:${NC}"
                qrencode -t ANSIUTF8 "$vmess_link"
            fi
        fi
    else
        warn "未找到配置文件"
    fi
}

view_logs() {
    echo ""
    echo -e "${PURPLE}================================================${NC}"
    echo -e "${PURPLE}               Xray 运行日志${NC}"
    echo -e "${PURPLE}================================================${NC}"
    journalctl -u xray --no-pager -n 30
}

# 主菜单
show_menu() {
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}       Xray 一键安装脚本(全自动修复版)${NC}"
    echo -e "${PURPLE}============================================${NC}"

    if check_xray_deployed; then
        echo -e "  ${GREEN}1${NC}. 重新部署 Xray"
        echo -e "  ${GREEN}2${NC}. 查看当前部署信息"
        echo -e "  ${GREEN}3${NC}. 卸载 Xray"
        echo -e "  ${GREEN}4${NC}. 查看节点配置信息"
        echo -e "  ${GREEN}5${NC}. 查看 Xray 运行日志"
        echo -e "  ${GREEN}6${NC}. 重启 Xray 服务"
        echo -e "  ${GREEN}7${NC}. 开启 BBR 加速"
        echo -e "  ${GREEN}8${NC}. 关闭 BBR 加速"
        echo -e "  ${GREEN}9${NC}. 查看 BBR 状态"
        echo -e "  ${GREEN}10${NC}. 退出脚本"
    else
        echo -e "  ${GREEN}1${NC}. 安装 Xray + 开启 BBR 加速"
        echo -e "  ${GREEN}2${NC}. 卸载 Xray"
        echo -e "  ${GREEN}3${NC}. 查看节点配置信息"
        echo -e "  ${GREEN}4${NC}. 查看 Xray 运行日志"
        echo -e "  ${GREEN}5${NC}. 重启 Xray 服务"
        echo -e "  ${GREEN}6${NC}. 开启 BBR 加速"
        echo -e "  ${GREEN}7${NC}. 关闭 BBR 加速"
        echo -e "  ${GREEN}8${NC}. 查看 BBR 状态"
        echo -e "  ${GREEN}9${NC}. 退出脚本"
    fi
    echo -e "${PURPLE}============================================${NC}"
}

# ====================== 【修复3】全新安装流程 ======================
install_new() {
    # 重置所有全局变量
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    SHORT_ID=""
    FINGERPRINT="chrome"
    DEST=""
    DEST_PORT=443
    UUID=""
    PORT=443
    SERVER_IP=""
    DOMAIN=""
    REMARK="xray"
    PROTOCOL_CHOICE=1
    VMESS_PORT_FINAL=""
    VLESS_LINK=""
    VMESS_LINK=""

    install_dependencies
    install_xray
    select_protocol

    # 获取服务器IP
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器公网IP: $SERVER_IP"

    # 基础参数设置
    read -p "请输入监听端口 [默认443]: " PORT
    PORT=${PORT:-443}
    read -p "请输入节点备注名称 [默认xray]: " REMARK
    REMARK=${REMARK:-"xray"}
    UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "生成的 UUID: $UUID"

    # VMess需要域名
    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        read -p "请输入域名 (VMess必须): " DOMAIN
        [[ -z "$DOMAIN" ]] && error "VMess 协议必须提供域名"
    else
        DOMAIN=""
    fi

    # Reality协议配置
    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        get_reality_input
    fi

    # 申请证书
    get_cert

    # 生成配置
    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config ;;
        3) gen_dual_server_config ;;
    esac

    # 创建 systemd 服务文件（手动安装时补充）
    create_systemd_service

    # ====================== 核心修复点 ======================
    # 原代码调用 start_service()（内含 enable+start）后再单独调用展示函数，
    # 与 redeploy 走不同路径，导致首次部署行为不一致。
    # 修复：统一调用 restart_and_show()，该函数已改为先 enable 再 restart，
    # 首次安装和重新部署均走同一套验证→启动→展示流程。
    restart_and_show

    # 证书续期
    setup_cert_renewal

    # 开启BBR
    read -p "是否开启 BBR 加速? [Y/n]: " enable_bbr_choice
    enable_bbr_choice=${enable_bbr_choice:-Y}
    [[ "$enable_bbr_choice" == "y" || "$enable_bbr_choice" == "Y" ]] && enable_bbr

    success "Xray 安装完成！节点可正常使用"
}

# 主函数
main() {
    check_root
    detect_system

    while true; do
        show_menu
        read -p "请输入选项编号: " choice
        choice=${choice:-1}

        if check_xray_deployed; then
            case $choice in
                1) redeploy_xray ;;
                2) view_current_deploy ;;
                3) uninstall ;;
                4) view_config ;;
                5) view_logs ;;
                6)
                    systemctl restart xray && sleep 2
                    systemctl is-active --quiet xray && success "服务重启成功" || warn "服务重启失败"
                    ;;
                7) enable_bbr ;;
                8) disable_bbr ;;
                9) view_bbr_status ;;
                10) exit 0 ;;
                *) warn "无效选项" ;;
            esac
        else
            case $choice in
                1) install_new ;;
                2) uninstall ;;
                3) view_config ;;
                4) view_logs ;;
                5) warn "Xray 未安装" ;;
                6) enable_bbr ;;
                7) disable_bbr ;;
                8) view_bbr_status ;;
                9) exit 0 ;;
                *) warn "无效选项" ;;
            esac
        fi
    done
}

# 执行主函数
main
