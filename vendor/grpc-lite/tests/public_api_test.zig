const std = @import("std");
const grpc = @import("grpc_lite");

test "stable public API compiles for downstream consumers" {
    comptime {
        _ = grpc.Channel;
        _ = grpc.ChannelOptions;
        _ = grpc.ReconnectOptions;
        _ = grpc.ClientTlsOptions;
        _ = grpc.Runtime;
        _ = grpc.CallOptions;
        _ = grpc.CallResult;
        _ = grpc.Server;
        _ = grpc.ServerOptions;
        _ = grpc.ServerTlsOptions;
        _ = grpc.ServerLocalAddress;
        _ = grpc.ServerContext;
        _ = grpc.UnaryHandler;
        _ = grpc.UnaryResponse;
        _ = grpc.Metadata;
        _ = grpc.MetadataEntry;
        _ = grpc.Status;
        _ = grpc.StatusCode;
        _ = grpc.Compression;
        _ = grpc.StreamBufferLimits;
        _ = grpc.StreamOptions;
        _ = grpc.StreamSendOptions;
        _ = grpc.StreamReceiveAction;
        _ = grpc.ClientStream;
        _ = grpc.ClientStreamCallbacks;
        _ = grpc.ServerStream;
        _ = grpc.ServerCall;
        _ = grpc.ServerCallId;
        _ = grpc.ServerTerminalReason;
        _ = grpc.ServerInitialMetadataMode;
        _ = grpc.ServerStreamHandler;
        _ = grpc.log;
        _ = grpc.protobuf;
        _ = grpc.xev;
    }

    _ = try std.SemanticVersion.parse(grpc.version);
    const channel_options: grpc.ChannelOptions = .{};
    try std.testing.expectEqualStrings("grpc-lite/" ++ grpc.version, channel_options.user_agent);
}
