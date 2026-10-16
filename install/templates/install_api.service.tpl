[Unit]
Description=Liuying Music web installer (temporary, self-disabled after success)
After=network.target

[Service]
Type=simple
WorkingDirectory=__ROOT__
ExecStart=/usr/bin/env python3 __ROOT__/install/install_api.py --root __ROOT__ --port __INSTALL_PORT__
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
