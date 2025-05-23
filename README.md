[![Zig Tests](https://github.com/ezzieyguywuf/zcad/actions/workflows/zig_test.yml/badge.svg)](https://github.com/ezzieyguywuf/zcad/actions/workflows/zig_test.yml)

Another attempt at my own Computer Aided Design (CAD) package.

# status

very much WIP. Currently I can render a few things (see demo).

# demo

Proof-of-concept for mouse picking. Currently hard-coding "1" for each line, but this shows the data originating from the fragment buffer and getting transferred and used on the cpu side.

[Screen recording 2025-03-27 10.37.16 PM.webm](https://github.com/user-attachments/assets/58a3ed53-2702-4dc8-a3e3-d77580c4a3ce)


<details>
  <summary> old demos </summary>
  
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

1.  **Pull the image from Docker Hub:**
    ```bash
    docker pull ezzieyguywuf/zcad-dev:latest
    ```

2.  **Run the Docker Container:**
    To start an interactive session, run the following command from the root of your repository:
    ```bash
    docker run --rm -it -v "$(pwd):/app" -w /app ezzieyguywuf/zcad-dev:latest /bin/bash
    ```
    *   `--rm`: Automatically removes the container when you exit.
    *   `-it`: Runs the container in interactive mode with a pseudo-TTY.
    *   `-v "$(pwd):/app"`: Mounts your project's root directory into `/app` inside the container.
    *   `-w /app`: Sets the working directory inside the container to `/app`.
    *   `ezzieyguywuf/zcad-dev:latest`: The Docker Hub image to use.
    *   `/bin/bash`: Starts a bash shell in the container.

### Option 2: Build Docker Image Locally

If you prefer to build the image yourself or want to customize it:

1.  **Build the Docker Image:**
    Navigate to the root of the repository and run:
    ```bash
    docker build -t zcad-dev -f docker/Dockerfile .
    ```
    This will build an image named `zcad-dev` (you can change this tag if you like).

2.  **Run the Locally Built Docker Container:**
    ```bash
    docker run --rm -it -v "$(pwd):/app" -w /app zcad-dev /bin/bash
    ```
    (Replace `zcad-dev` if you used a different tag when building).

### Develop Inside the Container

Once inside the container's bash shell (using either Option 1 or Option 2):

-   You'll be in the `/app` directory (your project root).
-   **Build the project:**
    ```bash
    zig build
    ```
-   **Run unit tests:**
    ```bash
    zig build test
    ```
-   Use `git`, `glslc`, etc., as they are installed in the environment.

# previous work

Previous attempts include [mycad](https://github.com/mycad-org/mycad-base)
(written in c++), [rcad](https://github.com/ezzieyguywuf/rcad) (written in
rust), and [mycad](https://github.com/ezzieyguywuf/mycad) written in haskell.

Actually the order was:

1. mycad in haskell
2. mycad in c++
3. rcad in rust

Those repositories/readmes probably include some interesting context/history.
