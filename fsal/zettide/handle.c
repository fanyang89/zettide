// SPDX-License-Identifier: LGPL-3.0-or-later
#include "config.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "FSAL/fsal_commonlib.h"
#include "fsal_convert.h"
#include "zettide_fsal.h"

static object_file_type_t zettide_type(uint8_t kind)
{
	switch (kind) {
	case ZETTIDE_NFS_FILE:
		return REGULAR_FILE;
	case ZETTIDE_NFS_DIRECTORY:
		return DIRECTORY;
	case ZETTIDE_NFS_SYMLINK:
		return SYMBOLIC_LINK;
	case ZETTIDE_NFS_FIFO:
		return FIFO_FILE;
	default:
		return NO_FILE_TYPE;
	}
}

static uint64_t load_u64(const uint8_t *bytes)
{
	uint64_t value;
	memcpy(&value, bytes, sizeof(value));
	return value;
}

static uint64_t zettide_fileid(const struct zettide_nfs_handle *wire)
{
	uint64_t fileid = UINT64_C(14695981039346656037);
	size_t index;

	for (index = 24; index < 40; index++) {
		fileid ^= wire->bytes[index];
		fileid *= UINT64_C(1099511628211);
	}
	return fileid == 0 ? 1 : fileid;
}

static struct timespec zettide_timespec(int64_t nanoseconds)
{
	struct timespec result;
	result.tv_sec = nanoseconds / 1000000000;
	result.tv_nsec = nanoseconds % 1000000000;
	if (result.tv_nsec < 0) {
		result.tv_sec--;
		result.tv_nsec += 1000000000;
	}
	return result;
}

static int64_t zettide_nanoseconds(struct timespec value)
{
	return (int64_t)value.tv_sec * 1000000000 + value.tv_nsec;
}

static int64_t zettide_now(void)
{
	struct timespec value;
	if (clock_gettime(CLOCK_REALTIME, &value) != 0)
		return 0;
	return zettide_nanoseconds(value);
}

void zettide_fill_attrs(const struct zettide_nfs_handle *wire,
			const struct zettide_nfs_attributes *source,
			struct fsal_attrlist *target)
{
	attrmask_t request_mask = target->request_mask;

	memset(target, 0, sizeof(*target));
	target->request_mask = request_mask;
	target->valid_mask = ATTRS_POSIX;
	target->supported = ATTRS_POSIX;
	target->type = zettide_type(source->kind);
	target->filesize = source->size;
	target->fsid.major = load_u64(&wire->bytes[8]);
	target->fsid.minor = load_u64(&wire->bytes[16]);
	target->fileid = zettide_fileid(wire);
	target->mode = source->mode & 07777;
	target->numlinks = source->nlink > UINT32_MAX ? UINT32_MAX
						      : source->nlink;
	target->owner = source->uid;
	target->group = source->gid;
	target->atime = zettide_timespec(source->atime_ns);
	target->mtime = zettide_timespec(source->mtime_ns);
	target->ctime = zettide_timespec(source->ctime_ns);
	target->spaceused = source->allocated_bytes;
	target->change = source->ctime_ns;
}

struct zettide_fsal_handle *
zettide_alloc_handle(struct zettide_fsal_export *export,
		     const struct zettide_nfs_handle *wire,
		     const struct zettide_nfs_attributes *attributes)
{
	struct zettide_fsal_handle *handle = gsh_calloc(1, sizeof(*handle));
	object_file_type_t type = zettide_type(attributes->kind);

	handle->export = export;
	handle->wire = *wire;
	handle->obj_handle.fsid.major = load_u64(&wire->bytes[8]);
	handle->obj_handle.fsid.minor = load_u64(&wire->bytes[16]);
	handle->obj_handle.fileid = zettide_fileid(wire);
	fsal_obj_handle_init(&handle->obj_handle, &export->export, type, true);
	handle->obj_handle.obj_ops = &ZETTIDE.handle_ops;
	return handle;
}

static struct zettide_fsal_handle *
zettide_handle(struct fsal_obj_handle *obj_hdl)
{
	return container_of(obj_hdl, struct zettide_fsal_handle, obj_handle);
}

static void zettide_release(struct fsal_obj_handle *obj_hdl)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	fsal_obj_handle_fini(obj_hdl, true);
	gsh_free(handle);
}

static fsal_status_t zettide_lookup(struct fsal_obj_handle *dir_hdl,
				    const char *name,
				    struct fsal_obj_handle **obj_hdl,
				    struct fsal_attrlist *attrs_out)
{
	struct zettide_fsal_handle *directory = zettide_handle(dir_hdl);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	struct zettide_fsal_handle *result;
	int status;

	*obj_hdl = NULL;
	if (strcmp(name, "..") == 0) {
		status = zettide_nfs_lookup_parent(directory->export->backend,
						   &directory->wire, &wire,
						   &attributes);
	} else if (strcmp(name, ".") == 0) {
		wire = directory->wire;
		status = zettide_nfs_getattr(directory->export->backend, &wire,
					     &attributes);
	} else {
		status = zettide_nfs_lookup(directory->export->backend,
					    &directory->wire, name,
					    strlen(name), &wire, &attributes);
	}
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	result = zettide_alloc_handle(directory->export, &wire, &attributes);
	*obj_hdl = &result->obj_handle;
	if (attrs_out != NULL)
		zettide_fill_attrs(&wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_readdir(struct fsal_obj_handle *dir_hdl,
				     fsal_cookie_t *whence, void *dir_state,
				     fsal_readdir_cb callback,
				     attrmask_t attrmask, bool *eof)
{
	struct zettide_fsal_handle *directory = zettide_handle(dir_hdl);
	struct zettide_nfs_directory *reader = NULL;
	uint64_t cookie = whence == NULL ? 0 : *whence;
	fsal_status_t result = fsalstat(ERR_FSAL_NO_ERROR, 0);
	int status;

	if (cookie > UINT32_MAX)
		return fsalstat(ERR_FSAL_BADCOOKIE, EINVAL);
	status = zettide_nfs_directory_open(directory->export->backend,
					    &directory->wire, (uint32_t)cookie,
					    &reader);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	*eof = true;
	for (;;) {
		struct zettide_nfs_directory_entry entry;
		struct zettide_fsal_handle *child;
		struct fsal_attrlist attributes;
		enum fsal_dir_result callback_result;
		bool has_entry;

		status = zettide_nfs_directory_read(reader, &entry, &has_entry);
		if (status != ZETTIDE_NFS_OK) {
			result = zettide_status(status);
			break;
		}
		if (!has_entry)
			break;

		child = zettide_alloc_handle(directory->export, &entry.handle,
					     &entry.attributes);
		fsal_prepare_attrs(&attributes, attrmask);
		zettide_fill_attrs(&entry.handle, &entry.attributes,
				   &attributes);
		callback_result = callback(entry.name, &child->obj_handle,
					   &attributes, dir_state,
					   entry.next_cookie);
		fsal_release_attrs(&attributes);
		if (callback_result >= DIR_READAHEAD) {
			*eof = false;
			break;
		}
	}

	status = zettide_nfs_directory_close(reader);
	if (!FSAL_IS_ERROR(result) && status != ZETTIDE_NFS_OK)
		result = zettide_status(status);
	return result;
}

static void zettide_parent_attrs(struct zettide_fsal_handle *directory,
				 struct fsal_attrlist *attributes)
{
	struct zettide_nfs_attributes backend_attributes;
	if (attributes == NULL)
		return;
	if (zettide_nfs_getattr(directory->export->backend, &directory->wire,
				&backend_attributes) == ZETTIDE_NFS_OK) {
		zettide_fill_attrs(&directory->wire, &backend_attributes,
				   attributes);
	} else {
		attributes->valid_mask = ATTR_RDATTR_ERR;
	}
}

static fsal_status_t zettide_create_ids(const struct fsal_attrlist *attributes,
					uint32_t *owner, uint32_t *group)
{
	if ((FSAL_TEST_MASK(attributes->valid_mask, ATTR_OWNER) &&
	     attributes->owner > UINT32_MAX) ||
	    (FSAL_TEST_MASK(attributes->valid_mask, ATTR_GROUP) &&
	     attributes->group > UINT32_MAX))
		return fsalstat(ERR_FSAL_INVAL, EINVAL);
	*owner = FSAL_TEST_MASK(attributes->valid_mask, ATTR_OWNER)
			 ? (uint32_t)attributes->owner
			 : (uint32_t)op_ctx->creds.caller_uid;
	*group = FSAL_TEST_MASK(attributes->valid_mask, ATTR_GROUP)
			 ? (uint32_t)attributes->group
			 : (uint32_t)op_ctx->creds.caller_gid;
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_create_access(struct fsal_obj_handle *directory,
					   bool child_is_directory)
{
	fsal_accessflags_t access =
		FSAL_MODE_MASK_SET(FSAL_W_OK) | FSAL_MODE_MASK_SET(FSAL_X_OK) |
		FSAL_ACE4_MASK_SET(FSAL_ACE_PERM_EXECUTE) |
		FSAL_ACE4_MASK_SET(child_is_directory
					   ? FSAL_ACE_PERM_ADD_SUBDIRECTORY
					   : FSAL_ACE_PERM_ADD_FILE);

	return fsal_access(directory, access);
}

static fsal_status_t zettide_sticky_access(struct zettide_fsal_handle *directory,
					   struct zettide_fsal_handle *target)
{
	struct zettide_nfs_attributes directory_attrs;
	struct zettide_nfs_attributes target_attrs;
	uid_t caller = op_ctx->creds.caller_uid;
	int status;

	if (caller == 0)
		return fsalstat(ERR_FSAL_NO_ERROR, 0);
	status = zettide_nfs_getattr(directory->export->backend,
				     &directory->wire, &directory_attrs);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);
	if ((directory_attrs.mode & S_ISVTX) == 0)
		return fsalstat(ERR_FSAL_NO_ERROR, 0);
	status = zettide_nfs_getattr(target->export->backend, &target->wire,
				     &target_attrs);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);
	if (caller == directory_attrs.uid || caller == target_attrs.uid)
		return fsalstat(ERR_FSAL_NO_ERROR, 0);
	return fsalstat(ERR_FSAL_PERM, EPERM);
}

static fsal_status_t zettide_mkdir(struct fsal_obj_handle *dir_hdl,
				   const char *name,
				   struct fsal_attrlist *attrs_in,
				   struct fsal_obj_handle **new_obj,
				   struct fsal_attrlist *attrs_out,
				   struct fsal_attrlist *parent_pre_attrs_out,
				   struct fsal_attrlist *parent_post_attrs_out)
{
	struct zettide_fsal_handle *directory = zettide_handle(dir_hdl);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	struct zettide_fsal_handle *result;
	uint32_t owner;
	uint32_t group;
	fsal_status_t access;
	int status;

	*new_obj = NULL;
	access = zettide_create_ids(attrs_in, &owner, &group);
	if (FSAL_IS_ERROR(access))
		return access;
	access = zettide_create_access(dir_hdl, true);
	if (FSAL_IS_ERROR(access))
		return access;
	zettide_parent_attrs(directory, parent_pre_attrs_out);
	status = zettide_nfs_mkdir(directory->export->backend, &directory->wire,
				   name, strlen(name), attrs_in->mode, owner,
				   group, &wire, &attributes);
	zettide_parent_attrs(directory, parent_post_attrs_out);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	result = zettide_alloc_handle(directory->export, &wire, &attributes);
	*new_obj = &result->obj_handle;
	if (attrs_out != NULL)
		zettide_fill_attrs(&wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_symlink(
	struct fsal_obj_handle *dir_hdl, const char *name,
	const char *link_path, struct fsal_attrlist *attrs_in,
	struct fsal_obj_handle **new_obj, struct fsal_attrlist *attrs_out,
	struct fsal_attrlist *parent_pre_attrs_out,
	struct fsal_attrlist *parent_post_attrs_out)
{
	struct zettide_fsal_handle *directory = zettide_handle(dir_hdl);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	struct zettide_fsal_handle *result;
	uint32_t owner;
	uint32_t group;
	fsal_status_t access;
	int status;

	*new_obj = NULL;
	access = zettide_create_ids(attrs_in, &owner, &group);
	if (FSAL_IS_ERROR(access))
		return access;
	access = zettide_create_access(dir_hdl, false);
	if (FSAL_IS_ERROR(access))
		return access;
	zettide_parent_attrs(directory, parent_pre_attrs_out);
	status = zettide_nfs_symlink(directory->export->backend,
				     &directory->wire, name, strlen(name),
				     link_path, strlen(link_path), owner, group,
				     &wire, &attributes);
	zettide_parent_attrs(directory, parent_post_attrs_out);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	result = zettide_alloc_handle(directory->export, &wire, &attributes);
	*new_obj = &result->obj_handle;
	if (attrs_out != NULL)
		zettide_fill_attrs(&wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_readlink(struct fsal_obj_handle *obj_hdl,
				      utf8string *link_content, bool refresh)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	char *buffer = gsh_malloc(MAXPATHLEN + 1);
	size_t length = 0;
	int status;

	(void)refresh;
	status = zettide_nfs_readlink(handle->export->backend, &handle->wire,
				      buffer, MAXPATHLEN, &length);
	if (status != ZETTIDE_NFS_OK) {
		gsh_free(buffer);
		return zettide_status(status);
	}
	buffer[length] = '\0';
	link_content->utf8string_val = buffer;
	link_content->utf8string_len = length;
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_getattrs(struct fsal_obj_handle *obj_hdl,
				      struct fsal_attrlist *attrs_out)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	struct zettide_nfs_attributes attributes;
	int status = zettide_nfs_getattr(handle->export->backend, &handle->wire,
					 &attributes);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);
	zettide_fill_attrs(&handle->wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_setattr2(struct fsal_obj_handle *obj_hdl,
				      bool bypass, struct state_t *state,
				      struct fsal_attrlist *attrs_set)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	struct zettide_nfs_set_attributes changes = { 0 };
	struct zettide_nfs_attributes result;
	attrmask_t unsupported;
	int status;

	(void)bypass;
	(void)state;
	unsupported =
		attrs_set->valid_mask &
		~(ATTR_MODE | ATTR_OWNER | ATTR_GROUP | ATTR_SIZE | ATTR_ATIME |
		  ATTR_MTIME | ATTR_ATIME_SERVER | ATTR_MTIME_SERVER);
	if (unsupported != 0)
		return fsalstat(ERR_FSAL_NOTSUPP, ENOTSUP);

	if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_MODE)) {
		changes.mask |= ZETTIDE_NFS_SET_MODE;
		changes.mode = attrs_set->mode;
	}
	if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_OWNER)) {
		if (attrs_set->owner > UINT32_MAX)
			return fsalstat(ERR_FSAL_INVAL, EINVAL);
		changes.mask |= ZETTIDE_NFS_SET_UID;
		changes.uid = attrs_set->owner;
	}
	if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_GROUP)) {
		if (attrs_set->group > UINT32_MAX)
			return fsalstat(ERR_FSAL_INVAL, EINVAL);
		changes.mask |= ZETTIDE_NFS_SET_GID;
		changes.gid = attrs_set->group;
	}
	if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_SIZE)) {
		changes.mask |= ZETTIDE_NFS_SET_SIZE;
		changes.size = attrs_set->filesize;
	}
	if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_ATIME) ||
	    FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_ATIME_SERVER)) {
		changes.mask |= ZETTIDE_NFS_SET_ATIME;
		changes.atime_ns =
			FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_ATIME_SERVER)
				? zettide_now()
				: zettide_nanoseconds(attrs_set->atime);
	}
	if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_MTIME) ||
	    FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_MTIME_SERVER)) {
		changes.mask |= ZETTIDE_NFS_SET_MTIME;
		changes.mtime_ns =
			FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_MTIME_SERVER)
				? zettide_now()
				: zettide_nanoseconds(attrs_set->mtime);
	}

	status = zettide_nfs_setattr(handle->export->backend, &handle->wire,
				     &changes, &result);
	return zettide_status(status);
}

static fsal_status_t zettide_link(struct fsal_obj_handle *obj_hdl,
				  struct fsal_obj_handle *destdir_hdl,
				  const char *name,
				  struct fsal_attrlist *destdir_pre_attrs_out,
				  struct fsal_attrlist *destdir_post_attrs_out)
{
	struct zettide_fsal_handle *source = zettide_handle(obj_hdl);
	struct zettide_fsal_handle *directory = zettide_handle(destdir_hdl);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	int status;

	if (source->export != directory->export)
		return fsalstat(ERR_FSAL_XDEV, EXDEV);
	zettide_parent_attrs(directory, destdir_pre_attrs_out);
	status = zettide_nfs_link(source->export->backend, &source->wire,
				  &directory->wire, name, strlen(name), &wire,
				  &attributes);
	zettide_parent_attrs(directory, destdir_post_attrs_out);
	return zettide_status(status);
}

static fsal_status_t zettide_rename(struct fsal_obj_handle *obj_hdl,
				    struct fsal_obj_handle *olddir_hdl,
				    const char *old_name,
				    struct fsal_obj_handle *newdir_hdl,
				    const char *new_name,
				    struct fsal_attrlist *olddir_pre_attrs_out,
				    struct fsal_attrlist *olddir_post_attrs_out,
				    struct fsal_attrlist *newdir_pre_attrs_out,
				    struct fsal_attrlist *newdir_post_attrs_out)
{
	struct zettide_fsal_handle *source = zettide_handle(obj_hdl);
	struct zettide_fsal_handle *old_directory = zettide_handle(olddir_hdl);
	struct zettide_fsal_handle *new_directory = zettide_handle(newdir_hdl);
	struct fsal_obj_handle *destination_hdl = NULL;
	struct zettide_fsal_handle *destination = NULL;
	fsal_status_t access;
	int status;

	if (old_directory->export != new_directory->export ||
	    source->export != old_directory->export)
		return fsalstat(ERR_FSAL_XDEV, EXDEV);
	access = zettide_lookup(newdir_hdl, new_name, &destination_hdl, NULL);
	if (FSAL_IS_ERROR(access) && access.major != ERR_FSAL_NOENT)
		return access;
	if (destination_hdl != NULL)
		destination = zettide_handle(destination_hdl);
	access = zettide_create_access(olddir_hdl, obj_hdl->type == DIRECTORY);
	if (FSAL_IS_ERROR(access))
		goto out;
	access = zettide_create_access(newdir_hdl, obj_hdl->type == DIRECTORY);
	if (FSAL_IS_ERROR(access))
		goto out;
	access = zettide_sticky_access(old_directory, source);
	if (FSAL_IS_ERROR(access))
		goto out;
	if (destination != NULL) {
		access = zettide_sticky_access(new_directory, destination);
		if (FSAL_IS_ERROR(access))
			goto out;
	}
	zettide_parent_attrs(old_directory, olddir_pre_attrs_out);
	if (newdir_hdl != olddir_hdl)
		zettide_parent_attrs(new_directory, newdir_pre_attrs_out);
	status = zettide_nfs_rename(old_directory->export->backend,
				    &old_directory->wire, old_name,
				    strlen(old_name), &new_directory->wire,
				    new_name, strlen(new_name), false);
	zettide_parent_attrs(old_directory, olddir_post_attrs_out);
	if (newdir_hdl != olddir_hdl)
		zettide_parent_attrs(new_directory, newdir_post_attrs_out);
	access = zettide_status(status);
out:
	if (destination_hdl != NULL)
		destination_hdl->obj_ops->put_ref(destination_hdl);
	return access;
}

static fsal_status_t zettide_unlink(struct fsal_obj_handle *dir_hdl,
				    struct fsal_obj_handle *obj_hdl,
				    const char *name,
				    struct fsal_attrlist *parent_pre_attrs_out,
				    struct fsal_attrlist *parent_post_attrs_out)
{
	struct zettide_fsal_handle *directory = zettide_handle(dir_hdl);
	struct zettide_fsal_handle *target = zettide_handle(obj_hdl);
	fsal_status_t access;
	int status;

	if (directory->export != target->export)
		return fsalstat(ERR_FSAL_XDEV, EXDEV);
	access = zettide_create_access(dir_hdl, obj_hdl->type == DIRECTORY);
	if (FSAL_IS_ERROR(access))
		return access;
	access = zettide_sticky_access(directory, target);
	if (FSAL_IS_ERROR(access))
		return access;
	zettide_parent_attrs(directory, parent_pre_attrs_out);
	status = zettide_nfs_remove(directory->export->backend,
				    &directory->wire, name, strlen(name));
	zettide_parent_attrs(directory, parent_post_attrs_out);
	return zettide_status(status);
}

static fsal_status_t zettide_open_access(struct fsal_obj_handle *obj_hdl,
					 fsal_openflags_t openflags)
{
	fsal_accessflags_t access = 0;

	if (openflags & FSAL_O_READ)
		access |= FSAL_MODE_MASK_SET(FSAL_R_OK) |
			  FSAL_ACE4_MASK_SET(FSAL_ACE_PERM_READ_DATA);
	if (openflags & (FSAL_O_WRITE | FSAL_O_TRUNC))
		access |= FSAL_MODE_MASK_SET(FSAL_W_OK) |
			  FSAL_ACE4_MASK_SET(FSAL_ACE_PERM_WRITE_DATA);
	return fsal_access(obj_hdl, access);
}

static void zettide_create_changes(struct fsal_attrlist *attrs,
				   struct zettide_nfs_set_attributes *changes)
{
	if (FSAL_TEST_MASK(attrs->valid_mask, ATTR_SIZE)) {
		changes->mask |= ZETTIDE_NFS_SET_SIZE;
		changes->size = attrs->filesize;
	}
	if (FSAL_TEST_MASK(attrs->valid_mask, ATTR_ATIME) ||
	    FSAL_TEST_MASK(attrs->valid_mask, ATTR_ATIME_SERVER)) {
		changes->mask |= ZETTIDE_NFS_SET_ATIME;
		changes->atime_ns =
			FSAL_TEST_MASK(attrs->valid_mask, ATTR_ATIME_SERVER)
				? zettide_now()
				: zettide_nanoseconds(attrs->atime);
	}
	if (FSAL_TEST_MASK(attrs->valid_mask, ATTR_MTIME) ||
	    FSAL_TEST_MASK(attrs->valid_mask, ATTR_MTIME_SERVER)) {
		changes->mask |= ZETTIDE_NFS_SET_MTIME;
		changes->mtime_ns =
			FSAL_TEST_MASK(attrs->valid_mask, ATTR_MTIME_SERVER)
				? zettide_now()
				: zettide_nanoseconds(attrs->mtime);
	}
}

static fsal_status_t
zettide_open2(struct fsal_obj_handle *obj_hdl, struct state_t *state,
	      fsal_openflags_t openflags, enum fsal_create_mode createmode,
	      const char *name, struct fsal_attrlist *attrs_set,
	      fsal_verifier_t verifier, struct fsal_obj_handle **new_obj,
	      struct fsal_attrlist *attrs_out, bool *caller_perm_check,
	      struct fsal_attrlist *parent_pre_attrs_out,
	      struct fsal_attrlist *parent_post_attrs_out)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	struct zettide_fsal_handle *result;
	uint32_t mode = 0600;
	uint32_t uid = op_ctx->creds.caller_uid;
	uint32_t gid = op_ctx->creds.caller_gid;
	struct zettide_nfs_set_attributes changes = { 0 };
	struct fsal_attrlist exclusive_attrs = { 0 };
	struct fsal_attrlist verifier_attrs;
	fsal_status_t access;
	bool created = false;
	int status;

	(void)state;
	if (new_obj != NULL)
		*new_obj = NULL;
	if (name == NULL) {
		if (openflags & FSAL_O_TRUNC) {
			struct zettide_nfs_set_attributes changes = {
				.mask = ZETTIDE_NFS_SET_SIZE,
			};
			status = zettide_nfs_setattr(handle->export->backend,
						     &handle->wire, &changes,
						     &attributes);
			if (status != ZETTIDE_NFS_OK)
				return zettide_status(status);
		}
		*caller_perm_check = true;
		return fsalstat(ERR_FSAL_NO_ERROR, 0);
	}

	if (attrs_set != NULL) {
		if (FSAL_TEST_MASK(attrs_set->valid_mask, ATTR_MODE))
			mode = attrs_set->mode;
		access = zettide_create_ids(attrs_set, &uid, &gid);
		if (FSAL_IS_ERROR(access))
			return access;
	}
	if (createmode >= FSAL_EXCLUSIVE && createmode != FSAL_EXCLUSIVE_9P) {
		if (attrs_set == NULL)
			attrs_set = &exclusive_attrs;
		set_common_verifier(attrs_set, verifier, false);
	}
	zettide_parent_attrs(handle, parent_pre_attrs_out);
	status = zettide_nfs_lookup(handle->export->backend, &handle->wire,
				    name, strlen(name), &wire, &attributes);
	if (status == ZETTIDE_NFS_NO_ENTRY) {
		if (createmode == FSAL_NO_CREATE)
			goto done;
		access = zettide_create_access(obj_hdl, false);
		if (FSAL_IS_ERROR(access))
			return access;
		status = zettide_nfs_create(handle->export->backend,
					    &handle->wire, name, strlen(name),
					    mode, uid, gid, &wire, &attributes);
		created = status == ZETTIDE_NFS_OK;
		if (created && attrs_set != NULL) {
			zettide_create_changes(attrs_set, &changes);
			if (changes.mask != 0) {
				status = zettide_nfs_setattr(
					handle->export->backend, &wire,
					&changes, &attributes);
				if (status != ZETTIDE_NFS_OK) {
					(void)zettide_nfs_remove(
						handle->export->backend,
						&handle->wire, name,
						strlen(name));
					created = false;
				}
			}
		}
	} else if (status == ZETTIDE_NFS_OK && createmode >= FSAL_EXCLUSIVE &&
		   createmode != FSAL_EXCLUSIVE_9P) {
		fsal_prepare_attrs(&verifier_attrs, ATTR_ATIME | ATTR_MTIME);
		zettide_fill_attrs(&wire, &attributes, &verifier_attrs);
		if (!check_verifier_attrlist(&verifier_attrs, verifier, false))
			status = ZETTIDE_NFS_EXISTS;
		fsal_release_attrs(&verifier_attrs);
	} else if (status == ZETTIDE_NFS_OK && createmode >= FSAL_GUARDED) {
		status = ZETTIDE_NFS_EXISTS;
	}
done:
	zettide_parent_attrs(handle, parent_post_attrs_out);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	result = zettide_alloc_handle(handle->export, &wire, &attributes);
	if (!created && (openflags & FSAL_O_TRUNC)) {
		access = zettide_open_access(&result->obj_handle, openflags);
		if (FSAL_IS_ERROR(access)) {
			result->obj_handle.obj_ops->put_ref(
				&result->obj_handle);
			return access;
		}
		memset(&changes, 0, sizeof(changes));
		changes.mask = ZETTIDE_NFS_SET_SIZE;
		status = zettide_nfs_setattr(handle->export->backend, &wire,
					     &changes, &attributes);
		if (status != ZETTIDE_NFS_OK) {
			result->obj_handle.obj_ops->put_ref(
				&result->obj_handle);
			return zettide_status(status);
		}
	}
	*new_obj = &result->obj_handle;
	*caller_perm_check = !created;
	if (attrs_out != NULL)
		zettide_fill_attrs(&wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static void zettide_release_read_buffer(void *buffer)
{
	free(buffer);
}

static void zettide_read2(struct fsal_obj_handle *obj_hdl, bool bypass,
			  fsal_async_cb done_cb, struct fsal_io_arg *read_arg,
			  void *caller_arg)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	fsal_status_t result = fsalstat(ERR_FSAL_NO_ERROR, 0);
	uint64_t offset = read_arg->offset;
	int index;

	(void)bypass;
	read_arg->io_amount = 0;
	read_arg->end_of_file = false;
	if (read_arg->info != NULL) {
		result = fsalstat(ERR_FSAL_NOTSUPP, ENOTSUP);
		goto done;
	}
	if (read_arg->iov[0].iov_base == NULL) {
		void *buffer = NULL;
		int status;

		if (read_arg->iov_count != 1) {
			result = fsalstat(ERR_FSAL_NOTSUPP, ENOTSUP);
			goto done;
		}
		status = posix_memalign(&buffer, 4096,
					read_arg->iov[0].iov_len);

		if (status != 0) {
			result = posix2fsal_status(status);
			goto done;
		}
		read_arg->iov[0].iov_base = buffer;
		read_arg->iov_release = zettide_release_read_buffer;
		read_arg->release_data = buffer;
	}
	for (index = 0; index < read_arg->iov_count; index++) {
		size_t amount = 0;
		size_t length = read_arg->iov[index].iov_len;
		int status = zettide_nfs_read(handle->export->backend,
					      &handle->wire, offset,
					      read_arg->iov[index].iov_base,
					      length, &amount);
		if (status != ZETTIDE_NFS_OK) {
			result = zettide_status(status);
			goto done;
		}
		read_arg->io_amount += amount;
		offset += amount;
		if (amount < length) {
			read_arg->end_of_file = true;
			break;
		}
	}
done:
	done_cb(obj_hdl, result, read_arg, caller_arg);
}

static void zettide_wait_for_stable_backlog(
	struct zettide_fsal_export *export, uint64_t target_ticket,
	uint64_t generation, uint32_t microseconds)
{
	struct timespec deadline;
	uint64_t nanoseconds;
	int status;

	if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0)
		return;
	nanoseconds = (uint64_t)deadline.tv_nsec +
		      (uint64_t)microseconds * 1000;
	deadline.tv_sec += nanoseconds / 1000000000;
	deadline.tv_nsec = nanoseconds % 1000000000;
	while (export->stable_serving_ticket != target_ticket &&
	       generation == export->stable_generation &&
	       export->stable_syncing) {
		status = pthread_cond_timedwait(&export->stable_cond,
						&export->stable_mutex, &deadline);
		if (status != 0)
			break;
	}
}

static void zettide_complete_stable_batch(struct zettide_fsal_export *export,
					  int status)
{
	export->stable_status = status;
	export->stable_generation++;
	if (status == ZETTIDE_NFS_OK)
		export->stable_success_generation = export->stable_generation;
	export->stable_syncing = false;
	__atomic_store_n(&export->stable_accepting_generation, 0,
			 __ATOMIC_RELEASE);
	pthread_cond_broadcast(&export->stable_cond);
}

static int zettide_stable_batch_status(struct zettide_fsal_export *export,
				       uint64_t target_generation)
{
	return export->stable_success_generation >= target_generation
		       ? ZETTIDE_NFS_OK
		       : export->stable_status;
}

static void zettide_write2(struct fsal_obj_handle *obj_hdl, bool bypass,
			   fsal_async_cb done_cb, struct fsal_io_arg *write_arg,
			   void *caller_arg)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	struct zettide_fsal_export *export = handle->export;
	fsal_status_t result = fsalstat(ERR_FSAL_NO_ERROR, 0);
	uint64_t offset = write_arg->offset;
	uint64_t stable_ticket = 0;
	bool stable_requested = write_arg->fsal_stable;
	bool stable_locked = false;
	int index;

	(void)bypass;
	write_arg->io_amount = 0;
	write_arg->fsal_stable = false;
	if (stable_requested) {
		stable_ticket = __atomic_fetch_add(
			&handle->export->stable_next_ticket, 1, __ATOMIC_RELAXED);
		pthread_mutex_lock(&handle->export->stable_mutex);
		stable_locked = true;
		while (stable_ticket != handle->export->stable_serving_ticket ||
		       (handle->export->stable_syncing &&
			(__atomic_load_n(
				 &handle->export->stable_accepting_generation,
				 __ATOMIC_ACQUIRE) !=
				 handle->export->stable_generation + 1 ||
			 stable_ticket ==
				 handle->export->stable_accepting_until_ticket)))
			pthread_cond_wait(&handle->export->stable_cond,
					  &handle->export->stable_mutex);
		handle->export->stable_serving_ticket++;
		pthread_cond_broadcast(&handle->export->stable_cond);
		handle->export->stable_writes++;
	} else {
		__atomic_add_fetch(&handle->export->unstable_writes, 1,
				   __ATOMIC_RELAXED);
	}
	for (index = 0; index < write_arg->iov_count; index++) {
		size_t amount = 0;
		int status = zettide_nfs_write(handle->export->backend,
					       &handle->wire, offset,
					       write_arg->iov[index].iov_base,
					       write_arg->iov[index].iov_len,
					       &amount);
		if (status != ZETTIDE_NFS_OK) {
			result = zettide_status(status);
			break;
		}
		write_arg->io_amount += amount;
		offset += amount;
		if (amount != write_arg->iov[index].iov_len)
			break;
	}
	if (!FSAL_IS_ERROR(result) && stable_requested) {
		uint64_t generation = handle->export->stable_generation;
		uint64_t target_generation = generation + 1;
		int status;

		if (!handle->export->stable_syncing) {
			uint64_t target_ticket = __atomic_load_n(
				&handle->export->stable_next_ticket,
				__ATOMIC_RELAXED);

			handle->export->stable_syncing = true;
			handle->export->stable_batches++;
			if (handle->export->stable_write_batch_us != 0 &&
			    target_ticket !=
				    handle->export->stable_serving_ticket) {
				uint64_t *accepting_generation =
					&export->stable_accepting_generation;
				uint64_t expected_generation = target_generation;

				handle->export->stable_accepting_until_ticket =
					target_ticket;
				__atomic_store_n(accepting_generation,
						 target_generation, __ATOMIC_RELEASE);
				zettide_wait_for_stable_backlog(
					handle->export, target_ticket, generation,
					handle->export->stable_write_batch_us);
				__atomic_compare_exchange_n(accepting_generation,
							    &expected_generation, 0,
							    false, __ATOMIC_RELEASE,
							    __ATOMIC_RELAXED);
			}
			if (generation == handle->export->stable_generation &&
			    handle->export->stable_syncing) {
				status = zettide_nfs_sync(handle->export->backend);
				handle->export->stable_syncs++;
				zettide_complete_stable_batch(handle->export,
							      status);
			} else {
				status = zettide_stable_batch_status(
					handle->export, target_generation);
			}
		} else {
			handle->export->stable_joins++;
			while (generation == handle->export->stable_generation)
				pthread_cond_wait(&handle->export->stable_cond,
						  &handle->export->stable_mutex);
			status = zettide_stable_batch_status(
				handle->export, target_generation);
		}
		if (status != ZETTIDE_NFS_OK)
			result = zettide_status(status);
		else
			write_arg->fsal_stable = true;
	}
	if (stable_locked)
		pthread_mutex_unlock(&handle->export->stable_mutex);
	done_cb(obj_hdl, result, write_arg, caller_arg);
}

static fsal_status_t zettide_commit2(struct fsal_obj_handle *obj_hdl,
				     off_t offset, size_t length)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	int status;

	(void)offset;
	(void)length;
	pthread_mutex_lock(&handle->export->stable_mutex);
	handle->export->commit_calls++;
	if (handle->export->stable_syncing)
		__atomic_store_n(&handle->export->stable_accepting_generation, 0,
				 __ATOMIC_RELEASE);
	status = zettide_nfs_sync(handle->export->backend);
	if (handle->export->stable_syncing) {
		handle->export->stable_syncs++;
		zettide_complete_stable_batch(handle->export, status);
	}
	pthread_mutex_unlock(&handle->export->stable_mutex);
	return zettide_status(status);
}

static fsal_status_t zettide_close(struct fsal_obj_handle *obj_hdl)
{
	(void)obj_hdl;
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_handle_to_wire(
	const struct fsal_obj_handle *obj_hdl, fsal_digesttype_t output_type,
	struct gsh_buffdesc *fh_desc)
{
	const struct zettide_fsal_handle *handle =
		container_of(obj_hdl, const struct zettide_fsal_handle,
			     obj_handle);
	if (output_type != FSAL_DIGEST_NFSV3 &&
	    output_type != FSAL_DIGEST_NFSV4)
		return fsalstat(ERR_FSAL_SERVERFAULT, EINVAL);
	if (fh_desc->len < sizeof(handle->wire))
		return fsalstat(ERR_FSAL_TOOSMALL, ERANGE);
	memcpy(fh_desc->addr, &handle->wire, sizeof(handle->wire));
	fh_desc->len = sizeof(handle->wire);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static void zettide_handle_to_key(struct fsal_obj_handle *obj_hdl,
				  struct gsh_buffdesc *fh_desc)
{
	struct zettide_fsal_handle *handle = zettide_handle(obj_hdl);
	fh_desc->addr = &handle->wire;
	fh_desc->len = sizeof(handle->wire);
}

void zettide_handle_ops_init(struct fsal_obj_ops *ops)
{
	fsal_default_obj_ops_init(ops);
	ops->release = zettide_release;
	ops->lookup = zettide_lookup;
	ops->readdir = zettide_readdir;
	ops->mkdir = zettide_mkdir;
	ops->symlink = zettide_symlink;
	ops->readlink = zettide_readlink;
	ops->getattrs = zettide_getattrs;
	ops->setattr2 = zettide_setattr2;
	ops->link = zettide_link;
	ops->rename = zettide_rename;
	ops->unlink = zettide_unlink;
	ops->close = zettide_close;
	ops->open2 = zettide_open2;
	ops->read2 = zettide_read2;
	ops->write2 = zettide_write2;
	ops->commit2 = zettide_commit2;
	ops->handle_to_wire = zettide_handle_to_wire;
	ops->handle_to_key = zettide_handle_to_key;
}
