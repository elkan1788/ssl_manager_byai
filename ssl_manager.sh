#!/bin/bash

scripts=(utils.sh ssl_list.sh ssl_query.sh ssl_download.sh ssl_nginx.sh)

for script in "${scripts[@]}"; do
  source "./$script"
done

# 主函数
main() {
    local config_file="config.ini"
    
    # 检查配置文件
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        exit 1
    fi

    # 设置DEBUG模式
    local debug_value=$(read_ini "common" "debug" "$config_file")
    if [ $? -eq 0 ] && [ -n "$debug_value" ]; then
        export DEBUG="$debug_value"
        log_debug "已启用调试模式，DEBUG值为: $DEBUG"
    else
        export DEBUG="0"
        # 即使未启用调试模式，也记录一条信息说明当前状态
        log_debug "调试模式未启用，使用默认DEBUG值: $DEBUG"
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
    else
        log_debug  "secret_id: ${secret_id:20}"
    fi

    local secret_key=$(read_ini "common" "secret_key" "$config_file")
    if [ $? -ne 0 ] || [ -z "$secret_key" ]; then
        log_error "配置错误: 未找到 secret_key 配置项"
        exit 1
    else
        log_debug  "secret_key: ${secret_key:20}"
    fi

    local region=$(read_ini "common" "region" "$config_file")
    local token=$(read_ini "common" "token" "$config_file")
    
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
        local response=$( get_certificate_list "$secret_id" "$secret_key" "$region" "$token")
       
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
        filtered_response=$(query_certificate "$cert_id" "$secret_id" "$secret_key" "$region" "$token" "$status_map_str")
        local certificate_id=$(echo "$filtered_response" | jq -r '.CertificateId')
        local status_code=$(echo "$filtered_response" | jq -r '.Status')
        if [ "$status_code" = "1" ]; then
            download_certificate "$certificate_id" "$secret_id" "$secret_key" "$region" "$token"
        fi
    done

    # 部署SSL证书
    deploy_nginx_ssl
}

# 执行主函数
main