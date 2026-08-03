# FSAL_ZETTIDE

`FSAL_ZETTIDE` is an in-process NFS-Ganesha module that calls the synchronous
Zettide NFS backend directly. It does not use FUSE, `FSAL_VFS`, Linux VFS, or
an IPC transport.

The module ABI is pinned to NFS-Ganesha `V13.0`, commit
`429463bc77a4654a4f00e0109b8c1496c272abb4`. Build it only in that source tree.

## Build

Build the position-independent backend archive first:

```sh
zig build -Doptimize=ReleaseSafe
```

Add this directory to Ganesha's `src/FSAL/CMakeLists.txt` with an absolute
source path:

```cmake
add_subdirectory("/path/to/zettide/fsal/zettide" FSAL_ZETTIDE)
```

Then configure and build Ganesha normally. Pass `ZETTIDE_SOURCE_DIR` when the
module is not located in the Zettide checkout:

```sh
cmake -S /path/to/nfs-ganesha/src -B /path/to/ganesha-build \
  -DCMAKE_BUILD_TYPE=Release \
  -DZETTIDE_SOURCE_DIR=/path/to/zettide \
  -DUSE_DBUS=ON -DUSE_GRPC=OFF -DUSE_MONITORING=OFF \
  -DUSE_NLM=OFF -DUSE_9P=OFF
cmake --build /path/to/ganesha-build --target fsalzettide
```

Ganesha `V13.0` requires either D-Bus or gRPC for declarations used by its
statistics source, so keep D-Bus enabled even when its administration API is
not used.

## Export

Use NFSv3 only. NFSv4 state, NLM locks, ACLs, xattrs, and quotas are not
implemented.

```text
NFS_Core_Param {
    Protocols = 3;
}

EXPORT {
    Export_Id = 77;
    Path = /zettide;
    Pseudo = /zettide;
    Access_Type = RW;
    Protocols = 3;
    Transports = TCP;
    SecType = sys;

    FSAL {
        name = ZETTIDE;
        Target = "/path/to/workspace.ddv";
        Writable = true;
    }
}
```

For the initial local-only deployment, bind Ganesha to loopback, disable NLM,
and mount with `vers=3,nolock`.
