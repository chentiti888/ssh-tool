#!/bin/bash
# =============================================================
#  SSH 小工具：修改 SSH 端口 / 生成密钥并下载 / CPU 性能测试 / 端口转发
#  用法：bash ssh-tool.sh
# =============================================================

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
SSHD_CONF="/etc/ssh/sshd_config"
KEY_DIR="/root/.ssh/keys"

info() { echo -e "${GREEN}[√]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[×]${NC} $*"; }

[[ $EUID -ne 0 ]] && { err "请使用 root 运行"; exit 1; }

# ---------------- 快捷命令（想改名就改这里） ----------------
CMD_NAME="chen"
OLD_CMDS=("sshm" "ssb")   # 曾经用过的旧命令名，运行时自动清理
CMD_PATH="/usr/local/bin/${CMD_NAME}"

# 脚本在 GitHub 仓库里的 raw 地址（上传仓库后按实际仓库名修改）
SCRIPT_URL="https://raw.githubusercontent.com/chentiti888/ssh-tool/main/ssh-tool.sh"

cleanup_old_cmds() {
    local old p
    for old in "${OLD_CMDS[@]}"; do
        p="/usr/local/bin/${old}"
        [[ "$p" == "$CMD_PATH" ]] && continue
        # 只删除确认是本脚本的旧文件，避免误删别的程序
        if [[ -f "$p" ]] && grep -q "SSH 小工具" "$p" 2>/dev/null; then
            rm -f "$p" && info "已清理旧命令：${old}"
        fi
    done
}

install_shortcut() {
    local self
    cleanup_old_cmds
    self=$(readlink -f "$0" 2>/dev/null)
    [[ "$self" == "$CMD_PATH" ]] && return
    if [[ -f "$self" ]]; then
        # 本地文件运行：直接复制
        cp -f "$self" "$CMD_PATH" 2>/dev/null
    else
        # 通过 bash <(curl ...) 运行：从仓库重新下载一份
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 "$SCRIPT_URL" -o "$CMD_PATH"
    fi
    if [[ -s "$CMD_PATH" ]] && head -1 "$CMD_PATH" | grep -q '^#!'; then
        chmod +x "$CMD_PATH"
        info "已安装快捷命令：以后直接输入 ${CMD_NAME} 即可打开本菜单"
    else
        rm -f "$CMD_PATH"
        warn "快捷命令安装失败：无法从 ${SCRIPT_URL} 下载脚本，请检查网络或 SCRIPT_URL"
        warn "可手动安装：curl -fsSL ${SCRIPT_URL} -o ${CMD_PATH} && chmod +x ${CMD_PATH}"
        sleep 3
    fi
}
install_shortcut

get_ip() {
    curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "服务器IP"
}

current_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    echo "${p:-22}"
}

restart_sshd() {
    # Ubuntu 22.10+ 默认 socket 激活，会无视 sshd_config 里的 Port
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "检测到 ssh.socket，改为直接由 ssh 服务监听"
        systemctl disable --now ssh.socket >/dev/null 2>&1
        systemctl enable ssh >/dev/null 2>&1
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
}

open_firewall() {
    local port=$1
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null && info "ufw 已放行 ${port}/tcp"
    fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
        firewall-cmd --reload >/dev/null && info "firewalld 已放行 ${port}/tcp"
    fi
    if command -v iptables >/dev/null && ! command -v ufw >/dev/null && ! command -v firewall-cmd >/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        info "iptables 已放行 ${port}/tcp（重启后可能失效，请自行持久化）"
    fi
    if command -v semanage >/dev/null && command -v getenforce >/dev/null \
        && [[ $(getenforce) == "Enforcing" ]]; then
        semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null \
            || semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null
    fi
}

# ---------------- 1. 修改端口 ----------------
change_port() {
    local old new
    old=$(current_port)
    echo -e "当前 SSH 端口：${CYAN}${old}${NC}"
    read -rp "请输入新端口 (1-65535，回车取消): " new
    [[ -z "$new" ]] && return
    if ! [[ "$new" =~ ^[0-9]+$ ]] || ((new < 1 || new > 65535)); then
        err "端口无效"; return
    fi
    if [[ "$new" == "$old" ]]; then
        warn "与当前端口相同，无需修改"; return
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${new}$"; then
        err "端口 ${new} 已被占用"; return
    fi

    cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份 sshd_config"

    # 注释掉主配置和 drop-in 里已有的 Port 行，再写入新端口
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /' "$SSHD_CONF"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /' "$f"
    done
    # 放在文件最前面，避免被 Match 块吞掉
    sed -i "1i Port ${new}" "$SSHD_CONF"

    if ! sshd -t 2>/tmp/sshd_err; then
        err "sshd 配置校验失败，已回滚："; cat /tmp/sshd_err
        cp -a "$(ls -t ${SSHD_CONF}.bak.* | head -1)" "$SSHD_CONF"
        return
    fi

    open_firewall "$new"
    restart_sshd
    sleep 1

    if ss -tln | awk '{print $4}' | grep -qE "[:.]${new}$"; then
        info "SSH 已监听新端口 ${new}"
        warn "请【不要关闭当前窗口】，先新开终端测试：ssh -p ${new} root@$(get_ip)"
        warn "云服务器还需要在【安全组/防火墙】里放行 ${new}/tcp，确认能登录后再关闭旧端口 ${old}"
    else
        err "新端口未监听，请检查：systemctl status sshd"
    fi
}

# ---------------- 2. 生成密钥 ----------------
gen_key() {
    local name type pass keyfile
    read -rp "密钥名称 (默认 id_$(hostname)): " name
    name=${name:-id_$(hostname)}
    name=${name//[^a-zA-Z0-9._-]/_}
    echo "密钥类型： 1) ed25519 (推荐)   2) rsa 4096"
    read -rp "请选择 [1]: " type
    read -rsp "私钥密码 (可留空): " pass; echo

    mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
    keyfile="${KEY_DIR}/${name}"
    if [[ -e "$keyfile" ]]; then
        read -rp "${keyfile} 已存在，覆盖？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
        rm -f "$keyfile" "${keyfile}.pub"
    fi

    if [[ "$type" == "2" ]]; then
        ssh-keygen -t rsa -b 4096 -f "$keyfile" -N "$pass" -C "$name" -q
    else
        ssh-keygen -t ed25519 -f "$keyfile" -N "$pass" -C "$name" -q
    fi
    [[ -f "$keyfile" ]] || { err "生成失败"; return; }
    chmod 600 "$keyfile"
    info "密钥已生成：${keyfile}"

    # 公钥写入 authorized_keys
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    if ! grep -qF "$(cut -d' ' -f2 "${keyfile}.pub")" /root/.ssh/authorized_keys; then
        cat "${keyfile}.pub" >> /root/.ssh/authorized_keys
        info "公钥已加入 /root/.ssh/authorized_keys"
    fi

    LAST_KEY="$keyfile"
    echo
    read -rp "现在下载这个私钥吗？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] || download_key "$keyfile"
}

# ---------------- 3. 下载密钥 ----------------
list_keys() {
    ls "$KEY_DIR" 2>/dev/null | grep -v '\.pub$'
}

download_key() {
    local keyfile=$1
    if [[ -z "$keyfile" ]]; then
        local keys; mapfile -t keys < <(list_keys)
        if ((${#keys[@]} == 0)); then err "还没有生成过密钥"; return; fi
        local i=1
        for k in "${keys[@]}"; do echo "  $i) $k"; ((i++)); done
        read -rp "选择要下载的密钥编号: " n
        [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#keys[@]})) || { err "无效选择"; return; }
        keyfile="${KEY_DIR}/${keys[$((n-1))]}"
    fi
    local ip port
    ip=$(get_ip)
    port=$(current_port)

    echo
    echo "下载方式："
    echo "  1) 直接显示私钥内容（复制保存为文件，最安全）"
    echo "  2) 临时 HTTP 链接下载（一次性，120 秒后自动关闭，明文传输有风险）"
    echo "  3) 显示 scp 命令（在你本地电脑执行）"
    read -rp "请选择 [1]: " m
    case "$m" in
    2)
        command -v python3 >/dev/null || { err "需要 python3"; return; }
        local dport token tmp
        dport=$((RANDOM % 10000 + 40000))
        token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        tmp=$(mktemp -d)
        cp "$keyfile" "${tmp}/${token}"
        open_firewall "$dport"
        warn "私钥将通过明文 HTTP 传输，下载完成后建议删除并重新生成"
        echo -e "下载链接：${CYAN}http://${ip}:${dport}/${token}${NC}"
        echo "（云服务器需在安全组临时放行 ${dport}/tcp；等待下载中，Ctrl+C 取消）"
        python3 - "$tmp" "$dport" "$token" <<'PY'
import http.server, sys, os, threading
d, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
os.chdir(d)
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.strip('/') != token:
            self.send_error(404); return
        super().do_GET()
        threading.Thread(target=self.server.shutdown, daemon=True).start()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('0.0.0.0', port), H)
threading.Timer(120, s.shutdown).start()
s.serve_forever()
PY
        rm -rf "$tmp"
        command -v ufw >/dev/null && ufw delete allow "${dport}/tcp" >/dev/null 2>&1
        command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --remove-port="${dport}/tcp" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; }
        iptables -D INPUT -p tcp --dport "$dport" -j ACCEPT 2>/dev/null
        info "临时下载服务已关闭"
        ;;
    3)
        echo -e "在本地电脑执行：\n${CYAN}scp -P ${port} root@${ip}:${keyfile} ./${keyfile##*/}${NC}"
        ;;
    *)
        echo -e "${YELLOW}↓↓↓ 复制下面全部内容保存为文件（含 BEGIN/END 行）↓↓↓${NC}"
        cat "$keyfile"
        echo -e "${YELLOW}↑↑↑ 结束 ↑↑↑${NC}"
        echo "本地保存后执行：chmod 600 文件名 ；登录：ssh -i 文件名 -p ${port} root@${ip}"
        ;;
    esac
}

# ---------------- 4. 禁用密码登录 ----------------
disable_password() {
    if ! [[ -s /root/.ssh/authorized_keys ]]; then
        err "authorized_keys 为空，禁用密码登录会把你锁在外面！请先生成密钥"; return
    fi
    warn "请确认你已经用密钥成功登录测试过！"
    read -rp "确定禁用密码登录？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    grep -q '^PasswordAuthentication' "$SSHD_CONF" || echo "PasswordAuthentication no" >> "$SSHD_CONF"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$f"
    done
    if sshd -t; then restart_sshd; info "已禁用密码登录"; else err "配置校验失败，未生效"; fi
}

# ---------------- 5. CPU 性能测试 ----------------
# 优先用 sysbench (很多 VPS 测评脚本用的同一种测法, 得分可以直接对比); 装不上就用 openssl 粗测
cpu_steal_read() {  # 输出: 总时间 steal时间
    local _ u n s i w q sq st _r
    read -r _ u n s i w q sq st _r < /proc/stat
    echo "$((u + n + s + i + w + q + sq + ${st:-0})) ${st:-0}"
}

bench_ensure_sysbench() {
    command -v sysbench >/dev/null 2>&1 && return 0
    read -rp "需要安装测试工具 sysbench（很小，只在测试时运行），现在安装？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return 1
    info "正在安装 sysbench ..."
    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysbench >/dev/null 2>&1 \
            || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysbench >/dev/null 2>&1; }
    elif command -v dnf >/dev/null; then
        dnf install -y -q sysbench >/dev/null 2>&1 || { dnf install -y -q epel-release >/dev/null 2>&1; dnf install -y -q sysbench >/dev/null 2>&1; }
    elif command -v yum >/dev/null; then
        yum install -y -q sysbench >/dev/null 2>&1 || { yum install -y -q epel-release >/dev/null 2>&1; yum install -y -q sysbench >/dev/null 2>&1; }
    elif command -v apk >/dev/null; then
        apk add --quiet sysbench >/dev/null 2>&1
    fi
    command -v sysbench >/dev/null 2>&1 && { info "sysbench 已安装"; return 0; }
    warn "sysbench 安装失败"
    return 1
}

bench_sysbench() {  # bench_sysbench 线程数 秒数 -> 每秒事件数
    sysbench cpu --cpu-max-prime=10000 --threads="$1" --time="$2" run 2>/dev/null |
        awk '/events per second/{print $NF; exit}'
}

bench_openssl() {  # bench_openssl 进程数 秒数 -> SHA256 速度 MB/s
    local out v
    if (($1 > 1)); then out=$(openssl speed -seconds "$2" -bytes 16384 -multi "$1" sha256 2>/dev/null)
    else out=$(openssl speed -seconds "$2" -bytes 16384 sha256 2>/dev/null); fi
    v=$(awk '$1=="sha256"{v=$NF} END{print v}' <<< "$out")
    if [[ -z "$v" ]]; then  # 老版本 openssl 不认 -bytes
        if (($1 > 1)); then out=$(openssl speed -seconds "$2" -multi "$1" sha256 2>/dev/null)
        else out=$(openssl speed -seconds "$2" sha256 2>/dev/null); fi
        v=$(awk '$1=="sha256"{v=$NF} END{print v}' <<< "$out")
    fi
    v=${v%k}
    [[ -n "$v" ]] && awk -v k="$v" 'BEGIN{printf "%.0f", k / 1024}'
}

cpu_bench() {
    local c mode tool cores model load s1="" sm="" a="" st0 tt0 st1 tt1 steal="0" unit
    cores=$(nproc 2>/dev/null || echo 1)
    model=$(awk -F: '/^(model name|Model Name|Hardware|cpu model)/{print $2; exit}' /proc/cpuinfo 2>/dev/null | tr -s ' ' | sed 's/^ //')
    [[ -z "$model" ]] && model=$(lscpu 2>/dev/null | awk -F: '/^Model name/{print $2; exit}' | tr -s ' ' | sed 's/^ //')
    read -r load _ < /proc/loadavg
    echo
    echo -e "${CYAN}========== CPU 性能测试 ==========${NC}"
    echo " 型号：${model:-未知}"
    echo " 核心：${cores} 个    当前负载：${load}"
    if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c * 0.5)}'; then
        warn "服务器现在比较忙，测出来会偏低"
    fi
    echo " 1) 单核 + 多核（约 25 秒）"
    echo " 2) 只测单核（10 秒）"
    echo " 3) 只测多核（10 秒）"
    echo " 0) 返回"
    read -rp "请选择 [1]: " c
    case "${c:-1}" in 1) mode=both ;; 2) mode=single ;; 3) mode=multi ;; *) return ;; esac
    if bench_ensure_sysbench; then
        tool=sysbench; unit="分"
    elif command -v openssl >/dev/null 2>&1; then
        tool=openssl; unit="MB/s"
        warn "改用 openssl 粗测（SHA256 计算速度），得分和 sysbench 不能直接比"
    else
        err "没有可用的测试工具"; return
    fi
    warn "测试期间 CPU 会跑满，服务器上的网站和程序可能短暂变慢"
    read -rp "开始测试？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    echo
    if [[ "$mode" != multi ]]; then
        printf ' 测试单核 ...'
        if [[ "$tool" == sysbench ]]; then s1=$(bench_sysbench 1 10); else s1=$(bench_openssl 1 5); fi
        printf '\r\033[K'
    fi
    if [[ "$mode" != single ]]; then
        printf ' 测试多核（%s 线程）...' "$cores"
        read -r tt0 st0 < <(cpu_steal_read)
        if [[ "$tool" == sysbench ]]; then sm=$(bench_sysbench "$cores" 10); else sm=$(bench_openssl "$cores" 5); fi
        read -r tt1 st1 < <(cpu_steal_read)
        printf '\r\033[K'
        steal=$(awk -v a=$((st1 - st0)) -v b=$((tt1 - tt0)) 'BEGIN{if (b > 0) printf "%.1f", a * 100 / b; else print 0}')
    fi
    [[ -z "$s1$sm" ]] && { err "测试没有输出结果"; return; }
    echo -e "${CYAN}测试结果${NC}（${tool}）"
    [[ -n "$s1" ]] && echo -e " 单核得分：${GREEN}${s1}${NC} ${unit}"
    [[ -n "$sm" ]] && echo -e " 多核得分：${GREEN}${sm}${NC} ${unit}（${cores} 线程）"
    if [[ -n "$s1" && -n "$sm" ]] && ((cores > 1)); then
        a=$(awk -v m="$sm" -v s="$s1" 'BEGIN{if (s > 0) printf "%.1f", m / s; else print 0}')
        echo " 多核/单核：${a} 倍（理想是 ${cores} 倍）"
    fi
    if [[ -n "$sm" ]]; then
        if awk -v s="$steal" 'BEGIN{exit !(s >= 10)}'; then
            echo -e " 被宿主占用：${steal}% ${YELLOW}（偏高，这台 VPS 可能超售）${NC}"
        else
            echo " 被宿主占用：${steal}%"
        fi
    fi
    if [[ "$tool" == sysbench ]]; then
        echo " 得分 = sysbench 每秒计算次数，越高越好"
    else
        echo " 得分 = 每秒 SHA256 计算量，越高越好"
    fi
    if [[ -n "$a" ]] && awk -v a="$a" -v c="$cores" 'BEGIN{exit !(a < c * 0.6)}'; then
        echo " 多核倍数明显低于核心数：可能是超线程，或核心被限速/超售"
    fi
}

# ---------------- 6. 端口转发 ----------------
# TCP/UDP DNAT 端口转发（来自 udp-f.sh，规则和独立脚本完全通用，两边都能看到、删除）
#   - 支持 TCP+UDP / 仅 UDP / 仅 TCP，中转端口和落地端口可以不同
#   - 重复添加相同转发不会重复写入；只处理 IPv4，不修改 SSH 等其他规则
#   - 同时识别并可删除旧版 UDP 脚本创建的 UDP_FORWARD_* 规则
DNAT_CHAIN="PORT_FWD_DNAT"
ACCEPT_CHAIN="PORT_FWD_ACCEPT"
LEGACY_DNAT_CHAIN="UDP_FORWARD_DNAT"
LEGACY_ACCEPT_CHAIN="UDP_FORWARD_ACCEPT"

FWD_RULES=()

# ---------------------------------------------------------------- 通用函数

fwd_install_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        return
    fi

    info "正在安装 iptables..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y iptables iptables-persistent
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iptables
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iptables
    else
        { err "无法识别包管理器，请手动安装 iptables 后重新运行。"; return 1; }
    fi
}

fwd_need_iptables() {
    command -v iptables >/dev/null 2>&1 || { err "未安装 iptables，没有可操作的规则。"; return 1; }
}

# 幂等添加规则：已存在则跳过
# 用法：fwd_ensure [-t table] CHAIN rule...
fwd_ensure() {
    local tbl=()
    if [[ "$1" == "-t" ]]; then
        tbl=(-t "$2")
        shift 2
    fi
    local chain="$1"
    shift
    iptables ${tbl[@]+"${tbl[@]}"} -C "$chain" "$@" 2>/dev/null ||
        iptables ${tbl[@]+"${tbl[@]}"} -A "$chain" "$@"
}

# 按正则筛选并删除规则
# 用法：fwd_purge TABLE CHAIN REGEX...   （REGEX 以 ! 开头表示"不匹配"）
fwd_purge() {
    local table="$1" chain="$2"
    shift 2
    local out line re
    local a=()
    out="$(iptables -t "$table" -S "$chain" 2>/dev/null | grep '^-A' || true)"
    for re in "$@"; do
        if [[ "$re" == '!'* ]]; then
            out="$(grep -Ev -- "${re:1}" <<< "$out" || true)"
        else
            out="$(grep -E -- "$re" <<< "$out" || true)"
        fi
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -ra a <<< "$line"
        a[0]="-D"
        iptables -t "$table" "${a[@]}" 2>/dev/null || true
    done <<< "$out"
}

fwd_save() {
    info "正在保存 iptables 规则..."
    # 系统自带 iptables 但没装 iptables-persistent 时, 规则保存了也不会在开机时恢复, 这里补装
    if ! command -v netfilter-persistent >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        info "正在安装 iptables-persistent（让转发规则重启后自动恢复）..."
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 \
            || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1; }
        command -v netfilter-persistent >/dev/null 2>&1 || warn "iptables-persistent 安装失败，服务器重启后转发规则可能丢失"
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        command -v apt-get >/dev/null 2>&1 || warn "已保存到 /etc/iptables/rules.v4；这个系统重启后需要自行设置恢复规则"
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent.service'; then
        systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    fi
}

# 读取当前所有转发规则到 FWD_RULES 数组
# 每项格式：chain|proto|前端端口|落地IP|落地端口
fwd_collect() {
    FWD_RULES=()
    local chain line proto front dest i
    local f=()
    for chain in "$DNAT_CHAIN" "$LEGACY_DNAT_CHAIN"; do
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            read -ra f <<< "$line"
            proto=""; front=""; dest=""
            for ((i = 0; i < ${#f[@]}; i++)); do
                case "${f[i]}" in
                    -p)               proto="${f[i+1]:-}" ;;
                    --dport)          front="${f[i+1]:-}" ;;
                    --to-destination) dest="${f[i+1]:-}" ;;
                esac
            done
            if [[ -n "$proto" && -n "$front" && -n "$dest" ]]; then
                FWD_RULES+=("${chain}|${proto}|${front}|${dest%:*}|${dest##*:}")
            fi
        done < <(iptables -t nat -S "$chain" 2>/dev/null | grep '^-A' || true)
    done
}

# 统计匹配的规则数，参数可用 * 作通配：fwd_count proto front ip port
fwd_count() {
    local n=0 r chain proto front ip port
    for r in ${FWD_RULES[@]+"${FWD_RULES[@]}"}; do
        IFS='|' read -r chain proto front ip port <<< "$r"
        # shellcheck disable=SC2053
        if [[ "$proto" == $1 && "$front" == $2 && "$ip" == $3 && "$port" == $4 ]]; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}

# 打印规则列表，返回规则数量到 FWD_COUNT
fwd_print() {
    fwd_collect
    FWD_COUNT=${#FWD_RULES[@]}
    if (( FWD_COUNT == 0 )); then
        echo "  （当前没有转发规则）"
        return
    fi
    printf "  %-4s %-6s %-10s %-24s %s\n" "编号" "协议" "中转端口" "落地地址" "来源"
    local i=1 r chain proto front ip port src
    for r in "${FWD_RULES[@]}"; do
        IFS='|' read -r chain proto front ip port <<< "$r"
        src="当前版本"
        [[ "$chain" == "$LEGACY_DNAT_CHAIN" ]] && src="旧版UDP脚本"
        printf "  %-6s %-6s %-12s %-24s %s\n" "$i" "${proto^^}" "$front" "${ip}:${port}" "$src"
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------- 添加转发

fwd_add() {
    local BACKEND_IP BACKEND_PORT FRONT_PORT PROTO_CHOICE CONFIRM
    local PROTOS=() PROTO_DESC="" PROTO OUT_IF o o1 o2 o3 o4

    echo
    read -r -p "请输入落地服务器 IP: " BACKEND_IP
    [[ "$BACKEND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "IP 格式不正确：$BACKEND_IP"; return 1; }

    IFS='.' read -r o1 o2 o3 o4 <<< "$BACKEND_IP"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( 10#$o <= 255 )) || { err "IP 地址不正确：$BACKEND_IP"; return 1; }
    done

    read -r -p "请输入落地服务器端口: " BACKEND_PORT
    [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || { err "端口必须是数字"; return 1; }
    (( BACKEND_PORT >= 1 && BACKEND_PORT <= 65535 )) || { err "端口范围必须是 1-65535"; return 1; }

    read -r -p "请输入中转服务器监听端口: " FRONT_PORT
    [[ "$FRONT_PORT" =~ ^[0-9]+$ ]] || { err "端口必须是数字"; return 1; }
    (( FRONT_PORT >= 1 && FRONT_PORT <= 65535 )) || { err "端口范围必须是 1-65535"; return 1; }

    echo
    echo "转发协议："
    echo "  1) TCP + UDP（默认）"
    echo "  2) 仅 UDP"
    echo "  3) 仅 TCP"
    read -r -p "请选择 [1-3]: " PROTO_CHOICE
    case "${PROTO_CHOICE:-1}" in
        1) PROTOS=(tcp udp); PROTO_DESC="TCP+UDP" ;;
        2) PROTOS=(udp);     PROTO_DESC="UDP" ;;
        3) PROTOS=(tcp);     PROTO_DESC="TCP" ;;
        *) { err "无效选择：$PROTO_CHOICE"; return 1; } ;;
    esac

    echo
    echo "----------------------------------------------"
    echo "转发协议 : ${PROTO_DESC}"
    echo "中转端口 : ${FRONT_PORT}"
    echo "落地地址 : ${BACKEND_IP}:${BACKEND_PORT}"
    echo "----------------------------------------------"
    read -r -p "确认配置？[Y/n]: " CONFIRM
    [[ -z "$CONFIRM" || "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; return; }

    fwd_install_iptables || return

    info "正在开启 IPv4 转发..."
    cat >/etc/sysctl.d/99-port-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl --system >/dev/null
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if ! ip route get "$BACKEND_IP" >/dev/null 2>&1; then
        warn "当前服务器没有到 $BACKEND_IP 的有效路由，继续配置可能无法工作。"
    fi

    OUT_IF="$(ip route get "$BACKEND_IP" 2>/dev/null | awk '
        {
            for (i=1; i<=NF; i++)
                if ($i=="dev") { print $(i+1); exit }
        }')"
    [[ -n "$OUT_IF" ]] || OUT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
    [[ -n "$OUT_IF" ]] || { err "无法确定出口网卡。"; return 1; }
    info "检测到出口网卡：$OUT_IF"

    iptables -t nat -N "$DNAT_CHAIN" 2>/dev/null || true
    iptables -N "$ACCEPT_CHAIN" 2>/dev/null || true

    for PROTO in "${PROTOS[@]}"; do
        info "正在配置 ${PROTO^^} 转发..."

        fwd_ensure -t nat PREROUTING -p "$PROTO" --dport "$FRONT_PORT" -j "$DNAT_CHAIN"
        fwd_ensure FORWARD -p "$PROTO" -d "$BACKEND_IP" --dport "$BACKEND_PORT" -j "$ACCEPT_CHAIN"

        fwd_ensure -t nat "$DNAT_CHAIN" -p "$PROTO" --dport "$FRONT_PORT" \
            -j DNAT --to-destination "${BACKEND_IP}:${BACKEND_PORT}"

        fwd_ensure "$ACCEPT_CHAIN" -p "$PROTO" -d "$BACKEND_IP" --dport "$BACKEND_PORT" \
            -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

        fwd_ensure "$ACCEPT_CHAIN" -p "$PROTO" -s "$BACKEND_IP" --sport "$BACKEND_PORT" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        fwd_ensure -t nat POSTROUTING -o "$OUT_IF" -p "$PROTO" -d "$BACKEND_IP" --dport "$BACKEND_PORT" \
            -j MASQUERADE
    done

    fwd_save

    echo
    echo "=============================================="
    echo -e "             ${GREEN}配置完成${RESET}"
    echo "=============================================="
    echo
    echo "中转服务器：$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "转发协议  ：${PROTO_DESC}"
    echo "中转端口  ：${FRONT_PORT}"
    echo "落地服务器：${BACKEND_IP}:${BACKEND_PORT}"
    echo "出口网卡  ：${OUT_IF}"
    echo "IPv4 转发 ：$(sysctl -n net.ipv4.ip_forward)"
    echo
    echo "当前转发规则："
    fwd_print
    echo
    info "重复添加相同配置不会重复写入相同规则。"
}

# ---------------------------------------------------------------- 删除转发

# 删除单条转发（参数：chain|proto|前端端口|落地IP|落地端口）
fwd_delete_one() {
    local entry="$1"
    local chain proto front ip port acc_chain ip_re
    IFS='|' read -r chain proto front ip port <<< "$entry"
    ip_re="${ip//./\\.}"

    acc_chain="$ACCEPT_CHAIN"
    [[ "$chain" == "$LEGACY_DNAT_CHAIN" ]] && acc_chain="$LEGACY_ACCEPT_CHAIN"

    # 1. 删除 DNAT 规则
    iptables -t nat -D "$chain" -p "$proto" --dport "$front" \
        -j DNAT --to-destination "${ip}:${port}" 2>/dev/null || true

    fwd_collect

    # 2. 没有其他规则使用该前端端口，则删除 PREROUTING 跳转
    if [[ "$(fwd_count "$proto" "$front" '*' '*')" == "0" ]]; then
        fwd_purge nat PREROUTING "-p ${proto} " "--dport ${front} " \
            "-j (${DNAT_CHAIN}|${LEGACY_DNAT_CHAIN})\$"
    fi

    # 3. 没有其他规则使用该落地目标，则删除放行与 MASQUERADE
    if [[ "$(fwd_count "$proto" '*' "$ip" "$port")" == "0" ]]; then
        fwd_purge filter FORWARD "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} " \
            "-j (${ACCEPT_CHAIN}|${LEGACY_ACCEPT_CHAIN})\$"
        fwd_purge filter "$acc_chain" "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} "
        fwd_purge filter "$acc_chain" "-p ${proto} " "-s ${ip_re}/32 " "--sport ${port} "
        fwd_purge nat POSTROUTING "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} " "-j MASQUERADE\$"
    fi

    # 4. 旧版回程规则（不带 --sport），该 IP+协议下已无转发才删除
    if [[ "$(fwd_count "$proto" '*' "$ip" '*')" == "0" ]]; then
        fwd_purge filter "$acc_chain" "-p ${proto} " "-s ${ip_re}/32 " "!--sport"
    fi

    info "已删除：${proto^^} ${front} -> ${ip}:${port}"
}

fwd_delete() {
    fwd_need_iptables || return
    echo
    echo "当前转发规则："
    fwd_print
    (( FWD_COUNT > 0 )) || return

    echo
    local sel idx
    local picks=() entries=()
    read -r -p "请输入要删除的编号（可多个，空格分隔；直接回车取消）: " sel
    [[ -n "$sel" ]] || { echo "已取消。"; return; }

    for idx in $sel; do
        [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= FWD_COUNT )) || { err "无效编号：$idx"; return 1; }
        entries+=("${FWD_RULES[idx-1]}")
    done

    local CONFIRM
    read -r -p "确认删除选中的 ${#entries[@]} 条规则？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; return; }

    local e
    for e in "${entries[@]}"; do
        fwd_delete_one "$e"
    done

    fwd_save
    echo
    echo "剩余转发规则："
    fwd_print
}

fwd_clear_all() {
    fwd_need_iptables || return
    echo
    echo "当前转发规则："
    fwd_print
    (( FWD_COUNT > 0 )) || { warn "没有规则，仍会清理残留的自定义链。"; }

    echo
    local CONFIRM
    read -r -p "确认清空全部转发规则（含旧版 UDP 脚本规则）？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; return; }

    local r chain proto front ip port ip_re c
    fwd_collect
    for r in ${FWD_RULES[@]+"${FWD_RULES[@]}"}; do
        IFS='|' read -r chain proto front ip port <<< "$r"
        ip_re="${ip//./\\.}"
        fwd_purge nat POSTROUTING "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} " "-j MASQUERADE\$"
    done

    fwd_purge nat PREROUTING "-j (${DNAT_CHAIN}|${LEGACY_DNAT_CHAIN})\$"
    fwd_purge filter FORWARD "-j (${ACCEPT_CHAIN}|${LEGACY_ACCEPT_CHAIN})\$"

    for c in "$DNAT_CHAIN" "$LEGACY_DNAT_CHAIN"; do
        iptables -t nat -F "$c" 2>/dev/null || true
        iptables -t nat -X "$c" 2>/dev/null || true
    done
    for c in "$ACCEPT_CHAIN" "$LEGACY_ACCEPT_CHAIN"; do
        iptables -F "$c" 2>/dev/null || true
        iptables -X "$c" 2>/dev/null || true
    done

    fwd_save
    info "已清空全部转发规则。"
}

fwd_list() {
    fwd_need_iptables || return
    echo
    echo "当前转发规则："
    fwd_print
    echo
    echo "详细规则查看："
    echo "  iptables -t nat -vnL"
    echo "  iptables -vnL FORWARD"
}

forward_menu() {
    local c
    while true; do
        echo
        echo -e "${CYAN}========== 端口转发（TCP/UDP）==========${NC}"
        echo " 1) 添加转发"
        echo " 2) 删除指定转发"
        echo " 3) 清空全部转发规则"
        echo " 4) 查看当前转发规则"
        echo " 0) 返回"
        read -rp "请选择: " c
        case "$c" in
            1) fwd_add ;;
            2) fwd_delete ;;
            3) fwd_clear_all ;;
            4) fwd_list ;;
            0|q|Q) return ;;
            *) warn "无效选择：$c" ;;
        esac
    done
}

# ---------------- 菜单 ----------------
while true; do
    echo
    echo -e "${CYAN}========== SSH 小工具 ==========${NC}"
    echo -e " 当前 SSH 端口：${GREEN}$(current_port)${NC}"
    echo " 1) 修改 SSH 端口"
    echo " 2) 生成密钥（自动加入 authorized_keys）"
    echo " 3) 下载已有密钥"
    echo " 4) 禁用密码登录（仅密钥登录）"
    echo " 5) CPU 性能测试（单核/多核）"
    echo " 6) 端口转发（TCP/UDP）"
    echo " 0) 退出"
    read -rp "请选择: " c
    case "$c" in
        1) change_port ;;
        2) gen_key ;;
        3) download_key "" ;;
        4) disable_password ;;
        5) cpu_bench ;;
        6) forward_menu ;;
        0) exit 0 ;;
        *) err "无效选择" ;;
    esac
done
