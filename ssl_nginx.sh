#!/bin/bash

# 设置SSL目录
LOG_TAG="ssl_nginx"

deploy_nginx_ssl() {

# 遍历 output 目录下的所有 JSON 文件
for json_file in ${OUTPUT_DIR}/*.json; do
    if [ ! -f "$json_file" ]; then
        log_debug "[$LOG_TAG] 未找到JSON文件，跳过处理" >&2
        continue
    fi

    # 提取 cert_file 和 Domain 字段
    cert_id=$(jq -r '.CertificateId' "$json_file")
    domain=$(jq -r '.Domain' "$json_file")
    cert_file=$(jq -r '.CertificateFile' "$json_file")
    remaining_days=$(jq -r '.RemainingDays' "$json_file")
    is_deployed=$(jq -r '.IsDeployed // 0' "$json_file")

    log_debug "[$LOG_TAG] 正在处理文件: $json_file" >&2
    log_debug "[$LOG_TAG] 域名为: $domain, 证书ID为：$cert_id，证书有效期：${remaining_days}（天），是否发布：${is_deployed}" >&2

    if [ -z "$cert_file" ] || [ "$cert_file" = "null" ]; then
        log_debug "[$LOG_TAG] $json_file JSON文件未包含 cert_file 字段，跳过处理" >&2
        continue
    fi

    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        log_debug "[$LOG_TAG] $json_file JSON文件未包含 Domain 字段，跳过处理" >&2
        continue
    fi

    # 检查 remaining_days 是否为有效整数
    if [[ ! "$remaining_days" =~ ^-?[0-9]+$ ]]; then
        log_error "[$LOG_TAG] 无效的剩余天数字段: $remaining_days，跳过域名 '$domain'" >&2
        continue
    fi

    # 仅处理未过期的证书
    if [ "$remaining_days" -lt 0 ]; then 
        log_info "[$LOG_TAG] 证书已过期，跳过处理" >&2
        continue
    fi

    # 检查ISdeploy参数是否为true，是则跳过部署
    if [ "${is_deployed}" -eq 1 ]; then
        log_info "[$LOG_TAG] $domain 证书已经更新，跳过部署" >&2
        continue
    fi

    # 构建目标路径
    zip_file="${OUTPUT_DIR}/$cert_file"

    if [ ! -f "$zip_file" ]; then
        log_error "[$LOG_TAG] 证书ZIP文件不存在: $zip_file" >&2
        continue
    fi

    # 解压证书到指定目录
    unzip -j -o "$zip_file" -d "$SSL_DIR" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "[$LOG_TAG] 解压证书失败: $zip_file -> $SSL_DIR" >&2
        continue
    fi

    log_info "[$LOG_TAG] 域名 '$domain' 的证书已成功部署至: $SSL_DIR" >&2

    json_file="${OUTPUT_DIR}/$cert_id.json"
    if [ -f "$json_file" ]; then
      log_debug "[$LOG_TAG] 找到 JSON 文件: $json_file"
      # 使用 jq 修改 JSON 文件
      cat $json_file | jq --arg  is_deployed 1 '. + {IsDeployed: $is_deployed}' > "${json_file}.tmp" && mv "${json_file}.tmp" "$json_file"
      log_info "[$LOG_TAG] SSL证书发布成功数据已更新: $json_file"
      rm -rf $zip_file
      log_info "[$LOG_TAG] 已删除证书下载文件: $zip_file"
    fi
done

# 检查 Nginx 配置
log_info "[$LOG_TAG] 正在检查 Nginx 配置..."
if ! nginx -t; then
    log_error "Nginx配置检查失败，取消重启服务" >&2
    exit 1
fi

# 重载 Nginx 服务
log_info "[$LOG_TAG] 正在重载 Nginx 服务..."
if ! nginx -s reload; then
    log_error "Nginx服务重载失败" >&2
    exit 1
fi

log_info "[$LOG_TAG] 所有证书已成功更新，Nginx 服务已重载。" >&2
}