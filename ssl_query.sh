#!/bin/bash

# 查询证书信息
query_certificate() {
    local certificate_id=$1
    local secret_id=$2
    local secret_key=$3
    local region=$4
    local token=$5
    local status_map_str=$6

    log_debug "开始查询证书: $certificate_id" >&2
    log_debug "查询证书: $certificate_id"


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
    if [ -f "$output_file" ]; then
        # 文件存在，仅更新特定字段，不覆盖原有内容
        local temp_file=$(mktemp)
        jq --argjson new_data "$filtered_response" '
            .CertificateId = $new_data.CertificateId 
            | .Domain = $new_data.Domain 
            | .Status = $new_data.Status 
            | .CertBeginTime = $new_data.CertBeginTime 
            | .CertEndTime = $new_data.CertEndTime 
            | .InsertTime = $new_data.InsertTime 
            | .StatusDesc = $new_data.StatusDesc 
            | .RemainingDays = $new_data.RemainingDays' "$output_file" > "$temp_file" && mv "$temp_file" "$output_file"
        if [ $? -ne 0 ]; then
            log_error "更新证书信息失败: $output_file" >&2
            return 1
        fi
    else
        # 文件不存在，直接写入新内容
        if ! echo "$filtered_response" > "$output_file"; then
            log_error "保存证书信息到文件失败: $output_file" >&2
            return 1
        fi
    fi
    log_debug "已保存证书信息到: $output_file" >&2

    # 输出信息到控制台
    local domain=$(echo "$filtered_response" | jq -r '.Domain // "未知"')
    local beginTime=$(echo "$filtered_response" | jq -r '.CertBeginTime // "未知"')
    local endTime=$(echo "$filtered_response" | jq -r '.CertEndTime // "未知"')
    
    log_info "----------------------------------------"
    log_info "证书ID: $certificate_id"
    log_info "域名: ${domain}"
    log_info "状态:  ${status_desc} (代码: ${status_code})"
    log_info "开始时间: ${beginTime}"
    log_info "结束时间: ${endTime}"
    log_info "剩余有效期: ${remaining_days}天"
    log_info "----------------------------------------"

    # 返回过滤后的响应数据，只保留证书ID，剩余有效期
    echo "$response" | jq --arg cert_id "$certificate_id" --arg status_code "$status_code" '{CertificateId: $cert_id, Status: $status_code}'
    return 0
}