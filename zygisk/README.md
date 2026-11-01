# Vector Zygisk Module and Framework Loader

## Overview

This subsystem constitutes the injection engine of the Vector framework. It acts as the bridge between the Android Zygote process and the high-level Java/Kotlin Xposed API. The architecture is designed to avoid standard Android service registration and disk-based class loading, operating entirely through in-memory execution, JNI-level Binder interception, and process identity transplantation.

The subsystem is divided into two discrete layers:
1. _Native Zygisk Layer_ (C++): Hooks process creation via Zygisk, filters target processes, establishes the initial IPC bridge, and bootstraps the Dalvik environment from memory.
2. _Framework Loader_ (Kotlin): The Java-world payload. It handles high-level Android framework manipulation, manages the custom Binder routing service, and orchestrates the Parasitic Manager execution.

## IPC Architecture and Binder Relay

Vector utilizes a two-phase IPC routing mechanism to establish communication between injected applications and the root daemon. Instead of registering standard AIDL endpoints with ServiceManager, it intercepts the lowest level of Java Binder communication within the Dalvik VM.

### The JNI Binder Trap
In `ipc_bridge.cpp`, the module uses the ART internal function `SetTableOverride` to replace the JNI function `CallBooleanMethodV`. This override intercepts all native calls to `android.os.Binder.execTransact` system-wide. 

When a transaction occurs, the hook inspects the transaction code. If it matches the constant kBridgeTransactionCode (`_VEC`), the transaction is diverted to the static Kotlin method `BridgeService.execTransact`. All other transactions pass through to the original Android framework unmodified.

### Phase 1: System Server Initialization
The `system_server` acts as the primary proxy router for the framework. During the `postServerSpecialize` callback, the following sequence occurs:
1. The native module queries `ServiceManager` for the rendezvous service, `serial` or `serial_vector` depending on whether a `system_server` was already running (see _Choosing the rendezvous name_ below).
2. The module sends a `_VEC` transaction to retrieve a temporary binder, which it uses to fetch the framework DEX file descriptor and the obfuscation map.
3. The module installs the JNI Binder Trap (`HookBridge`) and bootstraps the Kotlin layer via `Main.forkCommon`.
4. Concurrently, the root daemon initiates a Binder transaction directly to the `system_server`. The JNI trap intercepts this, and BridgeService processes the `SEND_BINDER` action, storing the daemon's primary `IVectorDaemon` binder, sending back `system_server` context and linking a `DeathRecipient`.

#### Choosing the rendezvous name
`serial` is a real `system_server` service, registered long after specialization. At boot it is therefore free, and a binder found under it can only be the daemon's proxy. When Zygisk instead attaches to a `system_server` that booted without Vector, the real service is already registered, and a lookup returning it would be indistinguishable from a successful rendezvous; `serial_vector`, a name no platform service uses, is claimed for that case.

The late case is NeoZygisk's late load — `ksud late-load`, a manual trigger, or a root session re-applied to a system that booted without one — which attaches to a `system_server` already serving and drives `postServerSpecialize` on a thread of its own ([NeoZygisk#174](https://github.com/JingMatrix/NeoZygisk/pull/174)). It says so through the `LATE_INJECT` runtime flag, and the module reads that first.

Nothing tells the daemon, which the same `service.sh` starts either way, so it asks the one question both sides can answer alike: does `activity` already answer? Nothing has registered it during a boot, and a `system_server` that is serving has. The module falls back on the same probe wherever the flag is absent. At boot the two cannot disagree: the module's poll for the rendezvous runs on `system_server`'s own thread during specialization, so `activity` cannot appear while a daemon is still starting up behind it.

`serial_vector` is the daemon's alone, so unlike `serial` nothing will ever come along and replace it. Once the module it existed for has let go of the binder, the daemon unregisters it through `registerClientCallback`, which is the only sequence servicemanager accepts — `tryUnregisterService` on its own is refused for as long as the service is marked as having a client, and for a name without a client callback that mark is never cleared.

#### When `system_server` restarts
A soft reboot, a crash or `ctl.restart zygote` leaves the daemon running and replaces the process it was talking to. The `DeathRecipient` the daemon linked on the `activity` binder is what notices, which is why that binder is retained for as long as the link is meant to last: the notification lives exactly as long as the `BinderProxy` it was registered on.

The replacement is forked by a zygote that already carries Vector's hooks, so it arrives exactly as one does at boot and looks the daemon up under `serial`, which its predecessor freed by dying. The daemon re-claims `serial` on the death notification and stops treating itself as late-injected: the replacement broadcasts a boot of its own, so there is nothing to replay.

### Phase 2: User Application Rendezvous
Standard applications initialize their IPC connection by routing requests through the `system_server`.
1. In `postAppSpecialize`, the application queries `ServiceManager` for the `activity` service (which resides in `system_server`).
2. The application sends a `_VEC` transaction containing the `GET_BINDER` action, its process name, and a newly allocated heartbeat `BBinder`.
3. The JNI trap inside `system_server` intercepts this transaction before the Activity Manager processes it.
4. The `system_server`'s BridgeService forwards the application's UID, PID, and heartbeat binder to the root daemon via the `IVectorDaemon` binder acquired in Phase 1.
5. The daemon evaluates the request against its internal scope state. If approved, it generates an `IFrameworkService` binder and returns it to the `system_server`, which writes it back to the waiting application's reply parcel.
6. The application uses this dedicated binder to fetch its specific framework DEX and obfuscation map.

### The Heartbeat Mechanism
To manage process lifecycles without polling, the native module generates a dummy Binder object (`heartbeat_binder`) during both initialization phases. This object is passed to the daemon and kept alive in the application process via a JNI Global Reference (`env->NewGlobalRef`). If the application or `system_server` terminates normally or is killed by the kernel, the global reference is destroyed, the binder node is released, and the daemon's `DeathRecipient` triggers immediate resource cleanup.

## Memory Execution and Obfuscation Synchronization

Vector does not write framework code to the /data partition.

1. Asset Delivery: The root daemon provides the framework DEX via a `SharedMemory` file descriptor, using `kDexTransactionCode`. The C++ layer wraps this file descriptor in a `java.nio.DirectByteBuffer` and initializes a `dalvik.system.InMemoryDexClassLoader`.
2. Dynamic Relinking: The daemon randomizes framework class names on each boot. The native module fetches a serialized dictionary over IPC, using `kObfuscationMapTransactionCode`. `SetupEntryClass` uses this map to locate the randomized entry point (`org.matrix.vector.core.Main`) and BridgeService, enabling the framework to link correctly at runtime.

## Parasitic Manager and Identity Transplantation

The Vector Manager application is not installed as a standard package. It runs by hollowing out a host process (e.g., `com.android.shell`) using a parasitic execution model.

### System Server Intent Redirection
Within the `system_server`, `ParasiticManagerSystemHooker` intercepts `ActivityTaskSupervisor.resolveActivity`. When it detects an Intent tagged with the `LAUNCH_MANAGER` category, it dynamically modifies the returned ActivityInfo. It forces the system to launch the host package while setting the processName to the Manager's package name and adjusting theme and recents flags to mimic a standalone application.

### Application Host Hijacking
When the native module detects the host package UID and the Manager process name during `preAppSpecialize`, it injects `GID_INET` (3003) into the process's GID array to ensure network access. Control is then passed to `ParasiticManagerHooker.kt`, which performs the identity transplantation:
1. Code Injection: It intercepts `LoadedApk.getClassLoader` and `ActivityThread.handleBindApplication`, swapping the host's ApplicationInfo with a hybrid object constructed from the manager's APK (provided via file descriptor). The manager's DEX is injected into the host's `PathClassLoader`.
2. State Forgery: The system ActivityManager is unaware of the spoofed Manager activities. To prevent data loss during lifecycle transitions (e.g., screen rotation), the hooker intercepts `performStopActivityInner` to manually capture Bundle and PersistableBundle states into static concurrent maps. These states are reinjected during `scheduleLaunchActivity`.
3. Context Spoofing: It intercepts `ActivityThread.installProvider` and `WebViewFactory.getProvider` to construct forged `ContextImpl` instances, bypassing internal Android and Chromium package-name validation checks.
