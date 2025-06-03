#!/bin/bash

# 申请证书
apply_certificate() {
    local secret_id=$1
    local secret_key=$2
    local region=$3
    local token=$4
    local domain=$5

    log_debug "开始申请证书: $domain" >&2

    # 构造请求 payload
    local payload=$(jq -n \
        --arg dv_method "DNS_AUTO" \
        --arg domain "$domain" \
        '{DvAuthMethod: $dv_method, DomainName: $domain}')

    if [ $? -ne 0 ]; then
        log_error "构造请求参数失败" >&2
        return 1
    fi

    # 发送 API 请求
    local response=$(send_api_request "ApplyCertificate" "$payload" "$secret_id" "$secret_key" "$region" "$token")
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        log_error "申请证书失败: $domain" >&2
        return 1
    fi

    # 提取 CertificateId
    local certificate_id=$(echo "$response" | jq -r '.Response.CertificateId')
    if [ -z "$certificate_id" ] || [ "$certificate_id" = "null" ]; then
        log_error "API未返回有效的证书ID" >&2
        return 1
    fi

    log_info "成功申请证书: $domain (CertificateId: $certificate_id)" >&2
    echo "$certificate_id"
    return 0
}