#ifndef GRPCPP_IMPL_CLIENT_STREAMING_CALL_H
#define GRPCPP_IMPL_CLIENT_STREAMING_CALL_H

#include <grpcpp/impl/client_unary_call.h>
#include <grpcpp/support/sync_stream.h>

#include <memory>
#include <string>

namespace grpc::internal {

template <class Request, class Response>
std::unique_ptr<ClientReader<Response>> BlockingServerStreamingCall(
    ChannelInterface* channel, const RpcMethod& method, ClientContext* context,
    const Request& request) {
  std::shared_ptr<BlockingCallState> state;
  if (channel == nullptr || context == nullptr) {
    state = BlockingCallState::Failed(
        context, {StatusCode::INVALID_ARGUMENT,
                  "null server streaming call argument"});
  } else {
    std::string request_bytes;
    if (!request.SerializeToString(&request_bytes)) {
      state = BlockingCallState::Failed(
          context, {StatusCode::INTERNAL, "failed to serialize request"});
    } else {
      state = channel->OpenRawStream(method.name(), context);
      const Status status = state->SendAndClose(request_bytes);
      (void)status;
    }
  }
  return std::unique_ptr<ClientReader<Response>>(
      new ClientReader<Response>(std::move(state)));
}

}  // namespace grpc::internal

#endif
