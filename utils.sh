#!/bin/bash

# 检查终端是否支持颜色输出
has_color_support() {
    # 检查是否是终端，且TERM不为dumb
    if [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
        return 0
    fi
    return 1
}

# 定义颜色输出
if has_color_support; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    NC=$(printf '\033[0m')
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

# 日志输出函数
log_debug() {
    if [ "${DEBUG}" = "1" ]; then
        printf "%s[DEBUG][%s] %s%s\n" "${YELLOW}" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${NC}" >&2
    fi
}

log_info() {
    printf "%s[INFO][%s] %s%s\n" "${GREEN}" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${NC}" >&2
}

log_error() {
    printf "%s[ERROR][%s] %s%s\n" "${RED}" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${NC}" >&2
}

# 检查依赖工具
check_dependencies() {
    local missing_deps=0
    for cmd in curl openssl jq date iconv; do
        if ! command -v $cmd >/dev/null 2>&1; then
            log_error "缺少必要工具: $cmd"
            missing_deps=1
        fi
    done
    
    if [ $missing_deps -eq 1 ]; then
        exit 1
    fi
}

# 读取ini配置文件
read_ini() {
    local section=$1
    local key=$2
    local file=$3
    local value=""
    local in_section=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # 去除行首尾的空白字符
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释行
        if [ -z "$line" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # 检查section
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
            else
                [ $in_section -eq 1 ] && break
                in_section=0
            fi
            continue
        fi
        
        # 在正确的section中查找key
        if [ $in_section -eq 1 ] && [[ "$line" =~ ^[[:space:]]*"$key"[[:space:]]*= ]]; then
            value=$(echo "$line" | sed -E 's/^[^=]+=[ ]*//')
            break
        fi
    done < "$file"
    
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    else
        log_debug "在配置文件的[$section]部分未找到键'$key'" >&2
        return 1
    fi
}

# 获取配置文件中的证书ID
get_configured_certificate_ids() {
  
    local config_file=$1
    # 使用awk提取[certificates]部分的证书ID值（等号后面的部分）
    awk -F '=' '/^\[certificates\]/{p=1;next} /^\[.*\]/{p=0} p&&/^[^#]/{print $2}' "$config_file" | \
        sed 's/[[:space:]]*//g' | \
        grep -v '^$'
}
# 获取状态映射
get_status_mapping() {
    local config_file=$1
    declare -A status_map
    local found_status=0
    
    while IFS='=' read -r code description; do
        # 跳过空行和注释行
        if [ -z "$code" ] || [[ "$code" =~ ^#.*$ ]]; then
            continue
        fi
        
        # 清理空白字符
        code=$(echo "$code" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        description=$(echo "$description" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 如果code和description都不为空，则添加到映射中
        if [[ -n "$code" && -n "$description" ]]; then
            status_map[$code]="$description"
            found_status=1
            log_debug "添加状态映射: $code => $description" >&2
        fi
    done < <(awk '/^\[status\]/{f=1;next} /^\[/{f=0} f' "$config_file")
    
    # 如果没有找到任何有效的状态映射，返回错误
    if [ $found_status -eq 0 ]; then
        log_debug "在配置文件中未找到任何有效的状态映射" >&2
        return 1
    fi
    
    declare -p status_map
    return 0
}

# 获取状态描述
get_status_description() {
    local status_code=$1
    local status_map_str=$2
    
    # 确保使用关联数组
    eval "$status_map_str"
    
    if [[ -n "${status_map[$status_code]}" ]]; then
        echo "${status_map[$status_code]}"
    else
        echo "未知状态($status_code)"
    fi
}

# 计算剩余天数
calculate_remaining_days() {
    local end_time=$1
    local current_time=$(date +%s)
    local end_timestamp=$(date -d "$end_time" +%s)
    echo $(( (end_timestamp - current_time) / 86400 ))
}

# 创建输出目录
create_output_dir() {
    if [ ! -d "output" ]; then
        mkdir -p output
        log_debug "创建输出目录: output/"
    fi
}

# 发送API请求的公共方法
send_api_request() {
    local action=$1
    local payload=$2
    local secret_id=$3
    local secret_key=$4
    local region=$5
    local token=${6:-""}  # 可选参数
    
    local service="ssl"
    local host="ssl.tencentcloudapi.com"
    local version="2019-12-05"
    local algorithm="TC3-HMAC-SHA256"
    local timestamp=$(date +%s)
    local date=$(date -u -d @$timestamp +"%Y-%m-%d")
    
    # 将所有日志输出重定向到stderr
    {
      log_debug "发送API请求: $action"
      log_debug "请求参数: $payload"
      
      # 步骤1：拼接规范请求串
      local http_request_method="POST"
      local canonical_uri="/"
      local canonical_querystring=""
      local canonical_headers="content-type:application/json; charset=utf-8\nhost:$host\nx-tc-action:$(echo $action | awk '{print tolower($0)}')\n"
      local signed_headers="content-type;host;x-tc-action"
      local hashed_request_payload=$(echo -n "$payload" | openssl sha256 -hex | awk '{print $2}')
      local canonical_request="$http_request_method\n$canonical_uri\n$canonical_querystring\n$canonical_headers\n$signed_headers\n$hashed_request_payload"
      
      log_debug "规范请求串:\n$canonical_request"
      
      # 步骤2：拼接待签名字符串
      local credential_scope="$date/$service/tc3_request"
      local hashed_canonical_request=$(printf "$canonical_request" | openssl sha256 -hex | awk '{print $2}')
      local string_to_sign="$algorithm\n$timestamp\n$credential_scope\n$hashed_canonical_request"
      
      log_debug "待签名字符串:\n$string_to_sign"
      
      # 步骤3：计算签名
      local secret_date=$(printf "$date" | openssl sha256 -hmac "TC3$secret_key" | awk '{print $2}')
      local secret_service=$(printf $service | openssl dgst -sha256 -mac hmac -macopt hexkey:"$secret_date" | awk '{print $2}')
      local secret_signing=$(printf "tc3_request" | openssl dgst -sha256 -mac hmac -macopt hexkey:"$secret_service" | awk '{print $2}')
      local signature=$(printf "$string_to_sign" | openssl dgst -sha256 -mac hmac -macopt hexkey:"$secret_signing" | awk '{print $2}')
      
      log_debug "计算得到的签名: ${signature:20}"
      
      # 步骤4：拼接Authorization
      local authorization="$algorithm Credential=$secret_id/$credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
      
      log_debug "Authorization头: ${authorization:20}"
      
      
      # 步骤5：记录请求信息
      log_debug "===== API请求信息 ====="
      log_debug "请求URL: https://$host"
      log_debug "Action: $action"
      log_debug "Region: $region"
      log_debug "Version: $version"
      log_debug "Timestamp: $timestamp"
      log_debug "请求体: $payload"
      if [ -n "$token" ]; then
          log_debug "Token: ${token:0:20}..."
      fi
      log_debug "===================="
    } >&2
    
    # 步骤6：使用临时文件存储响应，避免管道问题
    local temp_response_file=$(mktemp)
    local curl_exit_code=0
    
    curl -s -XPOST "https://$host" \
        --connect-timeout 10 \
        --max-time 30 \
        -d "$payload" \
        -H "Authorization: $authorization" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Host: $host" \
        -H "X-TC-Action: $action" \
        -H "X-TC-Timestamp: $timestamp" \
        -H "X-TC-Version: $version" \
        -H "X-TC-Region: $region" \
        ${token:+-H "X-TC-Token: $token"} \
        -o "$temp_response_file" 2>/dev/null || curl_exit_code=$?

    # 检查最终结果
    if [ ${curl_exit_code:-0} -ne 0 ]; then
        log_error "[$action] curl命令执行失败，错误码: $curl_exit_code" >&2
        rm -f "$temp_response_file"
        return 1
    fi

    # 读取响应
    local response=$(cat "$temp_response_file")
    rm -f "$temp_response_file"

    # 检查响应是否为空
    if [ -z "$response" ]; then
        log_error "[$action] API返回空响应" >&2
        return 1
    fi

    log_debug "[$action] API响应: $response" >&2

    # 检查响应是否成功
    if echo "$response" | jq -e '.Response.Error' >/dev/null 2>&1; then
        local error_code=$(echo "$response" | jq -r '.Response.Error.Code')
        local error_message=$(echo "$response" | jq -r '.Response.Error.Message')
        log_error "[$action] API请求失败: [$error_code] $error_message" >&2
        return 1
    fi

    log_debug "[$action] API调用成功完成" >&2

    # 只返回响应内容，不包含任何日志
    echo "$response"
}

# 验证API响应
validate_api_response() {
    local response="$1"
    local action="$2"
    
    # 检查响应是否为空
    if [ -z "$response" ]; then
        log_error "[$action] API返回空响应"
        return 1
    fi
    
    # 检查响应是否是有效的JSON
    if ! echo "$response" | jq '.' &>/dev/null; then
        log_error "[$action] API返回的响应不是有效的JSON格式"
        log_debug "无效的JSON响应: $response"
        return 1
    fi
    
    # 检查是否存在错误信息
    if echo "$response" | jq -e '.Response.Error' >/dev/null; then
        local error_code=$(echo "$response" | jq -r '.Response.Error.Code')
        local error_message=$(echo "$response" | jq -r '.Response.Error.Message')
        log_error "[$action] API返回错误: [$error_code] $error_message"
        return 1
    fi
    
    # 检查Response字段是否存在
    if ! echo "$response" | jq -e '.Response' >/dev/null; then
        log_error "[$action] API响应缺少Response字段"
        return 1
    fi
    
    return 0
}