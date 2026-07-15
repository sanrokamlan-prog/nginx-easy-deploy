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
- 查看 Nginx 当前证书的到期时间和风险状态
- 使用 Cloudflare DNS 自动申请、续签通配符证书
- 自动更新 Cloudflare IP 段，让访问日志记录真实访客 IP
- 检查系统环境、Nginx、端口、域名解析和公网 IP
- 删除站点前自动持久备份配置和证书，可选备份静态文件
- 导出 Nginx 配置、证书、外部 include 和 ACME 数据
- 新服务器一键恢复，恢复前自动创建回滚包
- 配置写入后先运行 `nginx -t`，失败时恢复原文件
- 可选的保守系统调优，以及备份后更新 Nginx

## 支持范围

主要支持：

- Debian / Ubuntu
- CentOS / RHEL
- Rocky Linux / AlmaLinux
- 使用 systemd 的原生 Nginx

不支持 Docker、Nginx Proxy Manager、宝塔中的定制 Nginx 和 Kubernetes。OpenResty 配置可以导出，但恢复前需要自行安装兼容的 OpenResty 版本。

## 下载并运行

推荐先下载再执行，便于检查脚本内容：

```bash
curl -fL \
  https://raw.githubusercontent.com/sanrokamlan-prog/nginx-easy-deploy/main/nginx-easy-deploy.sh \
  -o nginx-easy-deploy.sh
sudo bash nginx-easy-deploy.sh
```

脚本不带参数运行时会打开中文菜单，不会安装或常驻一个管理程序。

希望以后直接输入 `nginx-easy-deploy` 时，可以自行复制到 PATH；这只是可选快捷方式：

```bash
sudo install -m 755 nginx-easy-deploy.sh /usr/local/sbin/nginx-easy-deploy
sudo nginx-easy-deploy
```

## 命令行用法

安装 Nginx 和 Certbot：

```bash
sudo bash nginx-easy-deploy.sh install
```

反向代理本机 `3000` 端口并申请 HTTPS：

```bash
sudo bash nginx-easy-deploy.sh proxy app.example.com 3000 \
  --email you@example.com
```

也可以填写完整上游地址：

```bash
sudo bash nginx-easy-deploy.sh proxy app.example.com http://127.0.0.1:3000 \
  --email you@example.com
```

部署静态网站：

```bash
sudo bash nginx-easy-deploy.sh static example.com /var/www/example.com \
  --email you@example.com
```

只部署 HTTP：

```bash
sudo bash nginx-easy-deploy.sh proxy app.example.com 3000 --no-ssl
```

以后再启用 Let's Encrypt：

```bash
sudo bash nginx-easy-deploy.sh ssl app.example.com you@example.com
```

## 自有证书

上传 `fullchain.pem` 和 `privkey.pem` 到服务器后执行：

```bash
sudo bash nginx-easy-deploy.sh cert example.com \
  /root/certs/fullchain.pem \
  /root/certs/privkey.pem
```

证书和中间证书链是两个文件时：

```bash
sudo bash nginx-easy-deploy.sh cert example.com \
  /root/certs/cert.pem \
  /root/certs/privkey.pem \
  --chain /root/certs/chain.pem
```

脚本会把文件安装到 `/etc/nginx/ssl/<域名>/`。自有证书不会由 Certbot 自动续签，到期前需要重新执行 `cert` 命令。

## Cloudflare DNS 证书

适合域名开启了 Cloudflare 代理、80 端口不方便开放，或需要通配符证书的场景。先创建只允许目标域名 `Zone:DNS:Edit` 的 Cloudflare API Token，再准备凭据文件：

```ini
dns_cloudflare_api_token = YOUR_API_TOKEN
```

为已有站点申请 `example.com` 和 `*.example.com` 证书：

```bash
chmod 600 cloudflare.ini
sudo bash nginx-easy-deploy.sh dns-ssl example.com you@example.com \
  cloudflare.ini --wildcard
```

脚本会把凭据安全保存到 `/etc/letsencrypt/cloudflare/`，供 Certbot 自动续签使用。Token 不会出现在命令参数或日志里。

## Cloudflare 真实访客 IP

开启 Cloudflare 代理后，执行：

```bash
sudo bash nginx-easy-deploy.sh cf-realip
```

脚本从 Cloudflare 官方地址下载 IPv4/IPv6 段，校验后生成 Nginx `real_ip` 配置。需要每周自动更新时：

```bash
sudo bash nginx-easy-deploy.sh cf-realip --schedule
```

它使用系统的每周任务，不运行常驻进程。删除脚本管理的配置和任务：

```bash
sudo bash nginx-easy-deploy.sh cf-realip --remove
```

## 导出与迁移

旧服务器执行：

```bash
sudo bash nginx-easy-deploy.sh export --encrypt
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
sudo bash nginx-easy-deploy.sh export --encrypt --with-webroot
```

也可以额外指定目录：

```bash
sudo bash nginx-easy-deploy.sh export --encrypt --include /srv/my-site
```

恢复时会先把新机现有文件保存到：

```text
/var/backups/ngx-migrate/pre-restore-YYYYMMDD-HHMMSS.tar.gz
```

随后才会替换配置、执行 `nginx -t` 并启动服务。失败时脚本会尝试自动回滚。

## 其他管理命令

```bash
sudo bash nginx-easy-deploy.sh sites
sudo bash nginx-easy-deploy.sh status
sudo bash nginx-easy-deploy.sh doctor example.com
sudo bash nginx-easy-deploy.sh certs
sudo bash nginx-easy-deploy.sh renew
sudo bash nginx-easy-deploy.sh delete example.com
sudo bash nginx-easy-deploy.sh delete example.com --delete-cert
sudo bash nginx-easy-deploy.sh delete example.com --backup-files
```

删除站点前的持久备份保存在 `/var/backups/nginx-easy-deploy/sites/`。

可选的保守调优只提高偏低的连接队列和文件上限，并设置 Nginx systemd 文件限制；不会降低已有参数，也不会修改 Swap、THP 或防火墙：

```bash
sudo bash nginx-easy-deploy.sh tune
sudo bash nginx-easy-deploy.sh tune --bbr
sudo bash nginx-easy-deploy.sh tune --restore latest
```

BBR 不会默认启用，只有明确添加 `--bbr` 且当前内核支持时才会设置。

使用系统软件源更新 Nginx 前自动创建完整备份：

```bash
sudo bash nginx-easy-deploy.sh update
```

## 迁移注意事项

- 迁移包包含 TLS 私钥，建议始终使用 `--encrypt`。
- 新旧服务器尽量使用相同发行版和 Nginx 模块。
- 脚本不会迁移反代目标应用、数据库、Docker 容器或 DNS 记录。
- 申请 Let's Encrypt 前，域名必须指向当前服务器，80/443 端口必须可访问。
- 生产服务器迁移前应先在临时机器验证恢复流程。

## License

[MIT](LICENSE)
