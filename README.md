[![Zig Tests](https://github.com/ezzieyguywuf/zcad/actions/workflows/zig_test.yml/badge.svg)](https://github.com/ezzieyguywuf/zcad/actions/workflows/zig_test.yml)

Another attempt at my own Computer Aided Design (CAD) package.

# status

very much WIP. Currently I can render a few things (see demo).

# demo

Added faces and vertices as renderables - each with real mouse picking cpu-side.

https://github.com/user-attachments/assets/c2c1121b-57d6-4758-b99c-785caffa031e

<details>
  <summary> old demos </summary>

Real mouse picking: each line gets a UID cpu-side. These UIDs are passed along to the GPU. The GPU
writes these UIDs to a separate buffer, one UID for each pixel. Finally, that buffer is read back
CPU-side, and the coordinates of a click can be used to retrieve whether or not a line has been
clicked.

[Screen recording 2025-05-22 11.01.59 PM.webm](https://github.com/user-attachments/assets/1f146289-48bd-4059-b4f3-6e413bec7f28)

Proof-of-concept for mouse picking. Currently hard-coding "1" for each line, but this shows the data originating
from the fragment buffer and getting transferred and used on the cpu side.

[Screen recording 2025-03-27 10.37.16 PM.webm](https://github.com/user-attachments/assets/58a3ed53-2702-4dc8-a3e3-d77580c4a3ce)

Aliasing on left, AntiAliasing on the right

[Screen recording 2025-03-06 10.07.15 PM.webm](https://github.com/user-attachments/assets/f5e516ba-96fb-41df-93d1-37c347230246)

3d finally works

[Screen recording 2025-02-26 11.52.24 PM.webm](https://github.com/user-attachments/assets/2b1aa1c6-643b-42c8-b7cc-2698141c2e85)

3D is broken, the blue face is supposed to go back in the z-direction

[Screen recording 2025-02-25 11.50.29 PM.webm](https://github.com/user-attachments/assets/7437fba0-1c48-4e1d-a684-5e84ca2016a7)

Someone asked me how many FPS I get, so I measured it

[Screen recording 2025-02-25 10.17.14 AM.webm](https://github.com/user-attachments/assets/764aeec7-e55c-4c87-b46f-cff48a1ee19b)

3D lines

[Screen recording 2025-02-25 12.08.40 AM.webm](https://github.com/user-attachments/assets/6f855137-6480-4f0e-bd16-064cc84a815b)

I made a dot that doesn't change size or shape

[Screen recording 2025-02-20 2.05.30 PM.webm](https://github.com/user-attachments/assets/341ce543-2698-4a04-a3f0-e46aa0935843)

The wayland window can be resized now, and also closed gracefully

[Screen recording 2025-02-16 12.25.43 PM.webm](https://github.com/user-attachments/assets/9326298a-b482-4a93-8ecc-765e4e47b447)

Rotate left/right by left/right clicking

[Screen recording 2025-02-13 9.34.29 PM.webm](https://github.com/user-attachments/assets/c6257f9a-cae4-4032-bd67-2828d0bded77)

3D rotation, but it's pretty broken

[Screen recording 2025-02-10 11.09.21 PM.webm](https://github.com/user-attachments/assets/81e8bb22-1fbf-4c9e-852d-ebcd3d5c9f45)

</details>

## Development Environment with Docker

Using Docker provides a consistent development environment with all necessary
dependencies. You can either use our pre-built image from Docker Hub
(easier) or build the image locally (not that hard).

### Option 1: Use Pre-built Docker Hub Image (easier)

This is the quickest way to get started.

1. **Pull the image from Docker Hub:**

   ```bash
   docker pull ezzieyguywuf/zcad-dev:latest
   ```

1. **Run the Docker Container:**
   To start an interactive session, run the following command from the root of your repository:

   ```bash
   docker run --rm -it -v "$(pwd):/app" -w /app ezzieyguywuf/zcad-dev:latest /bin/bash
   ```

   - `--rm`: Automatically removes the container when you exit.
   - `-it`: Runs the container in interactive mode with a pseudo-TTY.
   - `-v "$(pwd):/app"`: Mounts your project's root directory into `/app` inside the container.
   - `-w /app`: Sets the working directory inside the container to `/app`.
   - `ezzieyguywuf/zcad-dev:latest`: The Docker Hub image to use.
   - `/bin/bash`: Starts a bash shell in the container.

### Option 2: Build Docker Image Locally

If you prefer to build the image yourself or want to customize it:

1. **Build the Docker Image:**
   Navigate to the root of the repository and run:

   ```bash
   docker build -t zcad-dev -f docker/Dockerfile .
   ```

   This will build an image named `zcad-dev` (you can change this tag if you like).

1. **Run the Locally Built Docker Container:**

   ```bash
   docker run --rm -it -v "$(pwd):/app" -w /app zcad-dev /bin/bash
   ```

   (Replace `zcad-dev` if you used a different tag when building).

### Develop Inside the Container

Once inside the container's bash shell (using either Option 1 or Option 2):

- You'll be in the `/app` directory (your project root).
- **Build the project:**
  ```bash
  zig build
  ```
- **Run unit tests:**
  ```bash
  zig build test
  ```
- Use `git`, `glslc`, etc., as they are installed in the environment.

## Build

### Needs zig

- Required Zig version: 0.14.0
- Download Zig from the official website: [https://ziglang.org/download/](https://ziglang.org/download/)
  - alternatively, consider using [zig version manager](https://github.com/tristanisham/zvm)
- Ensure that the `zig` executable is in your system's PATH.

The rest of these build instructions assume you already have zig installed and
working.

```bash
$ zig version
0.14.0
```

### System Dependencies

- General:

  - `git`
  - `pkg-config`
  - `glslc`

- Libraries:

  - Wayland
  - Vulkan
  - X11

  If you don't have a vulkan-enabled graphics card, I've had success using the
  [mesa llvmpipe](https://docs.mesa3d.org/drivers/llvmpipe.html) software vulkan
  rasterizer.

### Distribution-Specific Installation

Below are example commands for installing the necessary dependencies on various Linux distributions.

#### Ubuntu/Debian

`ca-certificates` seems to be needed by `zig build` whenever it fetches
dependencies, I guess for security.

`pkg-config` seems to be needed by zig-wayland

```bash
sudo apt-get update && sudo apt-get install -y \
    build-essential \
    ca-certificates \
    pkg-config \
    libwayland-dev \
    wayland-protocols \
    libvulkan-dev \
    libx11-dev \
    glslc
```

#### Arch Linux

I didn't seem to need the `ca-certificates` package when I tested this in an
`archlinux:latest` docker image, but your mileage may vary.

`vulkan-icd-loader` is needed for the vulkan library that does the dynamic
runtime driver stuff. 🤷

`shaderc` contains the `glslc` binary

```bash
sudo pacman -Syu --needed --noconfirm \
    pkgconf \
    wayland \
    wayland-protocols \
    vulkan-headers \
    vulkan-icd-loader \
    libx11 \
    shaderc
```

#### Gentoo

```bash
sudo emerge -av \
    dev-util/pkgconf \
    dev-libs/wayland \
    dev-libs/wayland-protocols \
    media-libs/vulkan-headers \
    media-libs/vulkan-loader \
    x11-libs/libX11 \
    media-gfx/shaderc
```

Note: `glslc` is provided by the `media-gfx/shaderc` package. Ensure your system profile is appropriate (e.g., includes `make`).

#### Fedora

```bash
sudo dnf install -y \
    pkgconf-pkg-config \
    wayland-devel \
    wayland-protocols-devel \
    vulkan-devel \
    libX11-devel \
    glslc
```

### Building the Project

This project uses Zig to manage the build process. Once you have installed Zig and the necessary system dependencies, you can build the project by running the following command in the root directory of the project:

```bash
zig build
```

# previous work

Previous attempts include [mycad](https://github.com/mycad-org/mycad-base)
(written in c++), [rcad](https://github.com/ezzieyguywuf/rcad) (written in
rust), and [mycad](https://github.com/ezzieyguywuf/mycad) written in haskell.

Actually the order was:

1. mycad in haskell
1. mycad in c++
1. rcad in rust

Those repositories/readmes probably include some interesting context/history.
