#include <stdio.h>
#include <string.h>

int zettide_spdk_pool_data_nvmf_benchmark(const char *ready_path,
		const char *expected_pool_id, int read_policy, int device_count,
		const char *const *devices);

static void
usage(const char *program)
{
	fprintf(stderr,
		"usage: %s READY_FILE EXPECTED_POOL_ID READ_POLICY DEVICE...\n"
		"READ_POLICY must be first_available or quorum\n", program);
}

int
main(int argc, char **argv)
{
	int read_policy;

	if (argc < 5) {
		usage(argv[0]);
		return 2;
	}
	if (strcmp(argv[3], "first_available") == 0) {
		read_policy = 0;
	} else if (strcmp(argv[3], "quorum") == 0) {
		read_policy = 1;
	} else {
		fprintf(stderr, "invalid read policy: %s\n", argv[3]);
		usage(argv[0]);
		return 2;
	}
	return zettide_spdk_pool_data_nvmf_benchmark(argv[1], argv[2],
		read_policy, argc - 4, (const char *const *)&argv[4]);
}
