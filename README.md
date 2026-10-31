![Repo size](https://img.shields.io/github/repo-size/eco-by-different/Eco-Media-server)
![Last commit](https://img.shields.io/github/last-commit/eco-by-different/Eco-Media-server)

# Eco Media Server

A lightweight, portable, and lightning-fast local DLNA/UPnP media server packed into a single executable. Designed for ultimate privacy and efficiency with zero setup required.

Built as part of the **eco-by-different** utility collection.

## Antivirus Notice (False Positives)

The `.exe` binary is generated, which some sensitive antivirus engines, including Windows Defender or machine-learning based scanners, may flag as a false positive.

The underlying PowerShell script is clean. If your system blocks the `.exe`, you can safely run the raw `Eco Media Server.ps1` script instead.

## Screenshot

![Eco-Media-server 1.0](Eco%20Media%20Server.png)

## Key Features
* **Single-file Architecture:** No installation, no registry bloat, and a tiny footprint of just ~66 KB.
* **Drag & Drop Interface:** Simply drop your video, audio, or image files directly into the window.
* **Instant Streaming:** Smart TVs, mobile devices, and media players (like VLC) on the same Wi-Fi/LAN network will automatically discover the server and start streaming instantly.
* **No Admin Rights Needed:** Runs completely in user mode. No UAC elevation or complex Windows Firewall rule tweaks required.
* **100% Private:** No cloud, no accounts, no data collection (LOCAL | PRIVATE | NO CLOUD).

*Note: On the first launch, Windows Firewall will prompt you to allow network access. Make sure to check **Private networks** so your Smart TV or other devices can discover and connect to the server.*

## How to Run
Simply download and run `EcoMediaServer.exe`. 

*Note: Under the hood, it utilizes an optimized PowerShell script paired with a WPF graphical user interface and an embedded C# network engine compiled directly at runtime.*

## License
This project is licensed under the **MIT License** — feel free to modify, share, and use the code as you wish, provided that the original author credit remains intact.
