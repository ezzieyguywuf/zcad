# ZCAD TODO List

This file tracks planned architectural improvements and new features.

## Bugs

- [ ] Why does bench.py crash on my laptop at ~4200 lines when sending one line
  at a time. batching by 100 lines at a time does not crash
- [ ] maybe start using github issues

## Misc

- [ ] Do real logging, stop sprinkling std.debug.print all over the place
- [ ] Flesh out X11 renderer
- [ ] window decorations
- [ ] UI elements like buttons and menus
- [ ] headless mode
- [ ] how to shrink bounding box?
- [ ] limit zooming based on collision with a solid.
- [ ] finish fleshing out the "unitless" approach - we store our data as i64 to
  try to maximize precision. we convert to float when we upload to the GPU.
  currently, this conversion loses all our precision: we force ourselves to
  use high integer values for high precision, which is fine ,but then
  convert them to big floats, which have lower precision than lil floats.
  Instead, we should store a conversion constant (e.g. if 1000 "units"
  equals "1", we store that somewhere) so that we can divide and _then_
  convert to float

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

- [ ] Make `window_ctx` in `HttpServer.ServerContext` optional (`?*WindowingContext`) to support headless mode where no window exists.
