#!/bin/bash

# WARP 官方客户端脚本 - Gemini 域名透明代理版 v2
# 使用 Cloudflare 官方 cloudflare-warp + warp-cli proxy 模式
# 仅将 Gemini 相关域名解析出的 IPv4 通过 redsocks 转发到 WARP SOCKS5

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WARP_SOCKS_PORT="40000"
REDSOCKS_PORT="12345"
REDSOCKS_CONF="/etc/redsocks-warp-gemini.conf"
REDSOCKS_SERVICE="warp-gemini-redsocks.service"
IPSET_NAME="WARP_GEMINI"
NAT_CHAIN="WARP_GEMINI"
DOMAIN_FILE="/etc/warp-gemini-domains.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/warp-gemini.conf"
REFRESH_SCRIPT="/usr/local/bin/warp-gemini-refresh"
CONTROL_SCRIPT="/usr/local/bin/warp-gemini"
COMPAT_SCRIPT="/usr/local/bin/warp"
SERVICE_FILE="/etc/systemd/system/warp-gemini.service"
REDSOCKS_SERVICE_FILE="/etc/systemd/system/warp-gemini-redsocks.service"
REFRESH_SERVICE="/etc/systemd/system/warp-gemini-refresh.service"
REFRESH_TIMER="/etc/systemd/system/warp-gemini-refresh.timer"
GAI_MARKER="# added-by-warp-gemini-domain-script"

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║        🌐 WARP 官方客户端 - Gemini 域名版 🌐       ║"
    echo "║       warp-cli proxy + redsocks + ipset            ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

need_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }
}

detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        CODENAME=${VERSION_CODENAME:-}
    else
        echo -e "${RED}无法检测系统${NC}"
        exit 1
    fi

    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
    esac

    echo -e "${GREEN}系统: $OS $VERSION ${CODENAME:+($CODENAME)} $ARCH${NC}"
}

install_packages() {
    echo -e "
${CYAN}[1/6] 安装依赖...${NC}"
    case "$OS" in
        ubuntu|debian)
            # Debian/Ubuntu 的 redsocks 包安装时可能自动拉起原生 redsocks.service，
            # 但默认配置经常导致 ExecStartPre 校验失败。这里临时禁止 postinst 启动服务，
            # 后续只使用本脚本自己的 warp-gemini-redsocks.service。
            POLICY_BACKUP=""
            if [ -e /usr/sbin/policy-rc.d ]; then
                POLICY_BACKUP="/usr/sbin/policy-rc.d.warp-gemini.bak.$(date +%s)"
                cp /usr/sbin/policy-rc.d "$POLICY_BACKUP" 2>/dev/null || true
            fi
            cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
            chmod +x /usr/sbin/policy-rc.d

            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget gnupg lsb-release ca-certificates iptables ipset dnsmasq dnsutils
            DEBIAN_FRONTEND=noninteractive apt-get install -y redsocks || true
            DEBIAN_FRONTEND=noninteractive apt-get -f install -y || true

            if [ -n "$POLICY_BACKUP" ] && [ -f "$POLICY_BACKUP" ]; then
                mv "$POLICY_BACKUP" /usr/sbin/policy-rc.d 2>/dev/null || true
            else
                rm -f /usr/sbin/policy-rc.d
            fi
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl wget gnupg ca-certificates iptables ipset dnsmasq redsocks bind-utils
            else
                yum install -y curl wget gnupg ca-certificates iptables ipset dnsmasq redsocks bind-utils
            fi
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            echo -e "${YELLOW}支持: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora${NC}"
            exit 1
            ;;
    esac

    # 禁用发行版自带 redsocks.service，避免它读取 /etc/redsocks.conf 后失败或与本脚本实例抢端口。
    systemctl disable --now redsocks.service >/dev/null 2>&1 || true
    systemctl mask redsocks.service >/dev/null 2>&1 || true

    if ! command -v redsocks >/dev/null 2>&1; then
        echo -e "${RED}redsocks 未安装成功，请先检查软件源是否包含 redsocks 包${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 依赖安装完成${NC}"
}
install_warp_official() {
    echo -e "\n${CYAN}[2/6] 安装 Cloudflare 官方 WARP 客户端...${NC}"

    if command -v warp-cli >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 已检测到 warp-cli，跳过安装${NC}"
        return 0
    fi

    case "$OS" in
        ubuntu|debian)
            CODENAME=${CODENAME:-$(lsb_release -cs 2>/dev/null)}
            if [ -z "$CODENAME" ]; then
                echo -e "${RED}无法获取 Debian/Ubuntu 发行版代号${NC}"
                exit 1
            fi
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo <<'REPO'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
REPO
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y cloudflare-warp
            else
                yum install -y cloudflare-warp
            fi
            ;;
    esac

    if ! command -v warp-cli >/dev/null 2>&1; then
        echo -e "${RED}WARP 官方客户端安装失败${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ WARP 官方客户端安装完成${NC}"
}

configure_warp_proxy() {
    echo -e "\n${CYAN}[3/6] 配置 WARP proxy 模式...${NC}"

    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    sleep 1

    warp-cli --accept-tos registration new >/dev/null 2>&1 || warp-cli --accept-tos register >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || warp-cli proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true

    sleep 2
    echo -e "${GREEN}✓ WARP proxy 已配置为 127.0.0.1:${WARP_SOCKS_PORT}${NC}"
}

write_domain_file() {
    if [ ! -f "$DOMAIN_FILE" ]; then
        cat > "$DOMAIN_FILE" <<'DOMAINS'
gemini.google.com
bard.google.com
aistudio.google.com
generativelanguage.googleapis.com
alkalimakersuite-pa.clients6.google.com
DOMAINS
    fi
}

configure_redsocks() {
    echo -e "
${CYAN}[4/6] 配置 redsocks...${NC}"

    cat > "$REDSOCKS_CONF" <<EOF_REDSOCKS
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = ${REDSOCKS_PORT};
    ip = 127.0.0.1;
    port = ${WARP_SOCKS_PORT};
    type = socks5;
}
EOF_REDSOCKS

    if ! redsocks -t -c "$REDSOCKS_CONF" >/tmp/warp-gemini-redsocks-test.log 2>&1; then
        echo -e "${RED}redsocks 配置校验失败：$REDSOCKS_CONF${NC}"
        cat /tmp/warp-gemini-redsocks-test.log
        exit 1
    fi

    echo -e "${GREEN}✓ redsocks 配置完成，使用独立配置 ${REDSOCKS_CONF}${NC}"
}
write_refresh_script() {
    cat > "$REFRESH_SCRIPT" <<'SCRIPT'
#!/bin/bash
set -o pipefail

IPSET_NAME="WARP_GEMINI"
DOMAIN_FILE="/etc/warp-gemini-domains.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/warp-gemini.conf"

log() { echo "[warp-gemini-refresh] $*"; }

ensure_ipset() {
    ipset create "$IPSET_NAME" hash:ip family inet timeout 1800 -exist
}

write_dnsmasq_conf() {
    [ -f "$DOMAIN_FILE" ] || exit 0
    {
        echo "# Generated by warp-gemini-refresh"
        echo "# Gemini domains will be added to ipset ${IPSET_NAME} when resolved through dnsmasq."
        while read -r domain; do
            domain=$(echo "$domain" | sed 's/#.*//' | xargs)
            [ -z "$domain" ] && continue
            echo "ipset=/${domain}/${IPSET_NAME}"
        done < "$DOMAIN_FILE"
    } > "$DNSMASQ_CONF"

    systemctl restart dnsmasq >/dev/null 2>&1 || service dnsmasq restart >/dev/null 2>&1 || true
}

resolve_domains() {
    [ -f "$DOMAIN_FILE" ] || exit 0
    while read -r domain; do
        domain=$(echo "$domain" | sed 's/#.*//' | xargs)
        [ -z "$domain" ] && continue

        # 优先用系统解析，失败再尝试常见公共 DNS。只加入 IPv4。
        ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
        if [ -z "$ips" ] && command -v dig >/dev/null 2>&1; then
            ips=$(dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u)
        fi
        if [ -z "$ips" ] && command -v dig >/dev/null 2>&1; then
            ips=$(dig +short A "$domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u)
        fi

        for ip in $ips; do
            ipset add "$IPSET_NAME" "$ip" timeout 1800 -exist 2>/dev/null || true
        done
    done < "$DOMAIN_FILE"
}

ensure_ipset
write_dnsmasq_conf
resolve_domains
log "refreshed $(ipset list "$IPSET_NAME" 2>/dev/null | awk '/Number of entries:/ {print $4}') entries"
SCRIPT
    chmod +x "$REFRESH_SCRIPT"
}

write_control_script() {
    cat > "$CONTROL_SCRIPT" <<'SCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WARP_SOCKS_PORT="40000"
REDSOCKS_PORT="12345"
REDSOCKS_CONF="/etc/redsocks-warp-gemini.conf"
REDSOCKS_SERVICE="warp-gemini-redsocks.service"
IPSET_NAME="WARP_GEMINI"
NAT_CHAIN="WARP_GEMINI"
DOMAIN_FILE="/etc/warp-gemini-domains.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/warp-gemini.conf"
REFRESH_SCRIPT="/usr/local/bin/warp-gemini-refresh"
REFRESH_TIMER="warp-gemini-refresh.timer"
GAI_MARKER="# added-by-warp-gemini-domain-script"

need_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行${NC}"; exit 1; }
}

ensure_ipset() {
    ipset create "$IPSET_NAME" hash:ip family inet timeout 1800 -exist
}

start_redsocks() {
    systemctl disable --now redsocks.service >/dev/null 2>&1 || true
    systemctl mask redsocks.service >/dev/null 2>&1 || true

    if ! redsocks -t -c "$REDSOCKS_CONF" >/tmp/warp-gemini-redsocks-test.log 2>&1; then
        echo -e "${RED}redsocks 配置校验失败：$REDSOCKS_CONF${NC}"
        cat /tmp/warp-gemini-redsocks-test.log
        exit 1
    fi

    systemctl restart "$REDSOCKS_SERVICE" >/dev/null 2>&1 || {
        pkill redsocks >/dev/null 2>&1 || true
        nohup redsocks -c "$REDSOCKS_CONF" >/var/log/warp-gemini-redsocks.log 2>&1 &
        sleep 1
    }

    if ! pgrep -x redsocks >/dev/null 2>&1; then
        echo -e "${RED}redsocks 启动失败，请查看：journalctl -xeu ${REDSOCKS_SERVICE}${NC}"
        exit 1
    fi
}

apply_iptables() {
    ensure_ipset
    iptables -t nat -N "$NAT_CHAIN" 2>/dev/null || iptables -t nat -F "$NAT_CHAIN"

    # 避免代理自身、本机保留地址进入重定向链。
    iptables -t nat -A "$NAT_CHAIN" -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A "$NAT_CHAIN" -d 240.0.0.0/4 -j RETURN

    # 仅 Gemini 域名解析出的 IPv4 走 redsocks -> WARP SOCKS5。
    iptables -t nat -A "$NAT_CHAIN" -p tcp -m set --match-set "$IPSET_NAME" dst -j REDIRECT --to-ports "$REDSOCKS_PORT"

    iptables -t nat -C OUTPUT -p tcp -j "$NAT_CHAIN" 2>/dev/null || iptables -t nat -A OUTPUT -p tcp -j "$NAT_CHAIN"
}

remove_iptables() {
    while iptables -t nat -C OUTPUT -p tcp -j "$NAT_CHAIN" 2>/dev/null; do
        iptables -t nat -D OUTPUT -p tcp -j "$NAT_CHAIN" 2>/dev/null || break
    done
    # 兼容旧版本没有 -p tcp 的跳转规则。
    while iptables -t nat -C OUTPUT -j "$NAT_CHAIN" 2>/dev/null; do
        iptables -t nat -D OUTPUT -j "$NAT_CHAIN" 2>/dev/null || break
    done
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
}

prefer_ipv4_for_google() {
    if ! grep -q "$GAI_MARKER" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100 $GAI_MARKER" >> /etc/gai.conf
    fi
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
}

remove_ipv4_prefer() {
    if [ -f /etc/gai.conf ]; then
        sed -i "\|$GAI_MARKER|d" /etc/gai.conf 2>/dev/null || true
    fi
    ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null || true
}

start_timer() {
    systemctl enable --now "$REFRESH_TIMER" >/dev/null 2>&1 || true
}

stop_timer() {
    systemctl disable --now "$REFRESH_TIMER" >/dev/null 2>&1 || true
}

start() {
    need_root
    echo -e "${CYAN}启动 Gemini 域名透明代理...${NC}"
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || warp-cli proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
    start_redsocks
    "$REFRESH_SCRIPT" >/dev/null 2>&1 || true
    apply_iptables
    prefer_ipv4_for_google
    start_timer
    echo -e "${GREEN}✓ 已启动，仅 Gemini 域名解析出的 IPv4 会走 WARP${NC}"
}

stop() {
    need_root
    echo -e "${CYAN}停止 Gemini 域名透明代理...${NC}"
    stop_timer
    remove_iptables
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    systemctl stop "$REDSOCKS_SERVICE" >/dev/null 2>&1 || true
    pkill redsocks >/dev/null 2>&1 || true
    remove_ipv4_prefer
    rm -f "$DNSMASQ_CONF"
    systemctl restart dnsmasq >/dev/null 2>&1 || service dnsmasq restart >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ 已停止并清除 iptables/ipset/轮询${NC}"
}

stop_all() {
    stop
    warp-cli disconnect >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ 已断开 WARP${NC}"
}

refresh() {
    need_root
    "$REFRESH_SCRIPT"
    echo -e "${GREEN}✓ 域名解析已刷新${NC}"
}

status() {
    echo -e "${CYAN}════════════ Gemini WARP 状态 ════════════${NC}"
    echo -e "\n${YELLOW}【WARP 客户端】${NC}"
    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli status 2>/dev/null || echo "warp-cli 状态获取失败"
    else
        echo -e "${RED}未安装 warp-cli${NC}"
    fi

    echo -e "\n${YELLOW}【redsocks】${NC}"
    pgrep -x redsocks >/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"

    echo -e "\n${YELLOW}【轮询刷新】${NC}"
    systemctl is-active "$REFRESH_TIMER" >/dev/null 2>&1 && echo -e "${GREEN}运行中，每 5 分钟刷新${NC}" || echo -e "${RED}未运行${NC}"

    echo -e "\n${YELLOW}【ipset】${NC}"
    if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        ipset list "$IPSET_NAME" | awk '/Name:|Number of entries:/ {print}'
        echo "最近部分 IP:"
        ipset list "$IPSET_NAME" | awk '/^[0-9]+\./ {print "  "$1}' | head -20
    else
        echo -e "${RED}无 ${IPSET_NAME}${NC}"
    fi

    echo -e "\n${YELLOW}【iptables】${NC}"
    iptables -t nat -S "$NAT_CHAIN" 2>/dev/null || echo -e "${RED}无 ${NAT_CHAIN} 链${NC}"
    iptables -t nat -S OUTPUT 2>/dev/null | grep "$NAT_CHAIN" || true
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
}

test_conn() {
    echo -e "${CYAN}测试连接...${NC}"
    echo -n "直连 IP: "
    curl -4 -s --max-time 8 ip.sb || true
    echo
    echo -n "WARP SOCKS IP: "
    curl -x socks5://127.0.0.1:${WARP_SOCKS_PORT} -4 -s --max-time 8 ip.sb || true
    echo
    echo -n "Gemini HTTP 状态: "
    curl -s --max-time 12 -o /dev/null -w "%{http_code}\n" https://gemini.google.com || true
}

domains() {
    need_root
    ${EDITOR:-nano} "$DOMAIN_FILE"
    refresh
}

uninstall() {
    need_root
    echo -e "${YELLOW}卸载 Gemini WARP 配置...${NC}"
    stop >/dev/null 2>&1 || true
    systemctl disable --now warp-gemini.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/warp-gemini.service
    rm -f /etc/systemd/system/warp-gemini-redsocks.service
    rm -f /etc/systemd/system/warp-gemini-refresh.service
    rm -f /etc/systemd/system/warp-gemini-refresh.timer
    rm -f /usr/local/bin/warp-gemini-refresh
    rm -f /usr/local/bin/warp-gemini
    rm -f /usr/local/bin/warp
    rm -f /etc/redsocks-warp-gemini.conf
    systemctl unmask redsocks.service >/dev/null 2>&1 || true
    rm -f "$DOMAIN_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ 已移除脚本配置。cloudflare-warp/redsocks/dnsmasq 软件包未自动卸载。${NC}"
}

case "$1" in
    start) start ;;
    stop|disable) stop ;;
    stop-all) stop_all ;;
    restart) stop; sleep 1; start ;;
    refresh) refresh ;;
    status) status ;;
    test) test_conn ;;
    domains) domains ;;
    uninstall) uninstall ;;
    *)
        echo "Gemini WARP 管理工具"
        echo "用法: warp-gemini <命令>"
        echo ""
        echo "命令:"
        echo "  start      启动 Gemini 域名透明代理"
        echo "  stop       停止代理并清理 iptables/ipset/轮询，不断开 WARP"
        echo "  stop-all   停止代理并断开 WARP"
        echo "  restart    重启代理"
        echo "  refresh    立即重新解析 Gemini 域名 IP"
        echo "  status     查看状态"
        echo "  test       测试连接"
        echo "  domains    编辑 Gemini 域名列表"
        echo "  uninstall  移除脚本配置"
        ;;
esac
SCRIPT
    chmod +x "$CONTROL_SCRIPT"
    ln -sf "$CONTROL_SCRIPT" "$COMPAT_SCRIPT"
}

write_systemd_units() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=WARP Gemini Domain Transparent Proxy
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${CONTROL_SCRIPT} start
ExecStop=${CONTROL_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    cat > "$REDSOCKS_SERVICE_FILE" <<EOF_REDSOCKS_SERVICE
[Unit]
Description=Redsocks for WARP Gemini transparent proxy
After=network.target warp-svc.service
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c ${REDSOCKS_CONF}
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF_REDSOCKS_SERVICE

    cat > "$REFRESH_SERVICE" <<EOF_REFRESH_SERVICE
[Unit]
Description=Refresh Gemini domain IPs into ipset
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${REFRESH_SCRIPT}
EOF_REFRESH_SERVICE

    cat > "$REFRESH_TIMER" <<'EOF_REFRESH_TIMER'
[Unit]
Description=Refresh Gemini domain IPs every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true
Unit=warp-gemini-refresh.service

[Install]
WantedBy=timers.target
EOF_REFRESH_TIMER

    systemctl daemon-reload
}

setup_all() {
    install_packages
    install_warp_official
    configure_warp_proxy
    write_domain_file
    configure_redsocks
    write_refresh_script
    write_control_script
    write_systemd_units

    echo -e "\n${CYAN}[5/6] 启动 Gemini 域名透明代理...${NC}"
    "$CONTROL_SCRIPT" start
    systemctl enable warp-gemini.service >/dev/null 2>&1 || true
    systemctl enable warp-gemini-redsocks.service >/dev/null 2>&1 || true

    echo -e "\n${CYAN}[6/6] 测试...${NC}"
    "$CONTROL_SCRIPT" test || true

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        安装完成：仅 Gemini 域名走 WARP             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "\n管理命令: ${CYAN}warp-gemini {start|stop|stop-all|restart|refresh|status|test|domains|uninstall}${NC}"
    echo -e "兼容命令: ${CYAN}warp {start|stop|stop-all|restart|refresh|status|test|domains|uninstall}${NC}\n"
}

do_status() {
    if [ -x "$CONTROL_SCRIPT" ]; then
        "$CONTROL_SCRIPT" status
    else
        echo -e "${RED}尚未安装管理脚本${NC}"
    fi
}

do_stop() {
    if [ -x "$CONTROL_SCRIPT" ]; then
        "$CONTROL_SCRIPT" stop
    else
        echo -e "${YELLOW}管理脚本不存在，尝试直接清理...${NC}"
        systemctl disable --now warp-gemini-refresh.timer >/dev/null 2>&1 || true
        iptables -t nat -D OUTPUT -p tcp -j "$NAT_CHAIN" 2>/dev/null || true
        iptables -t nat -F "$NAT_CHAIN" 2>/dev/null || true
        iptables -t nat -X "$NAT_CHAIN" 2>/dev/null || true
        ipset destroy "$IPSET_NAME" 2>/dev/null || true
        systemctl stop warp-gemini-redsocks.service >/dev/null 2>&1 || true
        pkill redsocks >/dev/null 2>&1 || true
    fi
}

show_menu() {
    echo -e "\n${YELLOW}请选择操作:${NC}\n"
    echo -e "  ${GREEN}1.${NC} 安装 / 修复 WARP 官方 Gemini 域名代理"
    echo -e "  ${GREEN}2.${NC} 停用代理并清理 iptables/ipset/轮询"
    echo -e "  ${GREEN}3.${NC} 查看状态"
    echo -e "  ${GREEN}4.${NC} 立即刷新 Gemini 域名 IP"
    echo -e "  ${GREEN}5.${NC} 编辑 Gemini 域名列表"
    echo -e "  ${GREEN}6.${NC} 卸载脚本配置"
    echo -e "  ${GREEN}0.${NC} 退出\n"

    read -r -p "请输入选项 [0-6]: " choice
    case "$choice" in
        1) setup_all ;;
        2) do_stop ;;
        3) do_status ;;
        4) "$CONTROL_SCRIPT" refresh ;;
        5) "$CONTROL_SCRIPT" domains ;;
        6) "$CONTROL_SCRIPT" uninstall ;;
        0) echo -e "\n${GREEN}再见！${NC}"; exit 0 ;;
        *) echo -e "\n${RED}无效选项${NC}" ;;
    esac
}

main() {
    need_root
    show_banner
    detect_system
    show_menu
}

main

