#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

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
        OLD_PORT=$(grep "端口:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_DEST=$(grep "回落目标:" /root/xray-client.txt | awk -F: '{print $2}' | sed 's/:.*//' | tr -d ' ')
        OLD_FP=$(grep "TLS 指纹:" /root/xray-client.txt | awk '{print $3}')
    fi

    UUID=${OLD_UUID:-$(xray uuid)}
    PORT=${OLD_PORT:-443}
    DEST=${OLD_DEST:-"www.microsoft.com"}
    DEST_PORT=443
    FINGERPRINT=${OLD_FP:-"chrome"}

    generate_reality_keys
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
    [[ -f "/root/xray-client.txt" ]] && sed -i "s/端口: ${OLD_PORT}/端口: ${NEW_PORT}/" /root/xray-client.txt

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

    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        read -p "请输入你的域名 (VMess 协议必须): " DOMAIN
        [[ -z "$DOMAIN" ]] && error "VMess 协议必须提供域名"
    else
        DOMAIN=""
    fi

    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        get_reality_input
    fi

    get_cert

    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config ;;
        3) gen_dual_server_config ;;
    esac

    restart_and_show
}

# 配置验证与服务重启
restart_and_show() {
    info "验证配置文件合法性..."
    xray run -test -config /usr/local/etc/xray/config.json > /dev/null 2>&1 || error "配置文件验证失败，请检查语法"

    info "重启 Xray 服务..."
    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray || error "Xray 服务重启失败，请执行 journalctl -u xray 查看错误日志"

    gen_qrcode
    gen_client_config
    save_config
    success "重新部署完成！节点已生效"
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

# ====================== ✅ 核心修复：变量全局化 + 首次安装必成功 ======================
generate_reality_keys() {
    info "开始生成 Reality 密钥对..."

    local KEYS_RAW=""
    if command -v xray &> /dev/null; then
        KEYS_RAW=$(xray x25519 2>&1)
    elif [[ -f /usr/local/bin/xray ]]; then
        KEYS_RAW=$(/usr/local/bin/xray x25519 2>&1)
    fi

    if [[ $? -ne 0 || -z "$KEYS_RAW" ]]; then
        warn "Xray 命令执行失败"
        _manual_input_keys
        return 0
    fi

    PRIVATE_KEY=$(echo "$KEYS_RAW" | grep -i "PrivateKey" | sed -E 's/.*PrivateKey:[[:space:]]*//i' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$KEYS_RAW" | grep -i "Password.*PublicKey" | sed -E 's/.*PublicKey\):[[:space:]]*//i' | tr -d '[:space:]')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        PRIVATE_KEY=$(echo "$KEYS_RAW" | grep -i "private" | sed -E 's/.*(Private Key|Private key):[[:space:]]*//i' | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$KEYS_RAW" | grep -i "public" | sed -E 's/.*(Public Key|Public key):[[:space:]]*//i' | tr -d '[:space:]')
    fi

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        PRIVATE_KEY=$(echo "$KEYS_RAW" | head -1 | awk '{print $NF}' | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$KEYS_RAW" | tail -1 | awk '{print $NF}' | tr -d '[:space:]')
    fi

    if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#PRIVATE_KEY} -ge 40 && ${#PUBLIC_KEY} -ge 40 ]]; then
        success "密钥自动生成成功！"
        return 0
    fi

    warn "自动提取失败，使用手动输入"
    _manual_input_keys
}

_manual_input_keys() {
    echo ""
    echo -e "${YELLOW}手动输入密钥：${NC}"
    echo "示例：PrivateKey: xxx"
    echo ""

    while true; do
        read -p "请输入 PrivateKey: " PRIVATE_KEY
        read -p "请输入 PublicKey: " PUBLIC_KEY

        PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')

        if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
            success "密钥输入完成"
            break
        fi
    done
}

# Reality配置
get_reality_input() {
    generate_reality_keys
    SHORT_ID=$(openssl rand -hex 8)
    info "Short ID: $SHORT_ID"

    echo ""
    echo -e "${PURPLE}请选择 Reality 回落目标${NC}"
    echo -e "  1. www.microsoft.com"
    echo -e "  2. dl.google.com"
    echo -e "  3. www.apple.com"
    echo -e "  4. www.amazon.com"
    echo -e "  5. 自定义"
    read -p "请选择 [默认 1]: " DEST_CHOICE
    DEST_CHOICE=${DEST_CHOICE:-1}

    case $DEST_CHOICE in
        1) DEST="www.microsoft.com" ;;
        2) DEST="dl.google.com" ;;
        3) DEST="www.apple.com" ;;
        4) DEST="www.amazon.com" ;;
        5) read -p "输入域名: " DEST ;;
    esac
    DEST_PORT=443

    echo ""
    read -p "选择 TLS 指纹 1(chrome)/2(firefox) [默认1]: " FP_CHOICE
    FINGERPRINT=${FP_CHOICE:-1}
    FINGERPRINT=$([[ $FINGERPRINT == 1 ]] && echo "chrome" || echo "firefox")
}

# SSL证书
get_cert() {
    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        return
    fi
    [[ -z "$DOMAIN" ]] && return
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        return
    fi
    info "为 $DOMAIN 申请SSL证书..."
    systemctl stop nginx apache2 caddy 2>/dev/null
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN" --key-type ecdsa > /dev/null 2>&1
}

# ====================== ✅ 配置生成（修复首次安装变量为空） ======================
gen_reality_server_config() {
    info "生成 VLESS + Reality 配置..."
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
}

gen_vmess_server_config() {
    info "生成 VMess + TLS + WebSocket 配置..."
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
}

gen_dual_server_config() {
    info "生成双协议配置..."
    mkdir -p /usr/local/etc/xray
    local VMESS_PORT=$((PORT + 1))

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
    VMESS_PORT_FINAL=$VMESS_PORT
}

# Systemd服务
create_systemd_service() {
    info "创建系统服务..."
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

start_service() {
    info "验证配置..."
    xray run -test -config /usr/local/etc/xray/config.json > /dev/null 2>&1 || error "配置无效！"

    info "启动服务..."
    systemctl enable --now xray && sleep 2
    systemctl is-active --quiet xray || error "服务启动失败！"
}

# 客户端链接
gen_vless_reality_link() {
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&xver=0#${REMARK}"
}

gen_vmess_link() {
    local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
    local vmess_json="{\"v\":\"2\",\"ps\":\"${REMARK}-VMess\",\"add\":\"${DOMAIN}\",\"port\":\"${PORT_USE}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess\",\"tls\":\"tls\"}"
    VMESS_LINK="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
}

gen_qrcode() {
    info "生成节点信息..."
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               客户端配置${NC}"
    echo -e "${BLUE}================================================${NC}"

    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        gen_vless_reality_link
        echo -e "${GREEN}VLESS + Reality:${NC}"
        echo -e "${GREEN}${VLESS_LINK}${NC}"
        qrencode -t ANSIUTF8 "$VLESS_LINK"

    elif [[ "$PROTOCOL_CHOICE" == "2" ]]; then
        gen_vmess_link
        echo -e "${GREEN}VMess:${NC}"
        echo -e "${GREEN}${VMESS_LINK}${NC}"
        qrencode -t ANSIUTF8 "$VMESS_LINK"
    else
        gen_vless_reality_link
        gen_vmess_link
        echo -e "${GREEN}VLESS:${NC}"
        echo "$VLESS_LINK"
        qrencode -t ANSIUTF8 "$VLESS_LINK"
        echo -e "${GREEN}VMess:${NC}"
        echo "$VMESS_LINK"
        qrencode -t ANSIUTF8 "$VMESS_LINK"
    fi
    echo -e "${BLUE}================================================${NC}"
}

gen_client_config() {
    echo -e "\n${PURPLE}================================================${NC}"
    echo -e "${PURPLE}           客户端 JSON 配置${NC}"
    echo -e "${PURPLE}================================================${NC}"
}

save_config() {
    local config_file="/root/xray-client.txt"
    gen_vless_reality_link
    [[ "$PROTOCOL_CHOICE" =~ 2|3 ]] && gen_vmess_link

    cat > "$config_file" << EOF
==========================================
    XRAY 节点配置
==========================================
服务器IP: ${SERVER_IP}
域名: ${DOMAIN:-无}
UUID: ${UUID}
端口: ${PORT}
配置时间: $(date "+%Y-%m-%d %H:%M:%S")
==========================================

【VLESS Reality】
私钥: ${PRIVATE_KEY}
公钥: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
SNI: ${DEST}
指纹: ${FINGERPRINT}

节点链接:
${VLESS_LINK}
==========================================
EOF
    info "配置已保存到: $config_file"
}

setup_cert_renewal() {
    [[ "$PROTOCOL_CHOICE" == "1" ]] && return
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * certbot renew --quiet && systemctl restart xray") | crontab -
}

uninstall() {
    echo ""
    warn "即将卸载 Xray，所有数据将删除！"
    read -p "确定卸载? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    systemctl disable --now xray 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /var/log/xray /etc/systemd/system/xray.service /root/xray-client.txt
    systemctl daemon-reload
    success "Xray 已卸载"
}

view_config() {
    [[ -f "/root/xray-client.txt" ]] && cat /root/xray-client.txt || warn "无配置文件"
}

view_logs() {
    journalctl -u xray --no-pager -n 30
}

show_menu() {
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}       Xray 一键安装脚本(修复版)${NC}"
    echo -e "${PURPLE}============================================${NC}"

    if check_xray_deployed; then
        echo -e "  1. 重新部署 Xray"
        echo -e "  2. 查看部署信息"
        echo -e "  3. 卸载 Xray"
        echo -e "  4. 查看节点配置"
        echo -e "  5. 查看运行日志"
        echo -e "  6. 重启服务"
        echo -e "  7. 开启 BBR"
        echo -e "  8. 关闭 BBR"
        echo -e "  9. 查看 BBR 状态"
        echo -e "  10. 退出"
    else
        echo -e "  1. 安装 Xray + BBR"
        echo -e "  2. 卸载 Xray"
        echo -e "  3. 查看节点配置"
        echo -e "  4. 查看运行日志"
        echo -e "  5. 重启服务"
        echo -e "  6. 开启 BBR"
        echo -e "  7. 关闭 BBR"
        echo -e "  8. 查看 BBR 状态"
        echo -e "  9. 退出"
    fi
    echo -e "${PURPLE}============================================${NC}"
}

install_new() {
    install_dependencies
    install_xray
    select_protocol

    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器IP: $SERVER_IP"

    read -p "监听端口 [默认443]: " PORT
    PORT=${PORT:-443}
    read -p "节点备注 [默认xray]: " REMARK
    REMARK=${REMARK:-"xray"}

    UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "UUID: $UUID"

    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        read -p "请输入域名: " DOMAIN
    fi

    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        get_reality_input
    fi

    get_cert

    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config ;;
        3) gen_dual_server_config ;;
    esac

    create_systemd_service
    start_service
    setup_cert_renewal
    gen_qrcode
    save_config

    read -p "开启 BBR? [Y/n]: " bbr
    [[ "$bbr" != "n" && "$bbr" != "N" ]] && enable_bbr

    success "安装完成！第一次直接成功！"
}

main() {
    check_root
    detect_system

    while true; do
        show_menu
        read -p "请选择: " choice
        choice=${choice:-1}

        if check_xray_deployed; then
            case $choice in
                1) redeploy_xray ;;
                2) view_current_deploy ;;
                3) uninstall ;;
                4) view_config ;;
                5) view_logs ;;
                6) systemctl restart xray && success "重启成功" ;;
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
                5) warn "未安装" ;;
                6) enable_bbr ;;
                7) disable_bbr ;;
                8) view_bbr_status ;;
                9) exit 0 ;;
                *) warn "无效选项" ;;
            esac
        fi
    done
}

main
