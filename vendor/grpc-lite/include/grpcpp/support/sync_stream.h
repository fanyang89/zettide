#ifndef GRPCPP_SUPPORT_SYNC_STREAM_H
#define GRPCPP_SUPPORT_SYNC_STREAM_H

#include <grpcpp/impl/blocking_call.h>
#include <grpcpp/server_context.h>

#include <climits>
#include <functional>
#include <memory>
#include <string>
#include <utility>

namespace grpc {

namespace internal {
template <class Response>
class ServerWriterAccess;
}

template <class Response>
class ServerWriter final {
 public:
  ServerWriter(const ServerWriter&) = delete;
  ServerWriter& operator=(const ServerWriter&) = delete;

  bool Write(const Response& response) {
    while (!context_->IsCancelled()) {
      const grpc_lite::Error error = try_write_(response);
      if (error.ok()) return true;
      if (error.code() != grpc_lite::ErrorCode::WouldBlock ||
          !wait_for_writable_()) {
        return false;
      }
    }
    return false;
  }

 private:
  friend class internal::ServerWriterAccess<Response>;
  ServerWriter(ServerContext* context,
               std::function<grpc_lite::Error(const Response&)> try_write,
               std::function<bool()> wait_for_writable)
      : context_(context),
        try_write_(std::move(try_write)),
        wait_for_writable_(std::move(wait_for_writable)) {}

  ServerContext* context_;
  std::function<grpc_lite::Error(const Response&)> try_write_;
  std::function<bool()> wait_for_writable_;
};

namespace internal {

template <class Response>
class ServerWriterAccess {
 public:
  static ServerWriter<Response> Create(
      ServerContext* context,
      std::function<grpc_lite::Error(const Response&)> try_write,
      std::function<bool()> wait_for_writable) {
    return ServerWriter<Response>(context, std::move(try_write),
                                  std::move(wait_for_writable));
  }
};

}  // namespace internal

template <class Response>
class ClientReader final {
 public:
  explicit ClientReader(std::shared_ptr<internal::BlockingCallState> state)
      : state_(std::move(state)) {}
  ~ClientReader() {
    if (!finished_) {
      state_->Cancel();
      Finish();
    }
  }
  ClientReader(const ClientReader&) = delete;
  ClientReader& operator=(const ClientReader&) = delete;

  bool Read(Response* response) {
    if (response == nullptr || finished_ || !parse_status_.ok()) return false;
    std::string payload;
    if (!state_->Read(&payload)) {
      read_exhausted_ = true;
      return false;
    }
    if (payload.size() > static_cast<std::size_t>(INT_MAX)) {
      parse_status_ = {StatusCode::RESOURCE_EXHAUSTED,
                       "response is too large to parse"};
      state_->Cancel();
      return false;
    }
    Response parsed_response;
    if (!parsed_response.ParseFromArray(payload.data(),
                                        static_cast<int>(payload.size()))) {
      parse_status_ = {StatusCode::INTERNAL, "failed to parse response"};
      state_->Cancel();
      return false;
    }
    *response = std::move(parsed_response);
    return true;
  }

  Status Finish() {
    if (finished_) return final_status_;
    if (!read_exhausted_) state_->Cancel();
    final_status_ = state_->Finish();
    if (!parse_status_.ok()) final_status_ = parse_status_;
    finished_ = true;
    return final_status_;
  }

 private:
  std::shared_ptr<internal::BlockingCallState> state_;
  Status final_status_;
  Status parse_status_;
  bool read_exhausted_ = false;
  bool finished_ = false;
};

}  // namespace grpc

#endif
