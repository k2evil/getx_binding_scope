# GetX Binding Scope

[![pub package](https://img.shields.io/pub/v/getx_binding_scope.svg)](https://pub.dev/packages/getx_binding_scope)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Scoped dependency injection for GetX — automatic cleanup, async safety, and nested bindings made easy.

## Overview

A lightweight package offering scoped dependency injection using GetX-style Bindings, but decoupled from `GetPage`. Register dependencies with `DI`, wrap widgets in `BindingScope`, and your dependencies are cleaned up automatically—no more lifecycle headaches.

Perfect for Flutter apps that want the power of GetX dependency injection without being locked into GetX navigation.

## ✨ Key Features

- 🗂 **Scoped DI**: Dependencies live only within their widget scope
- 🧹 **Automatic Cleanup**: Only deletes what a scope created - no memory leaks
- ⏳ **Async Safe**: First-registrant-wins behavior, handling `putAsync` races gracefully  
- 🔄 **Reverse-Order Teardown**: Maintains dependency integrity during cleanup
- 🏗️ **Nested Scopes**: Prevents ownership bleed between nested bindings
- 🚀 **Router-Agnostic**: Works with `go_router`, `auto_route`, Navigator 2.0, or any routing solution
- 🎯 **Zero Configuration**: Drop-in replacement for GetX bindings with zero setup

## 📦 Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  getx_binding_scope: ^1.0.0
  get: ^4.7.2
```

Then run:

```bash
flutter pub get
```

## 🚀 Quick Start

### 1. Define a Binding with `DI`

```dart
import 'package:getx_binding_scope/getx_binding_scope.dart';
import 'package:get/get.dart';

class HomeBinding extends Bindings {
  @override
  void dependencies() {
    // Immediate registration
    DI.put<Config>(Config());
    
    // Lazy registration (created when first accessed)
    DI.lazyPut<ApiService>(() => ApiService(DI.find<Config>()));
    
    // Async registration with automatic race condition handling
    DI.putAsync<UserSession>(() async {
      final token = await AuthService.fetchToken();
      return UserSession(token);
    });
    
    // Factory registration (new instance each time)
    DI.create<Logger>(() => Logger('${DateTime.now()}'));
  }
}
```

### 2. Wrap Your Widget in BindingScope

```dart
import 'package:flutter/material.dart';
import 'package:getx_binding_scope/getx_binding_scope.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BindingScope(
      binding: HomeBinding(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Home')),
        body: const HomeContent(),
      ),
    );
  }
}

class HomeContent extends StatelessWidget {
  const HomeContent({super.key});

  @override
  Widget build(BuildContext context) {
    // Access dependencies anywhere in the widget tree
    final apiService = DI.find<ApiService>();
    final config = DI.find<Config>();
    
    return Column(
      children: [
        Text('API Base URL: ${config.baseUrl}'),
        FutureBuilder<List<User>>(
          future: apiService.getUsers(),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return ListView.builder(
                shrinkWrap: true,
                itemCount: snapshot.data!.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(snapshot.data![index].name),
                  );
                },
              );
            }
            return const CircularProgressIndicator();
          },
        ),
      ],
    );
  }
}
```

## 🔄 Advanced Usage

### Nested Scopes

`BindingScope` supports nesting without ownership conflicts:

```dart
class ParentPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BindingScope(
      binding: ParentBinding(), // Creates ParentService
      child: Column(
        children: [
          Text('Parent: ${DI.find<ParentService>().name}'),
          ChildWidget(), // Has its own scope
        ],
      ),
    );
  }
}

class ChildWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BindingScope(
      binding: ChildBinding(), // Creates ChildService
      child: Column(
        children: [
          Text('Parent: ${DI.find<ParentService>().name}'), // Still accessible
          Text('Child: ${DI.find<ChildService>().name}'),   // Only in this scope
        ],
      ),
    );
  }
}
```

### Working with Different Routers

#### With GoRouter

```dart
final router = GoRouter(
  routes: [
    GoRoute(
      path: '/home',
      builder: (context, state) => BindingScope(
        binding: HomeBinding(),
        child: const HomePage(),
      ),
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => BindingScope(
        binding: ProfileBinding(),
        child: const ProfilePage(),
      ),
    ),
  ],
);
```

#### With AutoRoute

```dart
@AutoRouteConfig()
class AppRouter extends _$AppRouter {
  @override
  List<AutoRoute> get routes => [
    AutoRoute(
      page: HomeWrapperRoute.page,
      path: '/home',
    ),
  ];
}

@RoutePage()
class HomeWrapperPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BindingScope(
      binding: HomeBinding(),
      child: const HomePage(),
    );
  }
}
```

### Async Dependencies Best Practices

```dart
class AsyncBinding extends Bindings {
  @override
  void dependencies() {
    // Configure services that will be needed
    DI.put<Config>(Config());
    
    // Start async operations early
    DI.putAsync<DatabaseService>(() async {
      final db = DatabaseService();
      await db.initialize();
      return db;
    });
    
    // Dependent async services work correctly
    DI.putAsync<UserRepository>(() async {
      final db = await DI.find<DatabaseService>(); // Waits if still loading
      return UserRepository(db);
    });
  }
}
```

## 📋 Migration from GetX

Switching from GetX Bindings? Here's how to update:

| Before (GetX) | After (getx_binding_scope)   |
|---------------|------------------------------|
| `Get.put()` | `DI.put()`                   |
| `Get.lazyPut()` | `DI.lazyPut()`               |
| `Get.putAsync()` | `DI.putAsync()`              |
| `Get.create()` | `DI.create()`                |
| `Get.find()` | `DI.find()`                  |
| `GetPage(binding: ...)` | `BindingScope(binding: ...)` |

### Migration Example

```dart
// Before - GetX with routing
GetPage(
  name: '/home',
  page: () => HomePage(),
  binding: HomeBinding(),
)

// After - BindingScope (router agnostic)
BindingScope(
  binding: HomeBinding(),
  child: HomePage(),
)
```

## ⚠️ Important Notes

### Lifecycle Management

- **Automatic Cleanup**: Dependencies are automatically disposed when `BindingScope` is removed from the widget tree
- **Reverse Order**: Dependencies are disposed in reverse creation order, ensuring proper cleanup
- **Async Safety**: Async dependencies that finish after scope disposal are still cleaned up properly

### Best Practices

1. **One Binding Per Feature**: Create separate bindings for different features/pages
2. **Dependency Hierarchy**: Place shared dependencies in parent scopes
3. **Avoid Global State**: Use scoped dependencies instead of global singletons when possible
4. **Testing**: Mock dependencies by creating test-specific bindings

### Performance Considerations

- **Lazy Loading**: Use `DI.lazyPut()` for expensive objects that might not be used immediately
- **Memory Efficiency**: Scoped cleanup prevents memory leaks from accumulated dependencies
- **Async Handling**: First-registrant-wins prevents duplicate async operations

## 🧪 Testing

```dart
class TestBinding extends Bindings {
  @override
  void dependencies() {
    DI.put<ApiService>(MockApiService()); // Use mocks in tests
    DI.put<UserRepository>(MockUserRepository());
  }
}

testWidgets('HomePage displays user data', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BindingScope(
        binding: TestBinding(),
        child: HomePage(),
      ),
    ),
  );
  
  // Test your widget with mocked dependencies
  expect(find.text('Mock User Name'), findsOneWidget);
});
```


## 📚 API Reference

### DI Class

- `DI.put<T>(T instance)` - Register an immediate instance
- `DI.lazyPut<T>(T Function() builder)` - Register a lazy factory
- `DI.putAsync<T>(Future<T> Function() builder)` - Register an async instance
- `DI.create<T>(T Function() builder)` - Register a factory (new instance each find)
- `DI.find<T>()` - Retrieve a registered instance
- `DI.isRegistered<T>()` - Check if a type is registered

### BindingScope Widget

```dart
BindingScope({
  Key? key,
  required Bindings binding,
  required Widget child,
})
```

- `binding`: The GetX binding to execute
- `child`: The widget subtree that will have access to the dependencies

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Built with ❤️ for the Flutter community