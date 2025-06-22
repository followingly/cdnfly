#!/bin/bash -x

# 遇到错误时退出
set -o errexit

# 检查系统类型并设置变量
check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        SYSTEM_TYPE="centos"
        PACKAGE_NAME="cdnfly-agent-v5.1.16-centos-7.tar.gz"
        DIR_NAME="cdnfly-agent-v5.1.16"
        PYTHON_PACKAGE="python"
    elif [[ -f /etc/debian_version ]]; then
        SYSTEM_TYPE="ubuntu"
        PACKAGE_NAME="cdnfly-agent-v5.1.16-Ubuntu-16.04.tar.gz"
        DIR_NAME="cdnfly-agent-v5.1.16"
        PYTHON_PACKAGE="python-is-python2"
    else
        echo "该脚本仅支持 CentOS 或 Debian/Ubuntu 系统"
        exit 1
    fi
}

# 安装依赖
install_depend() {
    if [[ "$SYSTEM_TYPE" == "centos" ]]; then
        yum install -y wget $PYTHON_PACKAGE
    elif [[ "$SYSTEM_TYPE" == "ubuntu" ]]; then
        # 解决 apt 锁问题
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ; do
            echo "等待 apt 锁释放..."
            sleep 5
        done
        
        apt-get update || true
        apt-get install -y wget $PYTHON_PACKAGE cron curl ca-certificates
        
        # 确保 python 命令可用
        if ! command -v python &> /dev/null; then
            ln -s /usr/bin/python2 /usr/bin/python || true
        fi
    fi
}

# 下载文件
download() {
    local url1=$1
    local url2=$2
    local filename=$3

    # 获取下载速度
    speed1=$(curl -m 5 -L -s -w '%{speed_download}' "$url1" -o /dev/null || true)
    speed1=${speed1%%.*}
    speed2=$(curl -m 5 -L -s -w '%{speed_download}' "$url2" -o /dev/null || true)
    speed2=${speed2%%.*}
    echo "speed1: $speed1"
    echo "speed2: $speed2"
    url="$url1\n$url2"
    if [[ $speed2 -gt $speed1 ]]; then
        url="$url2\n$url1"
    fi
    echo -e $url | while read l; do
        echo "using url: $l"
        wget --dns-timeout=5 --connect-timeout=5 --read-timeout=10 --tries=2 "$l" -O "$filename" && break
    done
}

# 同步时间
sync_time() {
    echo "开始同步时间并添加同步命令到 cronjob..."

    if [[ "$SYSTEM_TYPE" == "centos" ]]; then
        yum -y install ntpdate wget
        /usr/sbin/ntpdate -u pool.ntp.org || true
        ! grep -q "/usr/sbin/ntpdate -u pool.ntp.org" /var/spool/cron/root > /dev/null 2>&1 && echo '*/10 * * * * /usr/sbin/ntpdate -u pool.ntp.org > /dev/null 2>&1 || (date_str=$(curl update.cdnfly.cn/common/datetime) && timedatectl set-ntp false && echo $date_str && timedatectl set-time "$date_str" )' >> /var/spool/cron/root
        service crond restart

        # 设置时区
        rm -f /etc/localtime
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

        /sbin/hwclock -w
    elif [[ "$SYSTEM_TYPE" == "ubuntu" ]]; then
        # Ubuntu/Debian 时间同步
        apt-get install -y chrony || true
        systemctl enable chrony
        systemctl restart chrony
        timedatectl set-timezone Asia/Shanghai
        
        # 添加定时同步任务
        ! grep -q "ntpdate" /etc/crontab > /dev/null 2>&1 && echo '*/10 * * * * root /usr/sbin/ntpdate -u pool.ntp.org > /dev/null 2>&1 || (date_str=$(curl -s update.cdnfly.cn/common/datetime) && timedatectl set-time "$date_str" )' >> /etc/crontab
        service cron restart
    fi
}

# 解析命令行参数
TEMP=$(getopt -o h --long help,master-ver:,agent-ver:,master-ip:,es-ip:,es-pwd:,ignore-ntp -- "$@")
if [ $? != 0 ]; then
    echo "参数解析失败" >&2
    exit 1
fi
eval set -- "$TEMP"

MASTER_VER=""
AGENT_VER=""
MASTER_IP=""
ES_IP=""
ES_PWD=""
IGNORE_NTP=""

while true; do
    case "$1" in
        -h|--help) echo "使用说明" ; exit 1 ;;
        --master-ver) MASTER_VER=$2; shift 2 ;;
        --agent-ver) AGENT_VER=$2; shift 2 ;;
        --master-ip) MASTER_IP=$2; shift 2 ;;
        --es-ip) ES_IP=$2; shift 2 ;;
        --es-pwd) ES_PWD=$2; shift 2 ;;
        --ignore-ntp) IGNORE_NTP=true; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

check_sys
install_depend
[[ -z "$IGNORE_NTP" ]] && sync_time

cd /opt

# 下载适用于当前系统的安装包
download "https://raw.githubusercontent.com/LoveesYe/cdnflydadao/main/agent//$PACKAGE_NAME" \
         "https://raw.githubusercontent.com/LoveesYe/cdnflydadao/main/agent//$PACKAGE_NAME" \
         "$PACKAGE_NAME"

rm -rf $DIR_NAME
tar xf $PACKAGE_NAME
rm -rf cdnfly
mv $DIR_NAME cdnfly

# 开始安装，传递所有参数
cd /opt/cdnfly/agent
chmod +x install.sh
./install.sh --master-ip "$MASTER_IP" --es-ip "$ES_IP" --es-pwd "$ES_PWD"
