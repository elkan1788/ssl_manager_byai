#!/bin/bash

# 下载证书
download_certificate() {
    local certificate_id=$1
    local secret_id=$2
    local secret_key=$3
    local region=$4
    local token=$5

    log_debug "开始下载证书: $certificate_id" >&2

    # 构造请求payload
    local payload=$(jq -n --arg cert_id "$certificate_id" --arg service_type "nginx" '{"CertificateId":$cert_id, "ServiceType":$service_type}')

    if [ $? -ne 0 ]; then
        log_error "构造请求参数失败" >&2
        return 1
    fi

    # 发送API请求获取下载链接
    local response=$(send_api_request "DescribeDownloadCertificateUrl" "$payload" "$secret_id" "$secret_key" "$region" "$token")
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        log_error "获取证书下载链接失败: $certificate_id" >&2
        return 1
    fi

    # 提取下载链接
    local download_url=$(echo "$response" | jq -r '.Response.DownloadCertificateUrl')
    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        log_error "API未返回有效的下载链接" >&2
        return 1
    else
      log_debug "下载链接: $download_url" >&2
    fi

    local download_file="$(echo "$response" | jq -r '.Response.DownloadFilename')"
    if [ -z "$download_file" ] || [ "$download_file" = "null" ]; then
        log_error "API未返回有效的下载文件名称" >&2
        return 1
    else
        log_debug "下载文件名称: $download_file" >&2
    fi

    # 创建输出目录
    if ! mkdir -p "output"; then
        log_error "创建输出目录失败" >&2
        return 1
    fi

    # 下载证书文件
    if ! curl -s -o "${OUTPUT_DIR}/$download_file" "$download_url"; then
        log_error "下载证书失败: $certificate_id" >&2
        return 1
    fi

    log_info "证书已成功下载至: ${OUTPUT_DIR}/$download_file" >&2

    # 更新原始JSON文件，添加cert_file字段
    local json_file="${OUTPUT_DIR}/${certificate_id}.json"
    if [ -f "$json_file" ]; then
        cat $json_file | jq --arg cert_file "$download_file" '. + {CertificateFile: $cert_file}' > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
        if [ $? -ne 0 ]; then
            log_error "更新JSON文件失败: $json_file" >&2
            return 1
        fi
        log_debug "JSON文件已更新，添加字段 CertifcateFile: $download_file" >&2
    else
        log_debug "未找到对应的JSON文件: $json_file，跳过更新" >&2
    fi

    return 0
}