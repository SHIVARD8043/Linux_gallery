# 🖼️ Shiva's Gallery

A high-performance, native Linux desktop photo and video gallery application built with Flutter. Designed for extreme speed, low RAM/CPU usage, and seamless handling of large external hard drives.

## ✨ Features

*   **🚀 Jet-Fast Performance:** Uses isolated background scanning, disk-based JSON indexing, and `RepaintBoundary` optimizations to load tens of thousands of HD photos without freezing or spiking CPU/RAM.
*   **🍏 Native HEIC/HEIF Support:** Seamlessly views iPhone photos on Linux via on-the-fly conversion and caching using `libheif`.
*   **🎬 MPV Video Integration:** Zero-overhead video playback! Videos open instantly in the native `mpv` player for flawless 4K/HDR playback without bloating the app.
*   **📅 Smart Grouping:** Groups photos dynamically by date (Today, Yesterday, Specific Date, Month) just like Google Photos.
*   **💾 External Drive Support:** Detects external drives and unmounted partitions. Includes one-click mounting via `udisksctl`.
*   **🖼️ Fullscreen Viewer:** Interactive viewer with smooth zooming, Left/Right arrow key navigation, and detailed EXIF/Metadata info (Path, Size, Date).
*   **🌓 Adaptive Theme:** Clean UI with Dark/Light mode support.

## 🛠️ Prerequisites & Dependencies

Since this app leverages powerful Linux native tools for maximum performance, you need to install the following dependencies on your Ubuntu/Debian system before running or building the app:

```bash
# Update package list
sudo apt update

# Install required dependencies
# 1. mpv: For high-performance video playback
# 2. libheif-examples: Provides 'heif-convert' for iPhone photo support
# 3. ffmpeg: For generating lightweight video thumbnails
# 4. udisks2: For auto-mounting external drives
sudo apt install mpv libheif-examples ffmpeg udisks2
```

## 🚀 How to Build & Run

### Running in Debug/Dev Mode
To run the app locally for testing:
```bash
flutter pub get
flutter run -d linux
```

### Building the Release Version
To build a highly optimized, standalone executable for Linux:
```bash
flutter build linux --release
```
*Once the build is complete, you can find the executable file inside:*
`build/linux/x64/release/bundle/`

Simply double-click the `shivas_gallery` executable in that folder, or run it via terminal!

## 🤝 Contributing
Built with ❤️ for a lightning-fast Linux desktop experience.