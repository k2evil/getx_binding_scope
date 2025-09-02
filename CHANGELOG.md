# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2025-09-02

### Added
- Initial release of GetX Binding Scope package
- `BindingScope` widget for scoped dependency injection
- `DI` facade class with automatic cleanup tracking
- Support for immediate registration with `DI.put()`
- Support for lazy registration with `DI.lazyPut()`
- Support for async registration with `DI.putAsync()`
- Support for factory registration with `DI.create()`
- Automatic cleanup of scoped dependencies on widget disposal
- First-registrant-wins behavior for async dependencies
- Nested scope support without ownership conflicts
- Router-agnostic design compatible with any routing solution
- Reverse-order dependency teardown for proper cleanup
- Comprehensive documentation with examples and migration guide

### Features
- Zero configuration setup
- Memory leak prevention through automatic cleanup
- Async-safe dependency registration
- Drop-in replacement for GetX bindings without navigation coupling
