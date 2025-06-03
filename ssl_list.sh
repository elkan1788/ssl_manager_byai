#!/bin/bash


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