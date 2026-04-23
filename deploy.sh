#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
success() { echo -e "${CYAN}[SUCCESS] $1${NC}"; }

check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
}

# ===== 修复1: 系统检测和包管理器更新分离 =====
detect_system() {
    if [[ -f /etc/debian_version ]]; then
        PM="apt"
        SYSTEM="debian"
    elif [[ -f /etc/redhat-release ]]; then
        PM="yum"
        SYSTEM="redhat"
    else
        error "不支持的系统"
    fi
}

# 只在需要安装依赖时才更新包管理器
update_package_manager() {
    info "更新包管理器..."
    $PM update -y
}

# ===== 修复2: 检查依赖是否已安装 =====
check_dependencies_installed() {
    local missing=0
    for pkg in curl wget jq openssl certbot qrencode net-tools unzip; do
        if ! command -v "$pkg" &> /dev/null && ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && ! rpm -q "$pkg" &> /dev/null; then
            missing=1
            break
        fi
    done
    return $missing
}

install_dependencies() {
    # 先检查是否已安装
    if check_dependencies_installed; then
        info "依赖已安装，跳过"
        return 0
    fi
    
    info "安装缺失依赖..."
    
    # 检查每个包，只安装缺失的
    local packages_to_install=""
    for pkg in curl wget jq openssl certbot qrencode net-tools unzip; do
        case $SYSTEM in
            debian)
                if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                    packages_to_install="$packages_to_install $pkg"
                fi
                ;;
            redhat)
                if ! rpm -q "$pkg" &> /dev/null; then
                    packages_to_install="$packages_to_install $pkg"
                fi
                ;;
        esac
    done
    
    if [[ -n "$packages_to_install" ]]; then
        info "安装: $packages_to_install"
        $PM install -y $packages_to_install
    fi
}

install_xray() {
    if command -v xray &> /dev/null; then
        info "Xray 已安装: $(xray version | head -1)"
        return
    fi
    
    info "安装 Xray..."
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || {
        warn "官方脚本失败，尝试手动安装..."
        
        local ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="64" ;;
            aarch64) ARCH="arm64-v8a" ;;
            armv7l) ARCH="arm32-v7a" ;;
            *) error "不支持的架构: $ARCH"
        esac
        
        local VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
        local URL="https://github.com/XTLS/Xray-core/releases/download/${VERSION}/Xray-linux-${ARCH}.zip"
        
        info "下载 Xray ${VERSION}..."
        wget -q "$URL" -O /tmp/xray.zip
        
        mkdir -p /usr/local/xray
        unzip -o /tmp/xray.zip -d /usr/local/xray
        
        mv /usr/local/xray/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        
        rm -rf /tmp/xray.zip /usr/local/xray
    }
    
    mkdir -p /var/log/xray
}

check_xray_deployed() {
    if [[ -f "/usr/local/etc/xray/config.json" ]] && command -v xray &> /dev/null; then
        return 0
    else
        return 1
    fi
}

view_current_deploy() {
    if [[ ! -f "/usr/local/etc/xray/config.json" ]]; then
        warn "未找到配置文件"
        return 1
    fi
    
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               当前部署信息${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    local CONFIG=$(cat /usr/local/etc/xray/config.json)
    
    local PORT=$(echo "$CONFIG" | grep -o '"port": [0-9]*' | head -1 | grep -o '[0-9]*')
    echo -e "${YELLOW}端口:${NC} ${PORT:-未知}"
    
    if echo "$CONFIG" | grep -q "realitySettings"; then
        echo -e "${YELLOW}协议:${NC} VLESS + Reality"
    elif echo "$CONFIG" | grep -q '"protocol": "vmess"'; then
        echo -e "${YELLOW}协议:${NC} VMess"
    else
        echo -e "${YELLOW}协议:${NC} 其他"
    fi
    
    if systemctl is-active --quiet xray; then
        echo -e "${YELLOW}服务状态:${NC} ${GREEN}运行中${NC}"
    else
        echo -e "${YELLOW}服务状态:${NC} ${RED}已停止${NC}"
    fi
    
    echo -e "${YELLOW}Xray 版本:${NC} $(xray version 2>/dev/null | head -1 || echo '未知')"
    
    if [[ -f "/root/xray-client.txt" ]]; then
        local CONFIG_TIME=$(grep "配置时间:" /root/xray-client.txt | cut -d: -f2-)
        echo -e "${YELLOW}上次配置:${NC} ${CONFIG_TIME:-未知}"
    fi
    
    echo -e "${BLUE}================================================${NC}"
}

redeploy_xray() {
    echo ""
    warn "重新部署将覆盖当前配置"
    
    view_current_deploy
    
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}           重新部署选项${NC}"
    echo -e "${PURPLE}============================================${NC}"
    echo -e "  ${GREEN}1${NC}. 保留当前 UUID，更新其他配置"
    echo -e "  ${GREEN}2${NC}. 全部重新生成 (包括 UUID)"
    echo -e "  ${GREEN}3${NC}. 只更新 Reality 密钥"
    echo -e "  ${GREEN}4${NC}. 只更换端口"
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
        *) warn "无效选择"; return ;;
    esac
}

redeploy_keep_uuid() {
    info "保留 UUID 重新部署..."
    
    if [[ -f "/root/xray-client.txt" ]]; then
        OLD_UUID=$(grep "UUID:" /root/xray-client.txt | head -1 | awk '{print $2}')
        info "当前 UUID: $OLD_UUID"
    else
        warn "未找到旧配置，将生成新 UUID"
        OLD_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    fi
    
    UUID=$OLD_UUID
    redeploy_common
}

redeploy_full() {
    info "全部重新生成..."
    
    UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "新 UUID: $UUID"
    
    redeploy_common
}

redeploy_update_keys() {
    if [[ ! -f "/usr/local/etc/xray/config.json" ]]; then
        error "未找到配置文件"
    fi
    
    if ! grep -q "realitySettings" /usr/local/etc/xray/config.json; then
        error "当前配置不是 Reality 协议"
    fi
    
    info "更新 Reality 密钥..."
    
    if [[ -f "/root/xray-client.txt" ]]; then
        OLD_UUID=$(grep "UUID:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_PORT=$(grep "端口:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_DEST=$(grep "回落目标:" /root/xray-client.txt | awk -F: '{print $2}' | sed 's/:.*//' | tr -d ' ')
    else
        warn "未找到旧配置"
        return
    fi
    
    UUID=$OLD_UUID
    PORT=${OLD_PORT:-443}
    DEST=${OLD_DEST:-"www.microsoft.com"}
    DEST_PORT=443
    
    generate_reality_keys
    
    echo ""
    echo -e "${PURPLE}请选择 TLS 指纹:${NC}"
    echo -e "  ${GREEN}1${NC}. chrome (推荐)"
    echo -e "  ${GREEN}2${NC}. firefox"
    read -p "请选择 [默认 1]: " FP_CHOICE
    FP_CHOICE=${FP_CHOICE:-1}
    FINGERPRINT=$([[ "$FP_CHOICE" == "1" ]] && echo "chrome" || echo "firefox")
    
    REMARK="xray"
    DOMAIN=""
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    
    gen_reality_server_config
    restart_and_show
}

redeploy_change_port() {
    info "更换端口..."
    
    if [[ ! -f "/usr/local/etc/xray/config.json" ]]; then
        error "未找到配置文件"
    fi
    
    local OLD_PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/xray/config.json | head -1 | grep -o '[0-9]*')
    info "当前端口: $OLD_PORT"
    
    read -p "请输入新端口: " NEW_PORT
    [[ -z "$NEW_PORT" ]] && error "端口不能为空"
    
    if netstat -tuln | grep -q ":${NEW_PORT} "; then
        warn "端口 $NEW_PORT 已被占用"
        read -p "是否继续? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi
    
    sed -i "0,/\"port\": ${OLD_PORT}/s/\"port\": ${OLD_PORT}/\"port\": ${NEW_PORT}/" /usr/local/etc/xray/config.json
    
    if [[ -f "/root/xray-client.txt" ]]; then
        sed -i "s/端口: ${OLD_PORT}/端口: ${NEW_PORT}/" /root/xray-client.txt
    fi
    
    info "端口已更新为 $NEW_PORT"
    
    systemctl restart xray
    sleep 2
    systemctl is-active --quiet xray && success "服务已重启" || warn "重启失败"
}

redeploy_common() {
    select_protocol
    
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器 IP: $SERVER_IP"
    
    read -p "请输入监听端口 [默认443]: " PORT
    PORT=${PORT:-443}
    
    read -p "请输入备注名称 [默认xray]: " REMARK
    REMARK=${REMARK:-"xray"}
    
    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        read -p "请输入你的域名 (VMess 需要): " DOMAIN
        [[ -z "$DOMAIN" ]] && error "域名不能为空"
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

restart_and_show() {
    info "验证配置..."
    
    local TEST_OUTPUT=$(xray run -test -config /usr/local/etc/xray/config.json 2>&1)
    if echo "$TEST_OUTPUT" | grep -q "Failed"; then
        echo "$TEST_OUTPUT"
        error "配置验证失败"
    fi
    
    info "重启 Xray 服务..."
    systemctl restart xray
    
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 重启成功"
    else
        error "Xray 重启失败"
    fi
    
    gen_qrcode
    gen_client_config
    save_config
    
    success "重新部署完成！"
}

# BBR
check_kernel_version() {
    local KERNEL_VERSION=$(uname -r | cut -d '-' -f 1)
    local MIN_VERSION="4.9"
    info "当前内核版本: $(uname -r)"
    
    if [[ $(echo "$KERNEL_VERSION $MIN_VERSION" | awk '{if($1>=$2) print 1; else print 0}') -eq 1 ]]; then
        return 0
    else
        return 1
    fi
}

check_bbr_status() {
    local BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    [[ "$BBR_STATUS" == "bbr" ]] && return 0 || return 1
}

enable_bbr() {
    info "开启 BBR 加速..."
    
    if ! check_kernel_version; then
        warn "内核版本低于 4.9"
        return 1
    fi
    
    if check_bbr_status; then
        success "BBR 已开启"
        return 0
    fi
    
    info "配置 BBR..."
    
    grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF

# BBR 加速配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    
    sysctl -p > /dev/null 2>&1
    
    sleep 1
    if check_bbr_status; then
        success "BBR 加速已开启"
        return 0
    else
        warn "BBR 开启失败"
        return 1
    fi
}

disable_bbr() {
    info "关闭 BBR 加速..."
    
    sed -i '/# BBR 加速配置/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    sysctl -p > /dev/null 2>&1
    
    info "BBR 已关闭"
}

view_bbr_status() {
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               BBR 加速状态${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    echo -e "${YELLOW}内核版本:${NC} $(uname -r)"
    echo -e "${YELLOW}TCP 拥塞控制:${NC} $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    
    echo -e "${BLUE}================================================${NC}"
    
    if check_bbr_status; then
        success "BBR 加速已开启"
    else
        warn "BBR 加速未开启"
    fi
}

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

generate_reality_keys() {
    info "生成 Reality 密钥对..."
    
    local KEYS_RAW=$(xray x25519 2>&1)
    
    PRIVATE_KEY=$(echo "$KEYS_RAW" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS_RAW" | grep -i "public" | awk '{print $NF}')
    
    if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#PRIVATE_KEY} -ge 40 && ${#PUBLIC_KEY} -ge 40 ]]; then
        info "密钥生成成功"
        info "Private Key: $PRIVATE_KEY"
        info "Public Key: $PUBLIC_KEY"
        return 0
    fi
    
    warn "自动生成失败，请手动输入密钥值"
    echo ""
    
    read -p "Private Key: " PRIVATE_KEY
    read -p "Public Key: " PUBLIC_KEY
    
    PRIVATE_KEY=$(echo "$PRIVATE_KEY" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$PUBLIC_KEY" | awk '{print $NF}')
    
    info "Private Key: $PRIVATE_KEY"
    info "Public Key: $PUBLIC_KEY"
}

get_reality_input() {
    generate_reality_keys
    
    SHORT_ID=$(openssl rand -hex 8)
    info "Short ID: $SHORT_ID"
    
    echo ""
    echo -e "${PURPLE}请选择回落目标 (dest):${NC}"
    echo -e "  ${GREEN}1${NC}. www.microsoft.com (推荐)"
    echo -e "  ${GREEN}2${NC}. www.apple.com"
    echo -e "  ${GREEN}3${NC}. www.amazon.com"
    echo -e "  ${GREEN}4${NC}. www.google.com"
    echo -e "  ${GREEN}5${NC}. 自定义"
    read -p "请选择 [默认 1]: " DEST_CHOICE
    DEST_CHOICE=${DEST_CHOICE:-1}
    
    case $DEST_CHOICE in
        1) DEST="www.microsoft.com"; DEST_PORT=443 ;;
        2) DEST="www.apple.com"; DEST_PORT=443 ;;
        3) DEST="www.amazon.com"; DEST_PORT=443 ;;
        4) DEST="www.google.com"; DEST_PORT=443 ;;
        5) 
            read -p "请输入回落目标地址: " DEST
            read -p "请输入回落目标端口 [默认443]: " DEST_PORT
            DEST_PORT=${DEST_PORT:-443}
            ;;
        *) DEST="www.microsoft.com"; DEST_PORT=443 ;;
    esac
    
    info "回落目标: ${DEST}:${DEST_PORT}"
    
    echo ""
    echo -e "${PURPLE}请选择 TLS 指纹:${NC}"
    echo -e "  ${GREEN}1${NC}. chrome (推荐)"
    echo -e "  ${GREEN}2${NC}. firefox"
    read -p "请选择 [默认 1]: " FP_CHOICE
    FP_CHOICE=${FP_CHOICE:-1}
    
    FINGERPRINT=$([[ "$FP_CHOICE" == "1" ]] && echo "chrome" || echo "firefox")
    
    info "TLS 指纹: $FINGERPRINT"
}

get_cert() {
    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        info "VLESS + Reality 无需证书"
        return
    fi
    
    if [[ -z "$DOMAIN" ]]; then
        error "VMess 需要域名，但未提供"
    fi
    
    info "申请 SSL 证书..."
    
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        warn "证书已存在，跳过"
        return
    fi
    
    info "检查域名解析..."
    local DOMAIN_IP=$(dig +short "$DOMAIN" | tail -1)
    
    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        warn "域名解析不匹配: $DOMAIN_IP vs $SERVER_IP"
        read -p "是否继续? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && error "请先配置域名解析"
    fi
    
    if netstat -tuln | grep -q ":80 "; then
        warn "80 端口被占用"
        systemctl stop nginx apache2 caddy 2>/dev/null
    fi
    
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN" --key-type ecdsa || {
        error "证书申请失败"
    }
    
    info "证书申请成功"
}

gen_reality_server_config() {
    info "生成 VLESS + Reality 服务端配置..."
    
    mkdir -p /usr/local/etc/xray
    
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
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
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:${DEST_PORT}",
          "serverNames": [
            "${DEST}",
            "www.${DEST}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
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
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

gen_vmess_server_config() {
    info "生成 VMess + TLS + WebSocket 服务端配置..."
    
    mkdir -p /usr/local/etc/xray
    
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
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
          "alpn": [
            "h2",
            "http/1.1"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
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
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

gen_dual_server_config() {
    info "生成双协议服务端配置..."
    
    mkdir -p /usr/local/etc/xray
    
    local VMESS_PORT=$((PORT + 1))
    
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
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
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:${DEST_PORT}",
          "serverNames": [
            "${DEST}",
            "www.${DEST}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
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
          ],
          "alpn": [
            "h2",
            "http/1.1"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
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
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
    
    VMESS_PORT_FINAL=$VMESS_PORT
}

create_systemd_service() {
    info "创建 systemd 服务..."
    
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
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
    info "验证配置文件..."
    
    local TEST_OUTPUT=$(xray run -test -config /usr/local/etc/xray/config.json 2>&1)
    if echo "$TEST_OUTPUT" | grep -q "Failed"; then
        echo "$TEST_OUTPUT"
        error "配置验证失败"
    fi
    
    info "启动 Xray 服务..."
    
    systemctl enable xray
    systemctl restart xray
    
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 启动成功"
    else
        error "Xray 启动失败，查看日志: journalctl -u xray -n 20"
    fi
}

gen_vless_reality_link() {
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${REMARK}"
}

gen_vmess_link() {
    local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
    
    local vmess_json="{\"v\":\"2\",\"ps\":\"${REMARK}-VMess\",\"add\":\"${DOMAIN}\",\"port\":\"${PORT_USE}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\"}"
    
    local vmess_base64=$(echo -n "$vmess_json" | base64 -w 0 2>/dev/null || echo -n "$vmess_json" | base64)
    VMESS_LINK="vmess://${vmess_base64}"
}

gen_qrcode() {
    info "生成二维码..."
    
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               客户端配置信息${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        gen_vless_reality_link
        
        echo -e "${GREEN}【VLESS + Reality + Vision】${NC}"
        echo ""
        echo -e "${YELLOW}服务器地址:${NC} ${SERVER_IP}"
        echo -e "${YELLOW}端口:${NC} ${PORT}"
        echo -e "${YELLOW}UUID:${NC} ${UUID}"
        echo -e "${YELLOW}Flow:${NC} xtls-rprx-vision"
        echo -e "${YELLOW}SNI:${NC} ${DEST}"
        echo -e "${YELLOW}Public Key:${NC} ${PUBLIC_KEY}"
        echo -e "${YELLOW}Short ID:${NC} ${SHORT_ID}"
        echo -e "${YELLOW}Fingerprint:${NC} ${FINGERPRINT}"
        echo ""
        echo -e "${YELLOW}链接:${NC}"
        echo -e "${GREEN}${VLESS_LINK}${NC}"
        echo ""
        echo -e "${YELLOW}二维码:${NC}"
        qrencode -t ANSIUTF8 "$VLESS_LINK"
        
    elif [[ "$PROTOCOL_CHOICE" == "2" ]]; then
        gen_vmess_link
        
        echo -e "${GREEN}【VMess + TLS + WebSocket】${NC}"
        echo ""
        echo -e "${YELLOW}服务器地址:${NC} ${DOMAIN}"
        echo -e "${YELLOW}端口:${NC} ${PORT}"
        echo -e "${YELLOW}UUID:${NC} ${UUID}"
        echo -e "${YELLOW}路径:${NC} /vmess"
        echo -e "${YELLOW}TLS:${NC} 启用"
        echo ""
        echo -e "${YELLOW}链接:${NC}"
        echo -e "${GREEN}${VMESS_LINK}${NC}"
        echo ""
        echo -e "${YELLOW}二维码:${NC}"
        qrencode -t ANSIUTF8 "$VMESS_LINK"
        
    else
        gen_vless_reality_link
        gen_vmess_link
        
        echo -e "${GREEN}【VLESS + Reality】(端口 ${PORT})${NC}"
        echo ""
        echo -e "${YELLOW}链接:${NC}"
        echo -e "${GREEN}${VLESS_LINK}${NC}"
        echo ""
        echo -e "${YELLOW}二维码:${NC}"
        qrencode -t ANSIUTF8 "$VLESS_LINK"
        
        echo ""
        echo -e "${BLUE}================================================${NC}"
        
        echo -e "${GREEN}【VMess + TLS】(端口 ${VMESS_PORT_FINAL})${NC}"
        echo ""
        echo -e "${YELLOW}链接:${NC}"
        echo -e "${GREEN}${VMESS_LINK}${NC}"
        echo ""
        echo -e "${YELLOW}二维码:${NC}"
        qrencode -t ANSIUTF8 "$VMESS_LINK"
    fi
    
    echo ""
    echo -e "${BLUE}================================================${NC}"
}

gen_client_config() {
    echo ""
    echo -e "${PURPLE}================================================${NC}"
    echo -e "${PURPLE}          客户端 JSON 配置${NC}"
    echo -e "${PURPLE}================================================${NC}"
    
    if [[ "$PROTOCOL_CHOICE" == "1" ]] || [[ "$PROTOCOL_CHOICE" == "3" ]]; then
        echo -e "${GREEN}【VLESS + Reality + Vision】${NC}"
        cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http", "port": 10809, "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${SERVER_IP}",
          "port": ${PORT},
          "users": [{ "id": "${UUID}", "flow": "xtls-rprx-vision", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "${FINGERPRINT}",
          "serverName": "${DEST}",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ]
}
EOF
    fi
    
    if [[ "$PROTOCOL_CHOICE" == "2" ]] || [[ "$PROTOCOL_CHOICE" == "3" ]]; then
        [[ "$PROTOCOL_CHOICE" == "3" ]] && echo ""
        local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
        
        echo -e "${GREEN}【VMess + TLS + WebSocket】${NC}"
        cat << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http", "port": 10809, "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [{
          "address": "${DOMAIN}",
          "port": ${PORT_USE},
          "users": [{ "id": "${UUID}", "alterId": 0, "security": "auto" }]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess", "headers": { "Host": "${DOMAIN}" } },
        "security": "tls",
        "tlsSettings": { "serverName": "${DOMAIN}", "fingerprint": "chrome" }
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ]
}
EOF
    fi
    
    echo -e "${PURPLE}================================================${NC}"
}

save_config() {
    local config_file="/root/xray-client.txt"
    
    gen_vless_reality_link
    [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]] && gen_vmess_link
    
    cat > "$config_file" << EOF
==========================================
    Xray 配置信息
==========================================
服务器 IP: ${SERVER_IP}
域名: ${DOMAIN:-无需}
UUID: ${UUID}
配置时间: $(date)
------------------------------------------

EOF

    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        cat >> "$config_file" << EOF
【VLESS + Reality + Vision】
端口: ${PORT}
Private Key: ${PRIVATE_KEY}
Public Key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
回落目标: ${DEST}:${DEST_PORT}
TLS 指纹: ${FINGERPRINT}

VLESS 链接:
${VLESS_LINK}

EOF
    fi
    
    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
        cat >> "$config_file" << EOF
【VMess + TLS + WebSocket】
端口: ${PORT_USE}
路径: /vmess

VMess 链接:
${VMESS_LINK}

EOF
    fi
    
    local TCP_CONGESTION=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    cat >> "$config_file" << EOF
【BBR 加速状态】
TCP 拥塞控制: ${TCP_CONGESTION}
==========================================
EOF
    
    info "配置已保存到: $config_file"
}

setup_cert_renewal() {
    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        info "VLESS + Reality 无需证书续期"
        return
    fi
    
    info "设置证书自动续期..."
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * certbot renew --quiet && systemctl restart xray") | crontab -
}

uninstall() {
    echo ""
    warn "即将卸载 Xray..."
    read -p "确认卸载? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    rm -f /usr/local/bin/xray
    rm -f /etc/systemd/system/xray.service
    rm -rf /usr/local/etc/xray
    rm -rf /var/log/xray
    rm -f /root/xray-client.txt
    systemctl daemon-reload
    
    info "Xray 已卸载"
}

view_config() {
    if [[ ! -f "/root/xray-client.txt" ]]; then
        warn "配置文件不存在"
        return
    fi
    
    cat /root/xray-client.txt
    
    echo ""
    read -p "是否显示二维码? [y/N]: " show_qr
    if [[ "$show_qr" == "y" || "$show_qr" == "Y" ]]; then
        if grep -q "VLESS" /root/xray-client.txt; then
            local vless_link=$(grep -A1 "VLESS 链接:" /root/xray-client.txt | tail -1)
            echo -e "${GREEN}VLESS 二维码:${NC}"
            qrencode -t ANSIUTF8 "$vless_link"
        fi
        
        if grep -q "VMess" /root/xray-client.txt; then
            local vmess_link=$(grep -A1 "VMess 链接:" /root/xray-client.txt | tail -1)
            echo -e "${GREEN}VMess 二维码:${NC}"
            qrencode -t ANSIUTF8 "$vmess_link"
        fi
    fi
}

view_logs() {
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}                 Xray 日志${NC}"
    echo -e "${PURPLE}============================================${NC}"
    
    journalctl -u xray --no-pager -n 30
}

show_menu() {
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}       Xray 一键安装脚本${NC}"
    echo -e "${PURPLE}============================================${NC}"
    
    if check_xray_deployed; then
        echo -e "  ${GREEN}1${NC}. 重新部署 Xray"
        echo -e "  ${GREEN}2${NC}. 查看当前部署信息"
        echo -e "  ${GREEN}3${NC}. 卸载 Xray"
        echo -e "  ${GREEN}4${NC}. 查看配置信息"
        echo -e "  ${GREEN}5${NC}. 查看日志"
        echo -e "  ${GREEN}6${NC}. 重启 Xray"
        echo -e "  ${GREEN}7${NC}. 开启 BBR 加速"
        echo -e "  ${GREEN}8${NC}. 关闭 BBR 加速"
        echo -e "  ${GREEN}9${NC}. 查看 BBR 状态"
        echo -e "  ${GREEN}10${NC}. 退出"
        echo -e "${PURPLE}============================================${NC}"
        echo -e "${YELLOW}提示: Xray 已部署${NC}"
    else
        echo -e "  ${GREEN}1${NC}. 安装 Xray + 开启 BBR"
        echo -e "  ${GREEN}2${NC}. 卸载 Xray"
        echo -e "  ${GREEN}3${NC}. 查看配置信息"
        echo -e "  ${GREEN}4${NC}. 查看日志"
        echo -e "  ${GREEN}5${NC}. 重启 Xray"
        echo -e "  ${GREEN}6${NC}. 开启 BBR 加速"
        echo -e "  ${GREEN}7${NC}. 关闭 BBR 加速"
        echo -e "  ${GREEN}8${NC}. 查看 BBR 状态"
        echo -e "  ${GREEN}9${NC}. 退出"
        echo -e "${PURPLE}============================================${NC}"
    fi
}

# ===== 修复3: 新安装时才更新包管理器和安装依赖 =====
install_new() {
    # 1. 只在安装时更新包管理器
    update_package_manager
    
    # 2. 安装依赖（已安装的会跳过）
    install_dependencies
    
    # 3. 安装 Xray
    install_xray
    
    # 4. 选择协议
    select_protocol
    
    # 5. 获取基本信息
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    info "服务器 IP: $SERVER_IP"
    
    read -p "请输入监听端口 [默认443]: " PORT
    PORT=${PORT:-443}
    
    read -p "请输入备注名称 [默认xray]: " REMARK
    REMARK=${REMARK:-"xray"}
    
    UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "生成的 UUID: $UUID"
    
    # 6. VMess 需要域名
    if [[ "$PROTOCOL_CHOICE" == "2" || "$PROTOCOL_CHOICE" == "3" ]]; then
        echo ""
        read -p "请输入你的域名 (VMess + TLS 需要): " DOMAIN
        [[ -z "$DOMAIN" ]] && error "VMess 协议需要域名"
    else
        DOMAIN=""
        info "VLESS + Reality 无需域名"
    fi
    
    # 7. Reality 配置
    if [[ "$PROTOCOL_CHOICE" == "1" || "$PROTOCOL_CHOICE" == "3" ]]; then
        get_reality_input
    fi
    
    # 8. 申请证书
    get_cert
    
    # 9. 生成配置
    case $PROTOCOL_CHOICE in
        1) gen_reality_server_config ;;
        2) gen_vmess_server_config ;;
        3) gen_dual_server_config ;;
    esac
    
    # 10. 启动服务
    create_systemd_service
    start_service
    setup_cert_renewal
    
    # 11. 显示配置
    gen_qrcode
    gen_client_config
    save_config
    
    # 12. 最后询问 BBR
    echo ""
    read -p "是否开启 BBR 加速? [Y/n]: " enable_bbr_choice
    enable_bbr_choice=${enable_bbr_choice:-Y}
    
    if [[ "$enable_bbr_choice" == "y" || "$enable_bbr_choice" == "Y" ]]; then
        enable_bbr
    fi
    
    success "安装完成！"
}

main() {
    check_root
    detect_system
    
    while true; do
        show_menu
        read -p "请选择 [默认 1]: " choice
        choice=${choice:-1}
        
        if check_xray_deployed; then
            case $choice in
                1) redeploy_xray ;;
                2) view_current_deploy ;;
                3) uninstall ;;
                4) view_config ;;
                5) view_logs ;;
                6)
                    systemctl restart xray
                    sleep 2
                    systemctl is-active --quiet xray && success "重启成功" || warn "重启失败"
                    ;;
                7) enable_bbr ;;
                8) disable_bbr ;;
                9) view_bbr_status ;;
                10) exit 0 ;;
                *) warn "无效选择" ;;
            esac
        else
            case $choice in
                1) install_new ;;
                2) uninstall ;;
                3) view_config ;;
                4) view_logs ;;
                5) warn "服务未安装" ;;
                6) enable_bbr ;;
                7) disable_bbr ;;
                8) view_bbr_status ;;
                9) exit 0 ;;
                *) warn "无效选择" ;;
            esac
        fi
    done
}

main
