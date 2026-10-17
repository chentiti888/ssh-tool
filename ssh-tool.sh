#!/bin/bash
# =============================================================
#  SSH 小工具：SSH 端口 / 密钥 / 密码登录 / 系统信息 / CPU 和硬盘测试 / BBR / 端口转发
#  用法：bash ssh-tool.sh
# =============================================================

TOOL_VER="2.9"   # 每次发新版改一下, 更新时会显示
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
SSHD_CONF="/etc/ssh/sshd_config"
KEY_DIR="/root/.ssh/keys"

trap 'printf "\033[?25h"' EXIT   # 万一在实时刷新时按了 Ctrl+C, 也把光标恢复
pause() { echo; read -rp "按回车返回菜单..." _; }
info() { echo -e "${GREEN}[√]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[×]${NC} $*"; }

[[ $EUID -ne 0 ]] && { err "请使用 root 运行"; exit 1; }

# ---------------- 快捷命令（想改名就改这里） ----------------
CMD_NAME="ssb"
OLD_CMDS=("sshm" "chen" "cc")   # 曾经用过的旧命令名，运行时自动清理
CMD_PATH="/usr/local/bin/${CMD_NAME}"

# 脚本在 GitHub 仓库里的 raw 地址（上传仓库后按实际仓库名修改）
SCRIPT_URL="https://raw.githubusercontent.com/chentiti888/ssh-tool/main/ssh-tool.sh"
# 导入公钥时默认拉取的地址 (仓库里只能放公钥, 绝对不要放私钥)
KEYS_URL_DEFAULT="https://raw.githubusercontent.com/chentiti888/gy/main/authorized_keys"
# 在菜单里改过的地址存在这个文件里 (不在脚本里, 所以更新脚本也不会丢)
TOOL_CONF="/etc/ssh-tool.conf"
KEYS_URL="$KEYS_URL_DEFAULT"
if [[ -f "$TOOL_CONF" ]]; then
    _u=$(sed -n 's/^KEYS_URL=//p' "$TOOL_CONF" | tail -1)
    [[ "$_u" =~ ^https:// ]] && KEYS_URL="$_u"
    unset _u
fi

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
        local dport="" token tmp="" dip rc fw=0
        # 这一步里任何时候按 Ctrl+C: 清理临时文件和防火墙规则, 回到菜单 (不退出整个脚本)
        dl_cleanup() {
            [[ -n "$tmp" ]] && rm -rf "$tmp"
            if ((fw)); then
                command -v ufw >/dev/null && ufw delete allow "${dport}/tcp" >/dev/null 2>&1
                command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --remove-port="${dport}/tcp" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; }
                iptables -D INPUT -p tcp --dport "$dport" -j ACCEPT 2>/dev/null
            fi
            tmp=""; fw=0
        }
        trap 'echo; warn "已取消"; dl_cleanup; trap - INT; return' INT
        # 链接里的 IP 用这次 SSH 连进来的地址 (NAT/中转机器上, 出口 IP 和入口 IP 可能不一样)
        dip=$(awk '{print $3}' <<< "${SSH_CONNECTION:-}")
        if [[ -z "$dip" || "$dip" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) || "$dip" == *:* ]]; then
            dip=$ip
        fi
        echo
        echo " NAT 机器（SSH 端口是服务商分配的那种）要填服务商给你转发好的端口，否则外面连不上"
        read -rp "下载端口（回车随机）: " dport
        if [[ -z "$dport" ]]; then
            dport=$((RANDOM % 10000 + 40000))
        elif ! [[ "$dport" =~ ^[0-9]+$ ]] || ((dport < 1 || dport > 65535)); then
            trap - INT; err "端口无效"; return
        fi
        if timeout 5 ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${dport}$"; then
            trap - INT; err "端口 ${dport} 已被占用，换一个"; return
        fi
        echo " 使用端口：${dport}"
        token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        tmp=$(mktemp -d)
        cp "$keyfile" "${tmp}/${token}"
        fw=1; open_firewall "$dport"
        warn "私钥将通过明文 HTTP 传输，下载完成后建议删除并重新生成"
        echo -e "下载链接：${CYAN}http://${dip}:${dport}/${token}${NC}"
        echo " 用手机/电脑浏览器打开链接，会下载一个名为 ${keyfile##*/} 的文件（在浏览器的"下载"里）"
        echo " 或在电脑上执行：curl -o ${keyfile##*/} http://${dip}:${dport}/${token}"
        echo " （云服务器需在安全组放行 ${dport}/tcp；120 秒内没人下载自动关闭；按 Ctrl+C 取消）"
        # 等待下载时按 Ctrl+C: 只结束下载服务, 然后照常往下清理
        trap ':' INT
        python3 - "$tmp" "$dport" "$token" "${keyfile##*/}" <<'PY'
import http.server, sys, os, threading
d, port, token, name = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(os.path.join(d, token), "rb").read()
result = {"ok": False}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.strip('/') != token:
            self.send_error(404); return
        # 告诉浏览器这是要下载的文件, 并用密钥名作为文件名 (不然会保存成一串随机字符)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
        result["ok"] = True
        threading.Thread(target=self.server.shutdown, daemon=True).start()
    def log_message(self, *a): pass
try:
    s = http.server.HTTPServer(('0.0.0.0', port), H)
except OSError as e:
    print(" 无法监听端口 %d：%s" % (port, e)); sys.exit(2)
t = threading.Timer(120, s.shutdown); t.daemon = True; t.start()
try:
    s.serve_forever()
except KeyboardInterrupt:
    print("\n 已取消下载"); sys.exit(1)
sys.exit(0 if result["ok"] else 3)
PY
        rc=$?
        trap - INT
        dl_cleanup
        case $rc in
            0) info "已下载，临时下载服务已关闭" ;;
            3) warn "120 秒内没有人下载，已自动关闭。连不上的话：检查安全组是否放行 ${dport}/tcp，NAT 机器要用转发好的端口" ;;
            *) info "临时下载服务已关闭" ;;
        esac
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
        read -rp "请选择: " c || return
        case "$c" in
            1) fwd_add; pause ;;
            2) fwd_delete; pause ;;
            3) fwd_clear_all; pause ;;
            4) fwd_list; pause ;;
            0|q|Q) return ;;
            *) warn "无效选择：$c" ;;
        esac
    done
}

# ---------------- 导入公钥 ----------------
# 从 GitHub 拉文件时先查最新提交, 按提交编号下载, 避开 raw 链接几分钟的缓存
gh_fresh_url() {  # gh_fresh_url raw地址 -> 能拿到最新内容的地址
    local u=$1 repo branch path sha
    if [[ "$u" =~ ^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/([^/]+)/(.+)$ ]]; then
        repo=${BASH_REMATCH[1]}; branch=${BASH_REMATCH[2]}; path=${BASH_REMATCH[3]}
        sha=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/commits/${branch}" 2>/dev/null |
            awk -F'"' '/"sha":/{print $4; exit}')
        [[ -n "$sha" ]] && { echo "https://raw.githubusercontent.com/${repo}/${sha}/${path}"; return; }
    fi
    echo "$u"
}

KEY_RE='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/]+=*( .*)?$'

keys_url_normalize() {  # 把各种写法统一成能直接下载的地址
    local u=$1
    u=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$u")
    if [[ "$u" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        # 用户名/仓库名 -> 仓库 main 分支根目录的 authorized_keys
        u="https://raw.githubusercontent.com/${u}/main/authorized_keys"
    elif [[ "$u" =~ ^https://github\.com/([^/]+/[^/]+)/blob/(.+)$ ]]; then
        # 网页上的文件地址 -> raw 地址
        u="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$u" =~ ^https://github\.com/([^/]+/[^/.]+)/?$ ]]; then
        # 只给了仓库首页
        u="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/main/authorized_keys"
    elif [[ "$u" =~ ^[A-Za-z0-9-]+$ ]]; then
        # 只给了 GitHub 用户名 -> 这个账号在 GitHub 上登记的所有公钥
        u="https://github.com/${u}.keys"
    fi
    echo "$u"
}

keys_url_set() {
    local u n yn
    echo
    echo " 当前地址：${KEYS_URL}"
    [[ "$KEYS_URL" == "$KEYS_URL_DEFAULT" ]] && echo " （默认地址）"
    echo " 可以填："
    echo "   用户名/仓库名           如 chentiti888/gy（取 main 分支的 authorized_keys）"
    echo "   GitHub 文件网页地址     如 https://github.com/用户/仓库/blob/main/文件"
    echo "   GitHub 用户名           如 chentiti888（取账号设置里登记的公钥）"
    echo "   任意 https 直链"
    echo "   输入 default 恢复默认地址"
    read -rp "新地址（回车取消）: " u
    [[ -z "$u" ]] && return
    if [[ "$u" == default ]]; then
        u=$KEYS_URL_DEFAULT
    else
        u=$(keys_url_normalize "$u")
    fi
    [[ "$u" =~ ^https:// ]] || { err "地址要以 https:// 开头：$u"; return; }
    echo " 解析为：${u}"
    info "正在试拉一次 ..."
    n=$(curl -fsSL --max-time 20 "$(gh_fresh_url "$u")" 2>/dev/null | tr -d '\r' | grep -cE "$KEY_RE")
    if ((n > 0)); then
        info "能拉到 ${n} 把公钥"
    else
        warn "这个地址没拉到公钥（地址不对、仓库是私有的，或文件里没有公钥）"
        read -rp "仍然保存这个地址？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
    fi
    KEYS_URL=$u
    { grep -v '^KEYS_URL=' "$TOOL_CONF" 2>/dev/null; echo "KEYS_URL=$u"; } > "$TOOL_CONF.tmp" && mv -f "$TOOL_CONF.tmp" "$TOOL_CONF"
    chmod 600 "$TOOL_CONF"
    info "已保存，以后从这个地址拉取（保存在 ${TOOL_CONF}，更新脚本也不会丢）"
}

import_keys() {
    local c src="" tmp line yn n=0 add=0 i blob comment fp state
    local -a keys=()
    echo
    echo -e "${CYAN}========== 导入公钥 ==========${NC}"
    echo " 1) 从仓库拉取"
    echo "    ${KEYS_URL}"
    echo " 2) 手动粘贴公钥"
    echo " 3) 修改拉取地址"
    echo " 0) 返回"
    read -rp "请选择 [1]: " c
    tmp=$(mktemp)
    case "${c:-1}" in
        1)
            info "正在拉取 ..."
            if ! curl -fsSL --retry 2 --max-time 20 "$(gh_fresh_url "$KEYS_URL")" -o "$tmp" 2>/dev/null; then
                rm -f "$tmp"; err "拉取失败：${KEYS_URL}"; return
            fi
            src="仓库" ;;
        2)
            echo "粘贴公钥（可以多行，以 ssh-ed25519 / ssh-rsa 等开头），粘贴完按一次回车（空行）结束："
            while IFS= read -r line; do [[ -z "$line" ]] && break; echo "$line" >> "$tmp"; done
            src="粘贴" ;;
        3) rm -f "$tmp"; keys_url_set; return ;;
        *) rm -f "$tmp"; return ;;
    esac
    tr -d '\r' < "$tmp" > "$tmp.x" && mv -f "$tmp.x" "$tmp"
    if grep -q 'PRIVATE KEY' "$tmp"; then
        rm -f "$tmp"
        err "内容里有【私钥】！私钥绝对不能放进仓库或发给别人，已停止导入"
        err "请马上删掉仓库里的私钥，并重新生成一对新密钥"
        return
    fi
    while IFS= read -r line; do
        line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ $KEY_RE ]]; then keys+=("$line"); else warn "跳过一行不像公钥的内容：${line:0:40}..."; fi
    done < "$tmp"
    rm -f "$tmp"
    ((${#keys[@]} == 0)) && { err "没有找到可用的公钥"; return; }
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    echo
    echo "从${src}读到 ${#keys[@]} 把公钥："
    for i in "${!keys[@]}"; do
        read -r _ blob comment <<< "${keys[i]}"
        fp=""
        command -v ssh-keygen >/dev/null 2>&1 && fp=$(ssh-keygen -lf <(echo "${keys[i]}") 2>/dev/null | awk '{print $2}')
        if grep -qF "$blob" /root/.ssh/authorized_keys; then state="已存在"; else state="${GREEN}新增${NC}"; add=$((add + 1)); fi
        echo -e "  $((i + 1))) ${keys[i]%% *}  ${comment:-（无备注）}  [${state}]"
        [[ -n "$fp" ]] && echo "     指纹：${fp}"
    done
    ((add == 0)) && { info "这些公钥都已经在服务器上了，不用导入"; return; }
    echo
    read -rp "把 ${add} 把新公钥加入 /root/.ssh/authorized_keys？（原有的不会删除）[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    cp -a /root/.ssh/authorized_keys "/root/.ssh/authorized_keys.bak.$(date +%Y%m%d%H%M%S)"
    # 原文件最后一行没换行时先补一个, 免得两把钥匙粘在一行
    [[ -s /root/.ssh/authorized_keys && -n "$(tail -c1 /root/.ssh/authorized_keys)" ]] && echo >> /root/.ssh/authorized_keys
    for i in "${!keys[@]}"; do
        read -r _ blob _ <<< "${keys[i]}"
        grep -qF "$blob" /root/.ssh/authorized_keys || { echo "${keys[i]}" >> /root/.ssh/authorized_keys; n=$((n + 1)); }
    done
    chmod 600 /root/.ssh/authorized_keys
    info "已导入 ${n} 把公钥（原文件已备份）"
    warn "请【新开一个终端】用私钥测试登录：ssh -i 私钥文件 -p $(current_port) root@服务器IP"
    warn "确认能登录后，再到 SSH 安全 → 5 禁用密码登录"
}

# ---------------- 恢复密码登录 ----------------
pass_state() {  # 当前是否允许密码登录 (以 sshd 实际生效的配置为准)
    local v
    v=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}')
    [[ "$v" == no ]] && echo "已禁用" || echo "允许"
}

enable_password() {
    local yn prl st
    echo -e "当前密码登录：${CYAN}$(pass_state)${NC}"
    read -rp "确定恢复密码登录？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    # 主配置和 drop-in (如云厂商的 50-cloud-init.conf) 里的设置都要改, sshd 以先读到的为准
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONF"
    grep -q '^PasswordAuthentication' "$SSHD_CONF" || sed -i "1i PasswordAuthentication yes" "$SSHD_CONF"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$f"
    done
    # root 只允许密钥登录时 (prohibit-password), 密码照样登不进 root
    prl=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2; exit}')
    if [[ "$prl" == prohibit-password || "$prl" == without-password || "$prl" == no ]]; then
        warn "当前 root 不允许用密码登录（PermitRootLogin ${prl}）"
        read -rp "同时允许 root 用密码登录？[Y/n]: " yn
        if ! [[ "$yn" =~ ^[Nn]$ ]]; then
            sed -i -E 's/^[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONF"
            grep -q '^PermitRootLogin' "$SSHD_CONF" || sed -i "1i PermitRootLogin yes" "$SSHD_CONF"
            for f in /etc/ssh/sshd_config.d/*.conf; do
                [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' "$f"
            done
        fi
    fi
    if ! sshd -t 2>/tmp/sshd_err; then
        err "sshd 配置校验失败，已回滚："; cat /tmp/sshd_err
        cp -a "$(ls -t ${SSHD_CONF}.bak.* | head -1)" "$SSHD_CONF"
        return
    fi
    restart_sshd
    info "密码登录：$(pass_state)"
    # 很多云服务器 root 默认没有密码 (已锁定), 开了密码登录也登不上
    st=$(passwd -S root 2>/dev/null | awk '{print $2}')
    if [[ "$st" == L || "$st" == LK || "$st" == NP ]]; then
        warn "root 账号目前没有可用的密码，需要先设置一个"
        read -rp "现在设置 root 密码？[Y/n]: " yn
        [[ "$yn" =~ ^[Nn]$ ]] || passwd root
    fi
}

# ---------------- 系统信息 ----------------
sys_info() {
    local os kern virt model cores load mem swap disk upt ip4 ip6 cc
    os=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s )
    kern=$(uname -r)
    virt=$(systemd-detect-virt 2>/dev/null || echo "未知")
    [[ "$virt" == none ]] && virt="独立服务器 / 未检测到虚拟化"
    model=$(awk -F: '/^(model name|Model Name|Hardware|cpu model)/{print $2; exit}' /proc/cpuinfo 2>/dev/null | tr -s ' ' | sed 's/^ //')
    cores=$(nproc 2>/dev/null || echo 1)
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d / %d MB (已用 %.0f%%)", $3, $2, $3*100/$2}')
    swap=$(free -m 2>/dev/null | awk '/^Swap:/{if ($2 > 0) printf "%d / %d MB", $3, $2; else print "未开启"}')
    disk=$(df -hP / 2>/dev/null | awk 'NR==2{printf "%s / %s (已用 %s)", $3, $2, $5}')
    upt=$(awk '{d=int($1/86400); h=int($1%86400/3600); m=int($1%3600/60); printf "%d 天 %d 小时 %d 分", d, h, m}' /proc/uptime)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo
    echo -e "${CYAN}========== 系统信息 ==========${NC}"
    echo " 主机名：$(hostname)"
    echo " 系统：  ${os}（$(uname -m)）"
    echo " 内核：  ${kern}"
    echo " 虚拟化：${virt}"
    echo " CPU：   ${model:-未知}（${cores} 核）"
    echo " 负载：  ${load}"
    echo " 内存：  ${mem}"
    echo " Swap：  ${swap}"
    echo " 硬盘：  ${disk}"
    echo " 运行：  ${upt}"
    echo " TCP 拥塞控制：${cc:-未知}$([[ "$cc" == bbr ]] && echo "（BBR 已开启）")"
    echo " SSH 端口：$(current_port)    密码登录：$(pass_state)    Ping：$(ping_state)"
    printf ' 查询公网 IP ...'
    ip4=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    ip6=$(curl -s6 --max-time 5 ip.sb 2>/dev/null)
    printf '\r\033[K'
    echo " IPv4：  ${ip4:-无}"
    echo " IPv6：  ${ip6:-无}"
}

# ---------------- 内存性能测试 ----------------
bench_sysbench_mem() {  # bench_sysbench_mem read|write 线程数 秒数 -> MB/s
    sysbench memory --memory-block-size=1M --memory-total-size=100T --memory-oper="$1" \
        --threads="$2" --time="$3" run 2>/dev/null |
        sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p' | head -1 | awk '{printf "%.0f", $1}'
}

bench_dd_mem() {  # 没有 sysbench 时: 内核在内存里搬数据的速度 -> MB/s
    LC_ALL=C dd if=/dev/zero of=/dev/null bs=1M count=20000 2>&1 |
        awk '/copied/{v=$(NF-1); u=$NF; if (u ~ /^GB/) v*=1000; else if (u ~ /^kB/) v/=1000; printf "%.0f", v}'
}

mem_bench() {
    local yn total avail swapu cores tool r1="" w1="" rm="" wm="" d=""
    cores=$(nproc 2>/dev/null || echo 1)
    total=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    swapu=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d", (t-f)/1024}' /proc/meminfo)
    echo
    echo -e "${CYAN}========== 内存性能测试 ==========${NC}"
    echo " 内存：${total} MB    可用：${avail} MB    Swap 已用：${swapu} MB"
    ((swapu > 100)) && warn "Swap 用了 ${swapu} MB，说明内存曾经不够用，测试结果可能偏低"
    echo " 测试内容：单线程读 / 写，多线程读 / 写（各 5 秒，约 20 秒）"
    echo " 只在内存里反复读写一小块数据，不会占满内存，也不写硬盘"
    if bench_ensure_sysbench; then
        tool=sysbench
    else
        tool=dd
        warn "改用 dd 粗测（只测一项搬运速度），结果和 sysbench 不能直接比"
    fi
    read -rp "开始测试？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    echo
    if [[ "$tool" == sysbench ]]; then
        printf ' 单线程读 ...'; r1=$(bench_sysbench_mem read 1 5); printf '\r\033[K'
        printf ' 单线程写 ...'; w1=$(bench_sysbench_mem write 1 5); printf '\r\033[K'
        if ((cores > 1)); then
            printf ' 多线程读（%s 线程）...' "$cores"; rm=$(bench_sysbench_mem read "$cores" 5); printf '\r\033[K'
            printf ' 多线程写（%s 线程）...' "$cores"; wm=$(bench_sysbench_mem write "$cores" 5); printf '\r\033[K'
        fi
        [[ -z "$r1$w1" ]] && { err "测试没有输出结果"; return; }
        echo -e "${CYAN}测试结果${NC}（sysbench，单位 MB/s，越高越好）"
        echo -e " 单线程读：${GREEN}${r1:-失败}${NC}"
        echo -e " 单线程写：${GREEN}${w1:-失败}${NC}"
        if ((cores > 1)); then
            echo -e " 多线程读：${GREEN}${rm:-失败}${NC}（${cores} 线程）"
            echo -e " 多线程写：${GREEN}${wm:-失败}${NC}（${cores} 线程）"
        fi
        echo
        echo " 说明："
        echo "  单线程 = 一个程序能用到的内存速度，影响网站/机器人的响应快慢"
        echo "  多线程 = 多个程序同时读写时的总速度，看整机内存带宽"
        if [[ -n "$r1" && -n "$rm" ]] && ((cores > 1)) && awk -v a="$rm" -v b="$r1" 'BEGIN{exit !(a < b * 1.2)}'; then
            echo -e "  ${YELLOW}多线程几乎没有比单线程快：内存带宽可能被限制，或多个核在争抢${NC}"
        fi
        echo "  同配置的机器之间对比才有意义；多测几次差距很大，可能是宿主机繁忙或超售"
    else
        printf ' 测试中 ...'; d=$(bench_dd_mem); printf '\r\033[K'
        [[ -z "$d" ]] && { err "测试没有输出结果"; return; }
        echo -e "${CYAN}测试结果${NC}（dd 粗测）"
        echo -e " 内存搬运速度：${GREEN}${d}${NC} MB/s"
        echo "  这是内核在内存里搬数据的速度，只适合同一种方法互相比较；装上 sysbench 结果更全面"
    fi
}

# ---------------- CPU 占用状态 ----------------
# 读 /proc 两次 (间隔几秒) 算出这段时间的真实占用; 不装任何工具, 看完就结束
cpu_snap() {  # cpu_snap 文件 : 记录 各核 和 各进程 的累计 CPU 时间
    local f line rest pid
    local -a a
    grep '^cpu' /proc/stat > "$1.stat"
    : > "$1.proc"
    for f in /proc/[0-9]*/stat; do
        read -r line < "$f" 2>/dev/null || continue
        pid=${line%% *}
        rest=${line##*) }              # 程序名里可能有空格, 从最后一个 ")" 后面开始数
        read -ra a <<< "$rest"
        echo "$pid $((a[11] + a[12]))" >> "$1.proc"   # utime + stime
    done
}

cpu_bar() {  # cpu_bar 百分比 -> 10 格进度条
    local n=$(( ($1 + 5) / 10 )) b=""
    ((n > 10)) && n=10
    for ((i = 0; i < 10; i++)); do if ((i < n)); then b+="█"; else b+="░"; fi; done
    printf '%s' "$b"
}

cpu_usage_show() {  # cpu_usage_show 采样秒数
    local sec=$1 t hz cores load1 load5 load15 x
    t=$(mktemp)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    cores=$(nproc 2>/dev/null || echo 1)
    cpu_snap "$t.a"; sleep "$sec"; cpu_snap "$t.b"
    read -r load1 load5 load15 _ < /proc/loadavg
    # 总体: user nice system idle iowait irq softirq steal
    read -r us ni sy id wa hi si st tot < <(awk '
        FNR==NR && $1=="cpu" {for (i=2;i<=9;i++) a[i]=$i; next}
        $1=="cpu" {t=0; for (i=2;i<=9;i++) {d[i]=$i-a[i]; t+=d[i]}; if (t<=0) t=1;
                   for (i=2;i<=9;i++) printf "%.1f ", d[i]*100/t; print t}' "$t.a.stat" "$t.b.stat")
    local used
    used=$(awk -v i="$id" 'BEGIN{printf "%.0f", 100-i}')
    echo -e "${CYAN}========== CPU 占用状态 ==========${NC}"
    echo -e " 总占用：${GREEN}${used}%${NC}（最近 ${sec} 秒，${cores} 核平均）"
    echo " 负载：  ${load1} / ${load5} / ${load15}（1 / 5 / 15 分钟）"
    echo
    echo -e "${CYAN}各核占用${NC}"
    awk 'FNR==NR && $1~/^cpu[0-9]/ {for (i=2;i<=9;i++) a[$1,i]=$i; next}
         $1~/^cpu[0-9]/ {t=0; idl=0; for (i=2;i<=9;i++) {d=$i-a[$1,i]; t+=d; if (i==5) idl=d}
                          if (t<=0) t=1; printf "%s %.0f\n", substr($1,4), (t-idl)*100/t}' "$t.a.stat" "$t.b.stat" |
    while read -r n p; do printf ' 核%-3s %s %3s%%\n' "$n" "$(cpu_bar "$p")" "$p"; done
    echo
    echo -e "${CYAN}占用细节${NC}"
    printf ' 用户程序   %5s%%  网站、机器人、代理等程序自己在计算\n' "$us"
    printf ' 系统内核   %5s%%  内核在帮程序收发数据、读写文件\n' "$sy"
    printf ' 低优先级   %5s%%  被调低优先级的后台任务（如探针）\n' "$ni"
    printf ' 等待硬盘   %5s%%  CPU 空等硬盘读写，高说明硬盘慢或太忙\n' "$wa"
    printf ' 网络中断   %5s%%  处理网卡收到的数据包，流量大时会升高\n' "$(awk -v a="$hi" -v b="$si" 'BEGIN{printf "%.1f", a+b}')"
    printf ' 被宿主占用 %5s%%  宿主机拿走的时间，高说明 VPS 超售\n' "$st"
    printf ' 空闲       %5s%%\n' "$id"
    echo
    echo -e "${CYAN}最耗 CPU 的程序（100% = 占满 1 个核）${NC}"
    printf ' %-7s %6s  %s\n' "PID" "CPU" "程序"
    awk -v hz="$hz" -v sec="$sec" 'FNR==NR {a[$1]=$2; next} ($1 in a) {d=$2-a[$1]; if (d>0) printf "%s %.1f\n", $1, d*100/(hz*sec)}' \
        "$t.a.proc" "$t.b.proc" | sort -k2,2nr | head -n 10 > "$t.top"
    if [[ -s "$t.top" ]]; then
        while read -r pid p; do
            local name cmd
            name=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
            printf ' %-7s %5s%%  %s\n' "$pid" "$p" "$name"
            [[ -n "$cmd" && "$cmd" != "$name" ]] && echo "                 ${cmd:0:44}"
        done < "$t.top"
    else
        echo " （这段时间没有程序明显占用 CPU）"
    fi
    # 简单结论
    echo
    x=""
    awk -v v="$used" 'BEGIN{exit !(v >= 90)}' && x+=" CPU 基本跑满，网站/程序可能变慢；"
    awk -v v="$wa" 'BEGIN{exit !(v >= 20)}' && x+=" 等待硬盘偏高，瓶颈在硬盘不在 CPU；"
    awk -v v="$st" 'BEGIN{exit !(v >= 10)}' && x+=" 被宿主占用偏高，这台 VPS 可能超售；"
    awk -v a="$hi" -v b="$si" 'BEGIN{exit !(a + b >= 20)}' && x+=" 网络中断偏高，流量很大（代理/转发）；"
    awk -v l="$load5" -v c="$cores" 'BEGIN{exit !(l > c * 1.5)}' && x+=" 5 分钟负载超过核心数 1.5 倍，任务在排队；"
    if [[ -s "$t.top" ]]; then
        read -r pid p < "$t.top"
        awk -v v="$p" 'BEGIN{exit !(v >= 90)}' &&
            x+=" 程序 $(cat "/proc/$pid/comm" 2>/dev/null || echo "PID $pid") 占满了约 $(awk -v v="$p" 'BEGIN{printf "%.0f", v/100}') 个核；"
    fi
    if [[ -n "$x" ]]; then echo -e " ${YELLOW}提示：${x%；}${NC}"; else echo -e " ${GREEN}状态正常${NC}"; fi
    rm -f "$t" "$t".*
}

cpu_usage() {
    local c k
    echo
    echo -e "${CYAN}========== CPU 占用状态 ==========${NC}"
    echo " 1) 查看一次（采样 3 秒）"
    echo " 2) 实时刷新（每 3 秒，按回车停止）"
    echo " 0) 返回"
    read -rp "请选择 [1]: " c
    case "${c:-1}" in
        1) echo " 正在采样 3 秒 ..."; cpu_usage_show 3 ;;
        2)
            # 不整屏清空 (那样会闪): 旧画面留着, 新数据算好后从左上角逐行覆盖, 多出来的旧行再擦掉
            local out line
            printf '\033[2J\033[H\033[?25l'; echo " 正在采样 3 秒 ..."
            while true; do
                out=$(cpu_usage_show 3)
                printf '\033[H'
                while IFS= read -r line; do printf '%s\033[K\n' "$line"; done <<< "$out"
                printf '\033[K\n （每 3 秒刷新，按回车停止）\033[K\n\033[J'
                read -rt 1 k && break
            done
            printf '\033[?25h' ;;
        *) return ;;
    esac
}

# ---------------- 硬盘 IO 测试 ----------------
io_dd() {  # io_dd 写|读 文件 MB数 -> 速度 (如 "512 MB/s")
    local out
    if [[ "$1" == 写 ]]; then
        out=$(LC_ALL=C dd if=/dev/zero of="$2" bs=1M count="$3" oflag=direct conv=fdatasync 2>&1) ||
            out=$(LC_ALL=C dd if=/dev/zero of="$2" bs=1M count="$3" conv=fdatasync 2>&1)   # 不支持直写的文件系统
    else
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        out=$(LC_ALL=C dd if="$2" of=/dev/null bs=1M iflag=direct 2>&1) ||
            out=$(LC_ALL=C dd if="$2" of=/dev/null bs=1M 2>&1)
    fi
    awk '/copied/{print $(NF-1), $NF}' <<< "$out"
}

io_bench() {
    local avail mb f yn w1 w2 w3 r
    avail=$(df -Pm /root 2>/dev/null | awk 'NR==2{print $4}')
    if ((${avail:-0} >= 2048)); then mb=1024
    elif ((${avail:-0} >= 600)); then mb=256
    else err "硬盘剩余空间不足（${avail:-0} MB），无法测试"; return; fi
    echo
    echo -e "${CYAN}========== 硬盘 IO 测试 ==========${NC}"
    echo " 硬盘剩余：${avail} MB"
    warn "会临时写入一个 ${mb}MB 的测试文件（测完自动删除），期间硬盘会很忙"
    read -rp "开始测试？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    f="/root/.ssh-tool-iotest.$$"
    trap 'rm -f "$f"' RETURN
    echo
    printf ' 写入测试 1/3 ...'; w1=$(io_dd 写 "$f" "$mb"); printf '\r\033[K'
    printf ' 写入测试 2/3 ...'; w2=$(io_dd 写 "$f" "$mb"); printf '\r\033[K'
    printf ' 写入测试 3/3 ...'; w3=$(io_dd 写 "$f" "$mb"); printf '\r\033[K'
    printf ' 读取测试 ...';    r=$(io_dd 读 "$f" "$mb");  printf '\r\033[K'
    rm -f "$f"; trap - RETURN
    [[ -z "$w1$w2$w3$r" ]] && { err "测试失败（dd 没有输出结果）"; return; }
    echo -e "${CYAN}测试结果${NC}（每次 ${mb}MB）"
    echo -e " 写入：${GREEN}${w1:-失败}${NC} / ${GREEN}${w2:-失败}${NC} / ${GREEN}${w3:-失败}${NC}"
    echo -e " 读取：${GREEN}${r:-失败}${NC}"
    echo " 参考：机械硬盘约 100 MB/s，普通 SSD 300 MB/s 以上，NVMe 可达 1 GB/s 以上"
}

# ---------------- BBR ----------------
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

bbr_menu() {
    local cc yn avail
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo
    echo -e "${CYAN}========== BBR 加速 ==========${NC}"
    echo " 当前拥塞控制：${cc:-未知}    队列：$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [[ "$cc" == bbr ]]; then
        echo -e " 状态：${GREEN}BBR 已开启${NC}"
        read -rp "关闭 BBR（恢复系统默认 cubic）？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
        rm -f "$BBR_CONF"
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
        info "已关闭 BBR（当前：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)）"
        return
    fi
    echo " 状态：未开启"
    echo " BBR 能明显提升高延迟、有丢包线路的速度，适合代理/中转服务器；只改内核参数，不占资源"
    # 内核 4.9 以上才自带 BBR
    if ! awk -v k="$(uname -r)" 'BEGIN{split(k, a, "[.-]"); exit !(a[1] > 4 || (a[1] == 4 && a[2] >= 9))}'; then
        err "内核版本 $(uname -r) 太旧（需要 4.9 以上），请先升级内核"; return
    fi
    read -rp "开启 BBR？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    modprobe tcp_bbr 2>/dev/null
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if [[ " $avail " != *" bbr "* ]]; then
        err "这台机器的内核没有 BBR 模块（可用：${avail:-未知}）。OpenVZ/LXC 这类容器 VPS 不能自己改，需要服务商开启"
        return
    fi
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > "$BBR_CONF"
    sysctl -p "$BBR_CONF" >/dev/null 2>&1
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$cc" == bbr ]]; then
        info "BBR 已开启，重启后也会保持（配置文件：${BBR_CONF}）"
    else
        rm -f "$BBR_CONF"
        err "开启失败（当前：${cc:-未知}），这台 VPS 可能不允许修改内核参数"
    fi
}

# ---------------- 禁 Ping ----------------
# 用内核参数只关掉"回应 ping", 其他 ICMP (如探测网络 MTU 用的) 照常, 不影响正常上网和代理
PING_CONF="/etc/sysctl.d/99-disable-ping.conf"

ping_state() {
    [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" == 1 ]] && echo "已禁用" || echo "允许"
}

ping_menu() {
    local yn has6=0 f
    sysctl -n net.ipv6.icmp.echo_ignore_all >/dev/null 2>&1 && has6=1
    echo
    echo -e "${CYAN}========== 禁 Ping ==========${NC}"
    echo -e " 当前：IPv4 Ping ${GREEN}$(ping_state)${NC}$( ((has6)) && [[ "$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null)" == 1 ]] && echo "，IPv6 Ping 已禁用")"
    if [[ "$(ping_state)" == 已禁用 ]]; then
        read -rp "恢复 Ping（允许别人 ping 通这台服务器）？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
        rm -f "$PING_CONF"
        sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
        ((has6)) && sysctl -w net.ipv6.icmp.echo_ignore_all=0 >/dev/null 2>&1
        # 别的配置文件里也写了禁 ping 的话, 重启后还会生效, 提示一下
        f=$(grep -lE '^[[:space:]]*net\.ipv4\.icmp_echo_ignore_all[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | head -1)
        [[ -n "$f" ]] && warn "${f} 里也设置了禁 ping，重启后会再次生效，需要的话请删掉那一行"
        info "Ping 已恢复（当前：$(ping_state)）"
        return
    fi
    echo " 禁用后：别人 ping 这台服务器会超时，扫描器更难发现它；网站、SSH、代理不受影响"
    echo " 注意：用 ping 做监控的工具（如部分测速、在线监控）会显示这台离线；tcping 照常可用"
    read -rp "禁用 Ping？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    {
        echo "# managed by ssh-tool: 禁止回应 ping"
        echo "net.ipv4.icmp_echo_ignore_all=1"
        ((has6)) && echo "net.ipv6.icmp.echo_ignore_all=1"
    } > "$PING_CONF"
    sysctl -p "$PING_CONF" >/dev/null 2>&1
    if [[ "$(ping_state)" == 已禁用 ]]; then
        info "已禁用 Ping，重启后也会保持$( ((has6)) && echo "（IPv4 和 IPv6）")"
    else
        rm -f "$PING_CONF"
        err "设置失败，这台 VPS 可能不允许修改内核参数（如 OpenVZ/LXC 容器）"
    fi
}

# ---------------- 回程线路检测 ----------------
# 从本机 traceroute 到国内 4 个城市的电信/联通/移动, 按经过的骨干网 IP 段判断线路类型
# 判断规则参考开源项目 oneclickvirt/backtrace (IP 段 + 经过顺序), 结果是推测, 仅供参考
RT_TARGETS=(
    "北京电信 219.141.140.10 CT" "北京联通 202.106.195.68 CU" "北京移动 221.179.155.161 CM"
    "上海电信 202.96.209.133 CT" "上海联通 210.22.97.1 CU"    "上海移动 211.136.112.200 CM"
    "广州电信 58.60.188.222 CT"  "广州联通 210.21.196.6 CU"   "广州移动 120.196.165.24 CM"
    "成都电信 61.139.2.69 CT"    "成都联通 119.6.6.6 CU"      "成都移动 211.137.96.205 CM"
)

# 每一跳的 IP -> 所属骨干网
RT_ASN_AWK='
function asn(ip,  a) {
    split(ip, a, ".")
    if (ip ~ /^59\.43\./) return "AS4809"
    if (ip ~ /^202\.97\./) return "AS4134"
    if (ip ~ /^(218\.105|210\.51)\./) return "AS9929"
    if (ip ~ /^(202\.77|43\.252|61\.14)\./) return "AS10099"
    if (ip ~ /^219\.158\./) return "AS4837"
    if (a[1] == 223 && ((a[2] == 118 && a[3] == 32) || (a[2] == 120 && a[3] >= 128) ||
        (a[2] == 119 && (a[3] == 8 || a[3] == 9 || (a[3] >= 10 && a[3] <= 15) || (a[3] >= 26 && a[3] <= 29) ||
         (a[3] >= 32 && a[3] <= 37) || a[3] == 74 || a[3] == 75 || a[3] == 88 || a[3] == 89 ||
         a[3] == 100 || a[3] == 252 || a[3] == 253)))) return "AS58807"
    if (ip ~ /^223\.(118|119|120|121)\./) return "AS58453"
    if (ip ~ /^(221\.183|111\.24)\./) return "AS9808"
    if (ip ~ /^(69\.194|203\.22)\./) return "AS23764"
    return ""
}
'

rt_parse() {  # rt_parse traceroute输出文件 : 每跳一行 "跳数 IP 毫秒 骨干网"
    awk "$RT_ASN_AWK"'
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ { ms = ($3 ~ /^[0-9.]+$/) ? $3 : "-"; print $1, $2, ms, asn($2) }
        $1 ~ /^[0-9]+$/ && $2 == "*"       { print $1, "*", "-", "" }' "$1"
}

rt_classify() {  # rt_classify 运营商(CT/CU/CM) 解析文件 -> 线路名称
    awk -v c="$1" '
        { if ($4 != "") { n[$4]++; if (!($4 in f)) f[$4] = NR } }
        function first(k) { return (k in f) ? f[k] : -1 }
        END {
            if (c == "CT") {
                if (first("AS4809") >= 0) {
                    if (n["AS4809"] < 2) { print "电信CN2混合 [优质线路]"; exit }
                    if (first("AS4134") < 0 || (f["AS4809"] < f["AS4134"] && n["AS4134"] <= 1)) { print "电信CN2 GIA [精品线路]"; exit }
                    if (f["AS4809"] < f["AS4134"]) { print "电信CN2混合 [优质线路]"; exit }
                    print "电信CN2 GT [优质线路]"; exit
                }
                if (first("AS23764") >= 0) { print "电信CTGNET [精品线路]"; exit }
                if (n["AS4134"] > 1) { print "电信163 [普通线路]"; exit }
                print (n["AS4134"] == 1) ? "只看到电信入口，无法判断" : "没看到电信骨干网"; exit
            }
            if (c == "CU") {
                if (first("AS9929") >= 0) {
                    if (first("AS4837") >= 0 && f["AS4837"] < f["AS9929"]) { print "联通9929混合 [优质线路]"; exit }
                    print "联通9929 [优质线路]"; exit
                }
                if (first("AS10099") >= 0) { print "联通CUG [优质线路]"; exit }
                if (n["AS4837"] > 1) { print "联通4837 [普通线路]"; exit }
                print (n["AS4837"] == 1) ? "只看到联通入口，无法判断" : "没看到联通骨干网"; exit
            }
            if (first("AS58807") >= 0) {
                if (first("AS58453") >= 0 && f["AS58453"] < f["AS58807"]) { print "移动CMIN2混合 [优质线路]"; exit }
                print "移动CMIN2 [精品线路]"; exit
            }
            if (first("AS58453") >= 0) { print "移动CMI [普通线路]"; exit }
            if (first("AS9808") >= 0) { print "移动CMNET [普通线路]"; exit }
            print "没看到移动骨干网"
        }' "$2"
}

ensure_traceroute() {
    command -v traceroute >/dev/null 2>&1 && return 0
    local yn
    read -rp "需要安装 traceroute（很小，只在检测时运行），现在安装？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return 1
    info "正在安装 traceroute ..."
    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq traceroute >/dev/null 2>&1 ||
            { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq traceroute >/dev/null 2>&1; }
    elif command -v dnf >/dev/null; then dnf install -y -q traceroute >/dev/null 2>&1
    elif command -v yum >/dev/null; then yum install -y -q traceroute >/dev/null 2>&1
    elif command -v apk >/dev/null; then apk add --quiet traceroute >/dev/null 2>&1
    fi
    command -v traceroute >/dev/null 2>&1 && return 0
    err "traceroute 安装失败"; return 1
}

route_check() {
    local t i name ip c line label last ms c1 c2 sel myip
    echo
    echo -e "${CYAN}========== 回程线路检测 ==========${NC}"
    echo " 回程 = 数据从这台服务器回到国内的路线，决定你下载/看视频的速度和稳定性"
    echo " 检测北京、上海、广州、成都的电信 / 联通 / 移动，约 30 秒"
    ensure_traceroute || return
    t=$(mktemp -d)
    printf ' 检测中 ...'
    for i in "${!RT_TARGETS[@]}"; do
        read -r name ip c <<< "${RT_TARGETS[i]}"
        ( traceroute -n -I -q 1 -w 1 -m 30 "$ip" > "$t/$i.raw" 2>/dev/null
          [[ -s "$t/$i.raw" ]] || traceroute -n -q 1 -w 1 -m 30 "$ip" > "$t/$i.raw" 2>/dev/null
          rt_parse "$t/$i.raw" > "$t/$i.hops" ) &
    done
    wait
    printf '\r\033[K'
    echo -e "${CYAN}检测结果${NC}（线路是根据途经的骨干网推测的）"
    for i in "${!RT_TARGETS[@]}"; do
        read -r name ip c <<< "${RT_TARGETS[i]}"
        label=$(rt_classify "$c" "$t/$i.hops")
        # 到达目标的延迟; 目标没回应时不显示中途某一跳的延迟, 免得误导
        ms=$(awk -v ip="$ip" '$2 == ip && $3 != "-" {printf "%.0f ms", $3; exit}' "$t/$i.hops")
        case "$label" in
            *精品*) c1=$GREEN ;; *优质*) c1=$CYAN ;; *普通*) c1=$YELLOW ;; *) c1=$NC ;;
        esac
        printf ' %s  %b%s%b  %s\n' "$name" "$c1" "$label" "$NC" "${ms:-目标没回应}"
    done
    echo
    echo " 说明：精品 > 优质 > 普通。电信 CN2 GIA、移动 CMIN2、联通 9929 一般最稳；163/4837/CMI 晚高峰容易拥堵"
    echo " 去程（国内到这台）在服务器上测不了，要从国内发起。可在手机/电脑浏览器打开："
    myip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    echo -e "   ${CYAN}https://www.itdog.cn/tracert/${myip:-你的服务器IP}${NC}"
    echo
    read -rp "查看某一条的详细路由？输入序号 1-${#RT_TARGETS[@]}（回车跳过）: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#RT_TARGETS[@]})); then
        read -r name ip c <<< "${RT_TARGETS[sel-1]}"
        echo
        echo -e "${CYAN}${name}（${ip}）详细路由${NC}"
        printf ' %-4s %-16s %-9s %s\n' "跳" "IP" "延迟" "骨干网"
        while read -r h hip hms has; do
            case "$has" in
                AS4809) has="电信CN2" ;; AS4134) has="电信163" ;; AS23764) has="电信CTGNET" ;;
                AS9929) has="联通9929" ;; AS10099) has="联通CUG" ;; AS4837) has="联通4837" ;;
                AS58807) has="移动CMIN2" ;; AS58453) has="移动CMI" ;; AS9808) has="移动CMNET" ;;
            esac
            printf ' %-4s %-16s %-9s %s\n' "$h" "$hip" "$([[ "$hms" == - ]] && echo - || echo "${hms}ms")" "$has"
        done < "$t/$((sel - 1)).hops"
    fi
    rm -rf "$t"
}

# ---------------- 流媒体 / AI 解锁检测 ----------------
# 按各平台网页/接口的返回特征判断; 平台改版后可能不准, 结果仅供参考
UA_WEB="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

ul_netflix() {
    local r1 r2 region
    r1=$(curl $UL_OPT -fsL 'https://www.netflix.com/title/81280792' -H 'accept-language: en-US,en;q=0.9' -A "$UA_WEB")
    r2=$(curl $UL_OPT -fsL 'https://www.netflix.com/title/70143836' -H 'accept-language: en-US,en;q=0.9' -A "$UA_WEB")
    [[ -z "$r1" || -z "$r2" ]] && { echo "? 检测失败（连不上）"; return; }
    if grep -q 'Oh no!' <<< "$r1" && grep -q 'Oh no!' <<< "$r2"; then echo "! 仅自制剧"; return; fi
    region=$(sed -n 's/.*"id":"\([^"]*\)".*"countryName":"[^"]*".*/\1/p' <<< "$r1" | head -1)
    echo "Y 完整解锁${region:+（地区 $region）}"
}

ul_disney() {
    local u
    u=$(curl $UL_OPT -sL 'https://www.disneyplus.com' -o /dev/null -w '%{http_code} %{url_effective}' -A "$UA_WEB")
    [[ -z "$u" || "$u" == 000* ]] && { echo "? 检测失败（连不上）"; return; }
    [[ "$u" == 403* ]] && { echo "N 不支持（IP 被封）"; return; }
    if [[ "$u" =~ preview|unavailable ]]; then echo "N 不支持"; else echo "Y 可访问（简易判断）"; fi
}

ul_youtube() {
    local r region
    r=$(curl $UL_OPT -sL 'https://www.youtube.com/premium' -H 'accept-language: en-US,en;q=0.9' \
        -H 'cookie: SOCS=CAISOAgDEitib3FfaWRlbnRpdHlmcm9udGVuZHVpc2VydmVyXzIwMjQwNTI2LjAxX3AwGgV6aC1DTiACGgYIgMnpsgY; PREF=f7=4000' -A "$UA_WEB")
    [[ -z "$r" ]] && { echo "? 检测失败（连不上）"; return; }
    grep -q 'www.google.cn' <<< "$r" && { echo "N 不支持（地区 CN）"; return; }
    grep -qi 'Premium is not available in your country' <<< "$r" && { echo "N 不支持"; return; }
    region=$(grep -o '"INNERTUBE_CONTEXT_GL" *: *"[^"]*"' <<< "$r" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if grep -qi 'ad-free' <<< "$r"; then echo "Y 支持${region:+（地区 $region）}"; else echo "? 检测失败（页面异常）"; fi
}

ul_prime() {
    local r region
    r=$(curl $UL_OPT -sL 'https://www.primevideo.com' -A "$UA_WEB")
    [[ -z "$r" ]] && { echo "? 检测失败（连不上）"; return; }
    grep -qi 'isServiceRestricted' <<< "$r" && { echo "N 不支持"; return; }
    region=$(grep -o '"currentTerritory":"[^"]*"' <<< "$r" | head -1 | cut -d'"' -f4)
    if [[ -n "$region" ]]; then echo "Y 支持（地区 $region）"; else echo "? 检测失败（页面异常）"; fi
}

ul_chatgpt() {
    local r1 r2 loc
    r1=$(curl $UL_OPT -s 'https://api.openai.com/compliance/cookie_requirements' -H 'authorization: Bearer null' \
        -H 'origin: https://platform.openai.com' -H 'referer: https://platform.openai.com/' -A "$UA_WEB")
    r2=$(curl $UL_OPT -s 'https://ios.chat.openai.com/' -A "$UA_WEB")
    [[ -z "$r1" || -z "$r2" ]] && { echo "? 检测失败（连不上）"; return; }
    loc=$(curl $UL_OPT -s 'https://chatgpt.com/cdn-cgi/trace' | sed -n 's/^loc=//p')
    local a=0 b=0
    grep -qi 'unsupported_country' <<< "$r1" && a=1
    grep -qi 'VPN' <<< "$r2" && b=1
    if ((a == 0 && b == 0)); then echo "Y 支持${loc:+（地区 $loc）}"
    elif ((a == 1 && b == 1)); then echo "N 不支持${loc:+（地区 $loc）}"
    elif ((a == 0)); then echo "! 仅网页版可用（App 不行）"
    else echo "! 仅 App 可用（网页版不行）"; fi
}

ul_claude() {
    local u
    u=$(curl $UL_OPT -sL -o /dev/null -w '%{url_effective}' -A "$UA_WEB" 'https://claude.ai/')
    [[ -z "$u" ]] && { echo "? 检测失败（连不上）"; return; }
    case "$u" in
        https://claude.ai/*) echo "Y 支持" ;;
        *app-unavailable-in-region*) echo "N 不支持（地区限制）" ;;
        *) echo "? 无法判断（跳转到 ${u:0:40}）" ;;
    esac
}

ul_gemini() {
    # 用 Gemini API 判断: 故意不带有效 key, 地区支持时返回 "API key not valid", 不支持时返回 "location is not supported"
    # (网页里的特征字符串会随改版失效, 接口的这两种报错更稳定)
    local r cc
    r=$(curl $UL_OPT -s 'https://generativelanguage.googleapis.com/v1beta/models?key=ssb-check' -A "$UA_WEB")
    cc=$(curl $UL_OPT -s 'https://www.cloudflare.com/cdn-cgi/trace' | sed -n 's/^loc=//p')
    if grep -qi 'location is not supported' <<< "$r"; then echo "N 不支持${cc:+（地区 $cc）}"; return; fi
    if grep -qiE 'API key not valid|API_KEY_INVALID' <<< "$r"; then echo "Y 支持${cc:+（地区 $cc）}"; return; fi
    # 接口没给出明确结果时, 退回网页判断
    r=$(curl $UL_OPT -sL 'https://gemini.google.com' -A "$UA_WEB")
    [[ -z "$r" ]] && { echo "? 检测失败（连不上）"; return; }
    if grep -q '45631641,null,true' <<< "$r"; then echo "Y 支持${cc:+（地区 $cc）}"; else echo "? 无法判断"; fi
}

unlock_check() {
    local c t i n v ipinfo f
    local -a names=("Netflix" "Disney+" "YouTube Premium" "Prime Video" "ChatGPT" "Claude" "Gemini")
    local -a funcs=(ul_netflix ul_disney ul_youtube ul_prime ul_chatgpt ul_claude ul_gemini)
    echo
    echo -e "${CYAN}========== 流媒体 / AI 解锁检测 ==========${NC}"
    echo " 1) 用 IPv4 检测"
    echo " 2) 用 IPv6 检测"
    echo -e " 0) ${GREEN}返回${NC}"
    read -rp "请选择 [1]: " c
    case "${c:-1}" in
        1) UL_OPT="-4 --max-time 10" ;;
        2) curl -6 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1 || { err "这台服务器没有可用的 IPv6"; return; }
           UL_OPT="-6 --max-time 10" ;;
        *) return ;;
    esac
    ipinfo=$(curl $UL_OPT -s https://www.cloudflare.com/cdn-cgi/trace)
    echo " 出口 IP：$(sed -n 's/^ip=//p' <<< "$ipinfo")    地区：$(sed -n 's/^loc=//p' <<< "$ipinfo")"
    printf ' 检测中（约 10 秒）...'
    t=$(mktemp -d)
    for i in "${!funcs[@]}"; do ( "${funcs[i]}" > "$t/$i" 2>/dev/null ) & done
    wait
    printf '\r\033[K'
    for i in "${!funcs[@]}"; do
        ((i == 0)) && echo -e "${CYAN}流媒体${NC}"
        ((i == 4)) && echo -e "${CYAN}AI${NC}"
        v=$(cat "$t/$i"); f=${v:0:1}; v=${v:2}
        case "$f" in
            Y) printf '  %-16s %b✔ %s%b\n' "${names[i]}" "$GREEN" "$v" "$NC" ;;
            N) printf '  %-16s %b✘ %s%b\n' "${names[i]}" "$RED" "$v" "$NC" ;;
            !) printf '  %-16s %b! %s%b\n' "${names[i]}" "$YELLOW" "$v" "$NC" ;;
            *) printf '  %-16s ? %s\n' "${names[i]}" "${v:-检测失败}" ;;
        esac
    done
    rm -rf "$t"
    echo
    echo " 说明：结果按各平台网页的特征判断，平台改版后可能不准；Disney+ 只做了简易判断"
}

# ---------------- 更新脚本 ----------------
update_self() {
    local url tmp oldv newv yn
    url=$(gh_fresh_url "$SCRIPT_URL")
    info "正在检查更新 ..."
    tmp=$(mktemp)
    if ! curl -fsSL --retry 2 --max-time 30 "$url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"; err "下载失败：${url}"; return
    fi
    if ! head -1 "$tmp" | grep -q '^#!' || ! grep -q "SSH 小工具" "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"; err "下载到的文件不完整或不是本脚本，已放弃更新"; return
    fi
    if [[ -f "$CMD_PATH" ]] && cmp -s "$tmp" "$CMD_PATH"; then
        rm -f "$tmp"; info "已经是最新版（v${TOOL_VER}）"; return
    fi
    oldv=$TOOL_VER
    newv=$(sed -n 's/^TOOL_VER="\(.*\)".*/\1/p' "$tmp" | head -1)
    echo " 当前：v${oldv}    仓库：v${newv:-?}"
    read -rp "现在更新？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && { rm -f "$tmp"; return; }
    install -m 755 "$tmp" "$CMD_PATH" && rm -f "$tmp" || { rm -f "$tmp"; err "写入失败"; return; }
    info "已更新到 v${newv:-?}，正在重新打开 ..."
    sleep 1
    exec bash "$CMD_PATH"
}

# ---------------- 菜单 ----------------
menu_ssh() {  # SSH 安全
    local c
    while true; do
        echo
        echo -e "${CYAN}========== SSH 安全 ==========${NC}"
        echo -e " SSH 端口：${GREEN}$(current_port)${NC}    密码登录：${GREEN}$(pass_state)${NC}"
        echo " 1) 修改 SSH 端口"
        echo " 2) 生成密钥（自动加入 authorized_keys）"
        echo " 3) 导入公钥（从仓库拉取 / 粘贴）"
        echo " 4) 下载已有密钥"
        echo " 5) 禁用密码登录（仅密钥登录）"
        echo " 6) 恢复密码登录"
        echo -e " 0) ${GREEN}返回${NC}"
        read -rp "请选择: " c || return
        case "$c" in
            1) change_port; pause ;;
            2) gen_key; pause ;;
            3) import_keys; pause ;;
            4) download_key ""; pause ;;
            5) disable_password; pause ;;
            6) enable_password; pause ;;
            0|q|Q) return ;;
            *) err "无效选择" ;;
        esac
    done
}

menu_perf() {  # 性能检测
    local c
    while true; do
        echo
        echo -e "${CYAN}========== 性能检测 ==========${NC}"
        echo " 1) CPU 占用状态（各核 / 细节 / 最耗 CPU 的程序）"
        echo " 2) CPU 性能测试（单核/多核）"
        echo " 3) 内存性能测试（读/写速度）"
        echo " 4) 硬盘 IO 测试"
        echo -e " 0) ${GREEN}返回${NC}"
        read -rp "请选择: " c || return
        case "$c" in
            1) cpu_usage; pause ;;
            2) cpu_bench; pause ;;
            3) mem_bench; pause ;;
            4) io_bench; pause ;;
            0|q|Q) return ;;
            *) err "无效选择" ;;
        esac
    done
}

menu_net() {  # 网络设置
    local c
    while true; do
        echo
        echo -e "${CYAN}========== 网络设置 ==========${NC}"
        echo -e " BBR：${GREEN}$([[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]] && echo 已开启 || echo 未开启)${NC}    Ping：${GREEN}$(ping_state)${NC}"
        echo " 1) BBR 加速（开启/关闭）"
        echo " 2) 禁 Ping（禁用/恢复）"
        echo " 3) 端口转发（TCP/UDP）"
        echo -e " 0) ${GREEN}返回${NC}"
        read -rp "请选择: " c || return
        case "$c" in
            1) bbr_menu; pause ;;
            2) ping_menu; pause ;;
            3) forward_menu ;;
            0|q|Q) return ;;
            *) err "无效选择" ;;
        esac
    done
}

menu_check() {  # 网络检测
    local c
    while true; do
        echo
        echo -e "${CYAN}========== 网络检测 ==========${NC}"
        echo " 1) 回程线路检测（电信 / 联通 / 移动）"
        echo " 2) 流媒体 / AI 解锁检测"
        echo -e " 0) ${GREEN}返回${NC}"
        read -rp "请选择: " c || return
        case "$c" in
            1) route_check; pause ;;
            2) unlock_check; pause ;;
            0|q|Q) return ;;
            *) err "无效选择" ;;
        esac
    done
}

while true; do
    echo
    echo -e "${CYAN}========== SSH 小工具 v${TOOL_VER} ==========${NC}"
    echo -e " SSH 端口：${GREEN}$(current_port)${NC}    密码登录：${GREEN}$(pass_state)${NC}"
    echo " 1) 系统信息"
    echo " 2) SSH 安全      端口 / 密钥 / 密码登录"
    echo " 3) 性能检测      CPU 占用 / CPU / 内存 / 硬盘"
    echo " 4) 网络设置      BBR / 禁 Ping / 端口转发"
    echo " 5) 网络检测      回程线路 / 流媒体 / AI 解锁"
    echo " 6) 更新脚本"
    echo -e " 0) ${RED}退出${NC}"
    read -rp "请选择: " c || exit 0
    case "$c" in
        1) sys_info; pause ;;
        2) menu_ssh ;;
        3) menu_perf ;;
        4) menu_net ;;
        5) menu_check ;;
        6) update_self; pause ;;
        0|q|Q) exit 0 ;;
        *) err "无效选择" ;;
    esac
done
