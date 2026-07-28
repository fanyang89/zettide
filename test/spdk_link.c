#include "spdk/stdinc.h"
#include "spdk/bdev.h"
#include "spdk/event.h"

int
main(void)
{
	struct spdk_app_opts opts = {0};

	spdk_app_opts_init(&opts, sizeof(opts));
	return 0;
}
