# Pixe

```
 ┌─┬─┬─┐
 │█│░│█│  P I X E
 │░│█│░│  GPU-accelerated image viewer for macOS
 │█│░│█│
 └─┴─┴─┘
```

A fast, GPU-accelerated image viewer for macOS built with Swift and Metal.

Pixe handles thousands of images efficiently with smart memory management, thumbnail caching, and two viewing modes — a grid browser and a full image viewer.

## Features

- **Thumbnail grid** with keyboard navigation and smooth scrolling
- **Full image viewer** with zoom, pan, and prefetching
- **RAW support** — ARW, CR2, CR3, NEF, RAF, ORF, RW2, DNG, PEF, SRW, X3F (instant embedded preview, full decode in background)
- **Display-resolution aware loading** — images downsampled to viewport size to keep memory bounded
- **LRU thumbnail cache** with optional disk persistence (`~/.cache/pixe/thumbs/`)
- **Metal rendering** — no Core Image, no MTKTextureLoader, direct texture uploads

## Requirements

- macOS 13+ (Ventura)
- Xcode 15+ / Swift 6.0 toolchain

## Installation

### Using Make

```bash
git clone https://github.com/riadafridishibly/pixe.git
cd pixe
make install
```

This builds a release binary and installs it to `/usr/local/bin/pixe`. To install to a different location:

```bash
make install PREFIX=$HOME/.local
```

### Manual

```bash
git clone https://github.com/riadafridishibly/pixe.git
cd pixe
swift build -c release
cp .build/release/pixe /usr/local/bin/
```

### Uninstall

```bash
make uninstall
```

## Usage

```
pixe [options] <image|directory> ...
```

### Options

| Flag | Description |
|---|---|
| `--thumb-dir <path>` | Thumbnail cache directory (default: `~/.cache/pixe/thumbs`) |
| `--thumb-size <int>` | Max thumbnail size in pixels (default: 256) |
| `--no-cache` | Disable disk thumbnail cache |
| `--include <exts>` | Only show these extensions (e.g. `jpg,png`) |
| `--exclude <exts>` | Hide these extensions (mutually exclusive with `--include`) |
| `--clean-thumbs` | Delete thumbnail cache and exit |
| `--debug-mem` | Enable memory profiler event logging to stderr |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

SVG and PDF files are excluded by default.

### Examples

```bash
pixe ~/Pictures/vacation       # Browse a directory
pixe photo.jpg                 # View a single image
pixe *.jpg                     # View matching files
pixe --include=jpg,png ~/mixed # Only JPG and PNG
pixe --no-cache ~/project      # Skip disk cache
```

## Controls

### Thumbnail Mode

| Key | Action |
|---|---|
| `h` `j` `k` `l` / Arrow keys | Navigate grid |
| `Enter` | Open selected image |
| `g` / `G` | Jump to first / last |
| `n` / `p` | Page down / up |
| `Space` / Scroll | Page down / scroll |
| `d` | Delete image (move to trash) |
| `o` | Reveal in Finder |
| `i` | Toggle image info |
| `f` | Toggle fullscreen |
| `m` | Memory profiler |
| `q` | Quit |

### Image Mode

| Key | Action |
|---|---|
| `n` `Space` / `p` | Next / previous image |
| Arrow keys | Next / previous image |
| `+` `-` `0` | Zoom in / out / fit |
| Pinch / scroll | Zoom |
| Two-finger drag | Pan (when zoomed) |
| `g` / `G` | First / last image |
| `d` | Delete image (move to trash) |
| `o` | Reveal in Finder |
| `i` | Toggle image info |
| `f` | Toggle fullscreen |
| `m` | Memory profiler |
| `Enter` / `Escape` / `q` | Back to thumbnails |
