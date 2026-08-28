#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int zettide_spdk_pool_data_nvmf_benchmark(const char *ready_path,
		const char *expected_pool_id, int read_policy, int device_count,
		const char *const *devices);

static void
usage(const char *program)
{
	fprintf(stderr,
		"usage: %s READY_FILE EXPECTED_POOL_ID READ_POLICY DEVICE...\n"
		"       %s READY_FILE READ_POLICY  (synthetic storage)\n"
		"READ_POLICY must be first_available or quorum\n", program,
		program);
}

int
main(int argc, char **argv)
{
	static const char zero_pool_id[] = "00000000000000000000000000000000";
	const char *storage_transport = getenv("ZETTIDE_POOL_DATA_STORAGE_TRANSPORT");
	const int synthetic = storage_transport != NULL &&
		strcmp(storage_transport, "synthetic") == 0;
	const char *expected_pool_id;
	const char *read_policy_text;
	int first_device;
	int read_policy;

	if ((synthetic && argc != 3) || (!synthetic && argc < 5)) {
		usage(argv[0]);
		return 2;
	}
	if (synthetic) {
		expected_pool_id = zero_pool_id;
		read_policy_text = argv[2];
		first_device = 3;
	} else {
		expected_pool_id = argv[2];
		read_policy_text = argv[3];
		first_device = 4;
	}
	if (strcmp(read_policy_text, "first_available") == 0) {
		read_policy = 0;
	} else if (strcmp(read_policy_text, "quorum") == 0) {
		read_policy = 1;
	} else {
		fprintf(stderr, "invalid read policy: %s\n", read_policy_text);
		usage(argv[0]);
		return 2;
	}
	return zettide_spdk_pool_data_nvmf_benchmark(argv[1], expected_pool_id,
		read_policy, argc - first_device,
		(const char *const *)&argv[first_device]);
}
