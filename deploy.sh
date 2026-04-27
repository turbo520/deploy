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

# 检查依赖是否已安装
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
    info "检查依赖..."

    local packages_to_install=""
    local all_installed=true

    for pkg in curl wget jq openssl certbot qrencode net-tools unzip; do
        if ! check_dependency_installed "$pkg"; then
            packages_to_install="$packages_to_install $pkg"
            all_installed=false
        fi
    done

    if $all_installed; then
        info "所有依赖已安装，跳过"
        return 0
    fi

    info "更新包管理器..."
    $PM update -y > /dev/null 2>&1

    info "安装缺失依赖: $packages_to_install"
    $PM install -y $packages_to_install > /dev/null 2>&1
}

install_xray() {
    if command -v xray &> /dev/null; then
        info "Xray 已安装: $(xray version | head -1)"
        return
    fi

    info "安装 Xray..."
    # 修复官方脚本安装方式
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || {
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

        wget -q "$URL" -O /tmp/xray.zip
        mkdir -p /usr/local/xray
        unzip -o /tmp/xray.zip -d /usr/local/xray
        mv /usr/local/xray/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        rm -rf /tmp/xray.zip /usr/local/xray
    }

    mkdir -p /var/log/xray
    chmod 644 /var/log/xray
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

    systemctl is-active --quiet xray && STATUS="${GREEN}运行中${NC}" || STATUS="${RED}已停止${NC}"
    echo -e "${YELLOW}服务状态:${NC} $STATUS"
    echo -e "${YELLOW}Xray 版本:${NC} $(xray version 2>/dev/null | head -1 || echo '未知')"

    [[ -f "/root/xray-client.txt" ]] && echo -e "${YELLOW}上次配置:${NC} $(grep "配置时间:" /root/xray-client.txt | cut -d: -f2-)"
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
    [[ -f "/root/xray-client.txt" ]] && OLD_UUID=$(grep "UUID:" /root/xray-client.txt | head -1 | awk '{print $2}')
    [[ -z "$OLD_UUID" ]] && { warn "未找到旧配置，生成新 UUID"; OLD_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid); }
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
    [[ ! -f "/usr/local/etc/xray/config.json" ]] && error "未找到配置文件"
    grep -q "realitySettings" /usr/local/etc/xray/config.json || error "当前配置不是 Reality 协议"

    info "更新 Reality 密钥..."
    [[ -f "/root/xray-client.txt" ]] && {
        OLD_UUID=$(grep "UUID:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_PORT=$(grep "端口:" /root/xray-client.txt | head -1 | awk '{print $2}')
        OLD_DEST=$(grep "回落目标:" /root/xray-client.txt | awk -F: '{print $2}' | sed 's/:.*//' | tr -d ' ')
    }

    UUID=${OLD_UUID:-$(xray uuid)}
    PORT=${OLD_PORT:-443}
    DEST=${OLD_DEST:-"www.microsoft.com"}
    DEST_PORT=443

    generate_reality_keys
    read -p "请选择 TLS 指纹 [1-chrome/2-firefox, 默认1]: " FP_CHOICE
    FINGERPRINT=$([[ "${FP_CHOICE:-1}" == "1" ]] && echo "chrome" || echo "firefox")

    REMARK="xray"
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    gen_reality_server_config
    restart_and_show
}

redeploy_change_port() {
    info "更换端口..."
    [[ ! -f "/usr/local/etc/xray/config.json" ]] && error "未找到配置文件"

    local OLD_PORT=$(grep -o '"port": [0-9]*' /usr/local/etc/xray/config.json | head -1 | grep -o '[0-9]*')
    info "当前端口: $OLD_PORT"
    read -p "请输入新端口: " NEW_PORT
    [[ -z "$NEW_PORT" ]] && error "端口不能为空"

    ss -tuln | grep -q ":${NEW_PORT} " && { warn "端口 $NEW_PORT 已被占用"; read -p "是否继续? [y/N]: " confirm; [[ "$confirm" != "y" ]] && return; }

    sed -i "0,/\"port\": ${OLD_PORT}/s/\"port\": ${OLD_PORT}/\"port\": ${NEW_PORT}/" /usr/local/etc/xray/config.json
    [[ -f "/root/xray-client.txt" ]] && sed -i "s/端口: ${OLD_PORT}/端口: ${NEW_PORT}/" /root/xray-client.txt

    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray && success "端口更新完成" || warn "服务重启失败"
}

redeploy_common() {
    select_protocol
    SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)
    read -p "请输入监听端口 [默认443]: " PORT
    PORT=${PORT:-443}
    read -p "请输入备注名称 [默认xray]: " REMARK
    REMARK=${REMARK:-"xray"}

    [[ "$PROTOCOL_CHOICE" =~ 2|3 ]] && { read -p "请输入你的域名: " DOMAIN; [[ -z "$DOMAIN" ]] && error "域名不能为空"; }
    [[ "$PROTOCOL_CHOICE" =~ 1|3 ]] && get_reality_input
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
    xray run -test -config /usr/local/etc/xray/config.json > /dev/null 2>&1 || error "配置验证失败"

    systemctl restart xray && sleep 2
    systemctl is-active --quiet xray || error "Xray 重启失败"

    gen_qrcode
    gen_client_config
    save_config
    success "重新部署完成！"
}

# BBR 优化
check_kernel_version() {
    local KERNEL_VERSION=$(uname -r | cut -d '-' -f 1)
    [[ $(echo "$KERNEL_VERSION 4.9" | awk '{if($1>=$2) print 1; else print 0}') -eq 1 ]] && return 0 || return 1
}

check_bbr_status() {
    [[ "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')" == "bbr" ]] && return 0 || return 1
}

enable_bbr() {
    check_kernel_version || { warn "内核版本过低，无法开启BBR"; return 1; }
    check_bbr_status && { success "BBR已开启"; return 0; }

    cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p > /dev/null 2>&1
    check_bbr_status && success "BBR开启成功" || warn "BBR开启失败"
}

disable_bbr() {
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    sysctl -p > /dev/null 2>&1
    success "BBR已关闭"
}

view_bbr_status() {
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               BBR 加速状态${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo -e "${YELLOW}内核版本:${NC} $(uname -r)"
    echo -e "${YELLOW}TCP 拥塞控制:${NC} $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    echo -e "${BLUE}================================================${NC}"
    check_bbr_status && success "BBR 已开启" || warn "BBR 未开启"
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

# 修复 Reality 密钥生成
generate_reality_keys() {
    info "生成 Reality 密钥对..."
    local KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "密钥生成失败"
    info "密钥生成完成"
}

# 修复 serverNames 重复域名BUG
get_reality_input() {
    generate_reality_keys
    SHORT_ID=$(openssl rand -hex 8)
    info "Short ID: $SHORT_ID"

    echo ""
    echo -e "${PURPLE}请选择回落目标:${NC}"
    echo "1.www.microsoft.com 2.www.apple.com 3.www.amazon.com 4.自定义"
    read -p "选择[默认1]: " DEST_CHOICE
    case $DEST_CHOICE in
        1) DEST="www.microsoft.com" ;;
        2) DEST="www.apple.com" ;;
        3) DEST="www.amazon.com" ;;
        4) read -p "输入目标域名: " DEST ;;
        *) DEST="www.microsoft.com" ;;
    esac
    DEST_PORT=443
    info "回落目标: ${DEST}:${DEST_PORT}"

    read -p "TLS指纹[1-chrome/2-firefox, 默认1]: " FP_CHOICE
    FINGERPRINT=$([[ "${FP_CHOICE:-1}" == "1" ]] && echo "chrome" || echo "firefox")
}

get_cert() {
    [[ "$PROTOCOL_CHOICE" == "1" ]] && { info "Reality无需证书"; return; }
    [[ -z "$DOMAIN" ]] && error "域名不能为空"

    [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] && { warn "证书已存在"; return; }

    local DOMAIN_IP=$(dig +short "$DOMAIN" | tail -1)
    SERVER_IP=$(curl -s4 ip.sb)
    [[ "$DOMAIN_IP" != "$SERVER_IP" ]] && { warn "域名解析不匹配"; read -p "继续?[y/N]: " c; [[ "$c" != "y" ]] && exit 1; }

    systemctl stop nginx apache2 2>/dev/null
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email admin@$DOMAIN --key-type ecdsa || error "证书申请失败"
    success "证书申请成功"
}

# ====================== 核心优化：配置文件生成 ======================
# 修复 serverNames 重复域名 + 增加性能优化 + 规范配置
gen_reality_server_config() {
    info "生成 VLESS + Reality 服务端配置..."
    mkdir -p /usr/local/etc/xray

    # 修复核心BUG：自动处理域名，避免 www.www.xxx 重复
    if [[ $DEST == www.* ]]; then
        CLEAN_DEST=${DEST#www.}
        SERVER_NAMES="[\"${DEST}\",\"${CLEAN_DEST}\"]"
    else
        SERVER_NAMES="[\"${DEST}\",\"www.${DEST}\"]"
    fi

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
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${DEST}:${DEST_PORT}",
          "serverNames": ${SERVER_NAMES},
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", ""]
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
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "TOS": 64
        }
      }
    },
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}
    ]
  }
}
EOF
}

gen_vmess_server_config() {
    info "生成 VMess 服务端配置..."
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
        "clients": [{"id": "${UUID}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess", "headers": {"Host": "${DOMAIN}"}},
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [{
            "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
            "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
          }],
          "alpn": ["h2", "http/1.1"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {"sockopt": {"tcpFastOpen": true}}
    },
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]
  }
}
EOF
}

gen_dual_server_config() {
    info "生成双协议配置..."
    mkdir -p /usr/local/etc/xray
    local VMESS_PORT=$((PORT + 1))

    if [[ $DEST == www.* ]]; then
        CLEAN_DEST=${DEST#www.}
        SERVER_NAMES="[\"${DEST}\",\"${CLEAN_DEST}\"]"
    else
        SERVER_NAMES="[\"${DEST}\",\"www.${DEST}\"]"
    fi

    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${DEST}:443",
          "serverNames": ${SERVER_NAMES},
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "tag": "vmess-ws-tls-in",
      "listen": "::",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {"clients": [{"id": "${UUID}", "alterId": 0}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess", "headers": {"Host": "${DOMAIN}"}},
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [{
            "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
            "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
          }]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {"sockopt": {"tcpFastOpen": true}}
    },
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]
  }
}
EOF
    VMESS_PORT_FINAL=$VMESS_PORT
}

# 修复 Systemd 服务拼写错误
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
    xray run -test -config /usr/local/etc/xray/config.json > /dev/null 2>&1 || error "配置无效"
    systemctl enable --now xray && sleep 2
    systemctl is-active --quiet xray && success "Xray启动成功" || error "启动失败"
}

gen_vless_reality_link() {
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${REMARK}"
}

gen_vmess_link() {
    local PORT_USE=${VMESS_PORT_FINAL:-$PORT}
    local vmess_json="{\"v\":\"2\",\"ps\":\"${REMARK}-VMess\",\"add\":\"${DOMAIN}\",\"port\":\"${PORT_USE}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess\",\"tls\":\"tls\"}"
    VMESS_LINK="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
}

gen_qrcode() {
    info "生成客户端配置..."
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}               客户端配置${NC}"
    echo -e "${BLUE}================================================${NC}"

    if [[ "$PROTOCOL_CHOICE" == "1" ]]; then
        gen_vless_reality_link
        echo -e "${GREEN}VLESS 链接:${NC}\n$VLESS_LINK"
        echo -e "${YELLOW}二维码:${NC}"
        qrencode -t ANSIUTF8 "$VLESS_LINK"
    elif [[ "$PROTOCOL_CHOICE" == "2" ]]; then
        gen_vmess_link
        echo -e "${GREEN}VMess 链接:${NC}\n$VMESS_LINK"
        qrencode -t ANSIUTF8 "$VMESS_LINK"
    else
        gen_vless_reality_link && gen_vmess_link
        echo -e "VLESS: $VLESS_LINK" && qrencode -t ANSIUTF8 "$VLESS_LINK"
        echo -e "VMess: $VMESS_LINK" && qrencode -t ANSIUTF8 "$VMESS_LINK"
    fi
}

gen_client_config() {
    echo -e "\n${PURPLE}客户端JSON配置${NC}"
    [[ "$PROTOCOL_CHOICE" =~ 1|3 ]] && cat << EOF
{
  "inbounds": [{"port": 10808,"protocol":"socks"}],
  "outbounds": [{
    "protocol":"vless",
    "settings":{"vnext":[{"address":"${SERVER_IP}","port":${PORT},"users":[{"id":"${UUID}","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{
      "security":"reality",
      "realitySettings":{"serverName":"${DEST}","publicKey":"${PUBLIC_KEY}","shortId":"${SHORT_ID}","fingerprint":"${FINGERPRINT}"}
    }
  }]
}
EOF
}

save_config() {
    gen_vless_reality_link
    [[ "$PROTOCOL_CHOICE" =~ 2|3 ]] && gen_vmess_link
    cat > /root/xray-client.txt << EOF
Xray 配置
服务器IP: ${SERVER_IP}
UUID: ${UUID}
配置时间: $(date)
VLESS链接: ${VLESS_LINK:-无}
VMess链接: ${VMESS_LINK:-无}
EOF
    info "配置保存至 /root/xray-client.txt"
}

setup_cert_renewal() {
    [[ "$PROTOCOL_CHOICE" == "1" ]] && return
    (crontab -l 2>/dev/null | grep -v certbot; echo "0 3 * * * certbot renew --quiet && systemctl restart xray") | crontab -
}

uninstall() {
    read -p "确认卸载Xray?[y/N]: " confirm
    [[ "$confirm" != "y" ]] && exit 0

    systemctl disable --stop xray 2>/dev/null
    rm -rf /usr/local/bin/xray /etc/systemd/system/xray.service /usr/local/etc/xray /var/log/xray /root/xray-client.txt
    systemctl daemon-reload
    success "Xray 已卸载"
}

view_config() {
    [[ -f "/root/xray-client.txt" ]] && cat /root/xray-client.txt || warn "无配置文件"
}

view_logs() {
    journalctl -u xray --no-pager -n 30
}

# 修复菜单错别字
show_menu() {
    echo ""
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}       Xray 一键安装脚本(优化版)${NC}"
    echo -e "${PURPLE}============================================${NC}"

    if check_xray_deployed; then
        echo -e "1.重新部署 2.查看部署 3.卸载 4.查看配置 5.日志 6.重启"
        echo -e "7.开启BBR 8.关闭BBR 9.查看BBR 10.退出"
    else
        echo -e "1.安装Xray+BBR 2.卸载 3.查看配置 4.日志 5.重启"
        echo -e "6.开启BBR 7.关闭BBR 8.查看BBR 9.退出"
    fi
}

install_new() {
    install_dependencies
    install_xray
    select_protocol

    SERVER_IP=$(curl -s4 ip.sb)
    read -p "端口[默认443]: " PORT
    PORT=${PORT:-443}
    read -p "备注[默认xray]: " REMARK
    UUID=$(xray uuid)

    [[ "$PROTOCOL_CHOICE" =~ 2|3 ]] && { read -p "域名: " DOMAIN; [[ -z "$DOMAIN" ]] && error "域名不能为空"; }
    [[ "$PROTOCOL_CHOICE" =~ 1|3 ]] && get_reality_input
    get_cert

    case $PROTOCOL_CHOICE in 1) gen_reality_server_config ;; 2) gen_vmess_server_config ;; 3) gen_dual_server_config ;; esac

    create_systemd_service
    start_service
    setup_cert_renewal
    gen_qrcode
    save_config

    read -p "开启BBR?[Y/n]: " bbr
    [[ "${bbr:-Y}" == "Y" ]] && enable_bbr
    success "安装完成！"
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
                1) redeploy_xray ;; 2) view_current_deploy ;; 3) uninstall ;; 4) view_config ;;
                5) view_logs ;; 6) systemctl restart xray && success "重启成功" ;;
                7) enable_bbr ;; 8) disable_bbr ;; 9) view_bbr_status ;; 10) exit 0 ;;
                *) warn "无效选项" ;;
            esac
        else
            case $choice in
                1) install_new ;; 2) uninstall ;; 3) view_config ;; 4) view_logs ;;
                6) enable_bbr ;;7) disable_bbr ;;8) view_bbr_status ;;9) exit 0 ;;
                *) warn "无效选项" ;;
            esac
        fi
    done
}

main
