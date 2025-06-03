#!/bin/bash

# 设置SSL目录
SSL_DIR="/etc/nginx/ssl"
OUTPUT="output/"
LOG_TAG="ssl_nginx"

# 创建SSL目录（如果不存在）
if ! mkdir -p "$SSL_DIR"; then
    log_error "创建SSL目录失败: $SSL_DIR" >&2
    exit 1
fi

deploy_nginx_ssl() {
# 遍历 output 目录下的所有 JSON 文件
for json_file in ${OUTPUT}/*.json; do
    if [ ! -f "$json_file" ]; then
        log_debug "未找到JSON文件，跳过处理" >&2
        continue
    fi

    # 提取 cert_file 和 Domain 字段
    cert_file=$(jq -r '.cert_file' "$json_file")
    domain=$(jq -r '.Domain' "$json_file")

    if [ -z "$cert_file" ] || [ "$cert_file" = "null" ]; then
        log_debug "$json_file JSON文件未包含 cert_file 字段，跳过处理" >&2
        continue
    fi

    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        log_debug "$json_file JSON文件未包含 Domain 字段，跳过处理" >&2
        continue
    fi

    # 构建目标路径
    zip_file="${OUTPUT}$cert_file"

    if [ ! -f "$zip_file" ]; then
        log_error "证书ZIP文件不存在: $zip_file" >&2
        continue
    fi


    # 解压证书到指定目录
    unzip -j -o "$zip_file" -d "$SSL_DIR" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "解压证书失败: $zip_file -> $SSL_DIR" >&2
        continue
    fi

    log_info "[$LOG_TAG] 域名 '$domain' 的证书已成功部署至: $SSL_DIR" >&2
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