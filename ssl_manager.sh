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
        printf "%s[DEBUG][%s] %s%s\n" "${YELLOW}" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${NC}"
    fi
}

log_info() {
    printf "%s[INFO][%s] %s%s\n" "${GREEN}" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${NC}"
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
        log_debug "在配置文件的[$section]部分未找到键'$key'"
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
        if [ -z "$code" ] || [[ "$code" =~ ^[[:space:]]*#.*$ ]]; then
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
    
    # 确保状态映射被正确导出
    declare -p status_map | sed 's/^declare -A/declare -A/'
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
        
        log_debug "计算得到的签名: $signature"
        
        # 步骤4：拼接Authorization
        local authorization="$algorithm Credential=$secret_id/$credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
        
        log_debug "Authorization头: $authorization"
        
        
        # 步骤5：记录请求信息
        log_debug "===== API请求信息 ====="
        log_debug "请求URL: https://$host"
        log_debug "Action: $action"
        log_debug "Region: $region"
        log_debug "Version: $version"
        log_debug "Timestamp: $timestamp"
        log_debug "请求体: $payload"
        # 不输出完整的Authorization头，因为包含敏感信息
        log_debug "Authorization: ${authorization:0:20}..."
        if [ -n "$token" ]; then
            log_debug "Token: ${token:0:20}..."
        fi
        log_debug "===================="
    } >&2
    
    # 步骤6：设置重试参数
    local max_retries=3
    local retry_count=0
    local retry_delay=2
    
    # 使用临时文件存储响应，避免管道问题
    local temp_response_file=$(mktemp)
    local curl_exit_code=0
    
    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            log_debug "第 $retry_count 次重试，等待 $retry_delay 秒..." >&2
            sleep $retry_delay
            # 更新时间戳和签名，因为重试时需要新的时间戳
            timestamp=$(date +%s)
            authorization=$(generate_authorization "$secret_id" "$secret_key" "$host" "$timestamp" "$payload")
        fi
        
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
        
        if [ ${curl_exit_code:-0} -eq 0 ] && [ -s "$temp_response_file" ]; then
            # 检查是否是可重试的错误
            local response_content=$(cat "$temp_response_file")
            if echo "$response_content" | jq -e '.Response.Error.Code' >/dev/null 2>&1; then
                local error_code=$(echo "$response_content" | jq -r '.Response.Error.Code')
                case "$error_code" in
                    "RequestLimitExceeded"|"InternalError"|"ServiceUnavailable")
                        log_debug "遇到可重试的错误: $error_code" >&2
                        retry_count=$((retry_count + 1))
                        retry_delay=$((retry_delay * 2))  # 指数退避
                        continue
                        ;;
                    *)
                        break  # 其他错误不重试
                        ;;
                esac
            else
                break  # 没有错误，退出重试循环
            fi
        elif [ ${curl_exit_code:-0} -ne 0 ]; then
            log_debug "curl命令失败，退出码: $curl_exit_code" >&2
            retry_count=$((retry_count + 1))
            retry_delay=$((retry_delay * 2))  # 指数退避
            continue
        fi
    done

    # 检查最终结果
    if [ ${curl_exit_code:-0} -ne 0 ]; then
        log_error "[$action] curl命令执行失败，错误码: $curl_exit_code，已重试 $retry_count 次" >&2
        rm -f "$temp_response_file"
        return 1
    fi

    # 读取响应
    local response=$(cat "$temp_response_file")
    rm -f "$temp_response_file"

    # 检查响应是否为空
    if [ -z "$response" ]; then
        log_error "[$action] API返回空响应，已重试 $retry_count 次" >&2
        return 1
    fi

    log_debug "[$action] API响应: $response" >&2

    # 检查响应是否成功
    if echo "$response" | jq -e '.Response.Error' >/dev/null 2>&1; then
        local error_code=$(echo "$response" | jq -r '.Response.Error.Code')
        local error_message=$(echo "$response" | jq -r '.Response.Error.Message')
        log_error "[$action] API请求失败: [$error_code] $error_message，已重试 $retry_count 次" >&2
        return 1
    fi

    # 记录成功信息
    if [ $retry_count -gt 0 ]; then
        log_info "[$action] API调用在第 $retry_count 次重试后成功完成" >&2
    else
        log_debug "[$action] API调用成功完成" >&2
    fi

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

# 获取证书列表
get_certificate_list() {
    local secret_id=$1
    local secret_key=$2
    local region=$3
    local token=$4
    
    local payload='{
        "Limit": 100,
        "Offset": 0
    }'
    local action="DescribeCertificates"
    local response=$(send_api_request "$action" "$payload" "$secret_id" "$secret_key" "$region" "$token")
    local api_status=$?
    
    # 检查API调用是否成功
    if [ $api_status -ne 0 ]; then
        log_error "[$action] API请求失败，状态码: $api_status" >&2
        return 1
    fi
    
    # 调试输出原始响应
    log_debug "[$action] API原始响应: $response" >&2
    
    # 验证API响应
    if ! validate_api_response "$response" "$action"; then
        return 1
    fi
    
    # 检查Certificates字段是否存在
    if ! echo "$response" | jq -e '.Response.Certificates' >/dev/null; then
        log_error "[$action] API响应缺少Certificates字段" >&2
        return 1
    fi
    
    # 检查是否有证书
    if echo "$response" | jq -e '.Response.Certificates | length > 0' > /dev/null; then
        local cert_count=$(echo "$response" | jq '.Response.Certificates | length')
        log_info "通过 API 方式自动获取，找到 $cert_count 个证书" >&2
        # 只返回证书ID列表，不包含任何日志信息
        echo "$response" | jq -r '.Response.Certificates[] | .CertificateId'
        return 0
    else
        log_debug "[$action] API返回成功但未找到证书" >&2
        return 2  # 特殊返回码：成功但无证书
    fi
}

# 查询证书信息
query_certificate() {
    local certificate_id=$1
    local secret_id=$2
    local secret_key=$3
    local region=$4
    local token=$5
    local status_map_str=$6
    
    log_debug "开始查询证书: $certificate_id" >&2        log_debug "查询证书: $certificate_id"

    
    # 构造请求payload，使用jq确保JSON格式正确
    local payload=$(jq -n --arg cert_id "$certificate_id" '{"CertificateId": $cert_id}')
    if [ $? -ne 0 ]; then
        log_error "构造请求参数失败" >&2
        return 1
    fi
    
    # 发送API请求
    local response=$(send_api_request "DescribeCertificate" "$payload" "$secret_id" "$secret_key" "$region" "$token")
    local api_status=$?
    
    # 检查API调用结果
    if [ $api_status -ne 0 ]; then
        log_error "查询证书 $certificate_id 失败" >&2
        return 1
    fi
    
    # 验证响应是否为有效的JSON
    if ! echo "$response" | jq '.' >/dev/null 2>&1; then
        log_error "API返回的响应不是有效的JSON格式" >&2
        log_debug "无效的JSON响应: $response" >&2
        return 1
    fi
    
    # 检查是否存在错误信息
    if echo "$response" | jq -e '.Response.Error' >/dev/null 2>&1; then
        local error_code=$(echo "$response" | jq -r '.Response.Error.Code')
        local error_message=$(echo "$response" | jq -r '.Response.Error.Message')
        
        case "$error_code" in
            "FailedOperation.CertificateNotFound")
                log_error "证书 $certificate_id 不存在" >&2
                ;;
            "AuthFailure.SecretIdNotFound")
                log_error "SecretId 无效或不存在" >&2
                ;;
            "AuthFailure.SignatureFailure")
                log_error "签名验证失败，请检查 SecretKey 是否正确" >&2
                ;;
            *)
                log_error "API请求失败: [$error_code] $error_message" >&2
                ;;
        esac
        return 1
    fi
    
    # 提取所需字段，使用jq的错误处理
    local filtered_response
    filtered_response=$(echo "$response" | jq -e '{
        CertificateId: .Response.CertificateId,
        Domain: .Response.Domain,
        Status: .Response.Status,
        CertBeginTime: .Response.CertBeginTime,
        CertEndTime: .Response.CertEndTime,
        InsertTime: .Response.InsertTime,
        RequestId: .Response.RequestId
    }' 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "处理证书信息失败，响应格式不符合预期" >&2
        log_debug "API响应: $response" >&2
        return 1
    fi
    
    # 创建输出目录（如果不存在）
    if ! mkdir -p "output"; then
        log_error "创建输出目录失败" >&2
        return 1
    fi
    
    # 获取状态码
    local status_code
    status_code=$(echo "$filtered_response" | jq -r '.Status')
    if [ $? -ne 0 ]; then
        log_error "获取证书状态码失败" >&2
        return 1
    fi
    
    # 获取状态描述
    local status_desc
    if [ -n "$status_map_str" ]; then
        # 调试输出状态映射字符串
        log_debug "状态映射字符串: $status_map_str" >&2
        log_debug "当前状态码: $status_code" >&2
        
        status_desc=$(get_status_description "$status_code" "$status_map_str")
        log_debug "获取到的状态描述: $status_desc" >&2
    else
        status_desc="未知状态($status_code)"
        log_debug "未提供状态映射，使用默认描述: $status_desc" >&2
    fi
    
    # 添加状态描述到响应
    filtered_response=$(echo "$filtered_response" | jq --arg desc "$status_desc" '. + {StatusDesc: $desc}')
    
    # 计算剩余有效期
    local end_time
    end_time=$(echo "$filtered_response" | jq -r '.CertEndTime')
    if [ $? -ne 0 ] || [ -z "$end_time" ]; then
        log_error "获取证书到期时间失败" >&2
        return 1
    fi
    
    local remaining_days
    remaining_days=$(calculate_remaining_days "$end_time")
    
    # 添加剩余天数到响应
    filtered_response=$(echo "$filtered_response" | jq --arg days "$remaining_days" '. + {RemainingDays: ($days|tonumber)}')
    
    # 保存JSON到文件
    local output_file="output/${certificate_id}.json"
    if ! echo "$filtered_response" > "$output_file"; then
        log_error "保存证书信息到文件失败: $output_file" >&2
        return 1
    fi
    log_debug "已保存证书信息到: $output_file" >&2
    
    # 输出信息到控制台
    {
        echo "----------------------------------------"
        echo "证书ID: $certificate_id"
        echo "域名: $(echo "$filtered_response" | jq -r '.Domain // "未知"')"
        echo "状态: $status_desc (代码: $status_code)"
        echo "开始时间: $(echo "$filtered_response" | jq -r '.CertBeginTime // "未知"')"
        echo "结束时间: $(echo "$filtered_response" | jq -r '.CertEndTime // "未知"')"
        echo "剩余有效期: ${remaining_days}天"
        echo "----------------------------------------"
    } || {
        log_error "输出证书信息时发生错误" >&2
        return 1
    }
    
    return 0
}

# 主函数
main() {
    local config_file="config.ini"
    
    # 检查配置文件
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        exit 1
    fi
    
    # 检查依赖
    check_dependencies
    
    # 创建输出目录
    create_output_dir
    
    # 读取配置
    local secret_id=$(read_ini "common" "secret_id" "$config_file")
    if [ $? -ne 0 ] || [ -z "$secret_id" ]; then
        log_error "配置错误: 未找到 secret_id 配置项"
        exit 1
    fi

    local secret_key=$(read_ini "common" "secret_key" "$config_file")
    if [ $? -ne 0 ] || [ -z "$secret_key" ]; then
        log_error "配置错误: 未找到 secret_key 配置项"
        exit 1
    fi

    local region=$(read_ini "common" "region" "$config_file")

    local token=$(read_ini "common" "token" "$config_file")
    if [ $? -ne 0 ]; then
        log_debug "未配置 token"
        token=""
    fi
    
    # 设置DEBUG模式
    local debug_value=$(read_ini "common" "debug" "$config_file")
    if [ $? -eq 0 ] && [ -n "$debug_value" ]; then
        export DEBUG="$debug_value"
        log_debug "已启用调试模式"
    else
        export DEBUG="0"
    fi
    
    # 获取状态映射
    log_debug "正在从配置文件读取状态映射..."
    local status_map_str=$(get_status_mapping "$config_file")
    if [ $? -ne 0 ] || [ -z "$status_map_str" ]; then
        log_error "获取状态映射失败，请检查配置文件中的 [status] 部分"
        exit 1
    fi
    log_debug "成功获取状态映射: $status_map_str"
    
    # 获取证书ID列表
    log_debug "开始获取证书ID列表..."
    log_debug "正在解析配置文件中的证书配置..."

    # 从配置文件获取证书ID值
    local cert_ids=()
    while IFS= read -r cert_id; do
        if [[ -n "$cert_id" ]]; then
            cert_ids+=("$cert_id")
            log_debug "找到有效证书ID: $cert_id"
        fi
    done < <(get_configured_certificate_ids "$config_file")

    # 检查配置文件中的证书ID
    if [ ${#cert_ids[@]} -gt 0 ]; then
        log_info "从配置文件中找到 ${#cert_ids[@]} 个证书ID"
        for cert_id in "${cert_ids[@]}"; do
            log_debug "将处理证书ID: $cert_id"
        done
    else
        log_info "配置文件中未找到证书ID，尝试通过API自动获取..."
        log_debug "准备调用API获取证书列表..."
        
        # 尝试自动获取证书列表
        log_debug "调用API获取证书列表..."
        local response
        response=$( get_certificate_list "$secret_id" "$secret_key" "$region" "$token")
       
        local get_status=$?
        
        log_debug "API调用返回状态码: $get_status"
        case $get_status in
            0)  # API调用成功且找到证书
                log_debug "API调用成功，开始解析证书ID..."
                cert_ids=()
                while IFS= read -r line; do
                    if [[ -n "$line" ]]; then
                      cert_ids+=("$line")                        
                    fi
                done < <(echo "$response")                
                ;;
            1)  # API调用失败
                log_error "获取证书列表失败，请检查API密钥配置是否正确"
                log_debug "API调用失败的详细信息可能在上方的日志中"
                exit 1
                ;;
            2)  # API调用成功但没有证书
                log_error "未找到任何证书，请确认账号下是否有SSL证书或在配置文件中指定证书ID"
                log_debug "API返回成功但证书列表为空"
                exit 1
                ;;
            *)  # 其他未知错误
                log_error "获取证书列表时发生未知错误，状态码: $get_status"
                exit 1
                ;;
        esac
    fi
    
    # 查询每个证书
    for cert_id in "${cert_ids[@]}"; do
        query_certificate "$cert_id" "$secret_id" "$secret_key" "$region" "$token" "$status_map_str"
    done
}

# 执行主函数
main