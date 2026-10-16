[Unit]
Description=Liuying Music backend (Python, 127.0.0.1:__API_PORT__)
After=network.target

[Service]
Type=simple
WorkingDirectory=__ROOT__
Environment=MUSIC_CONFIG=__ROOT__/config.json
ExecStart=/usr/bin/env python3 __ROOT__/server.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
