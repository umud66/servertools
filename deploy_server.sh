#!/bin/bash

set -euo pipefail

# 交互式新服务器部署工具
# 功能覆盖：域名管理、证书管理、Trojan-Go、Hysteria2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_NAME="Server Deploy Tool"
APP_ROOT="/etc/server-deploy-tool"
DOMAIN_DIR="$APP_ROOT/domains"
SERVICE_DIR="$APP_ROOT/services"
RUNTIME_DIR="$APP_ROOT/runtime"
LOG_FILE="$RUNTIME_DIR/deploy.log"
TROJAN_DIR="/etc/trojan-go"
HYSTERIA_DIR="/etc/hysteria2"
TROJAN_CONF="$TROJAN_DIR/server-deploy.conf"
TROJAN_JSON="$TROJAN_DIR/config.json"
HYSTERIA_CONF="$HYSTERIA_DIR/server-deploy.conf"
HYSTERIA_YAML="$HYSTERIA_DIR/config.yaml"
XRAY_DIR="/etc/xray"
XRAY_CONF="$XRAY_DIR/server-deploy.conf"
XRAY_JSON="$XRAY_DIR/config.json"
PICKED_DOMAIN_FILE=""

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                 Server Deploy Tool                      ║"
    echo "║          Trojan-Go / Hysteria2 / Cert Manager          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
    echo "[INFO] $(date '+%F %T') $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
    echo "[OK] $(date '+%F %T') $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $(date '+%F %T') $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date '+%F %T') $1" >> "$LOG_FILE" 2>/dev/null || true
}

pause_wait() {
    read -r -p "按回车继续..."
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "请使用 root 运行此脚本"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$DOMAIN_DIR" "$TROJAN_DIR" "$HYSTERIA_DIR" "$XRAY_DIR" "$RUNTIME_DIR"
    touch "$LOG_FILE"
}

detect_system() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-}"
    else
        log_error "无法检测系统类型"
        exit 1
    fi

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
    esac
}

run_cmd() {
    log_info "$1"
    eval "$1"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "缺少命令: $1"
        return 1
    fi
}

# 执行 HTTP 探测，输出状态码、耗时和结果判断
http_probe() {
    local name="$1"
    local url="$2"
    local body_file probe_result status time_total final_url result
    body_file="$(mktemp)"

    probe_result="$(curl -L -sS --max-time 20 --connect-timeout 8 -A "Mozilla/5.0" \
        -o "$body_file" -w "%{http_code}|%{time_total}|%{url_effective}" "$url" 2>/dev/null || echo "000|0|$url")"
    status="$(echo "$probe_result" | cut -d'|' -f1)"
    time_total="$(echo "$probe_result" | cut -d'|' -f2)"
    final_url="$(echo "$probe_result" | cut -d'|' -f3-)"

    case "$status" in
        200|204|301|302|307|308) result="可访问" ;;
        401) result="API 可达/需认证" ;;
        403) result="受限或被拒绝" ;;
        404) result="页面不存在或区域不可用" ;;
        451) result="区域或合规限制" ;;
        000|"") result="连接失败" ;;
        *) result="需人工判断" ;;
    esac

    printf "%-18s %-8s %-10s %ss\n" "$name" "$status" "$result" "$time_total"
    echo "  URL: $final_url"
    rm -f "$body_file"
}

show_public_ip_info() {
    require_command curl || return 1

    echo "==== 公网 IP 信息 ===="
    echo "IPv4: $(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo 未获取)"
    echo "IPv6: $(curl -6 -fsS --max-time 10 https://api64.ipify.org 2>/dev/null || echo 未获取)"
    echo
    echo "==== Geo 信息 ===="
    curl -fsS --max-time 15 https://ipinfo.io/json 2>/dev/null || log_warn "ipinfo.io 查询失败"
    echo
}

test_streaming_unlock() {
    require_command curl || return 1

    echo "==== 流媒体解锁初筛 ===="
    echo "说明: 结果用于快速判断，部分平台需要结合网页内容和账号状态复核。"
    printf "%-18s %-8s %-10s %s\n" "服务" "状态码" "结果" "耗时"
    http_probe "Netflix" "https://www.netflix.com/title/81215567"
    http_probe "Disney+" "https://www.disneyplus.com/"
    http_probe "YouTube" "https://www.youtube.com/premium"
    http_probe "TikTok" "https://www.tiktok.com/"
    http_probe "PrimeVideo" "https://www.primevideo.com/"
    http_probe "Hulu" "https://www.hulu.com/"
}

test_ai_unlock() {
    require_command curl || return 1

    echo "==== AI 服务可访问性测试 ===="
    echo "说明: 401 通常代表 API 可达但需要认证，403/451 多数代表限制或拒绝。"
    printf "%-18s %-8s %-10s %s\n" "服务" "状态码" "结果" "耗时"
    http_probe "OpenAI API" "https://api.openai.com/v1/models"
    http_probe "ChatGPT" "https://chatgpt.com/"
    http_probe "Gemini" "https://gemini.google.com/"
    http_probe "Claude" "https://claude.ai/"
    http_probe "Copilot" "https://copilot.microsoft.com/"
    http_probe "Perplexity" "https://www.perplexity.ai/"
}

run_all_ip_tests() {
    show_public_ip_info
    echo
    test_streaming_unlock
    echo
    test_ai_unlock
}

port_pids() {
    local port="$1"
    ss -lntp 2>/dev/null | awk -v port=":${port}" '
        $0 ~ port {
            while (match($0, /pid=[0-9]+/)) {
                print substr($0, RSTART + 4, RLENGTH - 4)
                $0 = substr($0, RSTART + RLENGTH)
            }
        }
    ' | sort -u
}

show_port_usage() {
    local port="$1"
    ss -lntp 2>/dev/null | awk -v port=":${port}" '$0 ~ port {print}'
}

free_tcp_port_for_certbot() {
    local port="$1"
    local pids services service stopped_services_file
    stopped_services_file="$(mktemp)"

    if [[ -z "$(port_pids "$port")" ]]; then
        echo "$stopped_services_file"
        return 0
    fi

    log_warn "TCP ${port} 端口已被占用："
    show_port_usage "$port"
    read -r -p "是否释放 ${port} 端口用于 Let's Encrypt standalone 签发? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 1

    services=("apache2" "httpd" "caddy")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "停止服务: $service"
            echo "$service" >> "$stopped_services_file"
            systemctl stop "$service" || true
        fi
    done

    pids="$(port_pids "$port")"
    if [[ -n "$pids" ]]; then
        log_warn "仍有进程占用 ${port} 端口，准备结束 PID: $pids"
        kill $pids 2>/dev/null || true
        sleep 2
    fi

    pids="$(port_pids "$port")"
    if [[ -n "$pids" ]]; then
        log_warn "进程未退出，强制结束 PID: $pids"
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi

    if [[ -n "$(port_pids "$port")" ]]; then
        log_error "TCP ${port} 端口仍被占用，无法继续签发"
        show_port_usage "$port"
        return 1
    fi

    echo "$stopped_services_file"
}

restore_services_after_certbot() {
    local stopped_services_file="$1"
    [[ -f "$stopped_services_file" ]] || return 0

    while read -r service; do
        [[ -n "$service" ]] || continue
        systemctl start "$service" >/dev/null 2>&1 || log_warn "服务恢复失败: $service"
    done < "$stopped_services_file"

    rm -f "$stopped_services_file"
}

safe_run() {
    local label="$1"
    shift
    log_info "开始执行: $label"
    if "$@"; then
        log_ok "操作完成: $label"
        return 0
    fi

    log_error "操作失败: $label"
    return 1
}

check_port_in_use() {
    local port="$1"
    if ss -lntup 2>/dev/null | grep -qE "[[:space:]]:${port}[[:space:]]"; then
        log_error "端口已被占用: $port"
        return 1
    fi
}

check_udp_port_in_use() {
    local port="$1"
    if ss -lunp 2>/dev/null | grep -qE "[[:space:]]\*?:${port}[[:space:]]|[[:space:]][0-9.]+:${port}[[:space:]]|[[:space:]]\[::\]:${port}[[:space:]]"; then
        log_error "UDP 端口已被占用: $port"
        ss -lunp 2>/dev/null | grep -E "[[:space:]]\*?:${port}[[:space:]]|[[:space:]][0-9.]+:${port}[[:space:]]|[[:space:]]\[::\]:${port}[[:space:]]" || true
        return 1
    fi
}

verify_service_active() {
    local service_name="$1"
    sleep 2
    if systemctl is-active --quiet "$service_name"; then
        log_ok "服务运行正常: $service_name"
        return 0
    fi

    log_error "服务启动失败: $service_name"
    systemctl --no-pager status "$service_name" || true
    return 1
}

preflight_check() {
    local mem_mb disk_avail root_fs current_443
    detect_system
    echo "==== 预检查 ===="
    echo "系统: ${OS_ID} ${OS_VERSION}"
    echo "架构: ${ARCH}"
    echo "内核: $(uname -r)"

    mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    root_fs="$(df -Pm / | awk 'NR==2 {print $6}')"
    disk_avail="$(df -Pm / | awk 'NR==2 {print $4}')"
    current_443="$(ss -lntp 2>/dev/null | awk '/:443 / {print $0}')"

    echo "内存(MB): ${mem_mb}"
    echo "根分区剩余(MB): ${disk_avail}"
    if [[ -n "$current_443" ]]; then
        echo "443 端口占用:"
        echo "$current_443"
    else
        echo "443 端口占用: 未发现"
    fi

    if (( mem_mb < 256 )); then
        log_warn "内存低于 256MB，安装代理服务风险较高"
    fi
    if (( disk_avail < 512 )); then
        log_warn "根分区可用空间低于 512MB，建议先清理"
    fi
    if [[ "$root_fs" != "/" ]]; then
        log_info "当前根挂载点: $root_fs"
    fi
}

sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

domain_file() {
    local domain
    domain="$(sanitize_name "$1")"
    echo "$DOMAIN_DIR/${domain}.conf"
}

yaml_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

normalize_ws_path() {
    local path="$1"
    path="${path:-/trojan}"
    [[ "$path" == /* ]] || path="/${path}"
    echo "$path"
}

save_kv_file() {
    local file="$1"
    shift
    : > "$file"
    while [[ "$#" -gt 0 ]]; do
        echo "$1" >> "$file"
        shift
    done
}

read_kv() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2-
}

domain_name_from_file() {
    local file="$1"
    local domain
    domain="$(read_kv "$file" DOMAIN || true)"

    if [[ -n "$domain" ]]; then
        echo "$domain"
        return 0
    fi

    # 兼容旧配置：缺少 DOMAIN= 时，用文件名作为域名并补写到文件开头
    domain="$(basename "$file" .conf)"
    if validate_domain_record "$domain" >/dev/null 2>&1; then
        sed -i.bak "1i\\
DOMAIN=$domain
" "$file"
        rm -f "${file}.bak"
        echo "[WARN] $(date '+%F %T') 旧域名配置缺少 DOMAIN，已自动补全: $domain" >> "$LOG_FILE" 2>/dev/null || true
        echo "$domain"
        return 0
    fi

    echo ""
    return 1
}

list_domains() {
    local found=0
    local index=1
    echo "已配置域名："
    for file in "$DOMAIN_DIR"/*.conf; do
        [[ -e "$file" ]] || continue
        found=1
        local domain cert_mode cert_file key_file
        domain="$(domain_name_from_file "$file" || true)"
        cert_mode="$(read_kv "$file" CERT_MODE || true)"
        cert_file="$(read_kv "$file" CERT_FILE || true)"
        key_file="$(read_kv "$file" KEY_FILE || true)"
        echo "[$index] ${domain:-未知域名} | 证书模式: ${cert_mode:-未设置} | cert: ${cert_file:-未设置} | key: ${key_file:-未设置}"
        index=$((index + 1))
    done
    [[ "$found" -eq 1 ]] || echo " - 暂无域名"
}

pick_domain() {
    local files=()
    local index=1
    local choice
    PICKED_DOMAIN_FILE=""

    for file in "$DOMAIN_DIR"/*.conf; do
        [[ -e "$file" ]] || continue
        files+=("$file")
        echo "[$index] $(domain_name_from_file "$file" || echo 未知域名)"
        index=$((index + 1))
    done

    if [[ "${#files[@]}" -eq 0 ]]; then
        log_warn "暂无可选域名，请先添加域名"
        return 1
    fi

    if [[ "${#files[@]}" -eq 1 ]]; then
        PICKED_DOMAIN_FILE="${files[0]}"
        log_info "仅有一个域名，已自动选择: $(domain_name_from_file "$PICKED_DOMAIN_FILE")"
        return 0
    fi

    read -r -p "选择域名编号: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
        for file in "${files[@]}"; do
            if [[ "$(domain_name_from_file "$file")" == "$choice" ]]; then
                PICKED_DOMAIN_FILE="$file"
                return 0
            fi
        done
        log_error "选择无效，请输入编号或完整域名"
        return 1
    fi

    PICKED_DOMAIN_FILE="${files[$((choice - 1))]}"
    return 0
}

validate_domain_record() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_error "域名格式不合法"
        return 1
    fi
}

add_domain() {
    local domain cert_mode cert_file key_file le_email target_file
    read -r -p "输入域名: " domain
    validate_domain_record "$domain" || return 1
    target_file="$(domain_file "$domain")"

    if [[ -f "$target_file" ]]; then
        log_warn "域名已存在: $domain"
        read -r -p "是否覆盖现有域名配置? [y/N]: " overwrite_confirm
        [[ "$overwrite_confirm" =~ ^[Yy]$ ]] || return 0
    fi

    echo "证书模式："
    echo "[1] 手动证书"
    echo "[2] Let's Encrypt"
    read -r -p "选择证书模式: " cert_choice

    cert_mode="manual"
    cert_file=""
    key_file=""
    le_email=""

    case "$cert_choice" in
        1)
            read -r -p "输入证书公钥路径(cert.pem/fullchain.pem): " cert_file
            read -r -p "输入证书私钥路径(key.pem/privkey.pem): " key_file
            ;;
        2)
            cert_mode="letsencrypt"
            read -r -p "输入用于签发的邮箱: " le_email
            cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
            key_file="/etc/letsencrypt/live/${domain}/privkey.pem"
            ;;
        *)
            log_error "选择无效"
            return 1
            ;;
    esac

    save_kv_file "$target_file" \
        "DOMAIN=$domain" \
        "CERT_MODE=$cert_mode" \
        "CERT_FILE=$cert_file" \
        "KEY_FILE=$key_file" \
        "LE_EMAIL=$le_email"

    log_ok "域名已保存: $domain"
}

edit_domain_cert() {
    local file domain cert_mode cert_file key_file le_email
    pick_domain || return 1
    file="$PICKED_DOMAIN_FILE"
    domain="$(read_kv "$file" DOMAIN)"

    echo "更新 ${domain} 的证书配置："
    echo "[1] 手动证书"
    echo "[2] Let's Encrypt"
    read -r -p "选择模式: " cert_choice

    cert_mode="manual"
    cert_file=""
    key_file=""
    le_email=""

    case "$cert_choice" in
        1)
            read -r -p "输入证书公钥路径: " cert_file
            read -r -p "输入证书私钥路径: " key_file
            ;;
        2)
            cert_mode="letsencrypt"
            read -r -p "输入用于签发的邮箱: " le_email
            cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
            key_file="/etc/letsencrypt/live/${domain}/privkey.pem"
            ;;
        *)
            log_error "选择无效"
            return 1
            ;;
    esac

    save_kv_file "$file" \
        "DOMAIN=$domain" \
        "CERT_MODE=$cert_mode" \
        "CERT_FILE=$cert_file" \
        "KEY_FILE=$key_file" \
        "LE_EMAIL=$le_email"

    log_ok "域名证书配置已更新"
}

remove_domain() {
    local file domain
    pick_domain || return 1
    file="$PICKED_DOMAIN_FILE"
    domain="$(read_kv "$file" DOMAIN)"
    read -r -p "确认删除域名 ${domain} ? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    rm -f "$file"
    log_ok "已删除域名: $domain"
}

remove_domain_by_name() {
    local domain file
    read -r -p "输入要删除的域名: " domain
    validate_domain_record "$domain" || return 1
    file="$(domain_file "$domain")"

    if [[ ! -f "$file" ]]; then
        log_error "域名不存在: $domain"
        return 1
    fi

    read -r -p "确认删除域名 ${domain} ? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    rm -f "$file"
    log_ok "已删除域名: $domain"
}

install_base_packages() {
    detect_system
    log_info "安装基础依赖"

    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar unzip openssl socat
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl wget tar unzip openssl socat
            else
                yum install -y epel-release || true
                yum install -y curl wget tar unzip openssl socat
            fi
            ;;
        *)
            log_error "暂不支持系统: $OS_ID"
            return 1
            ;;
    esac

    log_ok "基础依赖安装完成"
}

measure_apt_mirror() {
    local mirror="$1"
    local codename="$2"
    local test_url="${mirror}/dists/${codename}/Release"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null -w "%{time_total}" "$test_url" 2>/dev/null || echo "999"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        local start end
        start="$(date +%s)"
        timeout 10 wget -q -O /dev/null "$test_url" >/dev/null 2>&1 || { echo "999"; return 0; }
        end="$(date +%s)"
        echo "$((end - start))"
        return 0
    fi

    echo "999"
}

pick_fast_ubuntu_mirror() {
    local codename="$1"
    local arch="$2"
    local candidates=()
    local mirror time best_mirror best_time

    if [[ "$arch" == "arm64" || "$arch" == "armhf" || "$arch" == "ppc64el" || "$arch" == "s390x" ]]; then
        candidates+=("http://ports.ubuntu.com/ubuntu-ports")
    else
        candidates+=("http://archive.ubuntu.com/ubuntu")
        candidates+=("http://us.archive.ubuntu.com/ubuntu")
        candidates+=("http://cn.archive.ubuntu.com/ubuntu")
        candidates+=("http://jp.archive.ubuntu.com/ubuntu")
        candidates+=("http://kr.archive.ubuntu.com/ubuntu")
    fi

    best_mirror="${candidates[0]}"
    best_time="999"
    echo "==== Ubuntu 官方源测速 ====" >&2
    for mirror in "${candidates[@]}"; do
        time="$(measure_apt_mirror "$mirror" "$codename")"
        printf "%-42s %ss\n" "$mirror" "$time" >&2
        if awk "BEGIN {exit !($time < $best_time)}"; then
            best_time="$time"
            best_mirror="$mirror"
        fi
    done

    echo "$best_mirror"
}

backup_apt_sources() {
    local backup_suffix
    backup_suffix="$(date +%Y%m%d-%H%M%S)"

    if [[ -f /etc/apt/sources.list ]]; then
        cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.${backup_suffix}"
        log_ok "已备份 /etc/apt/sources.list"
    fi

    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        cp -a /etc/apt/sources.list.d/ubuntu.sources "/etc/apt/sources.list.d/ubuntu.sources.bak.${backup_suffix}"
        log_ok "已备份 /etc/apt/sources.list.d/ubuntu.sources"
    fi
}

write_ubuntu_sources() {
    local mirror="$1"
    local codename="$2"
    local arch="$3"
    local security_mirror="http://security.ubuntu.com/ubuntu"

    if [[ "$arch" == "arm64" || "$arch" == "armhf" || "$arch" == "ppc64el" || "$arch" == "s390x" ]]; then
        security_mirror="http://ports.ubuntu.com/ubuntu-ports"
    fi

    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${mirror}
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${security_mirror}
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        return 0
    fi

    cat > /etc/apt/sources.list <<EOF
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
deb ${security_mirror} ${codename}-security main restricted universe multiverse
EOF
}

optimize_ubuntu_sources() {
    local codename mirror
    detect_system

    if [[ "$OS_ID" != "ubuntu" ]]; then
        log_error "当前功能仅支持 Ubuntu"
        return 1
    fi

    codename="${VERSION_CODENAME:-}"
    if [[ -z "$codename" ]]; then
        codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    fi
    [[ -n "$codename" ]] || { log_error "无法识别 Ubuntu 发行版代号"; return 1; }

    mirror="$(pick_fast_ubuntu_mirror "$codename" "$ARCH" | tail -n 1)"
    log_info "选择最快官方源: $mirror"
    read -r -p "确认写入 Ubuntu 软件源并执行 apt-get update? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    backup_apt_sources
    write_ubuntu_sources "$mirror" "$codename" "$ARCH"
    apt-get update -y
    log_ok "Ubuntu 软件源已优化"
}

install_certbot_packages() {
    detect_system
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y certbot
            else
                yum install -y epel-release || true
                yum install -y certbot
            fi
            ;;
    esac
}

install_base_packages_safe() {
    preflight_check
    safe_run "install-base-packages" install_base_packages
}

install_bbr_acceleration() {
    local sysctl_file available_controls current_control current_qdisc
    detect_system

    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        log_warn "当前 BBR 安装流程主要按 Ubuntu/Debian 编写"
    fi

    sysctl_file="/etc/sysctl.d/99-server-deploy-tool-bbr.conf"

    if ! grep -qw "bbr" /proc/modules 2>/dev/null; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    available_controls="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ "$available_controls" != *"bbr"* ]]; then
        log_error "当前内核未报告支持 BBR"
        log_warn "请确认内核版本不低于 4.9，或已启用 tcp_bbr 模块"
        return 1
    fi

    cat > "$sysctl_file" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null

    current_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

    if [[ "$current_control" == "bbr" && "$current_qdisc" == "fq" ]]; then
        log_ok "BBR 已启用"
        return 0
    fi

    log_error "BBR 配置写入成功，但当前未生效"
    log_warn "建议检查内核模块后重试，必要时重启服务器"
    return 1
}

install_bbr_acceleration_safe() {
    safe_run "install-bbr" install_bbr_acceleration
}

show_ipv6_status() {
    local all_disabled default_disabled lo_disabled ipv6_addr_summary
    all_disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")"
    default_disabled="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "unknown")"
    lo_disabled="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo "unknown")"
    ipv6_addr_summary="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 / {print $2}' | paste -sd ', ' -)"

    echo "==== IPv6 状态 ===="
    echo "all.disable_ipv6: ${all_disabled}"
    echo "default.disable_ipv6: ${default_disabled}"
    echo "lo.disable_ipv6: ${lo_disabled}"
    if [[ "$all_disabled" == "1" && "$default_disabled" == "1" ]]; then
        echo "当前状态: 已关闭"
    elif [[ "$all_disabled" == "0" && "$default_disabled" == "0" ]]; then
        echo "当前状态: 已开启"
    else
        echo "当前状态: 部分开启/部分关闭"
    fi
    echo "全局 IPv6 地址: ${ipv6_addr_summary:-未检测到}"
}

set_ipv6_state() {
    local state="$1"
    local sysctl_file
    sysctl_file="/etc/sysctl.d/99-server-deploy-tool-ipv6.conf"

    case "$state" in
        enable)
            cat > "$sysctl_file" <<'EOF'
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
EOF
            ;;
        disable)
            cat > "$sysctl_file" <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
            ;;
        *)
            log_error "未知 IPv6 状态: $state"
            return 1
            ;;
    esac

    if ! sysctl --system >/dev/null; then
        log_error "sysctl 应用失败"
        return 1
    fi

    if [[ "$state" == "enable" ]]; then
        log_ok "IPv6 已开启"
    else
        log_ok "IPv6 已关闭"
    fi
}

ipv6_menu() {
    while true; do
        show_banner
        echo "IPv6 管理"
        echo "[1] 查看 IPv6 状态"
        echo "[2] 开启 IPv6"
        echo "[3] 关闭 IPv6"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) show_ipv6_status; pause_wait ;;
            2) set_ipv6_state enable; pause_wait ;;
            3) set_ipv6_state disable; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

show_bbr_status() {
    local kernel_version available_controls current_control current_qdisc loaded_module
    kernel_version="$(uname -r)"
    available_controls="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    current_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    loaded_module="未加载"

    if grep -qw "tcp_bbr" /proc/modules 2>/dev/null || grep -qw "bbr" /proc/modules 2>/dev/null; then
        loaded_module="已加载"
    fi

    echo "==== BBR 状态 ===="
    echo "内核版本: ${kernel_version}"
    echo "可用拥塞控制: ${available_controls:-未知}"
    echo "当前拥塞控制: ${current_control:-未知}"
    echo "当前队列算法: ${current_qdisc:-未知}"
    echo "模块状态: ${loaded_module}"
}

issue_letsencrypt_for_domain() {
    local file domain email cert_mode stopped_services_file
    pick_domain || return 1
    file="$PICKED_DOMAIN_FILE"
    domain="$(read_kv "$file" DOMAIN)"
    cert_mode="$(read_kv "$file" CERT_MODE)"
    email="$(read_kv "$file" LE_EMAIL)"

    if [[ "$cert_mode" != "letsencrypt" ]]; then
        log_error "当前域名不是 Let's Encrypt 模式"
        return 1
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        install_certbot_packages
    fi
    require_command certbot || return 1

    log_warn "签发前请确认域名 A/AAAA 记录已指向当前服务器，且 80 端口可访问"
    read -r -p "确认继续签发? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    stopped_services_file="$(free_tcp_port_for_certbot 80)" || return 1

    if ! certbot certonly --standalone --non-interactive --agree-tos -m "$email" -d "$domain"; then
        restore_services_after_certbot "$stopped_services_file"
        return 1
    fi

    restore_services_after_certbot "$stopped_services_file"
    log_ok "证书签发完成: $domain"
}

cleanup_legacy_instance_units() {
    local pattern="$1"
    local unit
    systemctl list-units --all --plain --no-legend "$pattern" 2>/dev/null | awk '{print $1}' | while read -r unit; do
        [[ -n "$unit" ]] || continue
        log_warn "停止并禁用旧服务单元: $unit"
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    done
}

install_trojan_go() {
    detect_system
    require_command curl || return 1
    require_command unzip || return 1

    local version url pkg temp_dir binary_path
    version="$(curl -fsSL https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest | grep '"tag_name"' | head -n 1 | cut -d '"' -f4)"
    [[ -n "$version" ]] || { log_error "无法获取 Trojan-Go 最新版本"; return 1; }

    url="https://github.com/p4gefau1t/trojan-go/releases/download/${version}/trojan-go-linux-${ARCH}.zip"
    temp_dir="$(mktemp -d)"
    pkg="${temp_dir}/trojan-go.zip"

    curl -fL "$url" -o "$pkg"
    unzip -oq "$pkg" -d "$temp_dir"
    binary_path="$(find "$temp_dir" -type f -name trojan-go | head -n 1)"
    [[ -n "$binary_path" ]] || { rm -rf "$temp_dir"; log_error "压缩包内未找到 trojan-go 二进制"; return 1; }
    install -m 0755 "$binary_path" /usr/local/bin/trojan-go
    rm -rf "$temp_dir"

    log_ok "Trojan-Go 安装完成"
}

install_hysteria2() {
    require_command curl || return 1
    local temp_script
    temp_script="$(mktemp)"
    curl -fsSL https://get.hy2.sh/ -o "$temp_script"
    bash "$temp_script"
    rm -f "$temp_script"
    log_ok "Hysteria2 安装完成"
}

install_xray() {
    local version asset_name url temp_dir pkg binary_path

    require_command curl || return 1
    require_command unzip || return 1

    case "$ARCH" in
        amd64) asset_name="Xray-linux-64.zip" ;;
        arm64) asset_name="Xray-linux-arm64-v8a.zip" ;;
        *) log_error "Xray 不支持当前架构: ${ARCH}"; return 1 ;;
    esac

    version="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name"' | head -n 1 | cut -d '"' -f4)"
    [[ -n "$version" ]] || { log_error "无法获取 Xray-core 最新版本"; return 1; }

    url="https://github.com/XTLS/Xray-core/releases/download/${version}/${asset_name}"
    temp_dir="$(mktemp -d)"
    pkg="${temp_dir}/xray.zip"

    if ! curl -fL "$url" -o "$pkg" || ! unzip -oq "$pkg" -d "$temp_dir"; then
        rm -rf "$temp_dir"
        log_error "Xray-core 下载或解压失败"
        return 1
    fi

    binary_path="$(find "$temp_dir" -type f -name xray | head -n 1)"
    [[ -n "$binary_path" ]] || { rm -rf "$temp_dir"; log_error "压缩包内未找到 xray 二进制"; return 1; }
    install -m 0755 "$binary_path" /usr/local/bin/xray
    rm -rf "$temp_dir"
    log_ok "Xray-core 安装完成: ${version}"
}

write_trojan_service_unit() {
    cat > "/etc/systemd/system/trojan-go.service" <<EOF
[Unit]
Description=Trojan-Go
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/trojan-go -config ${TROJAN_JSON}
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

write_hysteria_service_unit() {
    local hysteria_bin="$1"
    cat > "/etc/systemd/system/hysteria2.service" <<EOF
[Unit]
Description=Hysteria2
After=network.target

[Service]
Type=simple
ExecStart=${hysteria_bin} server -c ${HYSTERIA_YAML}
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

write_xray_service_unit() {
    cat > "/etc/systemd/system/xray.service" <<EOF
[Unit]
Description=Xray VLESS Reality
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config ${XRAY_JSON}
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

find_hysteria_binary() {
    if command -v hysteria >/dev/null 2>&1; then
        command -v hysteria
        return 0
    fi
    if [[ -x /usr/local/bin/hysteria ]]; then
        echo "/usr/local/bin/hysteria"
        return 0
    fi
    if [[ -x /usr/local/bin/hysteria2 ]]; then
        echo "/usr/local/bin/hysteria2"
        return 0
    fi
    return 1
}

cleanup_failed_hysteria_instances() {
    cleanup_legacy_instance_units 'hysteria2@*.service'
}

cleanup_failed_trojan_instances() {
    cleanup_legacy_instance_units 'trojan-go@*.service'
}

ensure_domain_cert_ready() {
    local domain_config="$1"
    local cert_file key_file domain
    domain="$(read_kv "$domain_config" DOMAIN)"
    cert_file="$(read_kv "$domain_config" CERT_FILE)"
    key_file="$(read_kv "$domain_config" KEY_FILE)"

    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        log_error "域名 ${domain} 的证书文件不存在"
        log_error "cert: $cert_file"
        log_error "key : $key_file"
        return 1
    fi
}

configure_trojan_instance() {
    local domain_config domain password port cert_file key_file fallback_addr fallback_port ws_path ws_host

    pick_domain || return 1
    domain_config="$PICKED_DOMAIN_FILE"
    ensure_domain_cert_ready "$domain_config" || return 1
    domain="$(read_kv "$domain_config" DOMAIN)"
    cert_file="$(read_kv "$domain_config" CERT_FILE)"
    key_file="$(read_kv "$domain_config" KEY_FILE)"

    read -r -p "输入 Trojan-Go 密码: " password
    read -r -p "输入 Trojan-Go 内部监听端口(建议 8443+): " port
    read -r -p "输入伪装回落地址(默认 127.0.0.1): " fallback_addr
    fallback_addr="${fallback_addr:-127.0.0.1}"
    read -r -p "输入伪装回落端口(默认 80): " fallback_port
    fallback_port="${fallback_port:-80}"
    read -r -p "输入 WebSocket 路径(默认 /trojan): " ws_path
    ws_path="$(normalize_ws_path "$ws_path")"
    read -r -p "输入 WebSocket Host(默认 ${domain}): " ws_host
    ws_host="${ws_host:-$domain}"
    check_port_in_use "$port" || return 1

    save_kv_file "$TROJAN_CONF" \
        "TYPE=trojan-go" \
        "DOMAIN=$domain" \
        "PORT=$port" \
        "CERT_FILE=$cert_file" \
        "KEY_FILE=$key_file" \
        "FALLBACK_ADDR=$fallback_addr" \
        "FALLBACK_PORT=$fallback_port" \
        "WS_ENABLED=true" \
        "WS_PATH=$ws_path" \
        "WS_HOST=$ws_host"

    cat > "$TROJAN_JSON" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${port},
  "remote_addr": "${fallback_addr}",
  "remote_port": ${fallback_port},
  "password": [
    "${password}"
  ],
  "ssl": {
    "cert": "${cert_file}",
    "key": "${key_file}",
    "sni": "${domain}",
    "alpn": [
      "http/1.1"
    ]
  },
  "websocket": {
    "enabled": true,
    "path": "${ws_path}",
    "host": "${ws_host}"
  }
}
EOF

    cleanup_failed_trojan_instances
    write_trojan_service_unit
    systemctl daemon-reload
    systemctl reset-failed trojan-go.service >/dev/null 2>&1 || true
    if ! systemctl enable --now trojan-go.service; then
        log_error "Trojan-Go 启动命令失败"
        journalctl -u trojan-go.service --no-pager -n 50 || true
        systemctl disable --now trojan-go.service >/dev/null 2>&1 || true
        return 1
    fi
    if ! verify_service_active trojan-go.service; then
        journalctl -u trojan-go.service --no-pager -n 50 || true
        systemctl disable --now trojan-go.service >/dev/null 2>&1 || true
        return 1
    fi
    log_ok "Trojan-Go 已启动"
}

configure_hysteria_instance() {
    local domain email port password masquerade_url hysteria_bin
    local quoted_domain quoted_email quoted_password quoted_masquerade_url

    hysteria_bin="$(find_hysteria_binary)" || { log_error "未找到 hysteria 二进制，请先安装 Hysteria2"; return 1; }

    read -r -p "输入 Hysteria2 域名: " domain
    validate_domain_record "$domain" || return 1
    read -r -p "输入 ACME 邮箱: " email
    read -r -p "输入 Hysteria2 密码: " password
    read -r -p "输入 Hysteria2 UDP 监听端口(默认 443): " port
    port="${port:-443}"
    read -r -p "输入伪装地址(默认 https://news.ycombinator.com/): " masquerade_url
    masquerade_url="${masquerade_url:-https://news.ycombinator.com/}"
    check_udp_port_in_use "$port" || return 1

    quoted_domain="$(yaml_quote "$domain")"
    quoted_email="$(yaml_quote "$email")"
    quoted_password="$(yaml_quote "$password")"
    quoted_masquerade_url="$(yaml_quote "$masquerade_url")"

    save_kv_file "$HYSTERIA_CONF" \
        "TYPE=hysteria2" \
        "DOMAIN=$domain" \
        "EMAIL=$email" \
        "PORT=$port" \
        "MASQUERADE_URL=$masquerade_url"

cat > "$HYSTERIA_YAML" <<EOF
listen: :${port}
acme:
  domains:
    - ${quoted_domain}
  email: ${quoted_email}
auth:
  type: password
  password: ${quoted_password}
masquerade:
  type: proxy
  proxy:
    url: ${quoted_masquerade_url}
    rewriteHost: true
EOF

    cleanup_failed_hysteria_instances
    write_hysteria_service_unit "$hysteria_bin"
    systemctl daemon-reload
    systemctl reset-failed hysteria2.service >/dev/null 2>&1 || true
    if ! systemctl enable --now hysteria2.service; then
        log_error "Hysteria2 启动命令失败"
        journalctl -u hysteria2.service --no-pager -n 50 || true
        systemctl disable --now hysteria2.service >/dev/null 2>&1 || true
        return 1
    fi
    if ! verify_service_active hysteria2.service; then
        journalctl -u hysteria2.service --no-pager -n 50 || true
        systemctl disable --now hysteria2.service >/dev/null 2>&1 || true
        return 1
    fi
    log_ok "Hysteria2 已启动"
}

configure_vless_reality() {
    local port access_domain reality_dest server_name short_id input_short_id uuid key_output private_key public_key
    local ipv6_bindv6only

    [[ -x /usr/local/bin/xray ]] || { log_error "未找到 xray 二进制，请先安装 Xray-core"; return 1; }
    require_command openssl || return 1

    read -r -p "输入 VLESS Reality TCP 监听端口(默认 443): " port
    port="${port:-443}"
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        log_error "端口必须是 1 到 65535 的整数"
        return 1
    fi
    check_port_in_use "$port" || return 1

    log_warn "访问域名必须使用 DNS-only 的 A/AAAA 记录指向本机，不能经过 Cloudflare 橙云或其他 CDN 代理"
    read -r -p "输入客户端访问域名（用于生成 VLESS 链接）: " access_domain
    validate_domain_record "$access_domain" || return 1

    read -r -p "输入 Reality 目标地址(默认 www.cloudflare.com:443): " reality_dest
    reality_dest="${reality_dest:-www.cloudflare.com:443}"
    if [[ ! "$reality_dest" =~ ^[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$ ]]; then
        log_error "Reality 目标地址格式应为 域名:端口"
        return 1
    fi
    if (( ${reality_dest##*:} > 65535 )); then
        log_error "Reality 目标端口必须小于等于 65535"
        return 1
    fi

    read -r -p "输入 Reality SNI(默认 www.cloudflare.com): " server_name
    server_name="${server_name:-www.cloudflare.com}"
    validate_domain_record "$server_name" || return 1

    short_id="$(openssl rand -hex 8)"
    read -r -p "输入 Reality Short ID(默认 ${short_id}): " input_short_id
    short_id="${input_short_id:-$short_id}"
    if ! [[ "$short_id" =~ ^[0-9a-fA-F]{2,16}$ ]] || (( ${#short_id} % 2 != 0 )); then
        log_error "Short ID 必须是 2 到 16 位、长度为偶数的十六进制字符串"
        return 1
    fi

    uuid="$(/usr/local/bin/xray uuid)"
    key_output="$(/usr/local/bin/xray x25519)"
    private_key="$(awk -F': *' 'tolower($1) ~ /^private[[:space:]]*key$/ {print $2; exit}' <<< "$key_output")"
    public_key="$(awk -F': *' 'tolower($1) ~ /^public[[:space:]]*key$/ || tolower($1) ~ /^password/ {print $2; exit}' <<< "$key_output")"
    if [[ -z "$uuid" || -z "$private_key" || -z "$public_key" ]]; then
        log_error "Xray Reality 密钥生成失败"
        return 1
    fi

    apply_vless_reality_config "::" "$port" "$reality_dest" "$server_name" "$uuid" "$private_key" "$short_id" "UseIPv4" || return 1
    save_vless_reality_state "::" "$port" "$access_domain" "$reality_dest" "$server_name" "$uuid" "$private_key" "$public_key" "$short_id" "chrome" "UseIPv4"

    log_ok "VLESS + Reality 已启动"
    ipv6_bindv6only="$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 0)"
    if [[ "$ipv6_bindv6only" == "1" ]]; then
        log_warn "当前 net.ipv6.bindv6only=1，监听 :: 时仅接受 IPv6；如需 IPv4 请改为 0 或单独添加 IPv4 入站"
    fi
    echo "服务监听地址: ::（IPv6；Ubuntu 默认 net.ipv6.bindv6only=0 时同时接受 IPv4）"
    echo "客户端访问域名: ${access_domain}"
    echo "使用“导出 VLESS Reality 链接”可查看已保存的域名链接。"
}

apply_vless_reality_config() {
    local listen_address="$1" port="$2" reality_dest="$3" server_name="$4" uuid="$5" private_key="$6" short_id="$7" outbound_strategy="$8"
    local temp_config backup_config had_backup=0

    temp_config="$(mktemp /tmp/xray-reality.XXXXXX.json)"
    cat > "$temp_config" <<EOF
{
  "log": {"loglevel": "warning"},
  "dns": {"queryStrategy": "UseIPv4"},
  "inbounds": [{
    "listen": "${listen_address}",
    "port": ${port},
    "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {"show": false, "dest": "${reality_dest}", "xver": 0, "serverNames": ["${server_name}"], "privateKey": "${private_key}", "shortIds": ["${short_id}"]}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct", "streamSettings": {"sockopt": {"domainStrategy": "${outbound_strategy}"}}}]
}
EOF

    if ! /usr/local/bin/xray run -test -config "$temp_config"; then
        rm -f "$temp_config"
        log_error "VLESS Reality 配置校验失败，未覆盖现有配置"
        return 1
    fi

    backup_config="$(mktemp /tmp/xray-reality-backup.XXXXXX.json)"
    if [[ -f "$XRAY_JSON" ]]; then
        cp "$XRAY_JSON" "$backup_config"
        had_backup=1
    fi
    install -m 0600 "$temp_config" "$XRAY_JSON"
    rm -f "$temp_config"

    write_xray_service_unit
    systemctl daemon-reload
    systemctl reset-failed xray.service >/dev/null 2>&1 || true
    if ! systemctl enable xray.service >/dev/null 2>&1 || ! systemctl restart xray.service; then
        if [[ "$had_backup" -eq 1 ]]; then
            install -m 0600 "$backup_config" "$XRAY_JSON"
            systemctl restart xray.service >/dev/null 2>&1 || true
            log_warn "Xray 启动失败，已恢复上一份配置"
        fi
        rm -f "$backup_config"
        log_error "Xray 启动失败"
        journalctl -u xray.service --no-pager -n 50 || true
        return 1
    fi
    rm -f "$backup_config"
    verify_service_active xray.service
}

save_vless_reality_state() {
    local listen_address="$1" port="$2" access_domain="$3" reality_dest="$4" server_name="$5" uuid="$6" private_key="$7" public_key="$8" short_id="$9" fingerprint="${10}" outbound_strategy="${11}"
    local vless_link

    vless_link="$(build_vless_reality_link "$access_domain" "$port" "$server_name" "$uuid" "$public_key" "$short_id" "$fingerprint")"
    save_kv_file "$XRAY_CONF" \
        "TYPE=vless-reality" \
        "LISTEN_ADDRESS=$listen_address" \
        "PORT=$port" \
        "SERVER_DOMAIN=$access_domain" \
        "OUTBOUND_DOMAIN_STRATEGY=$outbound_strategy" \
        "REALITY_DEST=$reality_dest" \
        "SNI=$server_name" \
        "UUID=$uuid" \
        "PRIVATE_KEY=$private_key" \
        "PUBLIC_KEY=$public_key" \
        "SHORT_ID=$short_id" \
        "FINGERPRINT=$fingerprint" \
        "VLESS_LINK=$vless_link"
    chmod 0600 "$XRAY_CONF"
}

read_xray_json_string() {
    local key="$1"
    sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$XRAY_JSON" | head -n 1
}

read_xray_json_number() {
    local key="$1"
    sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p" "$XRAY_JSON" | head -n 1
}

edit_vless_reality() {
    local listen_address port old_port access_domain reality_dest server_name short_id fingerprint outbound_strategy
    local uuid private_key public_key key_output input_value

    [[ -x /usr/local/bin/xray ]] || { log_error "未找到 xray 二进制，请先安装 Xray-core"; return 1; }
    [[ -f "$XRAY_JSON" ]] || { log_error "未找到 ${XRAY_JSON}，请先完成首次配置"; return 1; }

    listen_address="$(read_xray_json_string "listen" || true)"
    port="$(read_xray_json_number "port" || true)"
    access_domain="$(read_kv "$XRAY_CONF" "SERVER_DOMAIN" || true)"
    reality_dest="$(read_xray_json_string "dest" || true)"
    server_name="$(sed -nE 's/.*"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"]*)".*/\1/p' "$XRAY_JSON" | head -n 1)"
    uuid="$(read_xray_json_string "id" || true)"
    private_key="$(read_xray_json_string "privateKey" || true)"
    short_id="$(sed -nE 's/.*"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"]*)".*/\1/p' "$XRAY_JSON" | head -n 1)"
    outbound_strategy="$(read_xray_json_string "domainStrategy" || true)"
    fingerprint="$(read_kv "$XRAY_CONF" "FINGERPRINT" || true)"
    fingerprint="${fingerprint:-chrome}"
    outbound_strategy="${outbound_strategy:-UseIPv4}"
    old_port="$port"

    key_output="$(/usr/local/bin/xray x25519 -i "$private_key" 2>/dev/null || true)"
    public_key="$(awk -F': *' 'tolower($1) ~ /^public[[:space:]]*key$/ || tolower($1) ~ /^password/ {print $2; exit}' <<< "$key_output")"
    public_key="${public_key:-$(read_kv "$XRAY_CONF" "PUBLIC_KEY" || true)}"

    if [[ -z "$listen_address" || -z "$port" || -z "$access_domain" || -z "$reality_dest" || -z "$server_name" || -z "$uuid" || -z "$private_key" || -z "$public_key" || -z "$short_id" ]]; then
        log_error "现有配置不完整，无法安全编辑；请重新执行首次配置"
        return 1
    fi

    read -r -p "监听地址 [${listen_address}]: " input_value
    listen_address="${input_value:-$listen_address}"
    if [[ "$listen_address" =~ [[:space:]\"\\] ]]; then
        log_error "监听地址不能包含空格、双引号或反斜杠"
        return 1
    fi

    read -r -p "VLESS Reality TCP 监听端口 [${port}]: " input_value
    port="${input_value:-$port}"
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        log_error "端口必须是 1 到 65535 的整数"
        return 1
    fi
    if [[ "$port" != "$old_port" ]]; then
        check_port_in_use "$port" || return 1
    fi

    read -r -p "客户端访问域名 [${access_domain}]: " input_value
    access_domain="${input_value:-$access_domain}"
    validate_domain_record "$access_domain" || return 1

    read -r -p "Reality 目标地址 [${reality_dest}]: " input_value
    reality_dest="${input_value:-$reality_dest}"
    if [[ ! "$reality_dest" =~ ^[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$ ]] || (( ${reality_dest##*:} > 65535 )); then
        log_error "Reality 目标地址格式应为 域名:端口，端口最大 65535"
        return 1
    fi

    read -r -p "Reality SNI [${server_name}]: " input_value
    server_name="${input_value:-$server_name}"
    validate_domain_record "$server_name" || return 1

    read -r -p "用户 UUID [${uuid}]: " input_value
    uuid="${input_value:-$uuid}"
    if ! [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
        log_error "UUID 格式不合法"
        return 1
    fi

    read -r -p "Reality Short ID [${short_id}]: " input_value
    short_id="${input_value:-$short_id}"
    if ! [[ "$short_id" =~ ^[0-9a-fA-F]{2,16}$ ]] || (( ${#short_id} % 2 != 0 )); then
        log_error "Short ID 必须是 2 到 16 位、长度为偶数的十六进制字符串"
        return 1
    fi

    read -r -p "客户端指纹 [${fingerprint}]: " input_value
    fingerprint="${input_value:-$fingerprint}"
    case "$fingerprint" in
        chrome|firefox|safari|edge) ;;
        *) log_error "客户端指纹仅支持 chrome、firefox、safari 或 edge"; return 1 ;;
    esac

    read -r -p "服务器出站 IP 协议 [ipv4/ipv6，当前 ${outbound_strategy}]: " input_value
    case "${input_value:-$outbound_strategy}" in
        ipv4|IPv4|useipv4|UseIPv4) outbound_strategy="UseIPv4" ;;
        ipv6|IPv6|useipv6|UseIPv6) outbound_strategy="UseIPv6" ;;
        *) log_error "出站 IP 协议仅支持 ipv4 或 ipv6"; return 1 ;;
    esac

    apply_vless_reality_config "$listen_address" "$port" "$reality_dest" "$server_name" "$uuid" "$private_key" "$short_id" "$outbound_strategy" || return 1
    save_vless_reality_state "$listen_address" "$port" "$access_domain" "$reality_dest" "$server_name" "$uuid" "$private_key" "$public_key" "$short_id" "$fingerprint" "$outbound_strategy"
    log_ok "VLESS + Reality 配置已更新，UUID 与 Reality 密钥保持不变"
}

build_vless_reality_link() {
    local server_address="$1"
    local port="$2"
    local sni="$3"
    local uuid="$4"
    local public_key="$5"
    local short_id="$6"
    local fingerprint="$7"
    local server_address_uri

    if [[ "$server_address" == *:* && "$server_address" != \[*\] ]]; then
        server_address_uri="[${server_address}]"
    else
        server_address_uri="$server_address"
    fi
    echo "vless://${uuid}@${server_address_uri}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fingerprint:-chrome}&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-Reality"
}

show_vless_reality_link() {
    local vless_link
    vless_link="$(read_kv "$XRAY_CONF" "VLESS_LINK" || true)"
    if [[ -z "$vless_link" ]]; then
        log_error "未找到完整 VLESS Reality 配置，请先完成配置并启用服务"
        return 1
    fi

    echo "==== VLESS + Reality 客户端链接 ===="
    echo "$vless_link"
    echo
    echo "Worker 导入：配置管理 → 新增配置 → 导入链接 / JSON，粘贴这一整行 vless:// 链接。"
}

show_status() {
    echo "==== 域名 ===="
    list_domains
    echo
    echo "==== Trojan-Go 配置 ===="
    [[ -f "$TROJAN_CONF" ]] && cat "$TROJAN_CONF" || echo " - 未配置"
    echo
    echo "==== Hysteria2 配置 ===="
    [[ -f "$HYSTERIA_CONF" ]] && cat "$HYSTERIA_CONF" || echo " - 未配置"
    echo
    echo "==== VLESS + Reality 配置 ===="
    [[ -f "$XRAY_CONF" ]] && cat "$XRAY_CONF" || echo " - 未配置"
    echo
    echo "==== systemd 状态 ===="
    systemctl --no-pager --type=service | grep -E 'trojan-go.service|hysteria2.service|xray.service' || true
    echo
    show_bbr_status
    echo
    show_ipv6_status
    echo
    echo "日志文件: $LOG_FILE"
}

protection_menu() {
    while true; do
        show_banner
        echo "保护检查"
        echo "[1] 执行预检查"
        echo "[2] 查看日志路径"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) preflight_check; pause_wait ;;
            2) echo "$LOG_FILE"; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

test_tools_menu() {
    while true; do
        show_banner
        echo "测试工具"
        echo "[1] 公网 IP 与 Geo 信息"
        echo "[2] 流媒体解锁初筛"
        echo "[3] AI 服务可访问性测试"
        echo "[4] 执行全部测试"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) show_public_ip_info; pause_wait ;;
            2) test_streaming_unlock; pause_wait ;;
            3) test_ai_unlock; pause_wait ;;
            4) run_all_ip_tests; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

quick_wizard() {
    log_info "开始快速部署向导"
    preflight_check
    install_base_packages

    echo "选择要安装的服务："
    echo "[1] 仅 Trojan-Go"
    echo "[2] 仅 Hysteria2"
    echo "[3] 仅 VLESS + Reality"
    echo "[4] Trojan-Go、Hysteria2、VLESS + Reality"
    read -r -p "输入编号: " service_choice

    case "$service_choice" in
        1)
            echo "Trojan-Go 需要先配置域名和证书。"
            add_domain
            install_trojan_go
            configure_trojan_instance || return 1
            ;;
        2)
            install_hysteria2
            configure_hysteria_instance || return 1
            ;;
        3)
            install_xray
            configure_vless_reality || return 1
            ;;
        4)
            echo "Trojan-Go 需要先配置域名和证书。"
            add_domain
            install_trojan_go
            install_hysteria2
            install_xray
            configure_trojan_instance || return 1
            configure_hysteria_instance || return 1
            configure_vless_reality || return 1
            ;;
        *)
            log_warn "未选择服务，跳过服务配置"
            ;;
    esac

    log_ok "快速部署向导执行完成"
}

domain_menu() {
    while true; do
        show_banner
        echo "域名与证书管理"
        echo "[1] 查看域名"
        echo "[2] 添加域名"
        echo "[3] 修改证书配置"
        echo "[4] 签发 Let's Encrypt 证书"
        echo "[5] 按编号删除域名"
        echo "[6] 按域名删除域名"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) list_domains; pause_wait ;;
            2) add_domain; pause_wait ;;
            3) edit_domain_cert; pause_wait ;;
            4) issue_letsencrypt_for_domain; pause_wait ;;
            5) remove_domain; pause_wait ;;
            6) remove_domain_by_name; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

trojan_menu() {
    while true; do
        show_banner
        echo "Trojan-Go 管理"
        echo "[1] 安装 Trojan-Go"
        echo "[2] 配置并启用"
        echo "[3] 清理旧服务"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) install_trojan_go; pause_wait ;;
            2) configure_trojan_instance; pause_wait ;;
            3) cleanup_failed_trojan_instances; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

hysteria_menu() {
    while true; do
        show_banner
        echo "Hysteria2 管理"
        echo "[1] 安装 Hysteria2"
        echo "[2] 配置并启用"
        echo "[3] 清理旧服务"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) install_hysteria2; pause_wait ;;
            2) configure_hysteria_instance; pause_wait ;;
            3) cleanup_failed_hysteria_instances; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

xray_menu() {
    while true; do
        show_banner
        echo "VLESS + Reality 管理"
        echo "[1] 安装 Xray-core"
        echo "[2] 配置并启用 VLESS + Reality"
        echo "[3] 编辑已有 VLESS + Reality 配置"
        echo "[4] 查看 Xray 服务日志"
        echo "[5] 导出 VLESS Reality 链接"
        echo "[0] 返回主菜单"
        read -r -p "请选择: " choice

        case "$choice" in
            1) install_xray; pause_wait ;;
            2) configure_vless_reality; pause_wait ;;
            3) edit_vless_reality; pause_wait ;;
            4) journalctl -u xray.service --no-pager -n 80 || true; pause_wait ;;
            5) show_vless_reality_link; pause_wait ;;
            0) return 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

main_menu() {
    while true; do
        show_banner
        echo "主菜单"
        echo "[1] 优化 Ubuntu 软件源"
        echo "[2] 安装基础依赖"
        echo "[3] 安装/启用 BBR"
        echo "[4] IPv6 管理"
        echo "[5] 域名与证书管理"
        echo "[6] Trojan-Go 管理"
        echo "[7] Hysteria2 管理"
        echo "[8] VLESS + Reality 管理"
        echo "[9] 保护检查"
        echo "[10] 查看当前状态"
        echo "[11] 测试工具"
        echo "[12] 快速部署向导"
        echo "[0] 退出"
        read -r -p "请选择: " choice

        case "$choice" in
            1) optimize_ubuntu_sources; pause_wait ;;
            2) install_base_packages_safe; pause_wait ;;
            3) install_bbr_acceleration_safe; pause_wait ;;
            4) ipv6_menu ;;
            5) domain_menu ;;
            6) trojan_menu ;;
            7) hysteria_menu ;;
            8) xray_menu ;;
            9) protection_menu ;;
            10) show_status; pause_wait ;;
            11) test_tools_menu ;;
            12) quick_wizard; pause_wait ;;
            0) exit 0 ;;
            *) log_warn "无效选择"; pause_wait ;;
        esac
    done
}

main() {
    need_root
    ensure_dirs
    detect_system
    main_menu
}

main "$@"
