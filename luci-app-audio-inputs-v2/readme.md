luci-app-audio-inputs/ 

├── Makefile                                     ← OpenWrt feed package

├── install.sh                                   ← SSH installer/uninstaller

├── README.md

└── files/

    ├── usr/libexec/

    │   └── alsa-inputs-json                     ← backend shell script (chmod 755)

    ├── usr/share/rpcd/acl.d/

    │   └── luci-app-audio-inputs.json           ← rpcd ACL grant

    ├── usr/share/luci/menu.d/

    │   └── luci-app-audio-inputs.json           ← LuCI menu entry (Status → Audio Inputs)

    └── www/luci-static/resources/view/status/
        └── audio_inputs.js                      ← LuCI JS view (view.extend)
