# Radded's Mac Mini Home Assistant OS scripts

A tool to make Home Assistant OS a tolerable experience on an older Intel Mac Mini with Nvidia chipset (2011, MacMini4,1).

This script needs to run on system bootup with root level permissions and does the following:
1. Enables "Start up automatically after a power failure" which normally could only be enabled in MacOS
    - Done by resetting the SMC bit that MacOS normally would set if you enable this feature
2. Applies a quiet fan curve
    - Perfect for those of us who have a broken or missing temperature sensor somewhere

How to run:
1. Using a keyboard and display (or the developer SSH port 22222 method), obtain a root shell into your installation
    - Note: The "Terminal and SSH" addon is not sufficient here since that addon still runs within a Docker container.
2. Type and run the command
    - `curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install-macmini-tuning.sh | bash`
3. If needed, you can uninstall or check status with
    - `curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install-macmini-tuning.sh | bash -s -- status`
    - `curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install-macmini-tuning.sh | bash -s -- uninstall`