#include "spdk/bdev_endpoint.h"

#include "spdk/event.h"

#include <errno.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const char malloc_bdev_config[] =
	"{\"subsystems\":[{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":1024,"
	"\"bdev_io_cache_size\":32}},"
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"ZettideMalloc0\","
	"\"num_blocks\":256,\"block_size\":4096}}]}]}";

struct test_context {
	struct zettide_spdk_bdev_endpoint *endpoint;
	void *write_buffer;
	void *read_buffer;
	uint64_t io_size;
	uint32_t completion_count;
	int event_status;
};

static void
finish_test(struct test_context *context, int status)
{
	int close_status = 0;

	if (context->endpoint != NULL) {
		close_status = zettide_spdk_bdev_close(context->endpoint);
		context->endpoint = NULL;
	}
	zettide_spdk_dma_free(context->read_buffer);
	zettide_spdk_dma_free(context->write_buffer);
	context->read_buffer = NULL;
	context->write_buffer = NULL;
	spdk_app_stop(status != 0 ? status : close_status);
}

static void
read_complete(void *callback_context, int status)
{
	struct test_context *context = callback_context;

	context->completion_count++;
	if (status == 0 && context->event_status != 0) {
		status = context->event_status;
	}
	if (status == 0 && memcmp(context->write_buffer, context->read_buffer, context->io_size) != 0) {
		status = -EIO;
	}
	if (status == 0 && context->completion_count != 3) {
		status = -EIO;
	}
	finish_test(context, status);
}

static void
flush_complete(void *callback_context, int status)
{
	struct test_context *context = callback_context;

	context->completion_count++;
	if (status == 0 && context->event_status != 0) {
		status = context->event_status;
	}
	if (status == 0) {
		status = zettide_spdk_bdev_read(context->endpoint, context->read_buffer,
				0, context->io_size, read_complete, context);
	}
	if (status != 0) {
		finish_test(context, status);
	}
}

static void
write_complete(void *callback_context, int status)
{
	struct test_context *context = callback_context;

	context->completion_count++;
	if (status == 0 && context->event_status != 0) {
		status = context->event_status;
	}
	if (status == 0) {
		status = zettide_spdk_bdev_flush(context->endpoint, 0, context->io_size,
				flush_complete, context);
	}
	if (status != 0) {
		finish_test(context, status);
	}
}

static void
unexpected_event(void *callback_context, struct zettide_spdk_bdev_endpoint *endpoint,
		enum zettide_spdk_bdev_event event)
{
	struct test_context *context = callback_context;

	(void)endpoint;
	(void)event;
	context->event_status = -ENODEV;
}

static void
start_test(void *callback_context)
{
	struct test_context *context = callback_context;
	const struct zettide_spdk_bdev_geometry *geometry;
	uint8_t *bytes;
	uint64_t index;
	int status;

	status = zettide_spdk_bdev_open("ZettideMalloc0", true, unexpected_event,
			context, &context->endpoint);
	if (status != 0) {
		finish_test(context, status);
		return;
	}
	geometry = zettide_spdk_bdev_get_geometry(context->endpoint);
	if (geometry == NULL || geometry->logical_block_size != 4096 ||
		(geometry->flags & ZETTIDE_SPDK_BDEV_WRITABLE) == 0 ||
		(geometry->flags & ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0) {
		finish_test(context, -EINVAL);
		return;
	}
	context->io_size = geometry->logical_block_size * geometry->write_unit_blocks;
	context->write_buffer = zettide_spdk_dma_zmalloc(context->io_size, geometry->buffer_alignment);
	context->read_buffer = zettide_spdk_dma_zmalloc(context->io_size, geometry->buffer_alignment);
	if (context->write_buffer == NULL || context->read_buffer == NULL) {
		finish_test(context, -ENOMEM);
		return;
	}
	bytes = context->write_buffer;
	for (index = 0; index < context->io_size; index++) {
		bytes[index] = (uint8_t)(index * 31u + 17u);
	}
	status = zettide_spdk_bdev_write(context->endpoint, context->write_buffer,
			1, context->io_size, write_complete, context);
	if (status != -EINVAL) {
		finish_test(context, status == 0 ? -EIO : status);
		return;
	}
	status = zettide_spdk_bdev_write(context->endpoint, context->write_buffer,
			0, context->io_size, write_complete, context);
	if (status != 0) {
		finish_test(context, status);
		return;
	}
	status = zettide_spdk_bdev_close(context->endpoint);
	if (status != -EBUSY) {
		if (status == 0) {
			context->endpoint = NULL;
		}
		finish_test(context, status == 0 ? -EIO : status);
	}
}

static int
first_allowed_cpu(void)
{
	cpu_set_t allowed;
	int cpu;

	if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) {
		return -1;
	}
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (CPU_ISSET(cpu, &allowed)) {
			return cpu;
		}
	}
	return -1;
}

int
main(void)
{
	struct spdk_app_opts options = {0};
	struct test_context context = {0};
	char reactor_mask[32];
	int cpu = first_allowed_cpu();
	int status;

	if (cpu < 0 || snprintf(reactor_mask, sizeof(reactor_mask), "[%d]", cpu) < 0) {
		return 1;
	}
	spdk_app_opts_init(&options, sizeof(options));
	options.name = "zettide_spdk_endpoint_test";
	options.rpc_addr = NULL;
	options.reactor_mask = reactor_mask;
	options.mem_size = 320;
	options.no_pci = true;
	options.no_huge = true;
	options.disable_signal_handlers = true;
	options.disable_cpumask_locks = true;
	options.json_data = (void *)malloc_bdev_config;
	options.json_data_size = sizeof(malloc_bdev_config) - 1;
	status = spdk_app_start(&options, start_test, &context);
	spdk_app_fini();
	return status == 0 ? 0 : 1;
}
