# Liuying Music · Nginx 完整站点配置（安装期，标准 conf.d 模式）
# 由自动安装程序生成；安装成功后会切换为不含 /install 的正式版本。
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
