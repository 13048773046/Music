# Liuying Music · Nginx 完整站点配置（正式，标准 conf.d 模式）
# 由自动安装程序生成；HTTPS/证书建议在宝塔面板申请后由面板管理 443。
server {
    listen 80;
    server_name __DOMAIN__;

    root __ROOT__/web;
    index index.html;
    client_max_body_size 100m;

__LOCATIONS__

    # 官网落地页（静态）
    location / {
        try_files $uri $uri/ /index.html;
    }
}
