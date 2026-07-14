# nginx-easy-deploy

一个面向小型服务器和新手用户的原生 Nginx 一键脚本。

它不安装面板、不运行数据库，也不会常驻额外的管理服务。脚本只负责安装系统软件包、生成标准 Nginx 配置、管理 HTTPS，以及导出/恢复配置和证书。退出脚本后，所有站点仍然可以直接通过 `/etc/nginx` 维护。

## 功能

- 中文交互菜单
- 安装原生 Nginx 和 Certbot
- 一键创建反向代理站点
- 一键创建静态网站
- 自动申请和续签 Let's Encrypt 证书
- 上传并安装自有证书，可选单独证书链
- 检查证书格式、有效期、域名和公私钥匹配
- 导出 Nginx 配置、证书、外部 include 和 ACME 数据
- 新服务器一键恢复，恢复前自动创建回滚包
- 配置写入后先运行 `nginx -t`，失败时恢复原文件

## 支持范围

主要支持：

- Debian / Ubuntu
- CentOS / RHEL
- Rocky Linux / AlmaLinux
- 使用 systemd 的原生 Nginx

不支持 Docker、Nginx Proxy Manager、宝塔中的定制 Nginx 和 Kubernetes。OpenResty 配置可以导出，但恢复前需要自行安装兼容的 OpenResty 版本。

## 安装

推荐先下载再执行，便于检查脚本内容：

```bash
sudo curl -fL \
  https://raw.githubusercontent.com/sanrokamlan-prog/nginx-easy-deploy/main/nginx-easy-deploy.sh \
  -o /usr/local/sbin/nginx-easy-deploy
sudo chmod +x /usr/local/sbin/nginx-easy-deploy
sudo nginx-easy-deploy
```

直接运行且不带参数时，会打开中文菜单：

```bash
sudo bash nginx-easy-deploy.sh
```

## 命令行用法

安装 Nginx 和 Certbot：

```bash
sudo nginx-easy-deploy install
```

反向代理本机 `3000` 端口并申请 HTTPS：

```bash
sudo nginx-easy-deploy proxy app.example.com 3000 \
  --email you@example.com
```

也可以填写完整上游地址：

```bash
sudo nginx-easy-deploy proxy app.example.com http://127.0.0.1:3000 \
  --email you@example.com
```

部署静态网站：

```bash
sudo nginx-easy-deploy static example.com /var/www/example.com \
  --email you@example.com
```

只部署 HTTP：

```bash
sudo nginx-easy-deploy proxy app.example.com 3000 --no-ssl
```

以后再启用 Let's Encrypt：

```bash
sudo nginx-easy-deploy ssl app.example.com you@example.com
```

## 自有证书

上传 `fullchain.pem` 和 `privkey.pem` 到服务器后执行：

```bash
sudo nginx-easy-deploy cert example.com \
  /root/certs/fullchain.pem \
  /root/certs/privkey.pem
```

证书和中间证书链是两个文件时：

```bash
sudo nginx-easy-deploy cert example.com \
  /root/certs/cert.pem \
  /root/certs/privkey.pem \
  --chain /root/certs/chain.pem
```

脚本会把文件安装到 `/etc/nginx/ssl/<域名>/`。自有证书不会由 Certbot 自动续签，到期前需要重新执行 `cert` 命令。

## 导出与迁移

旧服务器执行：

```bash
sudo nginx-easy-deploy export --encrypt
```

上传生成的 `.tar.gz.enc` 文件和本脚本到新服务器，然后执行：

```bash
sudo bash nginx-easy-deploy.sh restore ngx-migrate-host-date.tar.gz.enc
```

默认迁移内容包括：

- Nginx 主配置和所有已加载的 include 文件
- Nginx 配置引用的证书、私钥、DH 参数和密码文件
- `/etc/letsencrypt`、Certbot 续签数据和 acme.sh 目录
- Nginx systemd override 和日志轮转配置
- Nginx 版本、编译参数、系统及软件包清单

静态站点文件默认不会打包。需要一起迁移时：

```bash
sudo nginx-easy-deploy export --encrypt --with-webroot
```

也可以额外指定目录：

```bash
sudo nginx-easy-deploy export --encrypt --include /srv/my-site
```

恢复时会先把新机现有文件保存到：

```text
/var/backups/ngx-migrate/pre-restore-YYYYMMDD-HHMMSS.tar.gz
```

随后才会替换配置、执行 `nginx -t` 并启动服务。失败时脚本会尝试自动回滚。

## 其他管理命令

```bash
sudo nginx-easy-deploy sites
sudo nginx-easy-deploy status
sudo nginx-easy-deploy renew
sudo nginx-easy-deploy delete example.com
sudo nginx-easy-deploy delete example.com --delete-cert
```

## 迁移注意事项

- 迁移包包含 TLS 私钥，建议始终使用 `--encrypt`。
- 新旧服务器尽量使用相同发行版和 Nginx 模块。
- 脚本不会迁移反代目标应用、数据库、Docker 容器或 DNS 记录。
- 申请 Let's Encrypt 前，域名必须指向当前服务器，80/443 端口必须可访问。
- 生产服务器迁移前应先在临时机器验证恢复流程。

## License

[MIT](LICENSE)
