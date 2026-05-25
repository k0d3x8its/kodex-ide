# 📋 Requirements

This Neovim configuration works on macOS, Ubuntu (PC/WSL), and Raspberry Pi. Follow the steps below to make sure you have all the necessary dependencies installed.

## 🔧 1. System Requirements

- Neovim: ```>= 0.11.0```
    - check your version:
        ```sh
        nvim --version
        ```
- **Git** → required for plugin management (```lazy.nvim```)
- **Build tools** → needed to compile certain plugins

## 🐧 2. Ubuntu (PC & WSL)

- Install dependencies:
    ```sh
    sudo apt update
    sudo apt install -y \
      build-essential \
      curl wget unzip \
      git \
      xclip \
      ripgrep \
      fd-find \
      luarocks \
      nodejs npm \
      python3 python3-pip \
      gcc g++ make
    ```
- Symlink fd to fdfind (Ubuntu quirk):
    ```sh
    sudo ln -s $(which fdfind) /usr/local/bin/fd
    ```
## 🍎 3. macOS (with Homebrew)

- Install dependencies
    ```sh
    brew install \
      neovim \
      git \
      gcc \
      ripgrep \
      fd \
      luarocks \
      node \
      python
    ```
- Clipboard support is built-in (*pbcopy/pbpaste*)

## 🥧 4. Raspberry Pi (Ubuntu server)

**⚠️Note:** Since official repos often lag behind, you ma need to build Neovim from source.

- First, install dependencies:
    ```sh
    sudo apt update
    sudo apt install -y \
    ninja-build \
    gettext \
    cmake \
    unzip curl \
    build-essential \
    git \
    xclip \
    ripgrep \
    fd-find \
    luarocks \
    nodejs npm \
    python3 python3-pip \
    gcc g++ make
    ```
- Then build Neovim (*if latest version isn't available via apt*):
    ```sh
    git clone https://github.com/neovim/neovim
    cd neovim
    git checkout stable
    make CMAKE_BUILD_TYPE=Release
    sudo make install
    ```

## ⚡5. Language Server Protocol (LSP) Support

- Many LSP servers require these runtimes:
    - **Node.js** → JavaScript, TypeScript, HTML, CSS, etc.
    - **Python 3 + pip** → Python development
    - **Rust (*cargo*)** → Rust tooling
    - **C/C++ compilers (*gcc/clang/zig*)** → C, C++, Zig, and for building some servers

## ✅ 6. Verification

- After installation, run:
    ```sh
    nvim --version
    git --version
    rg --version
    fd --version
    node --version
    npm --version
    python3 --version
    ```
- You should see valid version numbers for each.

# 📦 Installation

**⚠️Note:** This configuration assumes all your projects live inside ```~/dev```. If this directory doesn't exist, create it before continuing:

```sh
    mkdir -p ~/dev
```

## 1. Clone the repository

```sh
    cd ~/dev
    git clone git@github.com:k0d3x8its/kodex-ide.git
```

## 2. Backup any existing config

```sh
    mv ~/.config/nvim ~/.config/nvim.backup 2>/dev/null || true
```

## 3. Symlink your config

```sh
    ln -s ~/dev/kodex-ide ~/.config/nvim
```

## 4. Open Neovim

```sh
    nvim
```

The first time you open Neovim, lazy.nvim will automatically install all plugins. Wait until it finishes, then restart Neovim.

# 🛠️ Troubleshooting

 Here are some common issues and fixes:
- ```No C compiler found!``` during plugin/LSP install
    - **Ubuntu** → ```sudo apt install build-essential```
    - **macOS** → ```brew install gcc```
- ```ripgrep not installed```
    - **Ubuntu** → ```sudo apt install ripgrep```
    - **macOS** → ```brew install ripgrep```
- ```fd not installed```
    - **Ubuntu**:
        ```sh
            sudo apt install fd-find
            sudo ln -s "$(command -v fdfind)" /usr/local/bin/fd
        ```
    - **macOS** → ```brew install fd-find```
- Clipboard not working
    - **Ubuntu X11** → ```sudo apt install xclip```
    - **Ubuntu Wayland** → ```sudo apt install wl-clipboard```
    - **macOS** → built-in (```pbcopy```/```pbpaste```)
    - **WSL** → use clip.exe
- Neovim too old (0.9.x shows)
    - **Raspberry Pi** → build from source (*see above*)
    - **macOS** → ```brew upgrade neovim```
    - **Ubuntu** → use a newer PPA or build from source
- ```luarocks``` warnings (*Lua 5.1 deprecated*)
    - Keep ```luarocks``` updated via your package manager
    - Many plugins no longer require customer rocks; prcoeed unless an installer explicitly fails
- ```mason``` fails to install servers
    - Ensure Node, Python, and compilers are installed (*see Requirements*)
    - **Retry** → ```:Mason```, then reinstall the failed package
    - **Checklogs** → ```:Mason```, press ```l``` package for logs

