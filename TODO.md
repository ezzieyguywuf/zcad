# ZCAD TODO List

This file tracks planned architectural improvements and new features.

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

## B-Rep Modeling

- [ ] Define a `Surface` geometric primitive.
- [ ] Implement the core B-rep topological entities (`Face`, `Edge`, `Vertex`,
  `Loop`, etc.) and link them to their corresponding geometry.
- [ ] Implement `World.removeGeometry` and a robust method for recalculating the
  scene's bounding box after deletions.
