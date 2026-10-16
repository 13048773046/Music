[Unit]
Description=Liuying Music source bridge (NodeJS, 127.0.0.1:__BRIDGE_PORT__)
After=network.target

[Service]
Type=simple
WorkingDirectory=__ROOT__/source-bridge
Environment=BRIDGE_PORT=__BRIDGE_PORT__
Environment=SOURCE_FILE=__ROOT__/source-bridge/source.js
Environment=QS_SESSION_FILE=__ROOT__/source-bridge/qs_session.json
ExecStart=/usr/bin/env node __ROOT__/source-bridge/bridge.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
