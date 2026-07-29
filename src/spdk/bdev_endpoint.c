#include "bdev_endpoint.h"

#include "spdk/bdev.h"
#include "spdk/env.h"
#include "spdk/thread.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

enum request_operation {
	REQUEST_READ,
	REQUEST_WRITE,
	REQUEST_FLUSH,
};

struct zettide_spdk_bdev_endpoint {
	struct spdk_thread *owner;
	struct spdk_bdev_desc *descriptor;
	struct spdk_bdev *bdev;
	struct spdk_io_channel *channel;
	struct zettide_spdk_bdev_geometry geometry;
	uint64_t outstanding;
	bool writable;
	bool removed;
	zettide_spdk_bdev_event_cb event_cb;
	void *event_context;
};

struct bdev_request {
	struct zettide_spdk_bdev_endpoint *endpoint;
	enum request_operation operation;
	void *buffer;
	uint64_t offset;
	uint64_t length;
	zettide_spdk_bdev_io_cb callback;
	void *callback_context;
	struct spdk_bdev_io_wait_entry wait_entry;
};

static int issue_request(struct bdev_request *request);

static bool
on_owner_thread(const struct zettide_spdk_bdev_endpoint *endpoint)
{
	return spdk_get_thread() == endpoint->owner;
}

static int
refresh_geometry(struct zettide_spdk_bdev_endpoint *endpoint)
{
	uint64_t block_count = spdk_bdev_get_num_blocks(endpoint->bdev);
	uint32_t block_size = spdk_bdev_get_block_size(endpoint->bdev);
	size_t alignment = spdk_bdev_get_buf_align(endpoint->bdev);

	if (block_size == 0 || block_count > UINT64_MAX / block_size || alignment > UINT32_MAX) {
		return -EOVERFLOW;
	}
	endpoint->geometry.capacity_bytes = block_count * block_size;
	endpoint->geometry.block_count = block_count;
	endpoint->geometry.logical_block_size = block_size;
	endpoint->geometry.write_unit_blocks = spdk_bdev_get_write_unit_size(endpoint->bdev);
	endpoint->geometry.buffer_alignment = (uint32_t)alignment;
	endpoint->geometry.flags = 0;
	if (endpoint->writable) {
		endpoint->geometry.flags |= ZETTIDE_SPDK_BDEV_WRITABLE;
	}
	if (spdk_bdev_io_type_supported(endpoint->bdev, SPDK_BDEV_IO_TYPE_FLUSH)) {
		endpoint->geometry.flags |= ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED;
	}
	if (spdk_bdev_has_write_cache(endpoint->bdev)) {
		endpoint->geometry.flags |= ZETTIDE_SPDK_BDEV_WRITE_CACHE;
	}
	return 0;
}

static void
bdev_event(enum spdk_bdev_event_type type, struct spdk_bdev *bdev, void *context)
{
	struct zettide_spdk_bdev_endpoint *endpoint = context;
	enum zettide_spdk_bdev_event event;

	(void)bdev;
	switch (type) {
	case SPDK_BDEV_EVENT_REMOVE:
		endpoint->removed = true;
		event = ZETTIDE_SPDK_BDEV_REMOVE;
		break;
	case SPDK_BDEV_EVENT_RESIZE:
		if (refresh_geometry(endpoint) != 0) {
			endpoint->removed = true;
			event = ZETTIDE_SPDK_BDEV_REMOVE;
		} else {
			event = ZETTIDE_SPDK_BDEV_RESIZE;
		}
		break;
	default:
		return;
	}
	if (endpoint->event_cb != NULL) {
		endpoint->event_cb(endpoint->event_context, endpoint, event);
	}
}

int
zettide_spdk_bdev_open(const char *name, bool writable,
		zettide_spdk_bdev_event_cb event_cb, void *event_context,
		struct zettide_spdk_bdev_endpoint **endpoint_out)
{
	struct zettide_spdk_bdev_endpoint *endpoint;
	int rc;

	if (name == NULL || endpoint_out == NULL) {
		return -EINVAL;
	}
	if (spdk_get_thread() == NULL) {
		return -EPERM;
	}
	*endpoint_out = NULL;
	endpoint = calloc(1, sizeof(*endpoint));
	if (endpoint == NULL) {
		return -ENOMEM;
	}
	endpoint->owner = spdk_get_thread();
	endpoint->writable = writable;
	endpoint->event_cb = event_cb;
	endpoint->event_context = event_context;
	rc = spdk_bdev_open_ext(name, writable, bdev_event, endpoint, &endpoint->descriptor);
	if (rc != 0) {
		free(endpoint);
		return rc;
	}
	endpoint->bdev = spdk_bdev_desc_get_bdev(endpoint->descriptor);
	if (!spdk_bdev_io_type_supported(endpoint->bdev, SPDK_BDEV_IO_TYPE_READ) ||
		(writable && !spdk_bdev_io_type_supported(endpoint->bdev, SPDK_BDEV_IO_TYPE_WRITE))) {
		rc = -ENOTSUP;
		goto fail;
	}
	if (spdk_bdev_get_md_size(endpoint->bdev) != 0 || spdk_bdev_is_zoned(endpoint->bdev)) {
		rc = -ENOTSUP;
		goto fail;
	}
	endpoint->channel = spdk_bdev_get_io_channel(endpoint->descriptor);
	if (endpoint->channel == NULL) {
		rc = -ENOMEM;
		goto fail;
	}
	rc = refresh_geometry(endpoint);
	if (rc != 0) {
		spdk_put_io_channel(endpoint->channel);
		goto fail;
	}
	*endpoint_out = endpoint;
	return 0;

fail:
	spdk_bdev_close(endpoint->descriptor);
	free(endpoint);
	return rc;
}

int
zettide_spdk_bdev_close(struct zettide_spdk_bdev_endpoint *endpoint)
{
	if (endpoint == NULL) {
		return -EINVAL;
	}
	if (!on_owner_thread(endpoint)) {
		return -EPERM;
	}
	if (endpoint->outstanding != 0) {
		return -EBUSY;
	}
	spdk_put_io_channel(endpoint->channel);
	spdk_bdev_close(endpoint->descriptor);
	free(endpoint);
	return 0;
}

const struct zettide_spdk_bdev_geometry *
zettide_spdk_bdev_get_geometry(const struct zettide_spdk_bdev_endpoint *endpoint)
{
	return endpoint == NULL ? NULL : &endpoint->geometry;
}

const char *
zettide_spdk_bdev_get_name(const struct zettide_spdk_bdev_endpoint *endpoint)
{
	if (endpoint == NULL || !on_owner_thread(endpoint)) {
		return NULL;
	}
	return spdk_bdev_get_name(endpoint->bdev);
}

static int
validate_range(const struct zettide_spdk_bdev_endpoint *endpoint, const void *buffer,
		uint64_t offset, uint64_t length, bool write)
{
	uint64_t block_size = endpoint->geometry.logical_block_size;
	uint64_t write_unit = endpoint->geometry.write_unit_blocks;
	uint64_t offset_blocks;
	uint64_t length_blocks;
	uint32_t alignment = endpoint->geometry.buffer_alignment;

	if (!on_owner_thread(endpoint)) {
		return -EPERM;
	}
	if (endpoint->removed) {
		return -ENODEV;
	}
	if (buffer == NULL || length == 0 || offset % block_size != 0 || length % block_size != 0) {
		return -EINVAL;
	}
	if (offset > endpoint->geometry.capacity_bytes ||
		length > endpoint->geometry.capacity_bytes - offset) {
		return -ERANGE;
	}
	if (alignment > 1 && (uintptr_t)buffer % alignment != 0) {
		return -EINVAL;
	}
	if (!write) {
		return 0;
	}
	if (!endpoint->writable) {
		return -EBADF;
	}
	offset_blocks = offset / block_size;
	length_blocks = length / block_size;
	if (write_unit == 0 || offset_blocks % write_unit != 0 || length_blocks % write_unit != 0) {
		return -EINVAL;
	}
	return 0;
}

static void
finish_request(struct bdev_request *request, int status)
{
	struct zettide_spdk_bdev_endpoint *endpoint = request->endpoint;
	zettide_spdk_bdev_io_cb callback = request->callback;
	void *callback_context = request->callback_context;

	endpoint->outstanding--;
	free(request);
	callback(callback_context, status);
}

static void
complete_request(struct spdk_bdev_io *bdev_io, bool success, void *context)
{
	struct bdev_request *request = context;
	int status = 0;

	if (!success) {
		spdk_bdev_io_get_aio_status(bdev_io, &status);
		if (status >= 0) {
			status = -EIO;
		}
		if (request->endpoint->removed) {
			status = -ENODEV;
		}
	}
	spdk_bdev_free_io(bdev_io);
	finish_request(request, status);
}

static void
retry_request(void *context)
{
	struct bdev_request *request = context;
	int rc;

	if (request->endpoint->removed) {
		finish_request(request, -ENODEV);
		return;
	}
	rc = issue_request(request);
	if (rc != 0) {
		finish_request(request, rc);
	}
}

static int
issue_request(struct bdev_request *request)
{
	struct zettide_spdk_bdev_endpoint *endpoint = request->endpoint;
	int rc;

	switch (request->operation) {
	case REQUEST_READ:
		rc = spdk_bdev_read(endpoint->descriptor, endpoint->channel, request->buffer,
				request->offset, request->length, complete_request, request);
		break;
	case REQUEST_WRITE:
		rc = spdk_bdev_write(endpoint->descriptor, endpoint->channel, request->buffer,
				request->offset, request->length, complete_request, request);
		break;
	case REQUEST_FLUSH:
		rc = spdk_bdev_flush(endpoint->descriptor, endpoint->channel,
				request->offset, request->length, complete_request, request);
		break;
	default:
		return -EINVAL;
	}
	if (rc != -ENOMEM) {
		return rc;
	}
	request->wait_entry.bdev = endpoint->bdev;
	request->wait_entry.cb_fn = retry_request;
	request->wait_entry.cb_arg = request;
	return spdk_bdev_queue_io_wait(endpoint->bdev, endpoint->channel, &request->wait_entry);
}

static int
submit_request(struct zettide_spdk_bdev_endpoint *endpoint, enum request_operation operation,
		void *buffer, uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context)
{
	struct bdev_request *request;
	int rc;

	if (endpoint == NULL || callback == NULL) {
		return -EINVAL;
	}
	request = calloc(1, sizeof(*request));
	if (request == NULL) {
		return -ENOMEM;
	}
	request->endpoint = endpoint;
	request->operation = operation;
	request->buffer = buffer;
	request->offset = offset;
	request->length = length;
	request->callback = callback;
	request->callback_context = callback_context;
	endpoint->outstanding++;
	rc = issue_request(request);
	if (rc != 0) {
		endpoint->outstanding--;
		free(request);
	}
	return rc;
}

int
zettide_spdk_bdev_read(struct zettide_spdk_bdev_endpoint *endpoint,
		void *buffer, uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context)
{
	int rc;

	if (endpoint == NULL) {
		return -EINVAL;
	}
	rc = validate_range(endpoint, buffer, offset, length, false);
	if (rc != 0) {
		return rc;
	}
	if (!spdk_bdev_io_type_supported(endpoint->bdev, SPDK_BDEV_IO_TYPE_READ)) {
		return -ENOTSUP;
	}
	return submit_request(endpoint, REQUEST_READ, buffer, offset, length,
			callback, callback_context);
}

int
zettide_spdk_bdev_write(struct zettide_spdk_bdev_endpoint *endpoint,
		const void *buffer, uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context)
{
	int rc;

	if (endpoint == NULL) {
		return -EINVAL;
	}
	rc = validate_range(endpoint, buffer, offset, length, true);
	if (rc != 0) {
		return rc;
	}
	if (!spdk_bdev_io_type_supported(endpoint->bdev, SPDK_BDEV_IO_TYPE_WRITE)) {
		return -ENOTSUP;
	}
	return submit_request(endpoint, REQUEST_WRITE, (void *)buffer, offset, length,
			callback, callback_context);
}

int
zettide_spdk_bdev_flush(struct zettide_spdk_bdev_endpoint *endpoint,
		uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context)
{
	if (endpoint == NULL || callback == NULL) {
		return -EINVAL;
	}
	if (!on_owner_thread(endpoint)) {
		return -EPERM;
	}
	if (endpoint->removed) {
		return -ENODEV;
	}
	if (!endpoint->writable) {
		return -EBADF;
	}
	if (!spdk_bdev_io_type_supported(endpoint->bdev, SPDK_BDEV_IO_TYPE_FLUSH)) {
		return -ENOTSUP;
	}
	if (length == 0 || offset % endpoint->geometry.logical_block_size != 0 ||
		length % endpoint->geometry.logical_block_size != 0) {
		return -EINVAL;
	}
	if (offset > endpoint->geometry.capacity_bytes ||
		length > endpoint->geometry.capacity_bytes - offset) {
		return -ERANGE;
	}
	return submit_request(endpoint, REQUEST_FLUSH, NULL, offset, length,
			callback, callback_context);
}

void *
zettide_spdk_dma_zmalloc(size_t size, size_t alignment)
{
	return spdk_dma_zmalloc(size, alignment, NULL);
}

void
zettide_spdk_dma_free(void *buffer)
{
	spdk_dma_free(buffer);
}
