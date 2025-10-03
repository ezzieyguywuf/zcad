# ZCAD TODO List

This file tracks planned architectural improvements and new features.

## Misc

- [ ] Do real logging, stop sprinkling std.debug.print all over the place
- [ ] Flesh out X11 renderer
- [ ] window decorations
- [ ] UI elements like buttons and menus
- [ ] headless mode

## Architectural Refactoring

- [x] Minimize logic in `main.zig` to improve testability and reduce the chance
  of errors like resource leaks. Move setup and teardown logic into a more
  structured application context.
- [ ] Implement a Polyline rendering pipeline to efficiently draw curves made of
  many small segments, avoiding the overdraw of the current endcap approach.
- [ ] Consider migrating the HTTP API from raw URL parameters to a schema-based
  system like Protocol Buffers for more robust and extensible communication.
- [ ] Figure out where it makes the most sense to put World and Tesselator:
  `World.World` doesn't feel right
- [ ] support windows and macos with vulkan renderer
- [ ] maybe D3D12 and Metal renderers for window/mac respectively

## B-Rep Modeling

- [ ] Define a `Surface` geometric primitive.
- [ ] Implement the core B-rep topological entities (`Face`, `Edge`, `Vertex`,
  `Loop`, etc.) and link them to their corresponding geometry.
- [ ] Implement `World.removeGeometry` and a robust method for recalculating the
  scene's bounding box after deletions.
