#!/bin/bash

scripts=(utils.sh ssl_list.sh ssl_query.sh ssl_download.sh ssl_nginx.sh ssl_apply.sh ssl_delete.sh)

for script in "${scripts[@]}"; do
  source "./$script"
done

save_certificates() { 
  local secret_id=$1
  local secret_key=$2
  local region=$3
  local token=$4
  local status_map_str=$5

  # 从配置文件获取证书ID值
  local cert_ids=()
  while IFS= read -r cert_id; do
      if [[ -n "$cert_id" ]]; then
          cert_ids+=("$cert_id")
          log_info "找到有效证书ID: $cert_id"
      fi
  done < <(get_configured_certificate_ids)

  # 检查配置文件中的证书ID
  if [ ${#cert_ids[@]} -gt 0 ]; then
      log_info "从配置文件中找到 ${#cert_ids[@]} 个证书ID"
      for cert_id in "${cert_ids[@]}"; do
          log_debug "将处理证书ID: $cert_id"
      done
  else
    log_info "配置文件中未找到证书ID，尝试通过API自动获取..."
            
    # 尝试自动获取证书列表
    log_debug "调用API获取证书列表..."
    local response=$(get_certificate_list "$secret_id" "$secret_key" "$region" "$token")
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          cert_ids+=("$line")                        
        fi
    done < <(echo "$response")
  fi
  
  # 获取状态映射
  local status_map_str=$(get_status_mapping)

  # 查询每个证书&并下载证书
  for cert_id in "${cert_ids[@]}"; do
      filtered_response=$(query_certificate "$cert_id" "$secret_id" "$secret_key" "$region" "$token" "$status_map_str")
      local certificate_id=$(echo "$filtered_response" | jq -r '.CertificateId')
      local status_code=$(echo "$filtered_response" | jq -r '.Status')
      if [ "$status_code" = "1" ]; then
          download_certificate "$certificate_id" "$secret_id" "$secret_key" "$region" "$token"
      else
          log_info "证书 $certificate_id 状态已过期或其它，跳过下载"
      fi
  done
  log_info "所有证书的信息和证书文件都已保存到 ${OUTPUT_DIR} 目录中。"
}

renew_certificates() { 
  # 检查即将过期的证书并自动申请新证书
  log_info "开始检查即将过期的证书..."
  local all_records=$(read_certificate_records)

  # 使用 jq 解析 JSON 数组
  echo "$all_records" | jq -c '.[]' | while read -r record; do
      local domain=$(echo "$record" | jq -r '.Domain')
      local certificate_id=$(echo "$record" | jq -r '.CertificateId')
      local remaining_days=$(echo "$record" | jq -r '.RemainingDays')

      # 判断是否为有效整数（包括负数），并且剩余天数小于2
      if [[ "$remaining_days" =~ ^-?[0-9]+$ ]]; then
          if [ "$remaining_days" -lt 2 ]; then
              log_info "域名 '$domain' 的证书已/即将过期，剩余天数: $remaining_days 天，正在申请新证书..."
              new_cert_id=$(apply_certificate "$secret_id" "$secret_key" "$region" "$token" "$domain")
              if [ $? -eq 0 ] && [ -n "$new_cert_id" ]; then
                  log_info "成功申请新证书: $new_cert_id，准备删除旧证书: $certificate_id"
                  delete_certificate "$secret_id" "$secret_key" "$region" "$token" "$certificate_id"
                  rm -rf "${OUTPUT_DIR}/${certificate_id}.json"
                  log_info "成功删除旧证书: $certificate_id"
              fi
          else
              log_info "域名 '$domain' 的证书剩余天数充足: $remaining_days 天，跳过申请。"
          fi
      else
          log_error "无法识别剩余天数字段: $remaining_days，跳过处理域名 '$domain'"
      fi
  done
}

# 主程序入口
main() {
    # 检查依赖工具
    check_dependencies

    # 创建输出目录
    create_output_dir

    # 读取配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        exit 1
    fi

    # 开启DEBUG模式
    local debug_value=$(read_ini "common" "debug")
    if [ $? -eq 0 ] && [ -n "$debug_value" ]; then
        export DEBUG="$debug_value"
        log_info "已启用调试模式，DEBUG值为: $DEBUG"
    else
        export DEBUG="0"
        log_info "调试模式未启用，使用默认DEBUG值: $DEBUG"
    fi
    

    # 获取API密钥配置
    local secret_id=$(read_ini "common" "secret_id" )
    local secret_key=$(read_ini "common" "secret_key" )
    local region=$(read_ini "common" "region" )
    local token=$(read_ini "common" "token")

    if [ -z "$secret_id" ] || [ -z "$secret_key" ]; then
        log_error "缺少必要的凭证信息（secret_id 或 secret_key）"
        exit 1
    fi

    # 获取操作模式
    local mode="${1}"
    log_debug  "操作模式：$mode"
    case "$mode" in
      save)
          log_info "查询并保存SSL证书信息..."
          save_certificates "$secret_id" "$secret_key" "$region" "$token"
          ;;
      renew)
          log_info "重新申请并保存SSL证书信息..."
          renew_certificates
          ;;
      deploy)
          log_info "下载与部署SSL证书..."
          deploy_nginx_ssl
          ;;
      *)
          log_error "未知的执行模式: $mode. 支持的模式有: save, renew, deploy"
          exit 1
          ;;
    esac
}

# 执行主函数
main ${1:-save}