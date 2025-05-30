# SSL证书管理工具

这是一个用于管理腾讯云SSL证书的命令行工具，支持自动获取证书列表、查询证书详细信息、计算证书有效期等功能。

## 功能特性

- 自动获取账号下的所有证书列表
- 支持通过配置文件指定特定证书ID
- 查询证书详细信息，包括域名、状态、有效期等
- 自动计算证书剩余有效期
- 支持状态码到文字描述的自动转换
- JSON格式保存详细信息
- 完整的调试日志支持

## 依赖要求

工具依赖以下命令行工具：
- curl：用于发送API请求
- openssl：用于签名计算
- jq：用于JSON处理
- date：用于日期计算
- iconv：用于字符编码转换

## 配置文件

工具使用`config.ini`配置文件，包含以下配置项：

```ini
[common]
# 腾讯云API密钥信息（必需）
secret_id=YourSecretId
secret_key=YourSecretKey
# API区域（可选）
region=ap-guangzhou
# 临时token（可选）
token=
# 是否开启调试模式：0-关闭，1-开启
debug=0

[certificates]
# 证书ID列表（可选）
# 如果不配置，工具会自动获取账号下所有证书
cert1=YourCertificateId1
cert2=YourCertificateId2
# cert3=YourCertificateId3

[status]
# 证书状态码映射
0=审核中
1=已通过
2=审核失败
3=已过期
4=自动添加DNS记录
5=企业证书，待提交资料
6=订单取消中
7=已取消
8=已提交资料，待上传确认函
9=证书吊销中
10=已吊销
11=重颁发中
12=待上传吊销确认函
13=免费证书待提交资料
14=证书已退款
15=证书迁移中
```

## 使用方法

1. 准备配置文件：
   ```bash
   # 复制示例配置文件
   cp config.ini.example config.ini
   
   # 编辑配置文件，填入你的API密钥信息
   vim config.ini
   ```

2. 设置执行权限：
   ```bash
   chmod +x ssl_manager.sh
   ```

3. 运行工具：
   ```bash
   ./ssl_manager.sh
   ```

### 两种使用模式

1. **自动模式**：
   - 不在config.ini的[certificates]部分配置任何证书ID
   - 工具将自动获取账号下所有证书并查询信息

2. **指定证书模式**：
   - 在config.ini的[certificates]部分配置特定的证书ID
   - 工具将只查询指定的证书信息

## 输出说明

1. **控制台输出**：
   ```
   ----------------------------------------
   证书ID: 证书ID1
   域名: example.com
   状态: 已通过 (代码: 1)
   开始时间: 2023-01-01 00:00:00
   结束时间: 2024-01-01 00:00:00
   剩余有效期: 180天
   ----------------------------------------
   ```

2. **JSON输出**：
   - 每个证书的详细信息会保存在`output/证书ID.json`文件中
   - JSON格式包含完整的API响应数据
   ```json
   {
     "CertificateId": "证书ID",
     "Domain": "example.com",
     "Status": 1,
     "CertBeginTime": "2023-01-01 00:00:00",
     "CertEndTime": "2024-01-01 00:00:00",
     "InsertTime": "2023-01-01 00:00:00",
     "RequestId": "xxxxxx-xxxxx-xxxxx-xxxxx"
   }
   ```

## 调试模式

1. 在config.ini中设置`debug=1`开启调试模式
2. 调试模式将输出：
   - API请求详情
   - 签名计算过程
   - 服务器响应数据
   - 数据处理过程

## 错误处理

工具会处理常见的错误情况：
1. 配置文件缺失或格式错误
2. API密钥未配置
3. API调用失败
4. 证书ID不存在
5. 依赖工具缺失

遇到错误时，工具会：
1. 输出带颜色的错误信息
2. 提供错误原因说明
3. 在调试模式下输出详细信息

## 注意事项

1. 请妥善保管API密钥信息
2. 建议定期运行工具检查证书状态
3. 对于即将过期的证书，及时进行续期操作
4. 保持output目录中的JSON文件，可用于历史记录查询