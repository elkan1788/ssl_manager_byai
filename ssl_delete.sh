#!/bin/bash

# 删除证书
delete_certificate() {
    local secret_id=$1
    local secret_key=$2
    local region=$3
    local token=$4
    local certificate_id=$5
    local is_check_resource=${6:-false}

    log_debug "开始删除证书: $certificate_id" >&2

    # 构造请求 payload
    local payload=$(jq -n \
        --arg id "$certificate_id" \
        --argjson check "$is_check_resource" \
        '{CertificateId: $id, IsCheckResource: $check}')

    if [ $? -ne 0 ]; then
        log_error "构造请求参数失败" >&2
        return 1
    fi

    # 发送 API 请求
    local response=$(send_api_request "DeleteCertificate" "$payload" "$secret_id" "$secret_key" "$region" "$token")
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        log_error "删除证书失败: $certificate_id" >&2
        return 1
    fi

    # 提取 DeleteResult
    local delete_result=$(echo "$response" | jq -r '.Response.DeleteResult')
    if [ -z "$delete_result" ] || [ "$delete_result" = "null" ]; then
        log_error "API未返回有效的删除结果" >&2
        return 1
    fi

    if [ "$delete_result" = "true" ]; then
        log_info "成功删除证书: $certificate_id" >&2
        return 0
    else
        log_error "删除证书失败: $certificate_id" >&2
        return 1
    fi
}